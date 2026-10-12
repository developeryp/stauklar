"""Erzeugt die statische Website aus dem Cache (siehe fetch.py) nach dist/."""
import datetime as dt
import html
import json
import math
import os
import pathlib
import re
import shutil
from zoneinfo import ZoneInfo

from cities import CITIES

ROOT = pathlib.Path(__file__).parent
CACHE = ROOT / "cache"
DIST = ROOT / "dist"
TZ = ZoneInfo("Europe/Berlin")
SITE_URL = (os.environ.get("SITE_URL") or "https://stauklar.de").rstrip("/")
SITE_NAME = os.environ.get("SITE_NAME") or "Stauklar"
# Unterordner, solange die Seite unter github.io/stauklar läuft; mit eigener Domain leer lassen
BASE = (os.environ.get("BASE_PATH") or "").rstrip("/")
NOW = dt.datetime.now(TZ).replace(tzinfo=None, second=0, microsecond=0)
TONIGHT_END = (NOW + dt.timedelta(days=1)).replace(hour=6, minute=0)
WEEK_END = NOW + dt.timedelta(days=7)
SHORT = dt.timedelta(days=3)  # Zeitfenster bis 3 Tage gelten als kurzfristige Sperrung

WEEKDAYS = {"Montag": 0, "Dienstag": 1, "Mittwoch": 2, "Donnerstag": 3, "Freitag": 4, "Samstag": 5, "Sonntag": 6}
WD_SHORT = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

e = html.escape


# ---------- Zeiträume aus dem Fließtext lesen ----------

def _date(s):
    return dt.datetime.strptime(s, "%d.%m.%y")


def _at(day, hhmm):
    h, m = map(int, hhmm.split(":"))
    return day + dt.timedelta(hours=h, minutes=m)  # "24:00" ergibt korrekt den Folgetag


def _span(day, t1, t2):
    s, end = _at(day, t1), _at(day, t2)
    if end <= s:  # z. B. 20:00 bis 05:00 → endet am Folgetag
        end += dt.timedelta(days=1)
    return s, end


def parse_windows(lines):
    """Gibt eine sortierte Liste (start, ende) zurück."""
    text = "\n".join(lines)
    wins = []
    b = re.search(r"Beginn: (\d\d\.\d\d\.\d\d) um (\d\d:\d\d)", text)
    en = re.search(r"Ende: (\d\d\.\d\d\.\d\d) um (\d\d:\d\d)", text)
    if b and en:
        wins.append((_at(_date(b[1]), b[2]), _at(_date(en[1]), en[2])))
    for m in re.finditer(r"(\d\d\.\d\d\.\d\d) (\d\d:\d\d)(?: Uhr)? bis zum (\d\d\.\d\d\.\d\d) (\d\d:\d\d)", text):
        wins.append((_at(_date(m[1]), m[2]), _at(_date(m[3]), m[4])))
    for m in re.finditer(r"^(\d\d\.\d\d\.\d\d) von (\d\d:\d\d) bis (\d\d:\d\d)", text, re.M):
        wins.append(_span(_date(m[1]), m[2], m[3]))
    for m in re.finditer(r"Jeden (.+?) zwischen dem (\d\d\.\d\d\.\d\d) und dem (\d\d\.\d\d\.\d\d) von (\d\d:\d\d) bis (\d\d:\d\d)", text):
        days = set(range(7)) if m[1].startswith("Tag") else {WEEKDAYS[w] for w in re.findall(r"\w+", m[1]) if w in WEEKDAYS}
        d, last = _date(m[2]), _date(m[3])
        while d <= last:
            if d.weekday() in days:
                wins.append(_span(d, m[4], m[5]))
            d += dt.timedelta(days=1)
    ex = re.search(r"gilt nicht an folgenden Tagen:\n([\d., \n]+)", text)
    if ex:
        skip = {_date(s).date() for s in re.findall(r"\d\d\.\d\d\.\d\d", ex[1])}
        wins = [w for w in wins if w[0].date() not in skip or w[1] - w[0] > SHORT]
    return sorted(set(wins))


def total_end(lines):
    m = re.search(r"Ende der Gesamtmaßnahme: (\d\d\.\d\d\.\d\d)", "\n".join(lines))
    return _date(m[1]) if m else None


# ---------- Daten laden und aufbereiten ----------

def load(road, svc):
    p = CACHE / f"{road}_{svc}.json"
    if not p.exists():
        return []
    return json.loads(p.read_text()).get(svc, [])


def where_line(lines):
    return next((l for l in lines if re.match(r"^(A\d+\w*: |Abfahrt|Auffahrt|Ausfahrt|Von |Zufahrt)", l)), "")


def info_line(lines):
    return next((l for l in lines if l.startswith("Länge:")), "").replace("Länge: konnte nicht ermittelt werden", "").strip(" |")


def project_line(lines, used):
    rest = [l for l in lines if l and l not in used and not re.search(r"\d\d\.\d\d\.\d\d|Zeitraum|zu folgenden|gilt nicht|^Länge", l)]
    return rest[-1] if rest else ""


def simplify(coords, max_pts=60):
    """Linie auf höchstens max_pts Punkte ausdünnen und auf ~1 m runden (kleinere Kartendateien)."""
    if len(coords) > max_pts:
        step = (len(coords) - 1) / (max_pts - 1)
        coords = [coords[round(i * step)] for i in range(max_pts)]
    return [[round(c[0], 5), round(c[1], 5)] for c in coords]


def build_items(road):
    items = {}
    for svc in ("closure", "roadworks"):
        for x in load(road, svc):
            d = x.get("description", [])
            wins = parse_windows(d)
            wins = [w for w in wins if w[1] > NOW]
            if not wins:
                continue
            title = re.sub(rf"^{re.escape(road)}\s*\|\s*", "", x.get("title", "")).strip()
            key = (title, x.get("subtitle", "").strip(), tuple(wins))
            blocked = x.get("isBlocked") == "true"
            kind = "Vollsperrung" if blocked else ("Sperrung" if svc == "closure" else "Baustelle")
            if key in items:
                if svc == "closure":
                    items[key]["kind"] = kind
                continue
            where, info = where_line(d), info_line(d)
            c = x.get("coordinate") or {}
            items[key] = dict(
                kind=kind, title=title, dir=x.get("subtitle", "").strip(), wins=wins, total=total_end(d),
                where=where, info=info, project=project_line(d, {where}),
                lat=float(c.get("lat", 0)), lon=float(c.get("long", 0)),
                geom=simplify((x.get("geometry") or {}).get("coordinates") or []),
                lanes=[str(v) for v in ((x.get("impact") or {}).get("symbols") or []) if v],
            )
    out = []
    for it in items.values():
        wins = it["wins"]
        nxt = next(w for w in wins if w[1] > NOW)
        it["next"] = nxt
        it["active"] = any(s <= NOW < en for s, en in wins)
        long_now = any(s <= NOW < en and en - s > SHORT for s, en in wins)
        tonight = any(s < TONIGHT_END and en > NOW and en - s <= SHORT for s, en in wins)
        week = any(NOW < s <= WEEK_END and en - s <= SHORT for s, en in wins)
        if tonight or (it["kind"] == "Vollsperrung" and it["active"]):
            it["sec"] = "heute"
        elif long_now:
            it["sec"] = "dauer"
        elif week:
            it["sec"] = "woche"
        else:
            it["sec"] = "spaeter"
        out.append(it)
    out.sort(key=lambda i: (i["next"][0], i["title"]))
    return out


def build_warnings(road):
    res = []
    for x in load(road, "warning"):
        d = [l for l in x.get("description", []) if l]
        c = x.get("coordinate") or {}
        res.append(dict(
            title=re.sub(rf"^{re.escape(road)}\s*\|\s*", "", x.get("title", "")).strip(),
            dir=x.get("subtitle", "").strip(),
            text=[l for l in d if not l.startswith("Beginn:") and l != "Ereignismeldung:"][:4],
            lat=float(c.get("lat", 0)), lon=float(c.get("long", 0)),
            geom=simplify((x.get("geometry") or {}).get("coordinates") or []),
        ))
    return res


def build_services(road):
    parking = sorted({re.sub(rf"^{re.escape(road)}\s*\|\s*", "", x.get("title", "")).strip() for x in load(road, "parking_lorry")} - {""})
    charging = sorted({re.sub(rf"^{re.escape(road)}\s*\|\s*", "", x.get("title", "")).strip() for x in load(road, "electric_charging_station")} - {""})
    return parking, charging


# ---------- Aufbereitung für die Darstellung ----------

WD_LONG = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
SEV_LABEL = {"voll": "Vollsperrung", "sperr": "Sperrung", "kurz": "Kurzfristige Baustelle", "dauer": "Dauerbaustelle", "live": "Verkehrsmeldung"}
SEV_RANK = {"dauer": 0, "kurz": 1, "sperr": 2, "voll": 3, "live": 4}


def arrow(s):
    return s.replace("->", "→")


def fdate(d, year=True):
    return d.strftime("%d.%m.%Y" if year else "%d.%m.")


def fwin(w):
    s, en = w
    if en - s <= dt.timedelta(hours=24):
        return f"{WD_SHORT[s.weekday()]} {fdate(s, False)} {s:%H:%M} – {en:%H:%M} Uhr"
    return f"{fdate(s)} {s:%H:%M} – {fdate(en)} {en:%H:%M} Uhr"


def day_word(d):
    delta = (d.date() - NOW.date()).days
    if delta == 0:
        return "heute"
    if delta == 1:
        return "morgen"
    if 1 < delta < 7:
        return f"{WD_SHORT[d.weekday()]} {fdate(d, False)}"
    return fdate(d, False)


def hm(t):
    return "24:00" if t.time() == dt.time(0, 0) else t.strftime("%H:%M")


def human_when(w):
    """Zeitangabe so, wie man sie sagen würde: „jetzt bis 05:00“, „heute 20:00–05:00“, „ab Mo 12.10.“."""
    s, en = w
    if s <= NOW < en:
        if en - NOW <= dt.timedelta(hours=30):
            days = (en.date() - NOW.date()).days
            if en.date() == NOW.date() or (en.time() == dt.time(0, 0) and days == 1):
                return f"jetzt bis {hm(en)}"
            if days == 1 and en.hour < 10:
                return f"jetzt bis {hm(en)} morgen früh"
            return f"jetzt bis {hm(en)} ({day_word(en)})"
        return f"jetzt bis {fdate(en)}"
    if en - s <= dt.timedelta(hours=30):
        # 18 Uhr heute bis 6 Uhr morgen früh ist für Menschen „heute Nacht“, nicht „morgen“
        tonight = (s.date() == NOW.date() and s.hour >= 18) or ((s.date() - NOW.date()).days == 1 and s.hour < 6)
        return f"{'heute Nacht' if tonight else day_word(s)} {s:%H:%M}–{hm(en)}"
    return f"ab {day_word(s)} {s:%H:%M}, bis {fdate(en)}"


def maplink(fid, geom):
    if not geom:
        return ""
    return f'<button type="button" class="tomap" data-id="{fid}">Auf der Karte</button>'


LANE_CELL = {"SEPARATE": '<i class="ln sep"></i>', "BORDER_LEFT": '<i class="ln edge"></i>', "BORDER_RIGHT": '<i class="ln edge"></i>'}


def lane_counts(sym):
    """(befahrbare, gesperrte) Fahrstreifen in der eigenen Fahrtrichtung.
    Befahrbar zählt jeder Pfeil in Fahrtrichtung, auch auf dem Standstreifen oder übergeleitet auf die Gegenfahrbahn."""
    left = sym.index("BORDER_LEFT") if "BORDER_LEFT" in sym else -1
    right = sym.index("BORDER_RIGHT") if "BORDER_RIGHT" in sym else len(sym)
    first_sep = sym.index("SEPARATE") if "SEPARATE" in sym else -1
    zone = [v for i, v in enumerate(sym) if first_sep < i < right and i > left]
    return sym.count("ARROW_UP"), zone.count("CLOSED")


def lanes(sym):
    """Querschnitt der Fahrbahn (Grafik) und Klartext für die eigene Fahrtrichtung."""
    if not any(v in ("CLOSED", "ARROW_UP", "ARROW_DOWN") for v in sym):
        return "", ""
    left = sym.index("BORDER_LEFT") if "BORDER_LEFT" in sym else -1
    right = sym.index("BORDER_RIGHT") if "BORDER_RIGHT" in sym else len(sym)
    first_sep = sym.index("SEPARATE") if "SEPARATE" in sym else -1
    cells, opn, closed, opp, shoulder = [], 0, 0, 0, []
    for i, v in enumerate(sym):
        sh = i < left or i > right
        if v in LANE_CELL:
            cells.append(LANE_CELL[v])
            continue
        cls = "sh " if sh or v == "BREAKDOWN_LANE" else ""
        if v == "BREAKDOWN_LANE":
            cells.append('<i class="ln sh"></i>')
        elif v == "CLOSED":
            cells.append(f'<i class="ln {cls}x"></i>')
        elif v == "ARROW_UP":
            cells.append(f'<i class="ln {cls}up">↑</i>')
        elif v == "ARROW_DOWN":
            cells.append(f'<i class="ln {cls}down">↓</i>')
        if i > right:
            shoulder.append(v)
        elif i > first_sep and not sh:
            opn += v == "ARROW_UP"
            closed += v == "CLOSED"
            opp += v == "ARROW_DOWN"
    if opn == 0 and closed:
        text = ["Fahrbahn gesperrt"]
    elif closed:
        text = [f"{opn} von {opn + closed} Spuren frei"]
    else:
        text = [f"{opn} Spur{'en' if opn != 1 else ''} frei"]
    if "CLOSED" in shoulder:
        text.append("Standstreifen zu")
    if "ARROW_UP" in shoulder:
        text.append("Standstreifen befahrbar")
    if opp:
        text.append("Gegenverkehr")
    label = " · ".join(text)
    return f'<span class="road-x" role="img" aria-label="Fahrstreifen: {e(label)}">{"".join(cells)}</span>', label


def places_of(title):
    """„AS Harz - Bockenem“ → ["Harz", "Bockenem"]"""
    out = []
    for part in re.split(r"\s+-\s+|\s+bis\s+", title):
        p = re.sub(r"^A\d+\w*,?\s+", "", part.strip())
        p = re.sub(r"^(AS|AK|AD|AS/AD|AK/AS|Anschlussstelle|Kreuz|Dreieck)\s+", "", p)
        p = re.sub(r"\s*\(.*?\)\s*", " ", p).strip(" ,")
        if 2 < len(p) < 40 and not re.search(r"\d{3}|Vollsperrung|Bauwerk|Fahrbahn|Neubau|Erhalt|Arbeiten|zwischen", p):
            out.append(p)
    return out


# ---------- Richtung und Reihenfolge entlang der Strecke ----------

def to_km(lon, lat, lat0):
    return lon * 111.32 * math.cos(math.radians(lat0)), lat * 110.57


def road_axis(items, warns):
    """Hauptachse der Autobahn (Nord–Süd oder West–Ost), damit Meldungen in Fahrreihenfolge sortiert werden können."""
    pts = [it["geom"][len(it["geom"]) // 2] for it in items + warns if it.get("geom")]
    if len(pts) < 2:
        return None
    lat0 = sum(p[1] for p in pts) / len(pts)
    xy = [to_km(p[0], p[1], lat0) for p in pts]
    mx, my = sum(x for x, _ in xy) / len(xy), sum(y for _, y in xy) / len(xy)
    sxx = sum((x - mx) ** 2 for x, _ in xy)
    syy = sum((y - my) ** 2 for _, y in xy)
    sxy = sum((x - mx) * (y - my) for x, y in xy)
    th = 0.5 * math.atan2(2 * sxy, sxx - syy)
    vx, vy = math.cos(th), math.sin(th)
    ns = abs(vy) >= abs(vx)
    # Liste von oben nach unten lesen: Nord → Süd bzw. West → Ost
    if (ns and vy > 0) or (not ns and vx < 0):
        vx, vy = -vx, -vy
    return dict(lat0=lat0, mx=mx, my=my, vx=vx, vy=vy, ns=ns)


def along(ax, lon, lat):
    x, y = to_km(lon, lat, ax["lat0"])
    return (x - ax["mx"]) * ax["vx"] + (y - ax["my"]) * ax["vy"]


def assign_directions(road, items, warns):
    ax = road_axis(items, warns)
    groups = {"plus": [], "minus": []}
    for it in items + warns:
        g = it.get("geom") or []
        it["t"] = along(ax, *g[len(g) // 2]) if ax and g else 0.0
        it["d"] = ""
        if ax and len(g) >= 2:
            dlt = along(ax, *g[-1]) - along(ax, *g[0])
            if abs(dlt) > 0.03:
                it["d"] = "plus" if dlt > 0 else "minus"
    # Meldungen ohne verwertbare Linie: Richtung über den gleichen Richtungstext der anderen Meldungen
    votes = {}
    for it in items + warns:
        if it["d"]:
            votes.setdefault(it["dir"], []).append(it["d"])
    for it in items + warns:
        if not it["d"] and votes.get(it["dir"]):
            v = votes[it["dir"]]
            it["d"] = max(set(v), key=v.count)
        if it["d"]:
            groups[it["d"]].append(it)
    labels = {}
    for k, lst in groups.items():
        # Ziel benennen, das am weitesten in Fahrtrichtung liegt (≈ Ende der Autobahn), nicht das nächste Kreuz
        pos = {}
        for i in lst:
            if "->" in i["dir"]:
                tg = i["dir"].split("->")[-1].strip()
                if tg and not tg.startswith(("AS ", "AK ", "AD ")):
                    pos.setdefault(tg, []).append(i["t"])
        pos = {k: sum(v) / len(v) for k, v in pos.items() if len(v) >= 2} or {k: sum(v) / len(v) for k, v in pos.items()}
        targets = [max(pos, key=pos.get) if k == "plus" else min(pos, key=pos.get)] if pos else []
        if ax:
            compass = ("Süden" if k == "plus" else "Norden") if ax["ns"] else ("Osten" if k == "plus" else "Westen")
            sym = ("↓" if k == "plus" else "↑") if ax["ns"] else ("→" if k == "plus" else "←")
        else:
            compass, sym = "", ""
        name = max(set(targets), key=targets.count) if targets else compass
        labels[k] = dict(name=name, compass=compass, sym=sym, n=len(lst))
    return ax, labels


def enrich(it):
    """Zeit-Filter und Schweregrad für eine Meldung."""
    wins = it["wins"]
    it["w_heute"] = any(s < TONIGHT_END and en > NOW for s, en in wins)
    it["w_woche"] = any(s < WEEK_END and en > NOW for s, en in wins)
    long_win = any(en - s > SHORT for s, en in wins if en > NOW and s < WEEK_END)
    # Das API-Feld isBlocked ist immer „false“. Vollsperrung daher aus Spurdaten oder Text ableiten.
    sym = it.get("lanes") or []
    opn, closed = lane_counts(sym)
    fully = (closed > 0 and opn == 0) or "Vollsperrung" in f"{it['title']} {it.get('project', '')}"
    where = it.get("where", "")
    # „Von Auffahrt auf die A1 … nach A1“ / „… nach Abfahrt“: die Spurdaten beschreiben dann die Rampe, nicht die Autobahn
    ramp = (where.startswith(("Abfahrt", "Auffahrt", "Ausfahrt", "Zufahrt", "Von Auffahrt", "Von Abfahrt"))
            or "nach Abfahrt" in where or (where.startswith("Von ") and "zwischen" not in where))
    it["label"] = None
    if fully and not ramp:
        it["sev"], it["label"] = "voll", "Vollsperrung"
    elif fully:
        # Monatelang gesperrte Rampe gehört zu den Dauerbaustellen, kurzfristige bleibt oben sichtbar
        it["sev"] = "dauer" if long_win else "sperr"
        it["label"] = "Abfahrt gesperrt" if where.startswith(("Abfahrt", "Ausfahrt")) or "nach Abfahrt" in where else "Auffahrt gesperrt" if "Auffahrt" in where else "Zufahrt gesperrt"
    elif it["kind"] == "Sperrung":
        it["sev"] = "sperr" if not long_win else "dauer"
    else:
        it["sev"] = "dauer" if long_win else "kurz"
    # Für die Anzeige: das Zeitfenster, das jetzt gilt, sonst das nächste
    it["show"] = next((w for w in wins if w[0] <= NOW < w[1]), it["next"])


# ---------- HTML-Bausteine ----------

# ---------- Meldungen zu einer Maßnahme zusammenfassen ----------
# Die API meldet eine Baustelle mehrfach: je Fahrtrichtung, dazu jede gesperrte Auf-/Abfahrt.
# Für Menschen ist das eine Baustelle mit mehreren Folgen. Darum fassen wir nach Maßnahme + Zeitfenster zusammen.

RAMP_LABELS = ("Abfahrt gesperrt", "Auffahrt gesperrt", "Zufahrt gesperrt")


def plain_place(s):
    s = re.sub(r"\bAS\s+", "", s)
    s = re.sub(r"\bAK\s+", "Kreuz ", s)
    s = re.sub(r"\bAD\s+", "Dreieck ", s)
    s = re.sub(r"(\d+)\.(\d) km", r"\1,\2 km", s)
    return s.strip(" ,")


def plain_where(where):
    """Maschinentext der API → „zwischen Filandastraße und 0,9 km vor Kreuz Schöneberg“"""
    w = arrow(where or "")
    m = re.search(r"zwischen .+?(?= nach Abfahrt| nach Auffahrt|$)", w)
    if m:
        return plain_place(m.group(0))
    return plain_place(re.sub(r"^(Von )?A\d+\w*:\s*[^,]+,\s*", "", w))


def ramp_text(it):
    """„Auffahrt Feuerbachstraße (aus Richtung Saarstraße) gesperrt“"""
    w = arrow(it.get("where", ""))
    lab = it.get("label") or ""
    kind = lab.split()[0] if lab else "Zufahrt"
    m = None
    if kind == "Auffahrt":
        m = re.search(r"Auffahrt auf die A\d+\w*:\s*([^(]+?)\s*(?:\(|nach|$)", w)
    elif kind == "Abfahrt":
        m = re.search(r"Abfahrt von der A\d+\w*:\s*([^(]+?)\s*(?:\(|$)", w)
    name = plain_place(m.group(1)) if m else ""
    m2 = re.search(r"\(aus Richtung ([^)]+)\)", w)
    extra = f" (aus Richtung {plain_place(m2.group(1))})" if m2 else ""
    return f"{kind} {name}{extra} gesperrt" if name else f"{kind} gesperrt"


def nice_title(project, members):
    t = (project or members[0]["title"]).strip()
    t = re.sub(r"^(A\s?\d+\w*)[,:\s–-]+", "", t)
    t = re.sub(r"^(VIA|Via)\s+\w+\s+A\d+\w*\s+", "", t)
    # „… zwischen AS X und AS Y (km 2-3), beide FR“ → der Abschnitt steht ohnehin separat
    t = re.split(r",?\s+zwischen\s+", t)[0]
    t = re.sub(r",?\s*(beide FR|beide Fahrtrichtungen|bde\.? FR|FR\s+\w+|RF\s+\w+)\s*$", "", t, flags=re.I)
    t = re.sub(r"\s*\((km|Km)[^)]*\)", "", t)
    t = plain_place(re.sub(r"\s+", " ", t.replace("_", "/"))).strip(" ,-–")
    return (t[:1].upper() + t[1:]) if t else members[0]["title"]


WORK_WORDS = r"[\wäöüß-]*(arbeiten|instandsetzung|instandhaltung|sanierung|erneuerung|neubau|ersatzneubau|umbau|ausbau|rückbau|aufbau|abbau|markierung|reparatur|prüfung|reinigung|grasmahd|mahd|gehölz\w*|leitungs\w*|brücken\w*|tunnel\w*|versiegelung|deckenbau|asphalt\w*|betonsanierung|fahrbahn\w*|bauwerk\w*|beschilderung|sperrung|wartung|montage|verlegung)[\wäöüß-]*"
WORK_PREFIX = {"grundhafte", "grundhafter", "grundhaften", "teilweise", "nächtliche", "kleine", "große", "vollständige", "komplette", "provisorische"}


def what_of(project):
    """Aus „Büdelsdorf bis Bundesgrenze Dänemark beide RiFa Arbeiten an Schutzeinrichtungen“ → „Arbeiten an Schutzeinrichtungen“"""
    t = project or ""
    t = re.sub(r"\((AS|AD|AK)\)", "", t)
    t = re.sub(r"\b(beide|bde\.?)\s+(RiFa|FR|Fahrtrichtungen|Richtungen)\b", "", t, flags=re.I)
    t = re.sub(r"\b(RiFa|FR|RF)\s+[\wäöüß/-]+", "", t)
    t = re.sub(r"\bkm\s*[\d,.\-–]+", "", t)
    t = re.sub(r"\s+", " ", t).strip(" ,-–")
    m = re.search(WORK_WORDS, t, flags=re.I)
    if not m:
        return ""
    before = t[:m.start()].rstrip(" ,").split(" ")
    pre = before[-1] if before and before[-1].lower() in WORK_PREFIX else ""
    rest = re.split(r"[;(]", t[m.start():])[0]
    rest = re.sub(r"^\s*A\s?\d+\w*\s+", "", rest)
    phrase = f"{pre} {rest}".strip(" ,-–")
    phrase = re.sub(r"\s+", " ", phrase)
    return (phrase[:1].upper() + phrase[1:])[:70]


def section_of(members):
    names = []
    for m in sorted(members, key=lambda x: x["t"]):
        for pl in places_of(m["title"]):
            if pl not in names:
                names.append(pl)
    if len(names) >= 2:
        return f"{names[0]} – {names[-1]}"
    return names[0] if names else ""


def group_items(items):
    buckets = {}
    for it in items:
        key = (re.sub(r"\s+", " ", (it.get("project") or it["title"]).lower()), it["show"][0], it["show"][1])
        buckets.setdefault(key, []).append(it)
    groups = []
    for n, (key, mem) in enumerate(buckets.items()):
        gid = f"g{n}"
        for m in mem:
            m["g"] = gid
        main = [m for m in mem if (m.get("label") or "") not in RAMP_LABELS]
        ramps = [m for m in mem if (m.get("label") or "") in RAMP_LABELS]
        sev = max(mem, key=lambda m: SEV_RANK[m["sev"]])["sev"]
        dirs = []
        for d in ("minus", "plus", ""):
            ms = [m for m in main if m["d"] == d]
            if not ms:
                continue
            # bei mehreren Einträgen je Richtung den mit den meisten gesperrten Spuren zeigen
            best = max(ms, key=lambda m: lane_counts(m.get("lanes") or [])[1])
            dirs.append(dict(d=d, raw=arrow(best["dir"]), lanes=best.get("lanes") or [], laneText=lanes(best.get("lanes") or [])[1],
                             where=plain_where(best.get("where", "")), info=best.get("info", "")))
        if sev == "voll":
            label = "Vollsperrung"
        elif not main and ramps:
            label = "Auffahrt/Abfahrt gesperrt" if len({r["label"] for r in ramps}) > 1 else ramps[0]["label"]
        else:
            label = SEV_LABEL[sev]
        upcoming = max((len([w for w in m["wins"] if w[1] > NOW]) for m in mem), default=1)
        total = max((m["total"] for m in mem if m.get("total")), default=None)
        section = section_of(mem)
        what = what_of(mem[0].get("project") or "")
        groups.append(dict(
            id=gid, items=[m["id"] for m in mem], title=section or nice_title(mem[0].get("project"), mem), section=section, what=what,
            sev=sev, label=label, active=any(m["active"] for m in mem),
            heute=any(m["w_heute"] for m in mem), woche=any(m["w_woche"] for m in mem),
            show=mem[0]["show"], when=human_when(mem[0]["show"]), upcoming=upcoming, total=total,
            dirs=dirs, ramps=[ramp_text(r) for r in ramps],
            project=mem[0].get("project", ""), raw_titles=[m["title"] for m in mem],
            t=sum(m["t"] for m in mem) / len(mem), d=sorted({m["d"] for m in mem if m["d"]}),
            lat=mem[0]["lat"], lon=mem[0]["lon"], geom=[g for m in mem for g in (m.get("geom") or [])],
        ))
    groups.sort(key=lambda g: g["t"])
    return groups


def stop(g, labels):
    when = g["when"]
    tokens = " ".join(k for k, on in (("heute", g["heute"]), ("woche", g["woche"]), ("geplant", not g["heute"]), ("alle", True)) if on)
    q = " ".join([g["title"], g["section"], g["project"]] + g["raw_titles"] + [d["raw"] for d in g["dirs"]]).lower()
    now_badge = '<span class="badge now">jetzt</span>' if g["active"] else ""
    if g["active"]:
        when = when.removeprefix("jetzt ")
    lines = []
    for d in g["dirs"]:
        lab = labels.get(d["d"]) if d["d"] else None
        name = f'{lab["sym"]} {e(lab["name"])}' if lab else e(d["raw"] or "beide Richtungen")
        graphic, _ = lanes(d["lanes"])
        txt = e(d["laneText"]) if d["laneText"] else ("gesperrt" if g["sev"] == "voll" else "Baustelle")
        lines.append(f'<span class="dirline"><span class="dl">{name}</span>{graphic}<span class="dt">{txt}</span></span>')
    for r in g["ramps"]:
        lines.append(f'<span class="dirline ramp"><span class="dl">{e(r.replace(" gesperrt", ""))}</span><span class="dt closed">gesperrt</span></span>')
    rows = [("Zeitraum", fwin(g["show"]))]
    if g["upcoming"] > 1:
        rows.append(("Weitere Termine", f"{g['upcoming'] - 1} weitere"))
    if g["total"] and g["total"].date() > g["show"][1].date():
        rows.append(("Gesamte Maßnahme bis", fdate(g["total"])))
    for d in g["dirs"]:
        lab = labels.get(d["d"]) if d["d"] else None
        name = f'{lab["sym"]} {lab["name"]}' if lab else (d["raw"] or "Lage")
        if d["where"]:
            rows.append((name, d["where"]))
        if d["info"]:
            rows.append(("Details", d["info"].replace("Maximale Durchfahrtsbreite", "Breite").replace("Max. ", "max. ").replace(" | ", " · ")))
    if g["project"]:
        rows.append(("Originalmeldung", g["project"]))
    return f"""<li class="stop sev-{g['sev']}" id="{g['id']}" data-t="{g['t']:.2f}" data-d="{' '.join(g['d'])}" data-w="{tokens}" data-q="{e(q)}" data-ll="{g['lat']:.4f},{g['lon']:.4f}">
<details><summary>
<span class="node" aria-hidden="true"></span>
<span class="s-main"><span class="s-when">{now_badge}{e(when)}</span><span class="s-name">{e(g['title'])}</span>
<span class="s-sub">{e(g['label'])}{(' · ' + e(g['what'])) if g['what'] else ''}</span>
<span class="dirs">{''.join(lines)}</span></span>
<span class="chev" aria-hidden="true"></span>
</summary>
<div class="s-body"><dl>{''.join(f'<div><dt>{e(k)}</dt><dd>{e(v)}</dd></div>' for k, v in rows)}</dl>{maplink(g['id'], g['geom'])}</div>
</details></li>"""


def warn_stop(w, labels):
    dlab = labels.get(w["d"]) if w["d"] else None
    dir_txt = f'{dlab["sym"]} Richtung {e(dlab["name"])}' if dlab else f"Richtung {e(arrow(w['dir']))}"
    txt = w["text"]
    return f"""<li class="stop sev-live" id="{w['id']}" data-t="{w['t']:.2f}" data-d="{w['d']}" data-w="heute woche alle" data-q="{e((w['title'] + ' ' + w['dir']).lower())}" data-ll="{w['lat']:.4f},{w['lon']:.4f}">
<details><summary><span class="node" aria-hidden="true"></span>
<span class="s-main"><span class="s-when"><span class="badge live">live</span>{e(txt[0] if txt else 'aktuell')}</span><span class="s-name">{e(w['title'])}</span>
<span class="s-sub">Stau, Unfall oder Gefahr · {dir_txt}</span></span><span class="chev" aria-hidden="true"></span></summary>
<div class="s-body">{''.join(f'<p>{e(arrow(t))}</p>' for t in txt[1:])}{maplink(w['id'], w['geom'])}</div></details></li>"""


def features(items, warns, road=None, ids=None):
    """GeoJSON für die Karte: je Meldung eine Linie plus ein Punkt für die Übersicht bei kleinem Zoom."""
    out = []
    for it in items + warns:
        g = it.get("geom")
        if not g:
            continue
        live = it in warns
        props = dict(id=it["id"], g=it.get("g", it["id"]), sev="live" if live else it["sev"], now=1 if live or it.get("active") else 0,
                     title=it["title"], kind=SEV_LABEL["live"] if live else (it.get("label") or SEV_LABEL[it["sev"]]),
                     when=(it["text"][0] if live and it["text"] else "" if live else human_when(it["show"])))
        if road:
            props.update(road=road, url=f"{BASE}/{slug(road)}/#{it['id']}")
        out.append(dict(type="Feature", properties=props, geometry=dict(type="LineString", coordinates=g)))
        out.append(dict(type="Feature", properties=dict(props, pt=1), geometry=dict(type="Point", coordinates=g[len(g) // 2])))
    return {"type": "FeatureCollection", "features": out}


def status_of(items, warns):
    """Ampel für eine Autobahn."""
    today = [i for i in items if i["w_heute"]]
    if any(i["sev"] == "voll" for i in today):
        return "rot", "Vollsperrung heute"
    if warns:
        return "rot", "Stau oder Gefahr gemeldet"
    if any(i["sev"] in ("sperr", "kurz") for i in today):
        return "gelb", "Eingeschränkt heute"
    if today:
        return "gruen", "Nur Dauerbaustellen"
    return "gruen", "Keine Meldungen"


def plural(n, one, many):
    return f"{n} {one if n == 1 else many}"


def lage(road, items, warns):
    """Lagebericht in ganzen Sätzen statt Tabellen."""
    today = [i for i in items if i["w_heute"]]
    full = [i for i in today if i["sev"] == "voll"]
    short = [i for i in today if i["sev"] in ("sperr", "kurz")]
    dauer = [i for i in today if i["sev"] == "dauer"]
    out = []
    if full:
        f = full[0]
        out.append(f"Heute ist die {road} an {plural(len(full), 'Stelle', 'Stellen')} voll gesperrt, zum Beispiel {f['title']} ({human_when(f['show'])}).")
    if short:
        night = sum(1 for i in short if i["show"][0].hour >= 18 or i["show"][0].hour < 5)
        when = ({1: " Sie gilt nachts.", 2: " Beide gelten nachts."}.get(len(short), " Die meisten davon nachts.")) if night > len(short) * 0.6 else ""
        pl = [p for i in short for p in places_of(i["title"])]
        hot = max(set(pl), key=pl.count) if pl else ""
        where = f" Am meisten los ist rund um {hot}." if hot and pl.count(hot) >= 2 else ""
        out.append(f"Bis morgen früh gibt es {plural(len(short), 'kurzfristige Sperrung oder Baustelle', 'kurzfristige Sperrungen und Baustellen')}.{when}{where}")
    if warns:
        out.append(f"Gerade {'liegt' if len(warns) == 1 else 'liegen'} {plural(len(warns), 'Meldung', 'Meldungen')} zu Stau, Unfall oder Gefahren vor.")
    if dauer:
        out.append(f"Dazu kommen {plural(len(dauer), 'Dauerbaustelle', 'Dauerbaustellen')}, meist mit verengten Spuren.")
    if not out:
        out.append(f"Für die {road} sind heute keine Sperrungen oder Baustellen gemeldet.")
    return " ".join(out)


def page(title, desc, path, body, jsonld=(), extra_head="", body_class=""):
    canonical = SITE_URL + path
    ld = "".join(f'<script type="application/ld+json">{json.dumps(j, ensure_ascii=False)}</script>' for j in jsonld)
    return f"""<!doctype html>
<html lang="de" data-base="{BASE}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<link rel="canonical" href="{canonical}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{e(SITE_NAME)}">
<meta property="og:title" content="{e(title)}">
<meta property="og:description" content="{e(desc)}">
<meta property="og:url" content="{canonical}">
<meta property="og:locale" content="de_DE">
<meta name="theme-color" content="#1650a8">
<link rel="icon" href="/assets/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/style.css?v={VER}">
{ld}{extra_head}
</head>
<body class="{body_class}">
<header class="bar"><div class="bar-in">
<a href="/" class="brand" aria-label="{e(SITE_NAME)} – Startseite"><span class="brand-mark" aria-hidden="true"></span>{wordmark()}</a>
<span class="fresh">Aktualisiert {NOW:%H:%M} Uhr</span>
</div></header>
{body}
<footer class="foot"><div class="foot-in">
<p><strong>{e(SITE_NAME)}</strong> zeigt die offiziellen Daten der <a href="https://www.autobahn.de" rel="nofollow">Autobahn GmbH des Bundes</a>, alle 15 Minuten neu, Staus live. Angaben ohne Gewähr, vor der Fahrt zusätzlich Verkehrsfunk oder Navi prüfen.</p>
<p><a href="/">Alle Autobahnen</a> · <a href="/impressum/">Impressum</a> · <a href="/datenschutz/">Datenschutz</a></p>
</div></footer>
</body>
</html>"""


VER = NOW.strftime("%Y%m%d%H%M")


def wordmark():
    """„Stauklar“ als Wortmarke: „klar“ farbig abgesetzt. Andere Namen (SITE_NAME) bleiben schlicht."""
    if SITE_NAME.lower() == "stauklar":
        return '<span class="wm">Stau<span class="klar">klar</span></span>'
    return e(SITE_NAME)
MAP_HEAD = f'<link rel="stylesheet" href="/vendor/maplibre-gl.css"><script src="/vendor/maplibre-gl.js" defer></script><script src="/assets/app.js?v={VER}" defer></script>'


def num_key(road):
    m = re.match(r"A(\d+)(.*)", road)
    return (int(m[1]), m[2]) if m else (9999, road)


def slug(road):
    return road.lower()


def centroid(items, warns):
    pts = [(i["lat"], i["lon"]) for i in items + warns if i["lat"]]
    if not pts:
        return None
    return sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)


def dist_km(a, b):
    return math.hypot((a[1] - b[1]) * 111 * math.cos(math.radians(a[0])), (a[0] - b[0]) * 111)


def seg(name, options, current):
    """Segmentierter Umschalter (wie in iOS)."""
    btns = "".join(
        f'<button type="button" role="radio" aria-checked="{"true" if v == current else "false"}" data-v="{v}">{lab}<span class="n" data-n="{v}"></span></button>'
        for v, lab in options)
    return f'<div class="seg" role="radiogroup" data-seg="{name}">{btns}</div>'


def road_page(road, d, near):
    items, warns, labels = d["items"], d["warns"], d["labels"]
    today = [i for i in items if i["w_heute"]]
    week = [i for i in items if i["w_woche"]]
    status, status_txt = status_of(items, warns)
    lage_txt = lage(road, items, warns)
    n_full = sum(i["sev"] == "voll" for i in today)
    n_short = sum(i["sev"] in ("sperr", "kurz") for i in today)
    n_dauer = sum(i["sev"] == "dauer" for i in today)
    default_w = "heute" if today or warns else ("woche" if week else "alle")

    groups = d["groups"]
    stops = sorted([(gr["t"], stop(gr, labels)) for gr in groups] + [(w["t"], warn_stop(w, labels)) for w in warns], key=lambda x: x[0])
    route = "".join(h for _, h in stops)

    dir_opts = [("", "Beide Richtungen")]
    for k in ("minus", "plus"):
        if labels.get(k, {}).get("n"):
            dir_opts.append((k, f'{labels[k]["sym"]} {e(labels[k]["name"])}'))
    ends = ""
    if d["ax"]:
        ends = ("Norden", "Süden") if d["ax"]["ns"] else ("Westen", "Osten")

    title = f"{road} heute: Sperrungen, Baustellen & Staus | {SITE_NAME}"
    desc = f"{lage_txt} Stand {NOW:%d.%m.%Y, %H:%M} Uhr."
    if len(desc) > 300:
        desc = desc[:297].rsplit(" ", 1)[0] + " …"

    # Fragen und Antworten aus den echten Daten
    faq = []
    closed = [i for i in today if i["sev"] in ("voll", "sperr")]
    if closed:
        ex = "; ".join(f"{i['title']} ({human_when(i['show'])})" for i in closed[:3])
        faq.append((f"Ist die {road} heute gesperrt?", f"Ja, heute und heute Nacht gibt es {plural(len(closed), 'Sperrung', 'Sperrungen')}, zum Beispiel: {ex}."))
    elif n_short:
        faq.append((f"Ist die {road} heute gesperrt?", f"Eine Sperrung ist nicht gemeldet, aber {plural(n_short, 'kurzfristige Baustelle', 'kurzfristige Baustellen')} bis morgen früh, oft mit gesperrten Spuren."))
    else:
        faq.append((f"Ist die {road} heute gesperrt?", f"Für heute sind auf der {road} keine kurzfristigen Sperrungen gemeldet (Stand {NOW:%d.%m.%Y, %H:%M} Uhr)."))
    faq.append((f"Wie viele Baustellen gibt es auf der {road}?", f"Heute gelten {plural(len(today), 'Baustelle oder Sperrung', 'Baustellen und Sperrungen')}, davon {n_dauer} Dauerbaustellen. In den nächsten 7 Tagen sind es {len(week)}."))
    longest = max((i for i in items if i.get("total")), key=lambda i: i["total"], default=None)
    if longest:
        faq.append((f"Welche Baustelle auf der {road} dauert am längsten?", f"„{longest['project'] or longest['title']}“ ({longest['title']}) ist laut Autobahn GmbH bis {fdate(longest['total'])} geplant."))
    if d["parking"] or d["charging"]:
        faq.append((f"Wo gibt es an der {road} Rastplätze und Ladesäulen?", f"Die Autobahn GmbH listet {plural(len(d['parking']), 'Rast- oder Parkplatz', 'Rast- und Parkplätze')} und {plural(len(d['charging']), 'Standort', 'Standorte')} mit Ladesäulen. Die Liste steht unten auf dieser Seite."))

    svc = ""
    if d["parking"] or d["charging"]:
        cols = []
        if d["parking"]:
            cols.append(f'<details class="more"><summary>{plural(len(d["parking"]), "Rast- oder Parkplatz", "Rast- und Parkplätze")}</summary><ul class="cols">{"".join(f"<li>{e(p)}</li>" for p in d["parking"])}</ul></details>')
        if d["charging"]:
            cols.append(f'<details class="more"><summary>{plural(len(d["charging"]), "Ladesäulen-Standort", "Ladesäulen-Standorte")}</summary><ul class="cols">{"".join(f"<li>{e(p)}</li>" for p in d["charging"])}</ul></details>')
        svc = f'<section class="block"><h2>Pause machen an der {e(road)}</h2>{"".join(cols)}</section>'

    near_html = "".join(f'<a class="shield" href="/{slug(r)}/">{e(r)}</a>' for r in near)

    body = f"""
<main>
<section class="hero hero-road st-{status}">
  <div class="hero-in">
    <div class="hero-top"><span class="shield xl">{e(road)}</span><span class="status"><i></i>{status_txt}</span></div>
    <h1>{e(road)} heute</h1>
    <p class="lage">{e(lage_txt)}</p>
    <ul class="kpis">
      <li class="k-voll"><b>{n_full}</b>Vollsperrungen</li>
      <li class="k-kurz"><b>{n_short}</b>kurzfristig bis morgen früh</li>
      <li class="k-live"><b id="live-count">{len(warns)}</b>Staus &amp; Gefahren</li>
      <li class="k-dauer"><b>{n_dauer}</b>Dauerbaustellen</li>
    </ul>
  </div>
</section>

<div class="controls" id="controls"><div class="controls-in">
  {seg("w", [("heute", "Heute"), ("woche", "7 Tage"), ("geplant", "Geplant"), ("alle", "Alles")], default_w)}
  {seg("d", dir_opts, "") if len(dir_opts) > 2 else ''}
  <label class="tog"><input type="checkbox" id="dauer"{"" if (n_short or n_full or warns) else " checked"}><span class="tog-ui" aria-hidden="true"></span>Dauerbaustellen</label>
  <button type="button" class="locate" id="locate"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M14.3 1.7 1.9 6.6c-.7.3-.6 1.3.1 1.5l5 1.4 1.4 5c.2.7 1.2.8 1.5.1l4.9-12.4c.3-.7-.4-1.4-1.1-1.1z" fill="currentColor"/></svg><span class="lbl">In meiner Nähe</span></button>
  <label class="find"><span class="sr">Ort oder Abschnitt suchen</span><input id="find" type="search" placeholder="Stadt oder Anschlussstelle, z. B. {e((places_of(items[0]['title']) or ['Kassel'])[0]) if items else 'Kassel'}" autocomplete="off"></label>
</div></div>

<div class="split" data-road="{e(road)}" data-ax="{e(json.dumps(d['ax'])) if d['ax'] else ''}" data-labels="{e(json.dumps(labels, ensure_ascii=False))}">
  <div class="mapcol"><div id="map" data-src="map.json" role="region" aria-label="Karte der {e(road)}"></div>
    <div class="legend"><span><i class="sw voll"></i>Vollsperrung</span><span><i class="sw sperr"></i>Sperrung</span><span><i class="sw kurz"></i>kurzfristig</span><span><i class="sw dauer"></i>Dauerbaustelle</span><span><i class="sw live"></i>Stau/Gefahr</span></div>
  </div>
  <div class="listcol">
    <h2 class="route-h">Entlang der Strecke <span class="route-n" id="route-n"></span></h2>
    {f'<p class="route-end end-a">{ends[0]}</p>' if ends else ''}
    <ol class="route" id="route">{route}</ol>
    {f'<p class="route-end end-b">{ends[1]}</p>' if ends else ''}
    <p class="empty" id="empty" hidden>Für diese Auswahl ist nichts gemeldet. Gute Fahrt!</p>
  </div>
</div>

<div class="after">
<details class="more glossar"><summary>Was bedeuten die Begriffe?</summary>
<dl class="gl">
<div><dt><i class="sw voll"></i>Vollsperrung</dt><dd>In dieser Richtung geht nichts mehr durch. Umleitung nötig.</dd></div>
<div><dt><i class="sw sperr"></i>Sperrung</dt><dd>Eine Auf- oder Abfahrt oder ein kurzer Abschnitt ist dicht, meist nachts für wenige Stunden.</dd></div>
<div><dt><i class="sw kurz"></i>Kurzfristige Baustelle</dt><dd>Höchstens drei Tage, oft nur eine Nacht. Spuren sind verengt oder gesperrt, es geht aber durch.</dd></div>
<div><dt><i class="sw dauer"></i>Dauerbaustelle</dt><dd>Läuft Wochen bis Jahre. Man kennt sie meist schon, darum ist sie standardmäßig ausgeblendet.</dd></div>
<div><dt><i class="sw live"></i>Stau oder Gefahr</dt><dd>Aktuelle Meldung der Autobahn GmbH, alle zwei Minuten neu geladen.</dd></div>
<div><dt>Spurgrafik</dt><dd>Zeigt die Fahrbahn in Fahrtrichtung: Pfeil = Spur frei, rot-weiß = Spur gesperrt, schmaler Streifen = Standstreifen, gelbe Linie = Mittelstreifen.</dd></div>
</dl></details>
<aside class="app-teaser">
  <div><h2>Sag mir einfach Bescheid, wenn's auf meiner Strecke zu ist.</h2>
  <p>Bald als App: Strecke auf der {e(road)} einmal festlegen, morgens eine Nachricht bekommen, wenn dort heute gesperrt wird.</p></div>
  <span class="soon">Kommt bald</span>
</aside>
{svc}
<section class="block faq"><h2>Häufige Fragen zur {e(road)}</h2>
{''.join(f'<details class="more"><summary>{e(q)}</summary><p>{e(a)}</p></details>' for q, a in faq)}
</section>
<section class="block"><h2>Autobahnen in der Nähe</h2><div class="shields">{near_html}</div></section>
</div>
</main>"""

    jsonld = [
        {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": SITE_NAME, "item": SITE_URL + "/"},
            {"@type": "ListItem", "position": 2, "name": road, "item": f"{SITE_URL}/{slug(road)}/"}]},
        {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in faq]},
        {"@context": "https://schema.org", "@type": "WebPage", "name": title, "dateModified": NOW.replace(tzinfo=TZ).isoformat(), "inLanguage": "de-DE"},
    ]
    return page(title, desc, f"/{slug(road)}/", body, jsonld, extra_head=MAP_HEAD, body_class="p-road")


def index_page(roads, data):
    all_today = [(r, i) for r in roads for i in data[r]["items"] if i["w_heute"]]
    n_full = sum(i["sev"] == "voll" for _, i in all_today)
    n_short = sum(i["sev"] in ("sperr", "kurz") for _, i in all_today)
    n_warn = sum(len(data[r]["warns"]) for r in roads)

    def score(r):
        it = [i for i in data[r]["items"] if i["w_heute"]]
        return sum({"voll": 5, "sperr": 2, "kurz": 1}.get(i["sev"], 0) for i in it) + 3 * len(data[r]["warns"])

    top = sorted(roads, key=score, reverse=True)[:6]
    cards = []
    for r in top:
        d = data[r]
        st, st_txt = status_of(d["items"], d["warns"])
        it = [i for i in d["items"] if i["w_heute"]]
        nf = sum(i["sev"] == "voll" for i in it)
        ns = sum(i["sev"] in ("sperr", "kurz") for i in it)
        cards.append(f"""<a class="hot st-{st}" href="/{slug(r)}/">
<span class="hot-top"><span class="shield lg">{e(r)}</span><span class="status"><i></i>{st_txt}</span></span>
<span class="hot-txt">{e(lage(r, d['items'], d['warns']).split('. ')[0].rstrip('.'))}.</span>
<span class="hot-n"><span><b>{nf}</b> voll gesperrt</span><span><b>{ns}</b> kurzfristig</span><span><b>{len(d['warns'])}</b> Staus</span></span></a>""")

    tiles = []
    for r in roads:
        st, st_txt = status_of(data[r]["items"], data[r]["warns"])
        tiles.append(f'<li><a href="/{slug(r)}/" class="tile st-{st}" data-r="{e(r.lower())}" title="{e(st_txt)}"><span class="shield">{e(r)}</span><i></i></a></li>')

    body = f"""
<main>
<section class="hero hero-home">
  <div class="hero-in">
    <div>
    <h1>Wie frei ist deine Autobahn heute?</h1>
    <p class="lage">Sperrungen, Baustellen und Staus auf allen {len(roads)} Autobahnen, genau auf der Karte. Mit Spurgrafik, damit du siehst, welche Spur zu ist.</p>
    <div class="search" role="search">
      <label for="q" class="sr">Autobahn oder Ort</label>
      <input id="q" type="search" placeholder="Autobahn oder Stadt, z. B. A7 oder Berlin" autocomplete="off" aria-controls="sugg" aria-expanded="false">
      <ul id="sugg" class="sugg" role="listbox" hidden></ul>
    </div>
    <button type="button" class="locate big" id="locate"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M14.3 1.7 1.9 6.6c-.7.3-.6 1.3.1 1.5l5 1.4 1.4 5c.2.7 1.2.8 1.5.1l4.9-12.4c.3-.7-.4-1.4-1.1-1.1z" fill="currentColor"/></svg><span class="lbl">In meiner Nähe</span></button>
    <p class="quick">Heute viel los: {''.join(f'<a class="shield" href="/{slug(r)}/">{e(r)}</a>' for r in top)}</p>
    </div>
    <aside class="now-box" aria-label="Lage in Deutschland">
      <p class="now-h">Deutschland bis morgen früh</p>
      <ul class="kpis stack"><li class="k-voll"><b>{n_full}</b>Vollsperrungen</li><li class="k-kurz"><b>{n_short}</b>kurzfristige Sperrungen &amp; Baustellen</li><li class="k-live"><b>{n_warn}</b>Staus &amp; Gefahren gerade</li></ul>
    </aside>
  </div>
</section>

<section class="block wide" id="karte">
  <div class="today-head"><h2>Karte: heute und heute Nacht</h2><p class="sub">Hineinzoomen zeigt den genauen Abschnitt, Antippen die Details.</p></div>
  <div id="map" class="map-home" data-src="/heute.json" role="region" aria-label="Deutschlandkarte"></div>
  <div class="legend"><span><i class="sw voll"></i>Vollsperrung</span><span><i class="sw sperr"></i>Sperrung</span><span><i class="sw kurz"></i>kurzfristige Baustelle</span><span><i class="sw live"></i>Stau/Gefahr</span><span class="hint">Antippen für Details</span></div>
</section>

<section class="block wide nah" id="nah" hidden aria-live="polite"></section>

<section class="block wide">
  <h2>Hier ist heute am meisten los</h2>
  <div class="hots">{''.join(cards)}</div>
</section>

<section class="block wide">
  <h2>Alle Autobahnen</h2>
  <p class="sub"><span class="dot rot"></span>Vollsperrung oder Stau <span class="dot gelb"></span>eingeschränkt <span class="dot gruen"></span>nur Dauerbaustellen</p>
  <ul class="tiles">{''.join(tiles)}</ul>
</section>

<section class="block wide why">
  <div><b>Offizielle Daten</b><p>Direkt von der Autobahn GmbH des Bundes, ohne Umweg.</p></div>
  <div><b>Alle 15 Minuten neu</b><p>Staus und Unfälle sogar live, während du die Seite offen hast.</p></div>
  <div><b>Genau statt ungefähr</b><p>Jeder Abschnitt auf der Karte, jede gesperrte Spur als Grafik.</p></div>
</section>
</main>
<script src="/assets/search.js?v={VER}" defer></script>"""
    desc = f"Heute {n_full} Vollsperrungen, {n_short} kurzfristige Sperrungen und {n_warn} Staus auf deutschen Autobahnen. Jeder Abschnitt auf der Karte, mit Spurgrafik. Stand {NOW:%d.%m.%Y, %H:%M} Uhr."
    jsonld = [{"@context": "https://schema.org", "@type": "WebSite", "name": SITE_NAME, "url": SITE_URL + "/", "inLanguage": "de-DE"}]
    return page("Stauklar: Sperrungen, Baustellen & Staus auf der Karte", desc, "/", body, jsonld, extra_head=MAP_HEAD, body_class="p-home")


def legal_pages():
    imp = """<h1>Impressum</h1>
<h2>Angaben gemäß § 5 DDG</h2>
<p>Yacouba Pfälzner<br>Ehrenbergstraße 17<br>14195 Berlin</p>
<h2>Kontakt</h2>
<p>E-Mail: developeryp1@gmail.com</p>
<h2>Verantwortlich für den Inhalt nach § 18 Abs. 2 MStV</h2>
<p>Yacouba Pfälzner, Anschrift wie oben</p>
<h2>Datenquelle</h2>
<p>Die Verkehrsdaten stammen von der Autobahn GmbH des Bundes (verkehr.autobahn.de). Stauklar ist ein privates Angebot und steht in keiner Verbindung zur Autobahn GmbH. Alle Angaben ohne Gewähr.</p>
<h2>Haftung für Links</h2>
<p>Diese Website enthält Links zu externen Websites, auf deren Inhalte ich keinen Einfluss habe. Für diese Inhalte ist der jeweilige Anbieter verantwortlich.</p>"""
    ds = """<h1>Datenschutzerklärung</h1>
<h2>Verantwortlicher</h2>
<p>Yacouba Pfälzner, Ehrenbergstraße 17, 14195 Berlin, E-Mail: developeryp1@gmail.com</p>
<h2>Hosting</h2>
<p>Diese Website wird über GitHub Pages bereitgestellt, einen Dienst der GitHub Inc., 88 Colin P. Kelly Jr. Street, San Francisco, CA 94107, USA. Beim Aufruf verarbeitet GitHub technisch notwendige Daten wie Ihre IP-Adresse, Zeitpunkt und aufgerufene Seite, um die Website auszuliefern und vor Missbrauch zu schützen. Dabei können Daten in die USA übermittelt werden. GitHub ist unter dem EU-US Data Privacy Framework zertifiziert. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse an einer sicheren und zuverlässigen Bereitstellung).</p>
<h2>Abruf von Verkehrsmeldungen</h2>
<p>Auf den Seiten der einzelnen Autobahnen lädt Ihr Browser aktuelle Staumeldungen direkt von verkehr.autobahn.de (Die Autobahn GmbH des Bundes). Dabei wird Ihre IP-Adresse an diesen Server übermittelt. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO (aktuelle Verkehrsinformationen).</p>
<h2>Karten</h2>
<p>Für die Karten lädt Ihr Browser Kartenkacheln von OpenFreeMap (tiles.openfreemap.org, Kartendaten © OpenStreetMap-Mitwirkende). Dabei wird Ihre IP-Adresse an diesen Server übermittelt. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO (verständliche Darstellung der Verkehrslage). Die Kartensoftware und die Schriftarten liegen auf unserem eigenen Webspace, dafür werden keine Daten an Dritte übertragen.</p>
<h2>Standort („In meiner Nähe“)</h2>
<p>Wenn Sie „In meiner Nähe“ wählen, fragt Ihr Browser um Erlaubnis, Ihren Standort zu verwenden. Der Standort wird ausschließlich in Ihrem Browser verarbeitet, um Meldungen in Ihrer Umgebung anzuzeigen. Er wird weder an uns übertragen noch gespeichert. Sie können die Erlaubnis jederzeit in Ihren Browser-Einstellungen widerrufen. Rechtsgrundlage ist Ihre Einwilligung, Art. 6 Abs. 1 lit. a DSGVO.</p>
<h2>Cookies und Tracking</h2>
<p>Diese Website setzt keine Cookies und verwendet keine Analyse- oder Tracking-Dienste.</p>
<h2>Ihre Rechte</h2>
<p>Sie haben das Recht auf Auskunft (Art. 15 DSGVO), Berichtigung (Art. 16), Löschung (Art. 17), Einschränkung der Verarbeitung (Art. 18), Datenübertragbarkeit (Art. 20) und Widerspruch (Art. 21). Außerdem können Sie sich bei einer Datenschutz-Aufsichtsbehörde beschweren, zum Beispiel bei der Berliner Beauftragten für Datenschutz und Informationsfreiheit.</p>
<p><small>Stand: Oktober 2026</small></p>"""
    for p, t, b in (("impressum", "Impressum", imp), ("datenschutz", "Datenschutz", ds)):
        (DIST / p).mkdir(parents=True, exist_ok=True)
        (DIST / p / "index.html").write_text(page(f"{t} – {SITE_NAME}", t, f"/{p}/", f'<main class="legal">{b}</main>', extra_head='<meta name="robots" content="noindex">'))


# ---------- JSON-API für die App (api/v1/…) ----------

def iso(d):
    return d.replace(tzinfo=TZ).isoformat() if d else None


def api_item(it, labels):
    upcoming = [w for w in it["wins"] if w[1] > NOW][:12]
    return dict(
        id=it["id"], g=it.get("g", it["id"]), title=it["title"], dir=arrow(it["dir"]), d=it["d"], t=round(it["t"], 2),
        sev=it["sev"], label=it.get("label") or SEV_LABEL[it["sev"]], active=bool(it["active"]),
        heute=bool(it["w_heute"]), woche=bool(it["w_woche"]), when=human_when(it["show"]),
        start=iso(it["show"][0]), end=iso(it["show"][1]), total=iso(it.get("total")),
        windows=[[iso(s), iso(e)] for s, e in upcoming],
        where=arrow(it.get("where", "")), info=it.get("info", ""), project=it.get("project", ""),
        lanes=it.get("lanes") or [], laneText=lanes(it.get("lanes") or [])[1],
        lat=round(it["lat"], 5), lon=round(it["lon"], 5), geom=it.get("geom") or [],
    )


def api_group(g):
    return dict(id=g["id"], items=g["items"], title=g["title"], section=g["section"], what=g["what"], sev=g["sev"], label=g["label"],
                active=g["active"], heute=g["heute"], woche=g["woche"], when=human_when(g["show"]),
                start=iso(g["show"][0]), end=iso(g["show"][1]), total=iso(g["total"]), upcoming=g["upcoming"],
                dirs=[dict(d=x["d"], raw=x["raw"], lanes=x["lanes"], laneText=x["laneText"], where=x["where"], info=x["info"]) for x in g["dirs"]],
                ramps=g["ramps"], project=g["project"], t=round(g["t"], 2), d=g["d"], lat=round(g["lat"], 5), lon=round(g["lon"], 5))


def api_warn(w):
    return dict(id=w["id"], title=w["title"], dir=arrow(w["dir"]), d=w["d"], t=round(w["t"], 2),
                text=[arrow(x) for x in w["text"]], lat=round(w["lat"], 5), lon=round(w["lon"], 5), geom=w.get("geom") or [])


def write_api(roads, data, punkte):
    api = DIST / "api" / "v1"
    (api / "road").mkdir(parents=True)
    stand = iso(NOW)
    overview = []
    for r in roads:
        d = data[r]
        st, st_txt = status_of(d["items"], d["warns"])
        today = [i for i in d["items"] if i["w_heute"]]
        counts = dict(voll=sum(i["sev"] == "voll" for i in today), kurz=sum(i["sev"] in ("sperr", "kurz") for i in today),
                      live=len(d["warns"]), dauer=sum(i["sev"] == "dauer" for i in today))
        c = d["c"]
        overview.append(dict(id=r, slug=slug(r), status=st, statusText=st_txt, lage=lage(r, d["items"], d["warns"]), **counts,
                             lat=round(c[0], 4) if c else None, lon=round(c[1], 4) if c else None))
        near = sorted((o for o in roads if o != r and data[o]["c"] and c), key=lambda o: dist_km(c, data[o]["c"]))[:8]
        ends = (["Norden", "Süden"] if d["ax"]["ns"] else ["Westen", "Osten"]) if d["ax"] else []
        (api / "road" / f"{slug(r)}.json").write_text(json.dumps(dict(
            id=r, stand=stand, status=st, statusText=st_txt, lage=lage(r, d["items"], d["warns"]), **counts,
            axis=d["ax"], labels=d["labels"], ends=ends, near=near,
            items=[api_item(i, d["labels"]) for i in d["items"]], warns=[api_warn(w) for w in d["warns"]],
            groups=[api_group(g) for g in d["groups"]],
            parking=d["parking"], charging=d["charging"],
        ), ensure_ascii=False, separators=(",", ":")))
    (api / "roads.json").write_text(json.dumps(dict(stand=stand, roads=overview), ensure_ascii=False, separators=(",", ":")))
    (api / "points.json").write_text(json.dumps(dict(stand=stand, points=[
        dict(road=p[0], id=p[1], lat=p[2], lon=p[3], sev=p[4], heute=bool(p[5]), title=p[6], when=p[7], label=p[8], active=bool(p[9]))
        for p in punkte]), ensure_ascii=False, separators=(",", ":")))
    (api / "cities.json").write_text(json.dumps([dict(name=n, lat=la, lon=lo) for n, (la, lo) in CITIES.items()], ensure_ascii=False, separators=(",", ":")))


def main():
    roads = sorted(json.loads((CACHE / "roads.json").read_text()), key=num_key)
    if DIST.exists():
        shutil.rmtree(DIST)
    shutil.copytree(ROOT / "static", DIST)
    data = {}
    for r in roads:
        items, warns = build_items(r), build_warnings(r)
        for n, it in enumerate(items):
            it["id"] = f"m{n}"
            enrich(it)
        for n, w in enumerate(warns):
            w["id"] = f"w{n}"
        ax, labels = assign_directions(r, items, warns)
        parking, charging = build_services(r)
        data[r] = dict(items=items, warns=warns, groups=group_items(items), parking=parking, charging=charging, ax=ax, labels=labels, c=centroid(items, warns))
    # Autobahnen ohne jede Meldung bekommen keine eigene Seite (wäre für Google eine „leere“ Seite)
    roads = [r for r in roads if data[r]["items"] or data[r]["warns"] or data[r]["parking"]]
    places = {}
    for r in roads:
        c = data[r]["c"]
        near = sorted((o for o in roads if o != r and data[o]["c"] and c), key=lambda o: dist_km(c, data[o]["c"]))[:8]
        d = DIST / slug(r)
        d.mkdir(parents=True)
        (d / "index.html").write_text(road_page(r, data[r], near))
        (d / "map.json").write_text(json.dumps(features(data[r]["items"], data[r]["warns"]), ensure_ascii=False, separators=(",", ":")))
        for it in data[r]["items"] + data[r]["warns"]:
            # Ort → Position: erster Name im Titel liegt am Anfang der Linie, letzter am Ende
            names, g = places_of(it["title"]), it.get("geom") or []
            for k, p in enumerate(names):
                pt = (g[0] if k == 0 else g[-1]) if len(names) > 1 and g else (g[len(g) // 2] if g else [it["lon"], it["lat"]])
                rec = places.setdefault(p, [set(), []])
                rec[0].add(r)
                if pt and pt[0]:
                    rec[1].append(pt)
    # Alle Meldungen als Punkte für die Umkreissuche („in meiner Nähe“, „rund um Berlin“)
    punkte = []
    for r in roads:
        for it in data[r]["items"]:
            if it["lat"]:
                punkte.append([r, it["id"], round(it["lat"], 4), round(it["lon"], 4), it["sev"], 1 if it["w_heute"] else 0,
                               it["title"], human_when(it["show"]), it.get("label") or SEV_LABEL[it["sev"]], 1 if it["active"] else 0])
        for w in data[r]["warns"]:
            if w["lat"]:
                punkte.append([r, w["id"], round(w["lat"], 4), round(w["lon"], 4), "live", 1, w["title"], (w["text"] or ["aktuell"])[0], "Stau/Gefahr", 1])
    (DIST / "punkte.json").write_text(json.dumps(punkte, ensure_ascii=False, separators=(",", ":")))
    germany = {"type": "FeatureCollection", "features": []}
    for r in roads:
        today = [i for i in data[r]["items"] if i["w_heute"] and i["sev"] != "dauer"]
        germany["features"] += features(today, data[r]["warns"], road=r)["features"]
    (DIST / "heute.json").write_text(json.dumps(germany, ensure_ascii=False, separators=(",", ":")))
    write_api(roads, data, punkte)
    search = {"roads": [[r, status_of(data[r]["items"], data[r]["warns"])[1]] for r in roads],
              "cities": [[n, la, lo] for n, (la, lo) in CITIES.items()],
              "places": sorted([[p, sorted(rs, key=num_key), round(sum(c[1] for c in pts) / len(pts), 4), round(sum(c[0] for c in pts) / len(pts), 4)]
                                for p, (rs, pts) in places.items() if pts])}
    (DIST / "suche.json").write_text(json.dumps(search, ensure_ascii=False, separators=(",", ":")))
    (DIST / "index.html").write_text(index_page(roads, data))
    legal_pages()
    lastmod = NOW.replace(tzinfo=TZ).isoformat()
    urls = [SITE_URL + "/"] + [f"{SITE_URL}/{slug(r)}/" for r in roads]
    (DIST / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join(f"  <url><loc>{u}</loc><lastmod>{lastmod}</lastmod></url>\n" for u in urls) + "</urlset>\n")
    (DIST / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {SITE_URL}/sitemap.xml\n")
    if BASE:  # Root-Pfade in allen HTML-Dateien auf den Unterordner umbiegen
        for f in DIST.rglob("*.html"):
            f.write_text(re.sub(r'((?:href|src|data-src)=")/(?!/)', rf"\g<1>{BASE}/", f.read_text()))
    print(f"{len(roads)} Autobahn-Seiten erzeugt in {DIST}" + (f" (Unterordner {BASE})" if BASE else ""))


if __name__ == "__main__":
    main()
