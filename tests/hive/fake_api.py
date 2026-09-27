#!/usr/bin/env python3
"""Answers the miner API commands on 127.0.0.1:<port> with canned replies from a JSON file {"summary": "...", "cores": "..."}."""
import json, socket, sys
port, replies = int(sys.argv[1]), json.load(open(sys.argv[2]))
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(8)
print("ready", flush=True)
while True:
    c, _ = s.accept()
    cmd = c.recv(256).decode().strip()
    c.sendall((replies.get(cmd, "") + "\0").encode())
    c.close()
