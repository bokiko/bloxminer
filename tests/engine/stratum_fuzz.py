#!/usr/bin/env python3
"""Fake stratum pool that feeds BloxMiner malformed and boundary messages.

Usage: stratum_fuzz.py /path/to/bloxminer [case ...]
Each case starts the miner against this pool, performs the real handshake (as captured from a Verus pool),
sends the case's messages, and checks: the miner is still running, printed the expected line, exits cleanly
on SIGTERM (code 7), and no sanitizer report appeared. Run it against an ASan/UBSan build and the release build.
"""
import json, math, os, signal, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
NOTIFY = json.load(open(os.path.join(HERE, "fixtures", "notify.json")))
GOOD_TARGET = "00000013bce7176c9f007c9872c3ddabb312825474674bda64d6b51ecc0ed1f5"


def target_first_nonzero_at(i):
    b = ["00"] * 32
    b[i] = "7f"
    if i + 1 < 32:
        b[i + 1] = "ff"
    return "".join(b)


def expected_diff_line(i):
    """What the miner must log for target_first_nonzero_at(i): compact bits (exponent 32-i, top 3 bytes as the
    significand, bytes past the end count as 0) through target_to_diff_verus()."""
    sig = 0x7f0000 | (0xff00 if i + 1 < 32 else 0)
    return "Stratum difficulty set to %g" % math.ldexp(0x0f0f0f / sig, 8 * i)


def with_param(idx, value):
    p = list(NOTIFY["params"])
    p[idx] = value
    return notify(params=p)


def notify(**over):
    m = json.loads(json.dumps(NOTIFY))
    for k, v in over.items():
        if k == "params":
            m["params"] = v
    return m


def set_target(t):
    return {"jsonrpc": "2.0", "method": "mining.set_target", "params": [t], "id": None}


def show_message(s):
    return {"jsonrpc": "2.0", "method": "client.show_message", "params": [s], "id": None}


P = NOTIFY["params"]
JOB = "Stratum difficulty set to"      # printed only when a job was accepted and work was created from it
BAD = "Stratum notify: invalid parameters"
# name: (messages, text that must appear, text that must NOT appear)
CASES = {
    "baseline":               ([set_target(GOOD_TARGET), NOTIFY], JOB, None),
    "show_message_long":      ([set_target(GOOD_TARGET), show_message("equihash " + "A" * 5000 + " block 123"), NOTIFY], JOB, None),
    "notify_no_solution":     ([set_target(GOOD_TARGET), notify(params=P[:8])], BAD, JOB),
    "notify_solution_odd":    ([set_target(GOOD_TARGET), with_param(8, P[8] + "0")], BAD, JOB),
    "notify_solution_nonhex": ([set_target(GOOD_TARGET), with_param(8, "zz" + P[8][2:])], BAD, JOB),
    "notify_solution_too_long": ([set_target(GOOD_TARGET), with_param(8, "00" * 1345)], BAD, JOB),
    "notify_solution_max":    ([set_target(GOOD_TARGET), with_param(8, "00" * 1344)], JOB, None),
    "notify_solution_number": ([set_target(GOOD_TARGET), with_param(8, 12345)], BAD, JOB),
    "notify_version_nonhex":  ([set_target(GOOD_TARGET), with_param(1, "zzzzzzzz")], BAD, JOB),
    "notify_prevhash_nonhex": ([set_target(GOOD_TARGET), with_param(2, "g" * 64)], BAD, JOB),
    "notify_ntime_nonhex":    ([set_target(GOOD_TARGET), with_param(5, "nothex!!")], BAD, JOB),
    "notify_nbits_nonhex":    ([set_target(GOOD_TARGET), with_param(6, "xyzxyzxy")], BAD, JOB),
    "notify_ntime_00000000":  ([set_target(GOOD_TARGET), with_param(5, "00000000")], JOB, None),
    "notify_ntime_7fffffff":  ([set_target(GOOD_TARGET), with_param(5, "ffffff7f")], JOB, None),
    "notify_ntime_80000000":  ([set_target(GOOD_TARGET), with_param(5, "00000080")], JOB, None),
    "notify_ntime_ffffffff":  ([set_target(GOOD_TARGET), with_param(5, "ffffffff")], JOB, None),
    "notify_before_target":   ([NOTIFY, set_target(GOOD_TARGET), NOTIFY], JOB, None),
    "notify_before_target_bad": ([notify(params=P[:8])], BAD, JOB),
    "target_zero":            ([set_target("00" * 32), NOTIFY], "zero target ignored", None),
    "target_short":           ([set_target("00" * 31), NOTIFY], "invalid target ignored", None),
    "target_nonhex":          ([set_target("0g" + "00" * 31), NOTIFY], "invalid target ignored", None),
    "target_not_string":      ([{"jsonrpc": "2.0", "method": "mining.set_target", "params": [42], "id": None}, NOTIFY], "invalid target ignored", None),
    "garbage_json":           (["{this is not json", set_target(GOOD_TARGET), NOTIFY], JOB, None),
    "huge_line":              (["{\"x\":\"" + "a" * 200000 + "\"}", set_target(GOOD_TARGET), NOTIFY], JOB, None),
}
for i in range(32):  # compact-target conversion at every position: the exact difficulty the miner derives
    CASES["target_first_byte_%02d" % i] = ([set_target(target_first_nonzero_at(i)), NOTIFY], expected_diff_line(i), None)


def serve(sock, msgs, stop, delivered):
    conn, _ = sock.accept()
    conn.settimeout(0.5)
    f = conn.makefile("rwb", buffering=0)

    def send(obj):
        line = obj if isinstance(obj, str) else json.dumps(obj)
        try:
            f.write((line + "\n").encode())
        except OSError:
            pass

    while not stop.is_set():
        try:
            line = f.readline()
        except (socket.timeout, OSError):
            line = b""
        if line:
            try:
                req = json.loads(line)
            except ValueError:
                continue
            if req.get("method") == "mining.subscribe":
                send({"jsonrpc": "2.0", "result": ["FUZZSESSION", "70001265"], "id": req["id"]})
            elif req.get("method") == "mining.authorize":
                send({"jsonrpc": "2.0", "result": True, "id": req["id"]})
                for m in msgs:
                    send(m)
                delivered.set()
            elif "id" in req:
                send({"jsonrpc": "2.0", "result": True, "id": req["id"]})
    conn.close()


def run_case(binary, name, msgs, expect, forbid):
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    port = sock.getsockname()[1]
    stop, delivered = threading.Event(), threading.Event()
    t = threading.Thread(target=serve, args=(sock, msgs, stop, delivered), daemon=True)
    t.start()
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:abort_on_error=0", UBSAN_OPTIONS="print_stacktrace=1")
    proc = subprocess.Popen([binary, "-o", "stratum+tcp://127.0.0.1:%d" % port, "-u", "fuzz.worker", "-p", "x",
                             "-t", "1", "--no-dashboard", "-b", "0", "-q"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    time.sleep(4)
    alive = proc.poll() is None
    if alive:
        proc.send_signal(signal.SIGTERM)
    try:
        out, _ = proc.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
    stop.set()
    sock.close()
    text = out.decode(errors="replace")
    problems = []
    if not alive:
        problems.append("miner died (rc=%s)" % proc.returncode)
    elif proc.returncode != 7:
        problems.append("exit code %s after SIGTERM (want 7)" % proc.returncode)
    if "AddressSanitizer" in text or "runtime error:" in text or "UndefinedBehaviorSanitizer" in text:
        problems.append("sanitizer report")
    if not delivered.is_set():
        problems.append("handshake never completed: messages not delivered")
    if expect not in text:
        problems.append("missing expected output %r" % expect)
    if forbid and forbid in text:
        problems.append("unexpected output %r (the message should have been rejected)" % forbid)
    print("%-28s %s" % (name, "ok" if not problems else "FAIL: " + "; ".join(problems)))
    if problems:
        print("\n".join("    | " + l for l in text.splitlines()[-15:]))
    return not problems


def blocked_stdout(binary):
    """SIGTERM must end the miner within the 5 s watchdog even when nobody reads its output: the pool floods
    protocol lines (-P logs every line) into a stdout pipe that this test never reads."""
    sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0)); sock.listen(1); port = sock.getsockname()[1]
    flood = [show_message("equihash X block %d" % i + " " + "p" * 300) for i in range(3000)]
    stop, delivered = threading.Event(), threading.Event()
    threading.Thread(target=serve, args=(sock, [set_target(GOOD_TARGET), NOTIFY] + flood, stop, delivered), daemon=True).start()
    proc = subprocess.Popen([binary, "-o", "stratum+tcp://127.0.0.1:%d" % port, "-u", "fuzz.worker", "-p", "x",
                             "-t", "1", "--no-dashboard", "-b", "0", "-P"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0"))
    time.sleep(5)                       # the unread pipe (64 KiB) is full long before this
    t0 = time.time(); proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=10); took = time.time() - t0
        ok = took < 8
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait(); took, ok = None, False
    stop.set(); sock.close()
    print("%-28s %s" % ("blocked_stdout_sigterm", "ok (exited in %.1f s, rc=%s)" % (took, proc.returncode) if ok else "FAIL: no exit within 10 s"))
    return ok


def main():
    binary = sys.argv[1]
    names = sys.argv[2:] or list(CASES)
    ok = sum(run_case(binary, n, *CASES[n]) for n in names)
    total = len(names)
    if not sys.argv[2:]:
        ok += blocked_stdout(binary); total += 1
    print("%d/%d cases passed" % (ok, total))
    sys.exit(0 if ok == total else 1)


if __name__ == "__main__":
    main()
