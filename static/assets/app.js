// Karte + Streckenliste + Filter + Live-Staus. Ohne JavaScript bleibt die Seite vollständig lesbar.
(function () {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const COLORS = { voll: '#d70015', sperr: '#009e9e', kurz: '#ff8a00', dauer: '#9b7b56', live: '#8a3ffc' };
  const RANK = { dauer: 0, kurz: 1, sperr: 2, voll: 3, live: 4 };
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  // Pfad-Präfix, falls die Seite in einem Unterordner liegt (z. B. github.io/stauklar)
  const B = document.documentElement.dataset.base || '';

  // ---------- Gemeinsame Helfer: Orte, Entfernung, Standort ----------
  const norm = s => String(s).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/ß/g, 'ss').trim();
  const km = (a, b) => Math.hypot((a.lon - b.lon) * 111.32 * Math.cos(a.lat * Math.PI / 180), (a.lat - b.lat) * 110.57);
  let idxP = null, ptsP = null;
  const AB = window.AB = {
    norm, km, esc, base: B,
    index: () => idxP || (idxP = fetch(B + '/suche.json').then(r => r.json())),
    points: () => ptsP || (ptsP = fetch(B + '/punkte.json').then(r => { if (!r.ok) throw new Error(r.status); return r.json(); }).catch(err => { ptsP = null; throw err; })),
    // Ort finden: zuerst Städte, dann Anschlussstellen aus den Meldungen
    async findPlace(q) {
      const n = norm(q);
      if (n.length < 2) return null;
      const { cities, places } = await AB.index();
      const c = cities.find(([nm]) => norm(nm) === n) || cities.find(([nm]) => norm(nm).startsWith(n));
      if (c) return { name: c[0], lat: c[1], lon: c[2] };
      const p = places.find(([nm]) => norm(nm) === n) || places.find(([nm]) => norm(nm).startsWith(n)) || places.find(([nm]) => norm(nm).includes(n));
      return p ? { name: p[0], lat: p[2], lon: p[3], roads: p[1] } : null;
    },
    locate() {
      return new Promise((ok, fail) => {
        if (!navigator.geolocation) return fail(new Error('Dein Browser kann den Standort nicht bestimmen.'));
        // Safari ruft bei manchen Einstellungen gar keinen Rückruf auf: eigene Zeitgrenze
        const guard = setTimeout(() => fail(new Error('Der Standort kam nicht an. Prüfe unter Systemeinstellungen → Datenschutz & Sicherheit → Ortungsdienste, ob Safari den Standort verwenden darf.')), 12000);
        navigator.geolocation.getCurrentPosition(
          pos => { clearTimeout(guard); ok({ lat: pos.coords.latitude, lon: pos.coords.longitude, name: 'deinem Standort' }); },
          err => {
            clearTimeout(guard);
            fail(new Error(err.code === 1
              ? 'Standort nicht freigegeben. In Safari: Einstellungen → Websites → Standort → „localhost“ auf „Erlauben“ stellen. Auf dem Mac außerdem: Systemeinstellungen → Ortungsdienste → Safari einschalten.'
              : 'Standort konnte nicht bestimmt werden (' + (err.message || 'unbekannter Fehler') + '). Versuch es noch einmal oder suche nach einem Ort.'));
          },
          { enableHighAccuracy: false, timeout: 11000, maximumAge: 300000 });
      });
    },
    mark(lat, lon, radiusKm) {
      if (!map) return;
      if (!AB._marker) {
        const m = document.createElement('div');
        m.className = 'me-marker';
        AB._marker = new maplibregl.Marker({ element: m });
      }
      AB._marker.setLngLat([lon, lat]).addTo(map);
      if (radiusKm) AB.circle(lat, lon, radiusKm);
    },
    // Umkreis als Kreisfläche einzeichnen (Polygon mit 64 Ecken)
    circle(lat, lon, radiusKm) {
      const draw = () => {
        const pts = [];
        for (let i = 0; i <= 64; i++) {
          const a = (i / 64) * 2 * Math.PI;
          pts.push([lon + (radiusKm * Math.sin(a)) / (111.32 * Math.cos(lat * Math.PI / 180)), lat + (radiusKm * Math.cos(a)) / 110.57]);
        }
        const gj = { type: 'Feature', geometry: { type: 'Polygon', coordinates: [pts] } };
        if (map.getSource('me-r')) { map.getSource('me-r').setData(gj); return; }
        map.addSource('me-r', { type: 'geojson', data: gj });
        map.addLayer({ id: 'me-r-fill', type: 'fill', source: 'me-r', paint: { 'fill-color': '#0a84ff', 'fill-opacity': 0.08 } }, map.getLayer('ctx') ? 'ctx' : undefined);
        map.addLayer({ id: 'me-r-line', type: 'line', source: 'me-r', paint: { 'line-color': '#0a84ff', 'line-width': 1.5, 'line-dasharray': [2, 2] } });
      };
      if (map.isStyleLoaded()) draw(); else map.once('load', draw);
    },
    unmark() {
      if (AB._marker) AB._marker.remove();
      if (map && map.getSource('me-r')) map.getSource('me-r').setData({ type: 'FeatureCollection', features: [] });
      if (AB._center && !route) { AB._center = null; overview(); }
    },
    flyTo(lat, lon, zoom = 9.3) { AB._center = { lat, lon, zoom }; if (map) map.flyTo({ center: [lon, lat], zoom, duration: reduce ? 0 : 900 }); },
  };

  const split = $('.split');
  const route = $('#route');
  const road = split && split.dataset.road;
  const ax = split && split.dataset.ax ? JSON.parse(split.dataset.ax) : null;
  const labels = split ? JSON.parse(split.dataset.labels || '{}') : {};
  const state = { w: 'heute', d: '', q: '', near: null };
  const NEAR_KM = 30;
  // Filter nach Art (Vollsperrung, Auf-/Abfahrt zu, Baustelle, Dauerbaustelle, Stau & Gefahr); standardmäßig alles sichtbar
  const sevBox = $('#sevf');
  const sevKey = route ? 'sevf-road' : 'sevf-home';
  let sevOn = null;   // null = alles
  const sevOf = li => ([...li.classList].find(c => c.startsWith('sev-')) || 'sev-').slice(4);
  const sevOk = li => !sevOn || sevOn.includes(sevOf(li));
  function syncSev() { if (sevBox) $$('.chip', sevBox).forEach(b => b.setAttribute('aria-pressed', String(!sevOn || sevOn.includes(b.dataset.sev)))); }
  function showAllSev() { sevOn = null; try { localStorage.removeItem(sevKey); } catch (err) {} syncSev(); }
  if (sevBox) {
    try { const v = JSON.parse(localStorage.getItem(sevKey) || 'null'); if (Array.isArray(v)) sevOn = v; } catch (err) {}
    syncSev();
    AB.sevOn = sevOn;
    sevBox.addEventListener('click', ev => {
      const b = ev.target.closest('.chip');
      if (!b) return;
      const all = $$('.chip', sevBox).map(x => x.dataset.sev);
      const cur = new Set(sevOn || all);
      cur.has(b.dataset.sev) ? cur.delete(b.dataset.sev) : cur.add(b.dataset.sev);
      sevOn = cur.size === all.length ? null : [...cur];
      try { sevOn ? localStorage.setItem(sevKey, JSON.stringify(sevOn)) : localStorage.removeItem(sevKey); } catch (err) {}
      syncSev();
      AB.sevOn = sevOn;
      if (route) apply(true); else { if (map && map.getLayer('lines')) setFilters(); if (AB.lastNear && !$('#nah').hidden) AB.lastNear(); }
    });
  }

  $$('.seg').forEach(seg => {
    const on = $('[aria-checked="true"]', seg);
    if (on) state[seg.dataset.seg] = on.dataset.v;
  });

  // ---------- Filter ----------
  const matches = (li, w, d, q, ignoreSev) =>
    li.dataset.w.split(' ').includes(w) && (!d || !li.dataset.d || li.dataset.d.split(' ').includes(d)) && (!q || norm(li.dataset.q).includes(q))
    && (ignoreSev || sevOk(li))
    && (!state.near || nearLi(li, state.near.r));
  const llOf = li => { const [lat, lon] = (li.dataset.ll || '0,0').split(',').map(Number); return { lat, lon }; };
  function nearLi(li, r) {
    const p = llOf(li);
    return p.lat && km(state.near, p) <= r;
  }

  function apply(fit) {
    if (!route) return;
    const ids = [];
    const stops = $$('.stop', route);
    for (const li of stops) {
      const v = matches(li, state.w, state.d, state.q);
      li.hidden = !v;
      if (v) ids.push(li.id);
    }
    // In Fahrtrichtung lesen: Richtung Norden/Westen → Liste umdrehen
    route.classList.toggle('rev', state.d === 'minus');
    split.classList.toggle('rev', state.d === 'minus');
    $$('[data-seg="w"] .n').forEach(n => {
      n.textContent = stops.filter(li => matches(li, n.dataset.n, state.d, state.q)).length;
    });
    $('#route-n').textContent = ids.length;
    // Sichtbar machen, was die Filter-Knöpfe gerade verstecken
    const hiddenDauer = sevOn ? stops.filter(li => !sevOk(li) && matches(li, state.w, state.d, state.q, true)).length : 0;
    const note = $('#hidden-note');
    if (note) {
      note.hidden = hiddenDauer === 0;
      note.innerHTML = `${hiddenDauer} ausgeblendet · <b>Alle einblenden</b>`;
    }
    $('#route-n').textContent = ids.length + (hiddenDauer ? ` · ${hiddenDauer} ausgeblendet` : '');
    $('#empty').hidden = ids.length > 0;
    if (!ids.length) explainEmpty();
    visibleIds = ids;
    if (map && map.getLayer('lines')) {
      setFilters();
      // Bei Ort/Standort auf die Treffer zoomen, sonst immer die ganze Strecke zeigen
      if (fit) {
        if ((state.q || state.near) && ids.length) fitTo(data.features.filter(f => ids.includes(f.properties.g)));
        else if (state.near) AB.flyTo(state.near.lat, state.near.lon, 9);
        else overview();
      }
    }
  }

  $$('.seg').forEach(seg => seg.addEventListener('click', ev => {
    const b = ev.target.closest('button');
    if (!b) return;
    $$('button', seg).forEach(x => x.setAttribute('aria-checked', String(x === b)));
    state[seg.dataset.seg] = b.dataset.v;
    apply(true);
  }));
  const setW = w => { state.w = w; $$('[data-seg="w"] button').forEach(b => b.setAttribute('aria-checked', String(b.dataset.v === w))); };

  const hiddenNote = $('#hidden-note');
  if (hiddenNote) hiddenNote.addEventListener('click', () => { showAllSev(); apply(true); });
  const find = $('#find');
  const locBtn = $('#locate');
  const LOC_LABEL = 'In meiner Nähe';
  const setLbl = (btn, t) => { const l = btn.querySelector('.lbl'); if (l) l.textContent = t; else btn.textContent = t; };
  AB.setLbl = setLbl;
  function clearLoc() { if (locBtn) { locBtn.classList.remove('on'); setLbl(locBtn, LOC_LABEL); } }

  // Suche: Ein bekannter Ort (Stadt oder Anschlussstelle) filtert räumlich im Umkreis von 20 km,
  // sonst wird im Text gesucht. So findet „Kassel“ nicht jede Meldung „Richtung Kassel“.
  async function search(v) {
    v = v.trim();
    state.q = '';
    if (!v) { state.near = null; AB.unmark(); return apply(true); }
    const hit = await AB.findPlace(v);
    if (find && v !== find.value.trim()) return; // inzwischen weitergetippt
    if (hit) {
      state.near = { ...hit, r: 20, src: 'ort' };
      AB.mark(hit.lat, hit.lon, 20);
    } else {
      state.near = null; AB.unmark();
      state.q = norm(v);
    }
    clearLoc();
    apply(true);
  }
  let tFind;
  if (find) find.addEventListener('input', () => {
    clearTimeout(tFind);
    tFind = setTimeout(() => search(find.value), 280);
  });

  // Leere Liste: sagen warum und wohin stattdessen
  const emptyBase = $('#empty') ? $('#empty').innerHTML : '';
  function explainEmpty() {
    const box = $('#empty');
    if (!box) return;
    const n = state.near;
    if (n) {
      const isMe = n.name === 'deinem Standort';
      const nearHref = isMe ? `${B}/?nah=${n.lat.toFixed(4)},${n.lon.toFixed(4)}` : `${B}/?ort=${encodeURIComponent(n.name)}`;
      const anyNear = $$('.stop', route).some(li => nearLi(li, 60));
      if (!anyNear) {
        box.innerHTML = `${isMe ? 'Du bist nicht in der Nähe' : `${esc(n.name)} liegt nicht an`} der ${esc(road)}.
          <a class="empty-go" href="${nearHref}">Alle Autobahnen rund um ${isMe ? 'dich' : esc(n.name)} ansehen →</a>`;
      } else {
        box.innerHTML = `Rund um ${isMe ? 'dich' : esc(n.name)} ist auf der ${esc(road)} ${state.w === 'heute' ? 'heute' : 'in diesem Zeitraum'} nichts gemeldet${sevOn ? ' (einige Arten ausgeblendet)' : ''}.
          <button type="button" class="empty-go linkish" id="show-all">Alle Meldungen in der Nähe zeigen</button>`;
        $('#show-all').addEventListener('click', () => { setW('alle'); showAllSev(); apply(true); });
      }
      return;
    }
    if (state.q) {
      box.innerHTML = `Nichts zu „${esc(find.value)}“ auf der ${esc(road)} gefunden. Versuch es mit einer Stadt oder dem Namen einer Anschlussstelle.`;
      return;
    }
    box.innerHTML = emptyBase;
  }

  if (locBtn && route) locBtn.addEventListener('click', async () => {
    if (state.near && state.near.src === 'gps') { // zweiter Klick schaltet den Umkreis wieder aus
      state.near = null; clearLoc(); AB.unmark(); apply(true); return;
    }
    setLbl(locBtn, 'Suche Standort …');
    try {
      const pos = await AB.locate();
      state.near = { ...pos, r: 30, src: 'gps' };
      state.q = '';
      if (find) find.value = '';
      locBtn.classList.add('on');
      setLbl(locBtn, '30 km um dich ✕');
      AB.mark(pos.lat, pos.lon, 30);
      apply(true);
    } catch (err) {
      clearLoc();
      const box = $('#empty');
      box.hidden = false; box.textContent = err.message;
    }
  });

  // ---------- Karte ----------
  const el = $('#map');
  let map = null, data = { type: 'FeatureCollection', features: [] }, visibleIds = null, popup = null;

  const colorExpr = ['match', ['get', 'sev'], ...Object.entries(COLORS).flat(), '#888'];

  function setFilters() {
    const base = visibleIds ? ['in', ['get', 'g'], ['literal', visibleIds]] : true;
    const sev = sevOn ? ['in', ['get', 'sev'], ['literal', sevOn]] : true;
    map.setFilter('casing', ['all', ['!', ['has', 'pt']], base, sev]);
    map.setFilter('lines', ['all', ['!', ['has', 'pt']], base, sev]);
    map.setFilter('points', ['all', ['has', 'pt'], base, sev]);
  }

  function bbox(fs) {
    let b = [180, 90, -180, -90];
    for (const f of fs) {
      const cs = f.geometry.type === 'Point' ? [f.geometry.coordinates] : f.geometry.coordinates;
      for (const [x, y] of cs) b = [Math.min(b[0], x), Math.min(b[1], y), Math.max(b[2], x), Math.max(b[3], y)];
    }
    return b[0] > b[2] ? null : [[b[0], b[1]], [b[2], b[3]]];
  }
  function fitTo(fs, maxZoom = 12) {
    const b = bbox(fs);
    if (b) map.fitBounds(b, { padding: 40, maxZoom, duration: reduce ? 0 : 700 });
  }
  const GERMANY = [[5.8, 47.2], [15.1, 55.1]];
  function overview() {
    if (!map) return;
    if (route) fitTo(data.features.filter(f => !f.properties.pt), 11);
    else map.fitBounds(GERMANY, { padding: 10, duration: reduce ? 0 : 700 });
  }
  function highlight(id) {
    if (map && map.getLayer('hl')) map.setFilter('hl', ['all', ['!', ['has', 'pt']], ['==', ['get', 'g'], id || '']]);
  }
  function linesOf(id) { return data.features.filter(f => f.properties.g === id && !f.properties.pt); }

  function focusOnMap(id, scroll) {
    if (scroll) {
      // Zur Karte springen, unter der klebenden Filterleiste. Bei weiten Wegen sofort, weich scrollen bricht dort ab.
      const bar = $('#controls');
      const y = el.getBoundingClientRect().top + scrollY - (bar ? bar.offsetHeight : 0) - 12;
      const far = Math.abs(y - scrollY) > 2 * innerHeight;
      window.scrollTo({ top: y, behavior: reduce || far ? 'auto' : 'smooth' });
    }
    const fs = linesOf(id);
    if (!fs.length || !map) return;
    fitTo(fs, 15);
    highlight(id);
  }

  function openStop(id) {
    const li = document.getElementById(id);
    if (!li) return;
    if (li.hidden) { // Eintrag liegt außerhalb des Filters → Filter öffnen
      state.w = 'alle'; state.d = ''; state.q = '';
      if (!sevOk(li)) { sevOn = [...new Set([...(sevOn || []), sevOf(li)])]; syncSev(); }
      if (find) find.value = '';
      $$('.seg button').forEach(b => b.setAttribute('aria-checked', String(b.dataset.v === state[b.closest('.seg').dataset.seg])));
      apply(false);
    }
    $('details', li).open = true;
    li.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'center' });
    li.classList.add('flash');
    setTimeout(() => li.classList.remove('flash'), 1600);
  }

  function showPopup(p, lngLat) {
    if (popup) popup.remove();
    popup = new maplibregl.Popup({ maxWidth: '260px', offset: 10, closeButton: false })
      .setLngLat(lngLat)
      .setHTML(`<a class="pop sev-${esc(p.sev)}" href="${esc(p.url)}"><span class="pop-k">${esc(p.road)} · ${esc(p.kind)}</span><b>${esc(p.title)}</b><span>${esc(p.when)}</span><span class="pop-go">Details zur ${esc(p.road)} →</span></a>`)
      .addTo(map);
  }

  if (el && window.maplibregl) {
    map = new maplibregl.Map({
      container: el,
      style: 'https://tiles.openfreemap.org/styles/positron',
      bounds: [[5.8, 47.2], [15.1, 55.1]],
      fitBoundsOptions: { padding: 10 },
      cooperativeGestures: true,
      attributionControl: { compact: true },
      dragRotate: false,
      locale: {
        'CooperativeGesturesHandler.WindowsHelpText': 'Strg + Scrollen zum Zoomen',
        'CooperativeGesturesHandler.MacHelpText': '⌘ + Scrollen zum Zoomen',
        'CooperativeGesturesHandler.MobileHelpText': 'Mit zwei Fingern bewegen',
      },
    });
    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
    // Eigener Standort als blauer Punkt; wenn die Erlaubnis schon erteilt ist, ohne Nachfrage anzeigen
    const geo = new maplibregl.GeolocateControl({ positionOptions: { enableHighAccuracy: false }, trackUserLocation: false, showUserLocation: true, fitBoundsOptions: { maxZoom: 11 } });
    map.addControl(geo, 'top-right');
    if (navigator.permissions && navigator.permissions.query) {
      navigator.permissions.query({ name: 'geolocation' }).then(st => {
        if (st.state === 'granted') map.once('load', () => { const c = map.getCenter(), z = map.getZoom(); geo.trigger(); map.once('moveend', () => map.jumpTo({ center: c, zoom: z })); });
      }).catch(() => {});
    }
    map.touchZoomRotate.disableRotation();
    // Knopf zurück zur Übersicht (ganze Autobahn bzw. ganz Deutschland)
    map.addControl({
      onAdd() {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'map-reset';
        b.textContent = route ? 'Ganze Strecke' : 'Ganz Deutschland';
        b.addEventListener('click', () => { highlight(''); if (popup) popup.remove(); overview(); });
        const wrap = document.createElement('div');
        wrap.className = 'maplibregl-ctrl';
        wrap.appendChild(b);
        return wrap;
      },
      onRemove() {},
    }, 'top-left');
    // Safari misst die Karte manchmal vor dem endgültigen Layout (Schriften, klebende Spalte):
    // bei jeder Größenänderung neu ausmessen, sonst bleibt die Karte halb leer.
    const fix = () => map.resize();
    if (window.ResizeObserver) new ResizeObserver(fix).observe(el);
    if (document.fonts) document.fonts.ready.then(fix);
    window.addEventListener('load', fix);
    window.addEventListener('pageshow', fix);
    map.once('load', () => { fix(); setTimeout(fix, 300); });

    map.on('load', async () => {
      for (const l of map.getStyle().layers) {
        // Nur Ortsnamen eindeutschen; Autobahnschilder zeigen die Nummer („ref“) und bleiben unverändert
        const tf = l.type === 'symbol' && map.getLayoutProperty(l.id, 'text-field');
        const src = tf && JSON.stringify(tf);
        if (src && src.includes('name') && !src.includes('ref')) {
          map.setLayoutProperty(l.id, 'text-field', ['coalesce', ['get', 'name:de'], ['get', 'name']]);
        }
      }
      try { data = await (await fetch(el.dataset.src)).json(); } catch (err) { return; }
      for (const f of data.features) f.properties.rank = RANK[f.properties.sev] ?? 0;
      map.addSource('m', { type: 'geojson', data });
      const width = (a, b) => ['interpolate', ['linear'], ['zoom'], 7, a, 15, b];
      // Alle Abschnitte dezent im Hintergrund: zeigt den Verlauf der Autobahn, auch wenn gefiltert wird
      if (route || el.dataset.focus) map.addLayer({ id: 'ctx', type: 'line', source: 'm', filter: ['!', ['has', 'pt']],
        layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': '#1650a8', 'line-opacity': 0.28, 'line-width': ['interpolate', ['linear'], ['zoom'], 5, 3, 15, 8] } });
      map.addLayer({ id: 'casing', type: 'line', source: 'm', minzoom: 7,
        layout: { 'line-cap': 'round', 'line-join': 'round', 'line-sort-key': ['get', 'rank'] },
        paint: { 'line-color': '#fff', 'line-width': width(5, 15) } });
      map.addLayer({ id: 'lines', type: 'line', source: 'm', minzoom: 7,
        layout: { 'line-cap': 'round', 'line-join': 'round', 'line-sort-key': ['get', 'rank'] },
        paint: { 'line-color': colorExpr, 'line-width': width(3, 10),
          'line-opacity': ['case', ['==', ['get', 'now'], 1], 1, 0.5] } });
      map.addLayer({ id: 'hl', type: 'line', source: 'm', filter: ['==', ['get', 'id'], ''],
        layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': '#0f1b2b', 'line-width': width(9, 22), 'line-opacity': 0.28 } }, 'casing');
      map.addLayer({ id: 'points', type: 'circle', source: 'm', maxzoom: 9,
        layout: { 'circle-sort-key': ['get', 'rank'] },
        paint: { 'circle-color': colorExpr,
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 5, ['match', ['get', 'sev'], 'dauer', 2.5, 4.5], 9, 7],
          'circle-stroke-color': '#fff', 'circle-stroke-width': 1.5,
          'circle-opacity': ['case', ['==', ['get', 'now'], 1], 1, 0.6], 'circle-stroke-opacity': ['case', ['==', ['get', 'now'], 1], 1, 0.6] } });

      if (route) {
        apply(false);
        // Ziel aus dem Link: Maßnahme (g…) oder Stau (w…); ältere Links nennen die Einzelmeldung (m…) → zugehörige Maßnahme
        let target = decodeURIComponent(location.hash.slice(1));
        if (target && !document.getElementById(target)) {
          const f = data.features.find(f => f.properties.id === target);
          if (f && f.properties.g) target = f.properties.g;
        }
        if (target && document.getElementById(target)) { openStop(target); focusOnMap(target, false); }
        else overview();
      } else if (el.dataset.focus) {
        // Ereignisseite: nur diese Maßnahme farbig, der Rest der Autobahn als blauer Verlauf
        visibleIds = [el.dataset.focus];
        setFilters();
        fitTo(linesOf(el.dataset.focus), 13);
      } else if (el.dataset.center) {
        // Stadtseite: Umkreis um die Stadt
        const [lat, lon] = el.dataset.center.split(',').map(Number);
        map.jumpTo({ center: [lon, lat], zoom: 9 });
        AB.mark(lat, lon, Number(el.dataset.radius) || 30);
      } else if (AB._center) {
        map.jumpTo({ center: [AB._center.lon, AB._center.lat], zoom: AB._center.zoom });
      } else {
        overview();
      }
      if (sevOn) setFilters();

      // Treffer großzügig suchen: Linien sind nur wenige Pixel breit, auf dem Handy trifft man sie sonst kaum.
      // Gewählt wird die wichtigste Meldung im Umkreis von 14 px, bei Gleichstand die nächste.
      const HIT = 14;
      const pick = pt => {
        const fs = map.queryRenderedFeatures([[pt.x - HIT, pt.y - HIT], [pt.x + HIT, pt.y + HIT]], { layers: ['lines', 'points'] });
        if (!fs.length) return null;
        fs.sort((a, b) => (b.properties.rank - a.properties.rank));
        return fs[0];
      };
      map.on('click', ev => {
        const f = pick(ev.point);
        if (!f) return;
        const p = f.properties;
        if (route) { highlight(p.g); openStop(p.g); } else if (p.url) showPopup(p, ev.lngLat);
      });
      map.on('mousemove', ev => { map.getCanvas().style.cursor = pick(ev.point) ? 'pointer' : ''; });
    });
  }

  // ---------- Liste ↔ Karte ----------
  if (route) {
    route.addEventListener('toggle', ev => {
      const det = ev.target;
      if (det.tagName !== 'DETAILS' || !det.open) return;
      const id = det.closest('.stop').id;
      if (matchMedia('(min-width: 960px)').matches) focusOnMap(id, false); else highlight(id);
    }, true);
    route.addEventListener('mouseover', ev => {
      const li = ev.target.closest('.stop');
      if (li) highlight(li.id);
    });
    route.addEventListener('click', ev => {
      const b = ev.target.closest('.tomap');
      if (b) focusOnMap(b.dataset.id, true);
    });
  }

  // ---------- Live-Staumeldungen ----------
  const toKm = (lon, lat) => [lon * 111.32 * Math.cos(ax.lat0 * Math.PI / 180), lat * 110.57];
  const along = (lon, lat) => { const [x, y] = toKm(lon, lat); return (x - ax.mx) * ax.vx + (y - ax.my) * ax.vy; };
  const strip = t => t.replace(new RegExp('^' + road + '\\s*\\|\\s*'), '').trim();

  async function live() {
    try {
      const r = await fetch('https://verkehr.autobahn.de/o/autobahn/' + encodeURIComponent(road) + '/services/warning');
      if (!r.ok) return;
      const list = (await r.json()).warning || [];
      $$('.stop.sev-live', route).forEach(li => li.remove());
      const feats = [];
      list.forEach((w, n) => {
        const id = 'w' + n;
        const g = w.geometry && w.geometry.type === 'LineString' ? w.geometry.coordinates : null;
        const txt = (w.description || []).filter(l => l && !l.startsWith('Beginn:') && l !== 'Ereignismeldung:').slice(0, 4);
        let t = 0, d = '';
        if (g && ax) {
          const mid = g[Math.floor(g.length / 2)];
          t = along(mid[0], mid[1]);
          const dl = along(...g[g.length - 1]) - along(...g[0]);
          if (Math.abs(dl) > 0.03) d = dl > 0 ? 'plus' : 'minus';
        }
        const lab = labels[d];
        const dir = lab ? `${lab.sym} Richtung ${esc(lab.name)}` : 'Richtung ' + esc((w.subtitle || '').trim().replace('->', '→'));
        const title = strip(w.title || '');
        const li = document.createElement('li');
        li.className = 'stop sev-live'; li.id = id;
        li.dataset.t = t.toFixed(2); li.dataset.d = d; li.dataset.w = 'heute woche alle';
        li.dataset.q = (title + ' ' + (w.subtitle || '')).toLowerCase();
        li.innerHTML = `<details><summary><span class="node" aria-hidden="true"></span><span class="s-main"><span class="s-when"><span class="badge live">live</span>${esc(txt[0] || 'aktuell')}</span><span class="s-name">${esc(title)}</span><span class="s-sub">Stau, Unfall oder Gefahr · ${dir}</span></span><span class="chev" aria-hidden="true"></span></summary><div class="s-body">${txt.slice(1).map(l => `<p>${esc(l.replace('->', '→'))}</p>`).join('')}${g ? `<button type="button" class="tomap" data-id="${id}">Auf der Karte</button>` : ''}</div></details>`;
        const after = $$('.stop', route).find(x => parseFloat(x.dataset.t) > t);
        route.insertBefore(li, after || null);
        if (g) {
          const p = { id, g: id, sev: 'live', now: 1, title, kind: 'Verkehrsmeldung', when: txt[0] || '', rank: 4 };
          feats.push({ type: 'Feature', properties: p, geometry: { type: 'LineString', coordinates: g } });
          feats.push({ type: 'Feature', properties: { ...p, pt: 1 }, geometry: { type: 'Point', coordinates: g[Math.floor(g.length / 2)] } });
        }
      });
      const c = $('#live-count');
      if (c) c.textContent = list.length;
      if (map && map.getSource('m')) {
        data = { type: 'FeatureCollection', features: data.features.filter(f => f.properties.sev !== 'live').concat(feats) };
        map.getSource('m').setData(data);
      }
      apply(false);
    } catch (err) { /* statischer Stand bleibt stehen */ }
  }
  if (route && road) {
    // Von der Suche auf der Startseite: ?ort=Kassel → Liste gleich auf den Ort filtern
    const ort = new URLSearchParams(location.search).get('ort');
    if (ort && find) { find.value = ort; search(ort); }
    apply(false);
    live();
    setInterval(() => { if (!document.hidden) live(); }, 120000);
  }
})();
