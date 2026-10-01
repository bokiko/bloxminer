#!/usr/bin/env python3
"""Answers the miner API commands on 127.0.0.1:<port> with canned replies from a JSON file {"summary": "...", "cores": "..."}."""
import ctypes, json, signal, socket, sys
# Parent-death signal: SIGTERM this process the instant its direct parent (the bash test driver) dies for ANY
# reason, including a SIGKILL of that parent - which bypasses that parent's own trap-based cleanup entirely
# (an unmaskable signal skips shell traps outright; only the kernel can close this gap). Both fake servers in
# this repo had the same leak-on-external-force-kill exposure.
try:
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGTERM, 0, 0, 0)
except OSError:
    pass
port, replies = int(sys.argv[1]), json.load(open(sys.argv[2]))
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(8)
print("ready", flush=True)
while True:
    c, _ = s.accept()
    cmd = c.recv(256).decode().strip()
    c.sendall((replies.get(cmd, "") + "\0").encode())
    c.close()
