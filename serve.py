"""Lokaler Testserver für dist/ ohne Browser-Cache (Safari hält sonst alte Dateien fest).

Aufruf: python3 serve.py   →   http://localhost:8765
"""
import functools
import http.server
import pathlib
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
DIST = pathlib.Path(__file__).parent / "dist"


class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    handler = functools.partial(NoCache, directory=str(DIST))
    with http.server.ThreadingHTTPServer(("", PORT), handler) as srv:
        print(f"Stauklar läuft auf http://localhost:{PORT}")
        srv.serve_forever()
