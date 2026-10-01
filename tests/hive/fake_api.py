#!/usr/bin/env python3
"""Answers the miner API commands on 127.0.0.1:<port> with canned replies from a JSON file
{"summary": "...", "cores": "...", "delay": <seconds, optional> | {"summary": <seconds>, ...}}.
The reply file is re-read on every connection, so a test can change it (including the delay) between calls.
An optional "delay" answers the matching command(s) only after sleeping that long - simulates a healthy but
CPU-starved ccminer that is merely slow to answer, not a dead one."""
import ctypes, json, os, signal, socket, sys, time
_parent = os.getppid()
# Parent-death signal: SIGTERM this process the instant its direct parent (the bash test driver) dies for ANY
# reason, including a SIGKILL of that parent - which bypasses that parent's own trap-based cleanup entirely
# (an unmaskable signal skips shell traps outright; only the kernel can close this gap). Both fake servers in
# this repo had the same leak-on-external-force-kill exposure.
try:
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGTERM, 0, 0, 0)
except OSError:
    pass
# PR_SET_PDEATHSIG is not retroactive: if the parent died before the prctl above, we were already reparented and
# will never get the signal - exit instead of serving forever with the port bound.
if os.getppid() != _parent:
    sys.exit(0)
port, cfg_path = int(sys.argv[1]), sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(8)
print("ready", flush=True)
while True:
    c, _ = s.accept()
    cmd = c.recv(256).decode().strip()
    with open(cfg_path) as f:
        replies = json.load(f)
    delay = replies.get("delay", 0)
    if isinstance(delay, dict):
        delay = delay.get(cmd, 0)
    if delay:
        time.sleep(delay)
    c.sendall((replies.get(cmd, "") + "\0").encode())
    c.close()
