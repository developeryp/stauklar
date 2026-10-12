# Stauklar (stauklar.de)

Statische Website mit Sperrungen, Baustellen und Staus für alle deutschen Autobahnen.
Die Daten kommen aus der offenen API der Autobahn GmbH (verkehr.autobahn.de).

- `fetch.py` lädt alle Autobahnen in `cache/` (ca. 30 Sekunden, 555 Abrufe)
- `build.py` erzeugt daraus `dist/`: eine Seite pro Autobahn, Startseite, Sitemap, robots.txt
- `static/` enthält CSS, Skripte, Schriften (Barlow, selbst gehostet), MapLibre und die 404-Seite
- `static/assets/app.js` verbindet Karte, Streckenliste, Filter (Zeitraum, Richtung, Ort, Dauerbaustellen) und lädt Staus live nach
- `static/assets/search.js` ist die Suche nach Autobahn oder Ort auf der Startseite (Daten: `suche.json`)

So ist eine Autobahn-Seite aufgebaut:
- Lagebericht in ganzen Sätzen und eine Ampel (rot, gelb, grün)
- Meldungen in Streckenreihenfolge statt nach Datum; bei gewählter Richtung in Fahrtrichtung sortiert
- Richtungen werden aus dem Linienverlauf berechnet und nach dem Ende der Autobahn benannt (z. B. „↑ Flensburg / ↓ Füssen“)
- Spurgrafik aus dem API-Feld `impact.symbols`

Nur Python 3.9+ nötig, keine Pakete.

## Lokal ansehen

```bash
python3 fetch.py && python3 build.py
python3 serve.py
```

Dann http://localhost:8765 öffnen.

## Veröffentlichen (GitHub Pages)

Repository: https://github.com/developeryp/stauklar. Der Workflow „Website aktualisieren“
baut die Seite alle 15 Minuten neu und veröffentlicht sie auf GitHub Pages.

**Phase 1, ohne eigene Domain:** Die Seite läuft unter https://developeryp.github.io/stauklar/
mit diesen Repository-Variablen (Settings → Secrets and variables → Actions → Variables):
- `SITE_URL` = `https://developeryp.github.io/stauklar`
- `SITE_NAME` = `Stauklar`
- `BASE_PATH` = `/stauklar`

**Phase 2, mit stauklar.de:**
1. Beim Domain-Anbieter für `stauklar.de` vier A-Einträge auf die GitHub-Pages-Adressen setzen:
   `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
   und für `www.stauklar.de` einen CNAME-Eintrag auf `developeryp.github.io`.
2. Variablen ändern: `SITE_URL` = `https://stauklar.de`, `BASE_PATH` löschen, `CUSTOM_DOMAIN` = `stauklar.de`.
3. Workflow einmal von Hand starten (Actions → Website aktualisieren → Run workflow).
4. Unter Settings → Pages „Enforce HTTPS“ einschalten, sobald GitHub das Zertifikat ausgestellt hat.

GitHub startet geplante Läufe teilweise mit einigen Minuten Verspätung,
die Staumeldungen kommen aber ohnehin live über `app.js`.

## Sobald die App im App Store ist

Zwei Repository-Variablen setzen, dann verlinkt die Website die App automatisch (Download-Knöpfe, Seite /app/, Apples Smart App Banner auf jeder Seite):
- `APP_STORE_URL` = `https://apps.apple.com/de/app/stauklar/id1234567890`
- `APP_ID` = `1234567890` (die Zahl aus der URL)

Universal Links: `static/.well-known/apple-app-site-association` verknüpft stauklar.de mit der App (Team 6AY5V43PJ2, Bundle de.stauklar.app). Wer die App hat und einen Link wie stauklar.de/a7/ öffnet, landet direkt in der App.

## Vor dem Start erledigen

- `impressum/` und `datenschutz/` in `build.py` (Funktion `legal_pages`) mit echten Angaben füllen.
- In der Google Search Console die Domain bestätigen und `sitemap.xml` einreichen.
