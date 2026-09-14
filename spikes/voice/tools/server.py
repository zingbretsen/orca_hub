#!/usr/bin/env python3
"""Static server for the voice spike harness + a tiny WAV/JSON upload receiver.

Serves spikes/voice/ on 127.0.0.1 only. getUserMedia needs a SECURE CONTEXT;
http://localhost:<port> qualifies, http://<LAN-IP>:<port> does NOT (see README).

POST /upload?name=foo.wav  -> writes body to out/foo.wav
POST /results              -> writes body to out/results-<ts>.json
--coi                      -> add COOP/COEP so SharedArrayBuffer (ort threads) works
"""
import argparse, os, re, sys, time
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "out")
COI = False
SAFE = re.compile(r"^[A-Za-z0-9._-]+$")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def end_headers(self):
        if COI:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        path = self.path.split("?")[0]
        if path == "/upload":
            q = self.path.split("?", 1)[1] if "?" in self.path else ""
            name = ""
            for kv in q.split("&"):
                if kv.startswith("name="):
                    name = kv[5:]
            if not SAFE.match(name or ""):
                name = "seg-%d.wav" % int(time.time() * 1000)
            dest = os.path.join(OUT, name)
        elif path == "/results":
            dest = os.path.join(OUT, "results-%d.json" % int(time.time()))
        else:
            self.send_error(404); return
        os.makedirs(OUT, exist_ok=True)
        with open(dest, "wb") as f:
            f.write(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(os.path.relpath(dest, ROOT).encode())

    def log_message(self, fmt, *args):
        if os.environ.get("SPIKE_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--coi", action="store_true",
                    help="send COOP/COEP (cross-origin isolation) for wasm threads")
    a = ap.parse_args()
    COI = a.coi
    os.makedirs(OUT, exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print("voice spike harness: http://localhost:%d/  (coi=%s, root=%s)"
          % (a.port, a.coi, ROOT), flush=True)
    srv.serve_forever()
