#!/usr/bin/env bash
# Round 5: the huge-page ownership FINALIZATION gate (h-common.sh's finalize_rx_hugepages, called only from the
# TOP-LEVEL bloxminer/h-stats.sh, after sourcing engines/rx/h-stats.sh - see h-common.sh's "Huge-page ownership"
# section for the full design/xmrig-src-derived formula this exercises, and C4-CASK18-RESULT.md's FINDING for
# the real-Hive bug it fixes: XMRig itself raises vm.nr_hugepages beyond what Hive's own `hugepages -rx` set,
# so the OLD "ours = value right after -rx" was wrong and never let a prior=0 rig release its ~2.3 GB reservation).
# Every case here goes through the REAL top-level h-stats.sh, SOURCED (never executed, never a hand-copy of
# just the engine half) - the same shape Hive's own agent uses - against a fake procfs/meminfo/boot_id
# (BLOX_PROCFS_ROOT) and a fake xmrig HTTP API (tests/hive/fake_xmrig_api.py) serving /2/summary and
# /2/backends, exactly like engines/rx/h-stats.sh's own ownership-verified stats collection already does - this
# is not a new interface, just a second, independent consumer of the same one.
# Usage: tests/hive/test_hugepage_finalization.sh (Linux: needs jq, curl, python3, bash)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer" && pwd)
T=$(mktemp -d)
API_PID=""
cleanup() { [[ -n $API_PID ]] && kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-78s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-78s FAIL: %s\n' "$1" "$2"; }

export BLOX_DIR="$T/pkg"
CONF="$T/config.json"
HUGEFILE="$T/state/.bloxminer-hugepages"
LOGFILE="$T/log/bloxminer.log"
PORT=4069

setup_pkg() {
	rm -rf "$BLOX_DIR" "$T/log" "$T/state"; mkdir -p "$BLOX_DIR" "$T/log" "$T/state"
	cp -r "$PKGSRC"/* "$BLOX_DIR/"
	chmod +x "$BLOX_DIR"/*.sh "$BLOX_DIR"/engines/*/*.sh
	sed -i.bak -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$CONF#" \
	           -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer#" "$BLOX_DIR/h-manifest.conf"
	rm -f "$BLOX_DIR/h-manifest.conf.bak"
	: > "$BLOX_DIR/xmrig"; chmod +x "$BLOX_DIR/xmrig"   # placeholder: only its resolved /proc/<pid>/exe path is ever compared
}

# ---- config.json: a real, working rx config (engine_from_config -> rx); 1gb-pages toggled per test
write_rx_config() {   # $1 = "true"|"false" for randomx."1gb-pages" (default false)
	jq -n --arg onegb "${1:-false}" \
		'{pools: [{url:"stratum+tcp://p:1", user:"W", algo:"rx/0"}], randomx: {"1gb-pages": ($onegb == "true")}}' > "$CONF"
}
write_verus_config() { jq -n '{algo:"verus", pools:[{url:"stratum+tcp://p:1"}], user:"W"}' > "$CONF"; }

# ---- fake /proc: net/tcp (one listening socket on $PORT, owned by $BLOX_DIR/xmrig), sys/vm/nr_hugepages,
#      meminfo (HugePages_Free), sys/kernel/random/boot_id - the same technique
#      tests/hive/test_rx_under_load.sh already uses for its own ownership fixture.
setup_proc() {   # $1 = nr_hugepages (live) $2 = HugePages_Free $3 = boot_id string
	PROC="$T/proc"; rm -rf "$PROC"; mkdir -p "$PROC/sys/vm" "$PROC/sys/kernel/random" "$PROC/net"
	echo "$1" > "$PROC/sys/vm/nr_hugepages"
	printf 'HugePages_Free:  %8d kB\n' "$2" > "$PROC/meminfo"
	printf '%s\n' "$3" > "$PROC/sys/kernel/random/boot_id"
	python3 - "$PROC" "$BLOX_DIR/xmrig" "$PORT" <<'PY'
import os, sys
root, xmrig_path, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
pid = "9101"
fddir = os.path.join(root, pid, "fd"); os.makedirs(fddir, exist_ok=True)
os.symlink("socket:[424242]", os.path.join(fddir, "7"))
os.symlink(xmrig_path, os.path.join(root, pid, "exe"))
hexport = "%04X" % port
with open(os.path.join(root, "net", "tcp"), "w") as f:
	f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n")
	f.write("   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 424242 1 0000000000000000 100 0 0 10 0\n" % hexport)
PY
}
set_nr_hugepages() { echo "$1" > "$PROC/sys/vm/nr_hugepages"; }   # a "foreign" write between polls

# ---- fake xmrig API: one CPU thread reporting real hashrate, a CONTROLLABLE "hugepages":[allocated,total] on
#      /2/summary (the exact field xmrig.backend.cpu.CpuBackend.cpp:471 adds for REQ_SUMMARY - see h-common.sh)
API_CFG="$T/replies.json"
start_api() {   # $1 = hugepages allocated $2 = hugepages total $3 = hashrate (khs-bearing; 0 => no hashrate yet)
	local sum back
	sum=$(jq -nc --argjson alloc "$1" --argjson total "$2" \
		'{uptime:120, connection:{accepted:9,rejected:0}, algo:"rx/0", version:"6.26.0", hugepages:[$alloc,$total]}')
	back=$(jq -nc --argjson hs "${3:-500}" '[{type:"cpu", threads:[{affinity:0, hashrate:[$hs,null,null]}]}]')
	jq -n --argjson s "$sum" --argjson b "$back" '{summary:$s, backends:$b}' > "$API_CFG"
	python3 "$HERE/fake_xmrig_api.py" "$PORT" "$API_CFG" > "$T/api.out" 2>&1 &
	API_PID=$!
	for _ in $(seq 50); do grep -q ready "$T/api.out" 2>/dev/null && return 0; sleep 0.1; done
	return 1
}
stop_api() { [[ -n $API_PID ]] && kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; API_PID=""; }

# ---- one poll of the REAL top-level h-stats.sh, sourced, exactly as Hive's agent does; bloxsense/task-mask
#      binding is deliberately NOT modelled here (falls back to "unverified" per-thread rows) - irrelevant to
#      hugepage finalization, which reads only $khs and the API's own "hugepages" field, never per-core binding.
poll() {
	out=$(BLOX_DIR="$BLOX_DIR" BLOX_PROCFS_ROOT="$PROC" BLOX_API_PORT="$PORT" BLOX_STATE_DIR="$T/state" bash -c '
		. "$BLOX_DIR/h-stats.sh"
		echo "khs=[$khs]"
	' 2>&1)
}

hp_field() { sed -n "s/^$1=//p" "$HUGEFILE" 2>/dev/null; }
log_count() { grep -c "$1" "$LOGFILE" 2>/dev/null || echo 0; }

# ---- restore: real top-level h-run.sh (executed - engine binary is absent, so it exits after the hugepage
#      step, exactly like test_dispatcher.sh's run_h_run), with a fake `sysctl` on PATH so a real restore
#      attempt (or its absence) is directly observable.
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
echo "sysctl $*" >> "$SYSCTL_LOG"
[ "${SYSCTL_FAIL:-0}" = "1" ] && exit 1
[ "${SYSCTL_LIE:-0}" = "1" ] && exit 0   # "succeeds" but never touches PROCFILE - tests the readback check
for a in "$@"; do case $a in vm.nr_hugepages=*) echo "${a#vm.nr_hugepages=}" > "$PROCFILE" ;; esac; done
exit 0
SH
chmod +x "$FAKEBIN/sysctl"
SYSCTL_LOG="$T/sysctl.log"; export SYSCTL_LOG
attempt_restore() {   # writes $SYSCTL_LOG (engine binary absent, so h-run.sh's own exit status is not meaningful)
	write_verus_config
	: > "$SYSCTL_LOG"
	PROCFILE="$PROC/sys/vm/nr_hugepages" PATH="$FAKEBIN:$PATH" BLOX_PROCFS_ROOT="$PROC" BLOX_STATE_DIR="$T/state" \
		SYSCTL_FAIL="${SYSCTL_FAIL:-0}" SYSCTL_LIE="${SYSCTL_LIE:-0}" \
		timeout 2 bash "$BLOX_DIR/h-run.sh" > /dev/null 2>&1
}
sysctl_called() { grep -q '^sysctl ' "$SYSCTL_LOG" 2>/dev/null; }

# ================================================================== 1. cask18-shaped happy path, prior=0:
#    prior=0, prelim=1200 (Hive's `hugepages -rx` target on this CPU), free0=1199 (1 short of the 1200 XMRig's
#    dataset+scratchpads need) -> predicted = 1200 + max(0, 1200-1199) = 1201, exactly what was really observed
#    live on cask18. Fully allocated (1200/1200), real hashrate, matching boot_id -> ONE poll finalizes
#    (final=1, ours=1201); the record then round-trips through a REAL Verus restore back to 0 - proving the
#    exact bug (a prior=0 rig never releasing its reservation) is fixed end to end.
setup_pkg; write_rx_config false
setup_proc 1201 1199 boot-AAA
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-AAA\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500000 || bad "fake xmrig API startup" "$(cat "$T/api.out" 2>/dev/null)"
poll
poll_khs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$out")
if [[ -n $poll_khs ]] && awk -v k="$poll_khs" 'BEGIN{exit !(k>0)}'; then ok "poll 1: h-stats reports real hashrate (khs=$poll_khs > 0)"; else bad "poll 1: h-stats reports real hashrate" "$out"; fi
if [[ $(hp_field final) == 1 && $(hp_field ours) == 1201 ]]; then
	ok "poll 1: finalizes (final=1, ours=1201 = prelim 1200 + max(0, need 1200 - free0 1199)) - the cask18 formula"
else
	bad "poll 1: finalizes (final=1, ours=1201)" "$(cat "$HUGEFILE" 2>/dev/null)"
fi
stop_api
SYSCTL_FAIL=0 SYSCTL_LIE=0 attempt_restore
if sysctl_called && grep -q "nr_hugepages=0" "$SYSCTL_LOG"; then ok "restore after finalization: real Verus start restores the ORIGINAL prior (0)"; else bad "restore after finalization: restores prior (0)" "$(cat "$SYSCTL_LOG")"; fi
if [[ $(cat "$PROC/sys/vm/nr_hugepages") == 0 ]]; then ok "restore after finalization: live vm.nr_hugepages actually now 0"; else bad "restore after finalization: live value now 0" "$(cat "$PROC/sys/vm/nr_hugepages")"; fi
if [[ ! -e $HUGEFILE ]]; then ok "restore after finalization: ownership record removed (readback verified)"; else bad "restore after finalization: record removed" "$(cat "$HUGEFILE")"; fi

# ================================================================== 2. cask18's OWN shape: nonzero baseline
#    (prior=1201, left over from an earlier, never-released session) still finalizes and restores correctly -
#    the fix does not regress the one case where the old code happened to look right by accident.
setup_pkg; write_rx_config false
setup_proc 1201 1199 boot-BBB
mkdir -p "$T/state"; printf 'prior=1201\nprelim=1200\nfree0=1199\nboot=boot-BBB\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500 || bad "fake xmrig API startup (case 2)" "$(cat "$T/api.out" 2>/dev/null)"
poll
if [[ $(hp_field final) == 1 && $(hp_field ours) == 1201 ]]; then ok "cask18 nonzero baseline: finalizes (final=1, ours=1201)"; else bad "cask18 nonzero baseline: finalizes" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
stop_api
attempt_restore
if grep -q "nr_hugepages=1201" "$SYSCTL_LOG" 2>/dev/null; then ok "cask18 nonzero baseline: restores the ORIGINAL prior (1201)"; else bad "cask18 nonzero baseline: restores prior (1201)" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 3. second poll never rewrites an already-
#    finalized record (idempotent - h-stats.sh polls every ~10 s for the whole rx session)
setup_pkg; write_rx_config false
setup_proc 1201 1199 boot-CCC
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-CCC\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll   # finalizes
before=$(cat "$HUGEFILE")
poll   # should be a no-op now
after=$(cat "$HUGEFILE")
stop_api
if [[ $before == "$after" ]]; then ok "second poll after finalization: record byte-identical (never rewritten)"; else bad "second poll after finalization: record unchanged" "before=[$before] after=[$after]"; fi

# ================================================================== 4. not ready yet (dataset still allocating,
#    allocated < total): silently retried, NEVER logged, final stays 0 - this is the NORMAL early-poll case of
#    every fresh rx start, not an anomaly.
setup_pkg; write_rx_config false
setup_proc 1201 1199 boot-DDD
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-DDD\nfinal=0\n' > "$HUGEFILE"
start_api 600 1200 500   # only half the dataset's pages allocated so far
poll
stop_api
if [[ $(hp_field final) == 0 ]] && [[ ! -f $LOGFILE || $(log_count "predicted reservation") == 0 ]]; then
	ok "not yet fully allocated (600/1200): no finalize, not logged, retried next poll"
else
	bad "not yet fully allocated: no finalize, not logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

# ================================================================== 5. not ready yet (khs still 0, e.g. dataset
#    just finished but no 10 s hashrate window has elapsed): same - silent retry, never logged
setup_pkg; write_rx_config false
setup_proc 1201 1199 boot-EEE
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-EEE\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 0   # fully allocated but hashrate not up yet
poll
stop_api
if [[ $(hp_field final) == 0 ]] && [[ ! -f $LOGFILE || $(log_count "predicted reservation") == 0 ]]; then
	ok "khs still 0: no finalize, not logged, retried next poll"
else
	bad "khs still 0: no finalize, not logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

# ================================================================== 6. foreign change DURING the startup window
#    (readiness fully proven - allocated==total, khs>0 - but live != predicted): never finalize, logged EXACTLY
#    ONCE (final -> "conflict", a terminal state never revisited), record kept; a later poll does not re-log.
setup_pkg; write_rx_config false
setup_proc 1400 1199 boot-FFF   # live is 1400, not the predicted 1201 - something else raised it too
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-FFF\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
if [[ $(hp_field final) == conflict ]] && grep -q "does not match XMRig's own predicted reservation" "$LOGFILE" 2>/dev/null; then
	ok "foreign change during startup (live 1400 != predicted 1201): final=conflict, logged"
else
	bad "foreign change during startup: final=conflict, logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi
n1=$(log_count "does not match XMRig's own predicted reservation")
poll   # a second poll must NOT log again - final is already "conflict", not "0"
stop_api
n2=$(log_count "does not match XMRig's own predicted reservation")
if [[ $n1 == 1 && $n2 == 1 ]]; then ok "foreign change during startup: logged exactly ONCE, not every poll"; else bad "foreign change during startup: logged exactly once" "n1=$n1 n2=$n2"; fi
attempt_restore
if ! sysctl_called; then ok "foreign change during startup: a later Verus start never restores (final != 1)"; else bad "foreign change during startup: never restores" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 7. foreign change AFTER finalization: the
#    EXISTING restore-time conflict path (unchanged logic, now gated behind final=1) - never overwrites, record
#    retained with its already-finalized prior/ours intact.
setup_pkg; write_rx_config false
setup_proc 1201 1199 boot-GGG
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-GGG\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll   # finalizes: final=1, ours=1201
stop_api
set_nr_hugepages 5000   # a third party changes it AFTER finalization, before any Verus start
before=$(cat "$HUGEFILE")
attempt_restore
if ! sysctl_called && [[ $(cat "$PROC/sys/vm/nr_hugepages") == 5000 ]]; then ok "foreign change AFTER finalization: Verus start never overwrites it"; else bad "foreign change after finalization: never overwrites" "sysctl=$(cat "$SYSCTL_LOG") proc=$(cat "$PROC/sys/vm/nr_hugepages")"; fi
if [[ -e $HUGEFILE && $(cat "$HUGEFILE") == "$before" ]]; then ok "foreign change AFTER finalization: record kept unchanged (still final=1/ours=1201)"; else bad "foreign change after finalization: record kept" "$(cat "$HUGEFILE" 2>/dev/null)"; fi

# ================================================================== 8. boot_id mismatch: never finalize, never
#    even logged (not an anomaly - just "not this boot's record"; tmpfs would have cleared it on a real reboot
#    anyway, this only guards the same-boot-but-somehow-stale-record edge case) - and never restored either.
setup_pkg; write_rx_config false
setup_proc 1201 1199 boot-CURRENT
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-OLD\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
stop_api
if [[ $(hp_field final) == 0 ]] && [[ ! -f $LOGFILE || $(log_count "BloxMiner") == 0 ]]; then
	ok "boot_id mismatch (record=boot-OLD, live=boot-CURRENT): no finalize, not logged"
else
	bad "boot_id mismatch: no finalize, not logged" "final=$(hp_field final) log=$(cat "$LOGFILE" 2>/dev/null)"
fi
attempt_restore
if ! sysctl_called; then ok "boot_id mismatch: never restored (final != 1)"; else bad "boot_id mismatch: never restored" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 9. 1gb-pages guard: XMRig's own hugepages
#    total mixes 1GB/2MB units when this is set (see h-common.sh's documented limitation) - never finalize,
#    logged exactly once (final -> "conflict"), never restored.
setup_pkg; write_rx_config true   # randomx."1gb-pages": true
setup_proc 1201 1199 boot-HHH
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-HHH\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll
n1=$(log_count "1gb-pages is enabled")
poll
stop_api
n2=$(log_count "1gb-pages is enabled")
if [[ $(hp_field final) == conflict && $n1 == 1 && $n2 == 1 ]]; then
	ok "1gb-pages enabled: never finalizes, logged exactly once, not every poll"
else
	bad "1gb-pages enabled: never finalizes, logged once" "final=$(hp_field final) n1=$n1 n2=$n2 log=$(cat "$LOGFILE" 2>/dev/null)"
fi
attempt_restore
if ! sysctl_called; then ok "1gb-pages enabled: never restored (final != 1)"; else bad "1gb-pages enabled: never restored" "$(cat "$SYSCTL_LOG")"; fi

# ================================================================== 10. a failed sysctl write's EXIT STATUS
#    lied (exit 0) but never actually touched vm.nr_hugepages - the Round 5 readback verification catches this
#    even though the old code (trusting only `sysctl`'s own exit status) would not have.
setup_pkg; write_rx_config false
setup_proc 1201 1199 boot-III
mkdir -p "$T/state"; printf 'prior=0\nprelim=1200\nfree0=1199\nboot=boot-III\nfinal=0\n' > "$HUGEFILE"
start_api 1200 1200 500
poll   # finalizes: final=1, ours=1201
stop_api
before=$(cat "$HUGEFILE")
SYSCTL_LIE=1 attempt_restore
SYSCTL_LIE=0
if sysctl_called && [[ $(cat "$PROC/sys/vm/nr_hugepages") == 1201 ]]; then ok "sysctl exit-0-but-no-op: a restore WAS attempted, live value still 1201 (never actually changed)"; else bad "sysctl exit-0-but-no-op: restore attempted, value unchanged" "sysctl=$(cat "$SYSCTL_LOG") proc=$(cat "$PROC/sys/vm/nr_hugepages")"; fi
if [[ -e $HUGEFILE && $(cat "$HUGEFILE") == "$before" ]]; then ok "sysctl exit-0-but-no-op: record RETAINED (readback did not match, never silently dropped)"; else bad "sysctl exit-0-but-no-op: record retained" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
if grep -q "did not read back correctly" "$LOGFILE" 2>/dev/null; then ok "sysctl exit-0-but-no-op: readback failure logged"; else bad "sysctl exit-0-but-no-op: readback failure logged" "$(cat "$LOGFILE" 2>/dev/null)"; fi

# ================================================================== 11. legacy (pre-Round-5) record: only
#    prior=/ours=, no final= line at all - never trusted for a restore (final missing != "1"), left untouched
#    until the next reboot clears tmpfs; no migration code needed, per design.
setup_pkg; write_verus_config
setup_proc 1200 1199 boot-JJJ
mkdir -p "$T/state"; printf 'prior=512\nours=1200\n' > "$HUGEFILE"   # exactly the OLD (pre-Round-5) shape
attempt_restore
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "huge-page ownership record not finalized" "$LOGFILE" 2>/dev/null; then
	ok "legacy pre-Round-5 record (no final=): never restored, kept, logged"
else
	bad "legacy pre-Round-5 record: never restored, kept, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$(cat "$HUGEFILE" 2>/dev/null) log=$(cat "$LOGFILE" 2>/dev/null)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
