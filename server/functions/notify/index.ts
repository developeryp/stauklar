// Stauklar Push-Server (Supabase Edge Function).
// Läuft alle 15 Minuten per pg_cron. Zwei Aufgaben:
//  1. Sofortmeldung: neue Vollsperrung heute auf einer Lieblingsstrecke → Push innerhalb von 15 Minuten.
//  2. Morgenlage zur Wunschzeit des Geräts (Standard 06:30 Ortszeit): ein Push mit allen Sperrungen heute auf den eigenen Strecken.
// Geheimnisse (APNs-Schlüssel, Cron-Secret) liegen im Supabase Vault, abrufbar über public.get_secret().

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE = "https://stauklar.de/api/v1";
const TOPIC = "de.stauklar.app";
const TEAM_ID = "6AY5V43PJ2";

type Device = { token: string; env: string; roads: string[]; tz: string; digest_time?: string };
type Item = { id: string; title: string; sev: string; label: string; heute: boolean; active: boolean; when: string; start: string | null };
type Road = { id: string; items: Item[] };

// ---------- Supabase (REST mit Service-Role) ----------
const sb = (path: string, init: RequestInit = {}) =>
  fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });

async function secret(name: string): Promise<string> {
  const r = await sb("rpc/get_secret", { method: "POST", body: JSON.stringify({ name }) });
  if (!r.ok) throw new Error(`Secret ${name} fehlt (${r.status})`);
  const v = await r.json();
  if (!v) throw new Error(`Secret ${name} ist leer`);
  return v as string;
}

// ---------- APNs ----------
const b64url = (b: ArrayBuffer | string) => {
  const bytes = typeof b === "string" ? new TextEncoder().encode(b) : new Uint8Array(b);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function apnsToken(pem: string, keyId: string): Promise<string> {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: TEAM_ID, iat: Math.floor(Date.now() / 1000) }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
  return `${header}.${claims}.${b64url(sig)}`;
}

async function push(jwt: string, d: Device, title: string, body: string, road: string): Promise<"ok" | "gone" | "error"> {
  const host = d.env === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const r = await fetch(`https://${host}/3/device/${d.token}`, {
    method: "POST",
    headers: { authorization: `bearer ${jwt}`, "apns-topic": TOPIC, "apns-push-type": "alert", "apns-priority": "10" },
    body: JSON.stringify({ aps: { alert: { title, body }, sound: "default", "thread-id": road }, road }),
  });
  if (r.ok) return "ok";
  const txt = await r.text();
  console.warn("APNs", r.status, txt);
  return r.status === 410 || txt.includes("BadDeviceToken") || txt.includes("Unregistered") ? "gone" : "error";
}

// ---------- Daten ----------
const roadCache = new Map<string, Promise<Road | null>>();
function road(id: string): Promise<Road | null> {
  if (!roadCache.has(id)) {
    roadCache.set(id, fetch(`${SITE}/road/${id.toLowerCase()}.json`).then((r) => (r.ok ? r.json() : null)).catch(() => null));
  }
  return roadCache.get(id)!;
}

const closures = (r: Road) => r.items.filter((i) => i.heute && (i.sev === "voll" || i.sev === "sperr"));
const key = (r: string, i: Item) => `${r}/${i.id}/${i.start ?? ""}`;

function localNow(tz: string) {
  const parts = new Intl.DateTimeFormat("de-DE", { timeZone: tz || "Europe/Berlin", hour: "2-digit", minute: "2-digit", year: "numeric", month: "2-digit", day: "2-digit", hour12: false })
    .formatToParts(new Date()).reduce((o, p) => ({ ...o, [p.type]: p.value }), {} as Record<string, string>);
  return { hour: +parts.hour % 24, minute: +parts.minute, date: `${parts.year}-${parts.month}-${parts.day}` };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const force = url.searchParams.get("force"); // "digest" zum Testen
  const cronSecret = await secret("cron_secret");
  if (req.headers.get("x-cron-secret") !== cronSecret) return new Response("Nicht erlaubt", { status: 401 });

  const devices = (await (await sb("devices?select=token,env,roads,tz,digest_time")).json()) as Device[];
  const stats = { devices: devices.length, pushed: 0, removed: 0, errors: 0, skipped: 0 };
  if (!devices.some((d) => d.roads?.length)) return Response.json(stats);

  let jwt: string;
  try {
    const [pem, keyId] = await Promise.all([secret("apns_key"), secret("apns_key_id")]);
    jwt = await apnsToken(pem, keyId);
  } catch (e) {
    return Response.json({ ...stats, error: `APNs nicht konfiguriert: ${(e as Error).message}` }, { status: 500 });
  }
  const sentRows = (await (await sb("sent?select=token,key")).json()) as { token: string; key: string }[];
  const sent = new Set(sentRows.map((s) => `${s.token}|${s.key}`));

  for (const d of devices) {
    if (!d.roads?.length) { stats.skipped++; continue; }
    const now = localNow(d.tz);
    const digestKey = `digest/${now.date}`;
    // Wunschzeit des Geräts (z. B. „06:30“); der Lauf alle 15 Minuten trifft das Fenster [Zeit, Zeit+15)
    const [dh, dm] = (d.digest_time || "06:30").split(":").map(Number);
    const minutesNow = now.hour * 60 + now.minute, minutesWanted = (dh || 6) * 60 + (dm || 0);
    const digestTime = force === "digest" || (minutesNow >= minutesWanted && minutesNow < minutesWanted + 15);
    const newSent: string[] = [];
    const messages: { title: string; body: string; road: string }[] = [];
    const digestLines: string[] = [];
    // Neues Gerät: bestehende Vollsperrungen nur merken, nicht melden (sonst kommt beim Einschalten ein Schwall alter Meldungen)
    const isNew = !sentRows.some((s) => s.token === d.token);

    for (const rid of d.roads) {
      const r = await road(rid);
      if (!r) continue;
      const cl = closures(r);
      for (const it of cl) {
        const k = key(rid, it);
        if (it.sev === "voll" && !sent.has(`${d.token}|${k}`)) {
          if (!isNew) messages.push({ title: `${rid} voll gesperrt`, body: `${it.title}, ${it.when}`, road: rid });
          newSent.push(k);
        }
      }
      if (cl.length) {
        const first = cl[0];
        digestLines.push(`${rid}: ${cl.length} ${cl.length === 1 ? "Sperrung" : "Sperrungen"} heute, z. B. ${first.title} (${first.when})`);
      }
    }

    if (digestTime && digestLines.length && !sent.has(`${d.token}|${digestKey}`)) {
      messages.push({ title: "Deine Strecken heute", body: digestLines.join("\n"), road: d.roads[0] });
      newSent.push(digestKey);
    }

    let gone = false;
    for (const m of messages) {
      const res = await push(jwt, d, m.title, m.body, m.road);
      if (res === "ok") stats.pushed++;
      else if (res === "gone") { gone = true; break; }
      else stats.errors++;
    }
    if (gone) {
      await sb(`devices?token=eq.${encodeURIComponent(d.token)}`, { method: "DELETE" });
      stats.removed++;
      continue;
    }
    if (newSent.length) {
      await sb("sent", { method: "POST", headers: { Prefer: "resolution=ignore-duplicates" },
        body: JSON.stringify(newSent.map((k) => ({ token: d.token, key: k }))) });
    }
  }
  await sb(`sent?sent_at=lt.${new Date(Date.now() - 14 * 864e5).toISOString()}`, { method: "DELETE" });
  return Response.json(stats);
});
