// Stauklar Push-Server (Supabase Edge Function).
// Läuft jede Minute per pg_cron. Zwei Aufgaben:
//  1. Sofortmeldung: neue Vollsperrung (oder, wenn gewählt, jede neue Meldung) heute auf einer Lieblingsstrecke → Push.
//  2. Morgenlage genau zur Wunschzeit des Geräts (Standard 06:30 Ortszeit): jeden Tag ein Push mit der Lage auf allen eigenen Strecken, auch wenn dort nichts gesperrt ist.
// Geheimnisse (APNs-Schlüssel, Cron-Secret) liegen im Supabase Vault, abrufbar über public.get_secret().

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE = "https://stauklar.de/api/v1";
const TOPIC = "de.stauklar.app";
const TEAM_ID = "6AY5V43PJ2";

type Device = { token: string; env: string; roads: string[]; tz: string; digest_time?: string; digest_on?: boolean; alerts_on?: boolean; alerts_all?: boolean; alert_kinds?: string[] | null };
type Item = { id: string; title: string; sev: string; label: string; heute: boolean; active: boolean; when: string; start: string | null };
type Group = { title: string; sev: string; label: string; heute: boolean; when: string; start: string | null; items?: string[] };
type Warn = { title: string; dir: string; text: string[] };
type Road = { id: string; items: Item[]; groups?: Group[]; warns?: Warn[] };

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

// road/item: beim Antippen öffnet die App diese Autobahn bzw. genau diese Meldung; ohne road die Startseite
async function push(jwt: string, d: Device, title: string, body: string, road?: string, item?: string, itemTitle?: string): Promise<"ok" | "gone" | "error"> {
  const host = d.env === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const r = await fetch(`https://${host}/3/device/${d.token}`, {
    method: "POST",
    headers: { authorization: `bearer ${jwt}`, "apns-topic": TOPIC, "apns-push-type": "alert", "apns-priority": "10" },
    body: JSON.stringify({ aps: { alert: { title, body }, sound: "default", "thread-id": road ?? "digest" }, road, item, title: itemTitle }),
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
// Über den Titel, nicht die Nummer: die Nummern werden bei jedem Datenabruf neu vergeben
const key = (r: string, i: Item) => `v/${r}/${i.title}/${i.start ?? ""}`;

// „…, seit 12.10.2026, 14:05“ → Zeitpunkt (deutsche Ortszeit), sonst null
function startedAt(line: string): number | null {
  const m = line.match(/seit (\d{2})\.(\d{2})\.(\d{4}), (\d{2}):(\d{2})/);
  if (!m) return null;
  const [, dd, mm, yyyy, hh, mi] = m;
  const guess = Date.UTC(+yyyy, +mm - 1, +dd, +hh, +mi);
  // Versatz von Europe/Berlin zu UTC zu diesem Zeitpunkt (Sommer-/Winterzeit)
  const p = new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Berlin", hour12: false, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })
    .formatToParts(new Date(guess)).reduce((o, x) => ({ ...o, [x.type]: x.value }), {} as Record<string, string>);
  const asBerlin = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute);
  return guess - (asBerlin - guess);
}

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

  const devices = (await (await sb("devices?select=token,env,roads,tz,digest_time,digest_on,alerts_on,alerts_all,alert_kinds")).json()) as Device[];
  const stats = { devices: devices.length, pushed: 0, removed: 0, errors: 0, skipped: 0 };
  if (!devices.some((d) => d.roads?.length)) return Response.json(stats);

  let jwt: string;
  try {
    const [pem, keyId] = await Promise.all([secret("apns_key"), secret("apns_key_id")]);
    jwt = await apnsToken(pem, keyId);
  } catch (e) {
    return Response.json({ ...stats, error: `APNs nicht konfiguriert: ${(e as Error).message}` }, { status: 500 });
  }
  // Testnachricht an alle Geräte: erste Meldung der ersten eigenen Strecke, Antippen öffnet sie
  if (force === "test") {
    for (const d of devices.filter((d) => d.roads?.length)) {
      let sentOne = false;
      for (const rid of d.roads) {
        const r = await road(rid);
        const g = r?.groups?.find((g) => g.heute && g.sev !== "dauer") ?? r?.groups?.[0];
        if (!r || !g) continue;
        const res = await push(jwt, d, `Test: ${rid} – ${g.label}`, `${g.title}, ${g.when}. Antippen öffnet die Meldung.`, rid, g.items?.[0], g.title);
        if (res === "ok") stats.pushed++; else stats.errors++;
        sentOne = true;
        break;
      }
      if (!sentOne) stats.skipped++;
    }
    return Response.json(stats);
  }
  // Seitenweise lesen: die REST-Schnittstelle liefert höchstens 1000 Zeilen je Abfrage. Ohne das galt alles
  // darüber als „neu“ und wurde jede Minute erneut verschickt.
  const sentRows: { token: string; key: string; sent_at: string }[] = [];
  for (let off = 0; ; off += 1000) {
    const r = await sb(`sent?select=token,key,sent_at&order=token.asc,key.asc&limit=1000&offset=${off}`);
    if (!r.ok) return Response.json({ ...stats, error: `sent nicht lesbar (${r.status})` }, { status: 500 });
    const rows = (await r.json()) as { token: string; key: string; sent_at: string }[];
    if (!rows.length) break;
    sentRows.push(...rows);
  }
  const sent = new Set(sentRows.map((s) => `${s.token}|${s.key}`));
  // Was noch aktuell ist, darf beim Aufräumen nach 14 Tagen nicht verschwinden (sonst käme es erneut als „neu“)
  const stale = new Set(sentRows.filter((s) => Date.parse(s.sent_at) < Date.now() - 7 * 864e5).map((s) => `${s.token}|${s.key}`));
  const refresh: { token: string; key: string; sent_at: string }[] = [];
  const seen = (token: string, k: string) => { if (stale.has(`${token}|${k}`)) refresh.push({ token, key: k, sent_at: new Date().toISOString() }); };

  for (const d of devices) {
    if (!d.roads?.length) { stats.skipped++; continue; }
    const now = localNow(d.tz);
    const digestKey = `digest/${now.date}`;
    // Wunschzeit des Geräts (z. B. „06:30“): genau in dieser Minute; bis 10 Minuten Nachholfrist, falls ein Lauf ausfiel
    const [dh, dm] = (d.digest_time || "06:30").split(":").map(Number);
    const minutesNow = now.hour * 60 + now.minute, minutesWanted = (dh || 6) * 60 + (dm || 0);
    const digestTime = force === "digest" || (minutesNow >= minutesWanted && minutesNow < minutesWanted + 10);
    const newSent: string[] = [];
    const messages: { title: string; body: string; road?: string; item?: string; itemTitle?: string }[] = [];
    const digestLines: string[] = [];
    // Neues Gerät: bestehende Vollsperrungen nur merken, nicht melden (sonst kommt beim Einschalten ein Schwall alter Meldungen)
    const isNew = !sentRows.some((s) => s.token === d.token);

    // Gewählte Arten (voll, sperr, kurz, dauer, live); ältere App-Versionen schicken nur alerts_on/alerts_all
    const kinds = new Set(d.alert_kinds ?? (d.alerts_on === false ? [] : d.alerts_all ? ["voll", "sperr", "kurz", "dauer", "live"] : ["voll"]));
    // Art gerade erst gewählt: Bestehendes nur merken, nicht melden (Merker k/<art>/_)
    const fresh0 = (k: string) => !sent.has(`${d.token}|k/${k}/_`);
    for (const k of kinds) { if (k !== "voll" && fresh0(k)) newSent.push(`k/${k}/_`); seen(d.token, `k/${k}/_`); }
    // Umstellung der Vollsperrungs-Schlüssel: einmal still merken
    const vSeed = fresh0("v");
    if (vSeed) newSent.push("k/v/_");
    seen(d.token, "k/v/_");

    for (const rid of d.roads) {
      const r = await road(rid);
      if (!r) continue;
      // Neue Meldungen der gewählten Arten (außer Vollsperrung, die läuft unten wie bisher)
      const fresh: string[] = [];
      let freshItem: string | undefined, freshTitle: string | undefined;
      for (const g of (r.groups ?? []).filter((g) => g.heute && g.sev !== "voll" && kinds.has(g.sev))) {
        // Je Maßnahme einmal, nicht bei jedem Termin einer wiederkehrenden Baustelle
        const k = `k/${g.sev}/${rid}/${g.title}`;
        seen(d.token, k);
        if (!sent.has(`${d.token}|${k}`)) { newSent.push(k); if (!fresh0(g.sev)) { fresh.push(`${g.label}: ${g.title}, ${g.when}`); freshItem = g.items?.[0]; freshTitle = g.title; } }
      }
      if (kinds.has("live")) {
        // Staus kommen und gehen minütlich. Gemeldet wird nur, was wirklich gerade erst begonnen hat (≤ 30 Min.),
        // und höchstens eine Stau-Nachricht je Autobahn und halber Stunde. Ältere Staus werden nur still gemerkt.
        const slot = `p/live/${rid}/${Math.floor(Date.now() / 18e5)}`;
        const quiet = sent.has(`${d.token}|${slot}`);
        let added = false;
        for (const w of r.warns ?? []) {
          const k = `k/live/${rid}/${w.title}/${w.dir}/${w.text?.[0] ?? ""}`;
          seen(d.token, k);
          if (sent.has(`${d.token}|${k}`)) continue;
          newSent.push(k);
          const since = startedAt(w.text?.[0] ?? "");
          const recent = since !== null && Date.now() - since <= 30 * 60e3;
          if (!fresh0("live") && recent && !quiet) { fresh.push(`${w.text?.[0]?.split(",")[0] || "Stau oder Gefahr"}: ${w.title}`); added = true; }
        }
        if (added) newSent.push(slot);
      }
      if (fresh.length && !isNew) {
        messages.push(fresh.length === 1
          ? { title: `${rid}: neue Meldung`, body: fresh[0], road: rid, item: freshItem, itemTitle: freshTitle }
          : { title: `${rid}: ${fresh.length} neue Meldungen`, body: fresh.slice(0, 4).join("\n") + (fresh.length > 4 ? `\nund ${fresh.length - 4} weitere` : ""), road: rid });
      }
      const cl = closures(r);
      for (const it of cl) {
        const k = key(rid, it);
        seen(d.token, k);
        if (it.sev === "voll" && !sent.has(`${d.token}|${k}`)) {
          if (!isNew && !vSeed && kinds.has("voll")) messages.push({ title: `${rid} voll gesperrt`, body: `${it.title}, ${it.when}`, road: rid, item: it.id, itemTitle: it.title });
          newSent.push(k);
        }
      }
      // Morgenlage: jede Strecke bekommt eine Zeile, auch wenn dort nichts gesperrt ist
      const today = (r.groups ?? []).filter((g) => g.heute);
      const n = (sev: string) => today.filter((g) => g.sev === sev).length;
      const nVoll = n("voll"), nSperr = n("sperr"), nKurz = n("kurz"), nDauer = n("dauer"), nLive = (r.warns ?? []).length;
      const parts: string[] = [];
      if (nVoll) parts.push(`${nVoll} ${nVoll === 1 ? "Vollsperrung" : "Vollsperrungen"}`);
      if (nSperr) parts.push(`${nSperr} ${nSperr === 1 ? "Auf-/Abfahrt zu" : "Auf-/Abfahrten zu"}`);
      if (nKurz) parts.push(`${nKurz} ${nKurz === 1 ? "Baustelle" : "Baustellen"}`);
      if (nLive) parts.push(`${nLive} ${nLive === 1 ? "Stau/Gefahr" : "Staus/Gefahren"}`);
      if (nDauer) parts.push(`${nDauer} ${nDauer === 1 ? "Dauerbaustelle" : "Dauerbaustellen"}`);
      const firstVoll = today.find((g) => g.sev === "voll");
      digestLines.push(!parts.length ? `${rid}: frei, nichts gemeldet`
        : !nVoll && !nSperr && !nKurz && !nLive ? `${rid}: keine Sperrungen, ${parts.join(", ")}`
        : `${rid}: ${parts.join(", ")}${firstVoll ? ` – z. B. ${firstVoll.title} (${firstVoll.when})` : ""}`);
    }

    if (digestTime && d.digest_on !== false && digestLines.length && !sent.has(`${d.token}|${digestKey}`)) {
      messages.push({ title: "Deine Strecken heute", body: digestLines.join("\n") });
      newSent.push(digestKey);
    }

    // Notbremse: höchstens 3 Nachrichten je Gerät und Lauf, egal was oben schiefgeht
    let gone = false;
    for (const m of messages.slice(0, 3)) {
      const res = await push(jwt, d, m.title, m.body, m.road, m.item, m.itemTitle);
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
      // Fehlschlag beim Merken heißt: beim nächsten Lauf käme alles erneut. Dann lieber laut scheitern.
      const ins = await sb("sent", { method: "POST", headers: { Prefer: "resolution=ignore-duplicates" },
        body: JSON.stringify(newSent.map((k) => ({ token: d.token, key: k }))) });
      if (!ins.ok) console.error("sent speichern fehlgeschlagen", ins.status, await ins.text());
    }
  }
  if (refresh.length) {
    await sb("sent?on_conflict=token,key", { method: "POST", headers: { Prefer: "resolution=merge-duplicates" }, body: JSON.stringify(refresh) });
  }
  await sb(`sent?sent_at=lt.${new Date(Date.now() - 14 * 864e5).toISOString()}`, { method: "DELETE" });
  return Response.json(stats);
});
