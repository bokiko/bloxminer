#!/usr/bin/env python3
"""Serves XMRig's real JSON HTTP API (GET /2/summary, GET /2/backends) from a config file, for h-stats.sh tests.
Config file (JSON), re-read on every request so a test can change it between calls:
  {"summary": <json object or null>, "backends": <json array or null>, "delay": <seconds, optional>}
A null body answers with HTTP 500 (stands in for a down/erroring miner)."""
import ctypes
import http.server
import json
import signal
import sys
import time

# Parent-death signal (Linux prctl(PR_SET_PDEATHSIG)): this process asks the kernel to SIGTERM it the instant
# its direct parent (the bash test driver) dies for ANY reason - including a SIGKILL of that parent, which
# bypasses that parent's own EXIT/INT/TERM trap entirely (an unmaskable signal skips shell cleanup outright, so
# no bash-level trap can ever plug this hole; only the kernel can, right here). Belt-and-suspenders: every test
# already kills this process by its own tracked pid too - this only catches the case where that tracking itself
# was bypassed (an external force-kill of the driver script, not a normal test failure).
try:
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    PR_SET_PDEATHSIG = 1
    libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0)
except OSError:
    pass  # non-Linux / no libc.so.6 - the test's own pid-tracked cleanup still applies

port, cfg_path = int(sys.argv[1]), sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):  # noqa: N802 (BaseHTTPRequestHandler's naming)
        with open(cfg_path) as f:
            cfg = json.load(f)
        time.sleep(cfg.get("delay", 0))
        body = None
        if self.path == "/2/summary":
            body = cfg.get("summary")
        elif self.path == "/2/backends":
            body = cfg.get("backends")
        if body is None:
            self.send_response(500)
            self.end_headers()
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


srv = http.server.HTTPServer(("127.0.0.1", port), Handler)
print("ready", flush=True)
srv.serve_forever()
