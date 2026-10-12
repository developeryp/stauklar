// Startseite: Suche nach Autobahn, Stadt oder Anschlussstelle + Umkreisansicht („rund um Berlin“, „in meiner Nähe“).
(function () {
  const AB = window.AB;
  const q = document.getElementById('q');
  const box = document.getElementById('sugg');
  const panel = document.getElementById('nah');
  const locBtn = document.getElementById('locate');
  if (!q || !box || !AB) return;
  const { esc, norm, km } = AB;
  const B = AB.base || '';
  let sel = -1, results = [];

  // ---------- Vorschläge ----------
  function render() {
    box.innerHTML = results.map((r, i) => `<li role="option" id="o${i}" aria-selected="${i === sel}">${r.html}</li>`).join('');
    box.hidden = results.length === 0;
    q.setAttribute('aria-expanded', String(!box.hidden));
    if (sel >= 0) q.setAttribute('aria-activedescendant', 'o' + sel); else q.removeAttribute('aria-activedescendant');
  }

  async function update() {
    const v = q.value.trim();
    sel = -1;
    if (!v) { results = []; return render(); }
    const { roads, cities, places } = await AB.index();
    const n = norm(v).replace(/\s+/g, '');
    const asRoad = n.replace(/^a?(?=\d)/, 'a');
    const nv = norm(v);
    results = [];
    if (/^a\d/.test(asRoad)) {
      for (const [r, st] of roads) {
        if (r.toLowerCase().startsWith(asRoad)) {
          results.push({ href: `${B}/${r.toLowerCase()}/`, score: r.toLowerCase() === asRoad ? 0 : 1,
            html: `<a class="sg" href="${B}/${r.toLowerCase()}/"><span class="shield">${esc(r)}</span><span class="sg-t">${esc(st)}</span></a>` });
        }
      }
    }
    for (const [c, lat, lon] of cities) {
      const at = norm(c).indexOf(nv);
      if (at < 0) continue;
      const href = `${B}/?ort=${encodeURIComponent(c)}`;
      results.push({ href, score: at === 0 ? 1.5 : 3,
        html: `<a class="sg" href="${href}"><span class="sg-ic" aria-hidden="true">◎</span><span class="sg-t"><b>${esc(c)}</b><small>Alles im Umkreis von 30 km</small></span></a>` });
    }
    for (const [p, rs] of places) {
      const at = norm(p).indexOf(nv);
      if (at < 0) continue;
      const href = `${B}/?ort=${encodeURIComponent(p)}`;
      results.push({ href, score: at === 0 ? 2 : 4,
        html: `<a class="sg" href="${href}"><span class="sg-ic" aria-hidden="true">↳</span><span class="sg-t"><b>${esc(p)}</b><small>Anschlussstelle · Umkreis anzeigen</small></span></a>
<span class="rs">${rs.slice(0, 3).map(r => `<a class="shield sm" href="${B}/${r.toLowerCase()}/?ort=${encodeURIComponent(p)}">${esc(r)}</a>`).join('')}</span>` });
    }
    results.sort((a, b) => a.score - b.score);
    results = results.slice(0, 8);
    render();
  }

  q.addEventListener('focus', () => AB.index(), { once: true });
  q.addEventListener('input', update);
  q.addEventListener('keydown', async ev => {
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
      ev.preventDefault();
      if (!results.length) return;
      sel = (sel + (ev.key === 'ArrowDown' ? 1 : -1) + results.length) % results.length;
      render();
    } else if (ev.key === 'Enter') {
      ev.preventDefault();
      if (results.length) return go(results[Math.max(sel, 0)].href);
      const hit = await AB.findPlace(q.value);
      if (hit) go(`${B}/?ort=${encodeURIComponent(hit.name)}`);
    } else if (ev.key === 'Escape') {
      results = []; render();
    }
  });
  box.addEventListener('click', ev => {
    const a = ev.target.closest('a.sg');
    if (a && a.getAttribute('href').startsWith(B + '/?')) { ev.preventDefault(); go(a.getAttribute('href')); }
  });
  document.addEventListener('click', ev => { if (!ev.target.closest('.search')) { results = []; render(); } });

  // Umkreis-Links bleiben auf der Startseite: kein Neuladen, nur Ansicht wechseln
  function go(href) {
    if (!href.startsWith(B + '/?')) { location.href = href; return; }
    history.pushState(null, '', href);
    results = []; render();
    fromUrl(true);
  }
  window.addEventListener('popstate', () => fromUrl(false));

  // ---------- Umkreisansicht ----------
  const RADIUS = 30;
  function status(msg, busy) {
    panel.hidden = false;
    panel.innerHTML = `<p class="nah-load${busy ? ' busy' : ''}">${msg}</p>`;
  }
  async function showNearby(center, scroll) {
    status(`Suche Meldungen rund um ${center.name === 'deinem Standort' ? 'dich' : esc(center.name)} …`, true);
    let pts;
    try { pts = await AB.points(); } catch (err) {
      status('Die Meldungen konnten nicht geladen werden. Bitte Seite neu laden.');
      return;
    }
    let r = RADIUS;
    // Gleiche Auswahl wie die Knöpfe unter der Karte
    const ok = p => !AB.sevOn || AB.sevOn.includes(p[4]);
    let near = pts.map(p => ({ p, d: km(center, { lat: p[2], lon: p[3] }) })).filter(x => x.d <= r && ok(x.p));
    if (!near.length) { r = 60; near = pts.map(p => ({ p, d: km(center, { lat: p[2], lon: p[3] }) })).filter(x => x.d <= r && ok(x.p)); }
    AB.lastNear = () => showNearby(center, false);
    const RANK = { live: 0, voll: 1, sperr: 2, kurz: 3, dauer: 4 };
    const relevant = near.filter(x => x.p[5] && x.p[4] !== 'dauer').sort((a, b) => RANK[a.p[4]] - RANK[b.p[4]] || a.d - b.d);
    const dauer = near.filter(x => x.p[4] === 'dauer').sort((a, b) => a.d - b.d);
    const roadsNear = {};
    for (const x of near) roadsNear[x.p[0]] = Math.min(roadsNear[x.p[0]] ?? 1e9, x.d);
    const roadList = Object.entries(roadsNear).sort((a, b) => a[1] - b[1]);

    const row = ({ p, d }) => `<li class="nr sev-${p[4]}"><a href="${B}/${p[0].toLowerCase()}/#${p[1]}">
<span class="nr-dot" aria-hidden="true"></span><span class="shield sm">${esc(p[0])}</span>
<span class="nr-main"><span class="nr-when">${p[9] ? '<span class="badge">jetzt</span>' : ''}${esc(p[9] ? p[7].replace(/^jetzt /, '') : p[7])}</span><b>${esc(p[6])}</b><small>${esc(p[8])}</small></span>
<span class="nr-km">${d < 1 ? '< 1' : Math.round(d)} km</span></a></li>`;

    const where = center.name === 'deinem Standort' ? 'dich' : esc(center.name);
    panel.innerHTML = `<div class="nah-head">
  <div><p class="eyebrow">Umkreis ${r} km</p><h2>Rund um ${where}</h2>
  <p class="sub">${relevant.length ? `${relevant.length} ${relevant.length === 1 ? 'Meldung' : 'Meldungen'} für heute, die nächste zuerst.` : 'Heute keine Sperrungen und Baustellen in der Nähe. Gute Fahrt!'}</p></div>
  <button type="button" class="nah-close" aria-label="Umkreis schließen">✕</button>
</div>
${roadList.length ? `<p class="nah-roads">Autobahnen in der Nähe: ${roadList.slice(0, 10).map(([rd, d]) => `<a class="shield" href="${B}/${rd.toLowerCase()}/" title="${Math.round(d)} km entfernt">${esc(rd)}</a>`).join('')}</p>` : ''}
<ul class="nr-list">${relevant.slice(0, 40).map(row).join('')}</ul>
${dauer.length ? `<h3 class="nah-sub">Dauerbaustellen <span>${dauer.length}</span></h3><ul class="nr-list">${dauer.slice(0, 60).map(row).join('')}</ul>` : ''}`;
    panel.querySelector('.nah-close').addEventListener('click', () => { go(B + '/?'); });
    AB.mark(center.lat, center.lon, r);
    AB.flyTo(center.lat, center.lon, r > 30 ? 8 : 9);
    // Karte zeigt jetzt den Umkreis: dorthin scrollen, die Liste folgt direkt darunter
    if (scroll) document.getElementById('karte').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  async function fromUrl(scroll) {
    const ps = new URLSearchParams(location.search);
    const ort = ps.get('ort');
    const nah = ps.get('nah');
    if (nah) {
      const [lat, lon] = nah.split(',').map(Number);
      if (lat && lon) return showNearby({ lat, lon, name: 'deinem Standort' }, scroll);
    }
    if (ort) {
      q.value = ort;
      const hit = await AB.findPlace(ort);
      if (hit) return showNearby(hit, scroll);
      panel.hidden = false;
      panel.innerHTML = `<p class="nah-load">„${esc(ort)}“ kennen wir leider nicht. Versuch eine größere Stadt in der Nähe oder eine Autobahnnummer.</p>`;
      return;
    }
    panel.hidden = true;
    AB.unmark();
  }
  fromUrl(true);

  if (locBtn) locBtn.addEventListener('click', async () => {
    AB.setLbl(locBtn, 'Suche Standort …');
    locBtn.disabled = true;
    // Sofort sichtbar machen, dass etwas passiert
    status('Dein Standort wird bestimmt … Falls dein Browser fragt, bitte „Erlauben“ wählen.', true);
    document.getElementById('karte').scrollIntoView({ behavior: 'smooth', block: 'start' });
    try {
      const pos = await AB.locate();
      history.pushState(null, '', `${B}/?nah=${pos.lat.toFixed(4)},${pos.lon.toFixed(4)}`);
      await showNearby(pos, true);
    } catch (err) {
      status(`${esc(err.message)}<br><small>Tipp: Gib stattdessen oben eine Stadt ein, z. B. „Köln“.</small>`);
    }
    locBtn.disabled = false;
    AB.setLbl(locBtn, 'In meiner Nähe');
  });
})();
