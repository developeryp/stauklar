"""Lädt alle Autobahn-Daten von verkehr.autobahn.de in den Cache-Ordner.

Schlägt ein Abruf fehl, bleibt die letzte erfolgreiche Datei im Cache liegen,
damit die Website nie leere Seiten bekommt, nur weil die API kurz hakt.
"""
import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

API = "https://verkehr.autobahn.de/o/autobahn"
SERVICES = ["closure", "roadworks", "warning", "parking_lorry", "electric_charging_station"]
CACHE = pathlib.Path(__file__).parent / "cache"
HEADERS = {"User-Agent": "stauklar-sitegen/1.0 (+https://stauklar.de)", "Accept": "application/json"}


def get(url, tries=3):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001 – API wirft gelegentlich 5xx/Timeouts
            if i == tries - 1:
                raise
            time.sleep(2 * (i + 1))


def fetch_one(road, service):
    target = CACHE / f"{road}_{service}.json"
    try:
        data = get(f"{API}/{urllib.parse.quote(road)}/services/{service}")
        target.write_text(json.dumps(data, ensure_ascii=False))
        return True
    except Exception as e:  # noqa: BLE001
        print(f"  ! {road}/{service}: {e}", file=sys.stderr)
        return False


def main():
    CACHE.mkdir(exist_ok=True)
    roads = sorted({r.strip() for r in get(API + "/")["roads"]})
    (CACHE / "roads.json").write_text(json.dumps(roads))
    jobs = [(r, s) for r in roads for s in SERVICES]
    with ThreadPoolExecutor(max_workers=6) as pool:
        ok = list(pool.map(lambda j: fetch_one(*j), jobs))
    failed = ok.count(False)
    print(f"{len(roads)} Autobahnen, {len(jobs)} Abrufe, {failed} fehlgeschlagen")
    # Mehr als 20 % Ausfall: Build abbrechen, damit nicht mit lauter alten Daten veröffentlicht wird.
    if failed > len(jobs) * 0.2:
        sys.exit(1)


if __name__ == "__main__":
    main()
