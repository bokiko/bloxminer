#!/usr/bin/env python3
"""Serves XMRig's real JSON HTTP API (GET /2/summary, GET /2/backends) from a config file, for h-stats.sh tests.
Config file (JSON), re-read on every request so a test can change it between calls:
  {"summary": <json object or null>, "backends": <json array or null>, "delay": <seconds, optional>}
A null body answers with HTTP 500 (stands in for a down/erroring miner)."""
import http.server
import json
import sys
import time

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
