#!/usr/bin/env bash
# Tests for the top-level dispatcher (bloxminer/h-config.sh, h-run.sh, h-stats.sh, h-common.sh): engine
# selection from the flight-sheet algo (every mapping, including empty/unknown/mixed-case), that config.json
# is the SOLE authority for which engine is active (engine_from_config - any legacy/stale marker file is
# ignored, and anything it cannot positively recognise fails CLOSED, never defaulting to either engine), the
# rx<->verus huge-page ownership handoff (only the reservation THIS package made is ever touched), that an
# unknown algo fails cleanly without ever touching config.json (no restart storm), and that h-stats never
# reports the previous engine's data after a switch.
# Usage: tests/hive/test_dispatcher.sh (Linux: needs jq, bash)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer" && pwd)
T=$(mktemp -d)
S11_API_PID=""   # backstop only - killed inline right after its own case finishes; the trap exists so an
	# abnormal exit mid-case can never leave it running (pid only, never a pattern - 127.0.0.1:20015 is
	# permanently held by another, lead-owned process on shared build hosts)
trap '[[ -n $S11_API_PID ]] && kill -9 "$S11_API_PID" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-68s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-68s FAIL: %s\n' "$1" "$2"; }

# a stub 'message' so the dispatcher's fail() never hits the real (absent) Hive binary; logs to $MESSAGE_LOG so
# tests can prove a Hive error message really was sent, not just that the script happened to exit non-zero
MESSAGE_LOG="$T/message.log"
message() { printf '%s %s\n' "$1" "$2" >> "$MESSAGE_LOG"; }
export -f message
export MESSAGE_LOG

setup_pkg() {
	rm -rf "$T/pkg" "$T/state" "$T/log"; mkdir -p "$T/pkg" "$T/state" "$T/log"
	cp -r "$PKGSRC"/* "$T/pkg/"
	chmod +x "$T/pkg"/*.sh "$T/pkg"/engines/*/*.sh
	sed -i.bak \
		-e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
		-e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer#" \
		"$T/pkg/h-manifest.conf"; rm -f "$T/pkg/h-manifest.conf.bak"
	export BLOX_DIR=$T/pkg BLOX_STATE_DIR=$T/state
	: > "$MESSAGE_LOG"
}
CONF=$T/config.json
HUGEFILE=$T/state/.bloxminer-hugepages

hconfig() {   # url template pass extra algo -> runs the dispatcher h-config.sh, sets $out $rc
	# SOURCED, exactly as Hive really invokes it (hive-ref/miner's miner_config_gen():
	# `. $MINER_DIR/$CUSTOM_MINER/h-config.sh`; hive-ref/miner-run: `source $MINER_DIR/h-config.sh`) - with
	# CUSTOM_* as plain, NON-exported variables of the calling shell, never in the process environment. This
	# used to be `CUSTOM_URL=$1 ... bash "$BLOX_DIR/h-config.sh"`: an EXPORTED child-process call, which is
	# exactly the shape that masked the cask18 bug (a non-exported CUSTOM_URL, invisible to a plain child
	# process, produced "the pool URL in the flight sheet is empty" for both engines - see the Round 4 section
	# below). Each call still gets its own throwaway bash -c child for isolation between test cases, same as
	# before; only HOW the variables reach h-config.sh changed (source vs. an exported child process).
	out=$(bash -c '
		set +a
		CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 CUSTOM_ALGO=$5
		. "$BLOX_DIR/h-config.sh"
	' _ "$1" "$2" "$3" "$4" "$5" 2>&1); rc=$?
}
# cfgengine - calls h-common.sh's engine_from_config directly: the SOLE authority for which engine is active.
cfgengine() { bash -c '. "$BLOX_DIR/h-manifest.conf" 2>/dev/null; . "$BLOX_DIR/h-common.sh" 2>/dev/null; engine_from_config' 2>/dev/null; }
BASHBIN=$(command -v bash)   # resolved with a real PATH once: bash re-searches PATH for its OWN name when PATH
	# is the variable being temporarily reassigned on the command line, so "PATH= bash ..." cannot find "bash"
	# itself once PATH is empty - the jq-unavailable tests below need bash's absolute path for that reason.

# ============================================================== 1. engine selection: every algo mapping
setup_pkg
declare -A CASES=(
	[verus]=verus [VERUS]=verus [verushash]=verus [VerusHash]=verus
	[randomx]=rx [RANDOMX]=rx [RandomX]=rx ["rx/0"]=rx ["rx/wow"]=rx ["rx/arq"]=rx ["rx/graft"]=rx ["rx/sfx"]=rx ["rx/yada"]=rx
	["RX/WOW"]=rx
)
hconfig "pool.example.com:1" "W.rig" "" "" ""   # empty algo, tested separately: bash assoc arrays reject a
if [[ $rc == 0 && $(cfgengine) == verus ]]; then ok "algo '' (empty) -> engine verus"; else bad "algo '' (empty) -> engine verus" "rc=$rc engine=$(cfgengine) out=$out"; fi
for algo in "${!CASES[@]}"; do
	hconfig "pool.example.com:1" "W.rig" "" "" "$algo"
	want=${CASES[$algo]}
	if [[ $rc == 0 && $(cfgengine) == "$want" ]]; then
		ok "algo '$algo' -> engine $want"
	else
		bad "algo '$algo' -> engine $want" "rc=$rc engine=$(cfgengine) out=$out"
	fi
done

# rx algo is normalised in the generated config: "randomx" -> "rx/0", specific rx/* kept as-is
setup_pkg
hconfig "p:1" "W" "" "" "randomx"
if [[ $rc == 0 && $(jq -r '.pools[0].algo' "$CONF" 2>/dev/null) == "rx/0" ]]; then ok "algo alias randomx -> config algo rx/0"; else bad "algo alias randomx -> config algo rx/0" "$(cat "$CONF" 2>/dev/null)"; fi
hconfig "p:1" "W" "" "" "rx/graft"
if [[ $rc == 0 && $(jq -r '.pools[0].algo' "$CONF" 2>/dev/null) == "rx/graft" ]]; then ok "algo rx/graft kept as-is in config"; else bad "algo rx/graft kept as-is in config" "$(cat "$CONF" 2>/dev/null)"; fi
hconfig "p:1" "W" "" "" "verus"
if [[ $rc == 0 && $(jq -r '.algo' "$CONF" 2>/dev/null) == "verus" ]]; then ok "algo alias verus -> config algo verus"; else bad "algo alias verus -> config algo verus" "$(cat "$CONF" 2>/dev/null)"; fi

# config.json actually carries the real flight-sheet pool URL / wallet template through, for both engines - not
# previously asserted anywhere in this file, which is exactly how the cask18 empty-pool-URL bug went unnoticed
hconfig "pool.example.com:1234" "MyWallet.rig1" "" "" ""
if [[ $(jq -r '.pools[0].url' "$CONF" 2>/dev/null) == "stratum+tcp://pool.example.com:1234" ]]; then ok "verus: config.json pool URL matches CUSTOM_URL"; else bad "verus: config.json pool URL matches CUSTOM_URL" "$(cat "$CONF" 2>/dev/null)"; fi
if [[ $(jq -r '.user' "$CONF" 2>/dev/null) == "MyWallet.rig1" ]]; then ok "verus: config.json user matches CUSTOM_TEMPLATE"; else bad "verus: config.json user matches CUSTOM_TEMPLATE" "$(cat "$CONF" 2>/dev/null)"; fi
hconfig "pool.example.com:5678" "MyWallet.rig2" "" "" "rx/0"
if [[ $(jq -r '.pools[0].url' "$CONF" 2>/dev/null) == "stratum+tcp://pool.example.com:5678" ]]; then ok "rx: config.json pool URL matches CUSTOM_URL"; else bad "rx: config.json pool URL matches CUSTOM_URL" "$(cat "$CONF" 2>/dev/null)"; fi
if [[ $(jq -r '.pools[0].user' "$CONF" 2>/dev/null) == "MyWallet.rig2" ]]; then ok "rx: config.json user matches CUSTOM_TEMPLATE"; else bad "rx: config.json user matches CUSTOM_TEMPLATE" "$(cat "$CONF" 2>/dev/null)"; fi

# ============================================================== 2. unknown algo: fails cleanly, no restart storm
setup_pkg
hconfig "p:1" "W" "" "" ""; before_conf=$(cat "$CONF")   # establish a known-good baseline (verus) first
for algo in sha256 x11 "rx/9" "verushash2" "  "; do
	hconfig "p:1" "W" "4" "" "$algo"
	ok1=$([[ $rc != 0 ]] && echo y)
	ok2=$([[ -z ${out##*Algorithm must be*} ]] && echo y)
	if [[ -n $ok1 && -n $ok2 ]]; then ok "unknown algo '$algo' -> Hive error, exit 1"; else bad "unknown algo '$algo' -> Hive error, exit 1" "rc=$rc out=$out"; fi
done
# repeat 5x: every attempt fails the same clean way (no crash loop, no hang, no config drift) - the "no
# restart storm" gate: bounded, deterministic, always the same result, never escalating.
n=0; for _ in 1 2 3 4 5; do hconfig "p:1" "W" "" "" "bogus"; [[ $rc == 1 ]] && n=$((n+1)); done
if [[ $n == 5 && $(cat "$CONF") == "$before_conf" ]]; then ok "unknown algo: 5x repeated calls all fail the same way, config.json untouched"; else bad "unknown algo: 5x repeated calls all fail the same way, config.json untouched" "n=$n"; fi

# ============================================================== 3. config.json atomicity: a failing engine
#    h-config.sh call leaves config.json exactly as it was (no half-switch, no partial write)
setup_pkg
hconfig "pool.example.com:1" "W.rig" "4" "" ""   # verus, succeeds
good_conf=$(cat "$CONF")
hconfig "" "W.rig" "4" "" ""                     # empty URL: the verus engine's own h-config.sh fails
if [[ $rc != 0 && $(cat "$CONF") == "$good_conf" ]]; then
	ok "engine h-config failure leaves config.json untouched"
else
	bad "engine h-config failure leaves config.json untouched" "rc=$rc conf_changed=$([[ $(cat "$CONF") != "$good_conf" ]] && echo yes)"
fi
# same for a failing rx call (invalid extra config breaks jq parsing) after a good rx run
hconfig "pool.example.com:1" "W.rig" "" "" "rx/0"
good_conf2=$(cat "$CONF")
hconfig "pool.example.com:1" "W.rig" "" 'not json' "rx/0"
if [[ $rc != 0 && $(cat "$CONF") == "$good_conf2" ]]; then
	ok "rx engine h-config failure leaves config.json untouched"
else
	bad "rx engine h-config failure leaves config.json untouched" "rc=$rc"
fi

# ============================================================== 4. Extra config cannot select the OTHER
#    engine. Neither engine's PROTECTED-key stripping covers the OTHER engine's own config.json marker (verus
#    does not protect "randomx" - it has no use for that key itself; rx does not protect a top-level "algo" -
#    its own algo lives nested under pools[0].algo), so without this check Extra config could make
#    engine_from_config misidentify - or flag ambiguous - a config generated for the OTHER engine than the one
#    the flight sheet actually selected. reject_foreign_selector (h-config.sh, before the engine's own
#    h-config.sh ever runs) refuses any Extra config carrying that key: config.json is left completely
#    untouched, never merely "correct but ambiguous".
setup_pkg
rm -f "$CONF"   # a clean baseline: no leftover config.json from an earlier section's successful hconfig call
hconfig "p:1" "W" "" '"randomx": {"1gb-pages": true}' ""      # verus (empty algo) + a "randomx" top-level key
if [[ $rc != 0 && ! -f $CONF ]] && grep -qF "randomx" <<< "$out"; then
	ok "verus + Extra config \"randomx\" -> rejected, config.json never written"
else
	bad "verus + Extra config \"randomx\" -> rejected, config.json never written" "rc=$rc conf_exists=$([[ -f $CONF ]] && echo yes) out=$out"
fi
hconfig "p:1" "W" "" '"randomx": {"1gb-pages": true}' "verus"   # explicit "verus" algo, not just empty
if [[ $rc != 0 && ! -f $CONF ]]; then ok "verus (explicit) + Extra config \"randomx\" -> rejected"; else bad "verus (explicit) + Extra config \"randomx\" -> rejected" "rc=$rc"; fi

hconfig "p:1" "W" "" '"algo": "verus"' "rx/0"                  # rx + a top-level "algo" key (not pools[0].algo)
if [[ $rc != 0 && ! -f $CONF ]] && grep -qF "algo" <<< "$out"; then
	ok "rx + Extra config \"algo\" -> rejected, config.json never written"
else
	bad "rx + Extra config \"algo\" -> rejected, config.json never written" "rc=$rc conf_exists=$([[ -f $CONF ]] && echo yes) out=$out"
fi

# a rejection must never leave a PREVIOUS good config.json touched either (same atomicity guarantee as section 3)
hconfig "p:1" "W" "4" "" ""                                     # good verus baseline
good_conf3=$(cat "$CONF")
hconfig "p:1" "W" "4" '"randomx": {}' ""
if [[ $rc != 0 && $(cat "$CONF") == "$good_conf3" ]]; then ok "foreign-selector rejection leaves a PRIOR good config.json untouched"; else bad "foreign-selector rejection leaves a PRIOR good config.json untouched" "rc=$rc"; fi

# regression: legitimate Extra config (no foreign selector key) for both engines still works exactly as before
hconfig "p:1" "W" "" '"dashboard": true' ""
if [[ $rc == 0 && $(jq -r '.algo' "$CONF" 2>/dev/null) == verus ]]; then ok "verus + legitimate Extra config (dashboard) still accepted"; else bad "verus + legitimate Extra config (dashboard) still accepted" "rc=$rc out=$out"; fi
hconfig "p:1" "W" "" '"tls": true' "rx/0"
if [[ $rc == 0 && $(jq -r '.pools[0].tls' "$CONF" 2>/dev/null) == true ]]; then ok "rx + legitimate Extra config (tls) still accepted"; else bad "rx + legitimate Extra config (tls) still accepted" "rc=$rc out=$out"; fi

# ============================================================== 5. engine derivation: config.json is the SOLE
#    authority. A leftover/mismatched marker file (however it got there - an old install, a half-completed
#    switch simulated either direction) is ignored outright; config always wins. Anything engine_from_config
#    cannot positively recognise - missing, unreadable, garbage, valid JSON with neither engine's marker, or jq
#    itself unavailable - fails CLOSED end to end: h-run.sh refuses to start (non-zero exit, a Hive error
#    message, engine binary never exec'd), h-stats.sh still returns a safe, valid, empty answer and never
#    crashes the sourcing agent. Never a default-to-verus guess anywhere in this section.
setup_pkg
LEFTOVER="$T/state/.bloxminer-engine"   # the OLD (removed) state-file path: nothing reads this any more: it
	# exists here purely as a hostile/stale artefact the tests plant to prove it changes nothing.

hconfig "p:1" "W" "" "" "rx/0"; mkdir -p "$T/state"; printf 'verus\n' > "$LEFTOVER"
if [[ $(cfgengine) == rx ]]; then ok "config=rx, mismatched leftover marker=verus -> config wins (rx)"; else bad "config=rx, mismatched leftover marker=verus -> config wins (rx)" "$(cfgengine)"; fi

hconfig "p:1" "W" "" "" ""; printf 'rx\n' > "$LEFTOVER"
if [[ $(cfgengine) == verus ]]; then ok "config=verus, mismatched leftover marker=rx -> config wins (verus)"; else bad "config=verus, mismatched leftover marker=rx -> config wins (verus)" "$(cfgengine)"; fi
rm -f "$LEFTOVER"

run_h_run_fail_closed() {   # $1 = test label; expects: engine binaries are absent in this fixture, so the
	# ONLY way h-run.sh can exit non-zero here is its OWN fail-closed refusal (a successful derivation always
	# reaches exec, which fails with "No such file", not a controlled non-zero exit) - see section 7.
	: > "$MESSAGE_LOG"
	out=$(bash "$BLOX_DIR/h-run.sh" 2>&1); rc=$?
	if [[ $rc != 0 ]] && grep -q "^error " "$MESSAGE_LOG" && [[ -z ${out##*BloxMiner: cannot start*} ]]; then
		ok "h-run.sh: $1 -> fails closed (exit $rc, Hive message error, no exec)"
	else
		bad "h-run.sh: $1 -> fails closed (exit $rc, Hive message error, no exec)" "rc=$rc msg=$(cat "$MESSAGE_LOG") out=$out"
	fi
}
run_h_stats_fail_closed() {   # $1 = test label; must NEVER crash the sourcing agent: khs=0, a minimal valid
	# stats object (never an empty string - neither engine's own VER/algo is known at this level, but a valid
	# object beats an empty one when Hive's own handling of an empty $stats is not itself verifiable here),
	# clean return.
	res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; echo "rc=$? khs=[$khs] stats=[$stats]"' 2>&1); rc=$?
	if [[ $rc == 0 && $res == 'rc=0 khs=[0] stats=[{"hs":[0],"hs_units":"khs","temp":[null],"ar":[0,0],"uptime":0}]' ]]; then
		ok "h-stats.sh: $1 -> returns cleanly (khs=0, minimal valid stats, never crashes)"
	else
		bad "h-stats.sh: $1 -> returns cleanly (khs=0, minimal valid stats, never crashes)" "rc=$rc res=$res"
	fi
}

hconfig "p:1" "W" "" "" ""   # establish a valid baseline config first, then destroy it per case below
rm -f "$CONF"
if [[ -z $(cfgengine) ]]; then ok "missing config.json -> engine_from_config fails closed (no output)"; else bad "missing config.json -> engine_from_config fails closed (no output)" "$(cfgengine)"; fi
run_h_run_fail_closed "missing config.json"
run_h_stats_fail_closed "missing config.json"

printf 'this is not json at all {{{' > "$CONF"
if [[ -z $(cfgengine) ]]; then ok "garbage (invalid JSON) config.json -> fails closed"; else bad "garbage (invalid JSON) config.json -> fails closed" "$(cfgengine)"; fi
run_h_run_fail_closed "garbage config.json"
run_h_stats_fail_closed "garbage config.json"

printf '{"pools":[{"url":"p:1"}],"threads":4}\n' > "$CONF"   # valid JSON, neither "randomx" nor algo=="verus"
if [[ -z $(cfgengine) ]]; then ok "config.json with neither engine's marker -> fails closed"; else bad "config.json with neither engine's marker -> fails closed" "$(cfgengine)"; fi
run_h_run_fail_closed "config.json with neither marker"
run_h_stats_fail_closed "config.json with neither marker"

# a hand-crafted config.json (never something either engine's own h-config.sh would produce - section 4 keeps
# a LEGITIMATELY generated one from ever reaching this state) carrying BOTH markers is ambiguous -> fails
# closed exactly like neither marker being present, never a guess either way
printf '{"algo":"verus","randomx":{}}\n' > "$CONF"
if [[ -z $(cfgengine) ]]; then ok "config.json with BOTH markers (algo=verus AND randomx) -> fails closed, ambiguous"; else bad "config.json with BOTH markers (algo=verus AND randomx) -> fails closed, ambiguous" "$(cfgengine)"; fi
run_h_run_fail_closed "config.json with both markers"
run_h_stats_fail_closed "config.json with both markers"

# a "randomx" key present but not an object (never something either engine would write) does not count as the
# rx marker - only the OTHER, correctly-typed marker (if any) is honoured, never treated as an added ambiguity
printf '{"algo":"verus","randomx":"not-an-object"}\n' > "$CONF"
if [[ $(cfgengine) == verus ]]; then ok "config.json with wrong-type \"randomx\" (string) + valid algo=verus -> verus, not ambiguous"; else bad "config.json with wrong-type \"randomx\" (string) + valid algo=verus -> verus, not ambiguous" "$(cfgengine)"; fi

hconfig "p:1" "W" "" "" ""   # a genuinely valid config again, to isolate the jq-absence case from a bad config
# shellcheck disable=SC1007,SC2016   # PATH="" is intentional; the single-quoted $vars expand inside the child, not here
noqj=$(PATH="" "$BASHBIN" -c '. "$BLOX_DIR/h-manifest.conf" 2>/dev/null; . "$BLOX_DIR/h-common.sh" 2>/dev/null; engine_from_config' 2>/dev/null)
if [[ -z $noqj ]]; then
	ok "jq unavailable -> engine_from_config fails closed even with a valid config"
else
	bad "jq unavailable -> engine_from_config fails closed even with a valid config" "unexpected output: $noqj"
fi
: > "$MESSAGE_LOG"
# shellcheck disable=SC1007   # PATH="" (an intentionally empty PATH), not a stray assignment typo
out=$(PATH="" "$BASHBIN" "$BLOX_DIR/h-run.sh" 2>&1); rc=$?
if [[ $rc != 0 ]] && grep -q "^error " "$MESSAGE_LOG" && [[ -z ${out##*BloxMiner: cannot start*} ]]; then
	ok "h-run.sh: jq unavailable -> fails closed (exit $rc, Hive message error)"
else
	bad "h-run.sh: jq unavailable -> fails closed (exit $rc, Hive message error)" "rc=$rc msg=$(cat "$MESSAGE_LOG") out=$out"
fi
# shellcheck disable=SC1007,SC2016   # PATH="" is intentional; the single-quoted $vars expand inside the child, not here
res=$(PATH="" "$BASHBIN" -c '. "$BLOX_DIR/h-stats.sh"; echo "rc=$? khs=[$khs] stats=[$stats]"' 2>&1); rc=$?
if [[ $rc == 0 && $res == 'rc=0 khs=[0] stats=[{"hs":[0],"hs_units":"khs","temp":[null],"ar":[0,0],"uptime":0}]' ]]; then
	ok "h-stats.sh: jq unavailable -> returns cleanly (khs=0, minimal valid stats, never crashes)"
else
	bad "h-stats.sh: jq unavailable -> returns cleanly (khs=0, minimal valid stats, never crashes)" "rc=$rc res=$res"
fi

# ============================================================== 6. huge-page ownership handoff: ONLY the
#    reservation this package itself made is ever touched - never a blind host-wide reset, and never restored
#    over the top of a change something else made since. note_rx_hugepages_start (rx start, h-run.sh) records
#    prior=/prelim=/free0=/boot=/final=0; a Verus start only ever restores when final=1 (finalize_rx_hugepages,
#    h-stats.sh - tested end to end, including the whole cask18 scenario, in tests/hive/test_hugepage_
#    finalization.sh) AND the CURRENT value still equals the finalized "ours"; otherwise it is left alone, a
#    conflict is logged, and the record is KEPT (never silently dropped) for a later attempt. A failed restore
#    write also keeps the record - it is consumed ONLY on a verified, successful (readback-checked) restore.
#    This section covers note_rx_hugepages_start's OWN field-writing/never-overwrite behaviour and restore_
#    verus_hugepages's OWN gating/atomicity - `finalize_record_for_test` stands in for finalize_rx_hugepages
#    (which needs a real xmrig HTTP API, out of scope for this file) by writing exactly what it would have
#    written on success, so restore's own logic can be exercised without duplicating the finalization suite.
setup_pkg
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
PROCROOT="$T/proc"; mkdir -p "$PROCROOT/sys/vm" "$PROCROOT/sys/kernel/random"
PROCFILE="$PROCROOT/sys/vm/nr_hugepages"
MEMINFO="$PROCROOT/meminfo"
BOOTFILE="$PROCROOT/sys/kernel/random/boot_id"
printf 'boot-TEST-CONSTANT\n' > "$BOOTFILE"
printf '1000.00 0.00\n' > "$PROCROOT/uptime"   # Round 5c: note_rx_hugepages_start now also needs /proc/uptime
	# (start_uptime) to write a record at all - a static value throughout this section is fine, since the
	# window-bound itself is exercised end to end in tests/hive/test_hugepage_finalization.sh, not here.
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
echo "sysctl $*" >> "$SYSCTL_LOG"
[ "${SYSCTL_FAIL:-0}" = "1" ] && exit 1
# Round 5: restore_verus_hugepages now reads vm.nr_hugepages BACK after this call and only removes the record
# if it really changed - so this fake must really write it, not just log the call and exit 0.
for a in "$@"; do case $a in vm.nr_hugepages=*) echo "${a#vm.nr_hugepages=}" > "$PROCFILE" ;; esac; done
exit 0
SH
chmod +x "$FAKEBIN/sysctl"
cat > "$FAKEBIN/hugepages" <<'SH'
#!/bin/sh
echo "hugepages $*" >> "$SYSCTL_LOG"
if [ "$1" = "-rx" ]; then
	echo "${HUGEPAGES_TARGET:-1200}" > "$PROCFILE"
	printf 'HugePages_Free:  %8d kB\n' "${HUGEPAGES_FREE0:-100}" > "$MEMINFO"
fi
exit 0
SH
chmod +x "$FAKEBIN/hugepages"
SYSCTL_LOG="$T/sysctl.log"; export SYSCTL_LOG PROCFILE MEMINFO BOOTFILE
sysctl_called() { grep -q '^sysctl ' "$SYSCTL_LOG" 2>/dev/null; }
hugepages_called() { grep -q '^hugepages ' "$SYSCTL_LOG" 2>/dev/null; }
run_h_run() { PATH="$FAKEBIN:$PATH" BLOX_PROCFS_ROOT="$PROCROOT" HUGEPAGES_TARGET="${HUGEPAGES_TARGET:-1200}" HUGEPAGES_FREE0="${HUGEPAGES_FREE0:-100}" SYSCTL_FAIL="${SYSCTL_FAIL:-0}" timeout 2 bash "$BLOX_DIR/h-run.sh" > /dev/null 2>&1; }   # engine binary absent -> exec fails after the hugepage step, harmless here
# marks the CURRENT record final=1, ours=<live nr_hugepages> - simulates a successful finalize_rx_hugepages
# poll (real end-to-end finalization behaviour, including the exact xmrig-src-derived formula, is covered in
# tests/hive/test_hugepage_finalization.sh) so this section can test restore_verus_hugepages's OWN logic.
finalize_record_for_test() {
	local prior prelim free0 boot start_uptime
	prior=$(sed -n 's/^prior=//p' "$HUGEFILE" 2>/dev/null); prelim=$(sed -n 's/^prelim=//p' "$HUGEFILE" 2>/dev/null)
	free0=$(sed -n 's/^free0=//p' "$HUGEFILE" 2>/dev/null); boot=$(sed -n 's/^boot=//p' "$HUGEFILE" 2>/dev/null)
	start_uptime=$(sed -n 's/^start_uptime=//p' "$HUGEFILE" 2>/dev/null)
	printf 'prior=%s\nprelim=%s\nfree0=%s\nboot=%s\nstart_uptime=%s\nfinal=1\nours=%s\n' \
		"$prior" "$prelim" "$free0" "$boot" "$start_uptime" "$(cat "$PROCFILE")" > "$HUGEFILE"
}

# ---- fresh verus start, a foreign reservation already on the box (512), no ownership record -> untouched
echo 512 > "$PROCFILE"
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && ! hugepages_called && [[ ! -e $HUGEFILE ]]; then
	ok "fresh verus start, foreign reservation (512), no record -> untouched, no sysctl/hugepages call"
else
	bad "fresh verus start, foreign reservation (512), no record -> untouched, no sysctl/hugepages call" "log=$(cat "$SYSCTL_LOG" 2>/dev/null) hugefile=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE")"
fi
if [[ $(cat "$PROCFILE") == 512 ]]; then ok "fresh verus start: host's own nr_hugepages value (512) left as-is"; else bad "fresh verus start: host's own nr_hugepages value (512) left as-is" "$(cat "$PROCFILE")"; fi

# ---- rx start (from the 512 baseline) -> runs `hugepages -rx` itself (idempotent with rx's own later call),
#      records prior=512 (what was there before), prelim=1200 (post-`hugepages -rx`, via the fake tool),
#      free0=100 (fake HugePages_Free), boot=the fixture's boot_id, and final=0 - NOT "ours" any more (Round 5:
#      only finalize_rx_hugepages, proven separately, ever writes that - see the top-of-section comment)
HUGEPAGES_TARGET=1200; HUGEPAGES_FREE0=100
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run
rec1=$(cat "$HUGEFILE" 2>/dev/null)
if [[ $(sed -n 's/^prior=//p' <<< "$rec1") == 512 && $(sed -n 's/^prelim=//p' <<< "$rec1") == 1200 \
      && $(sed -n 's/^free0=//p' <<< "$rec1") == 100 && $(sed -n 's/^boot=//p' <<< "$rec1") == boot-TEST-CONSTANT \
      && $(sed -n 's/^final=//p' <<< "$rec1") == 0 && -z $(sed -n 's/^ours=//p' <<< "$rec1") ]]; then
	ok "rx start: records prior=512, prelim=1200, free0=100, boot, final=0 (no ours= yet)"
else
	bad "rx start: records prior=512, prelim=1200, free0=100, boot, final=0 (no ours= yet)" "$rec1"
fi
# a FRESH rx start calls `hugepages -rx` TWICE: once from note_rx_hugepages_start itself (to observe "prelim"),
# once more from engines/rx/h-run.sh's own unchanged, unconditional call right after exec - both hit the same
# fake tool here, so counting (not just presence) is what actually distinguishes a fresh start from a restart
# below. Never sysctl directly (that only ever happens on a Verus start).
if [[ $(grep -c '^hugepages -rx$' "$SYSCTL_LOG" 2>/dev/null) == 2 ]] && ! sysctl_called; then ok "rx start: calls hugepages -rx TWICE (this dispatcher's own + the rx engine's own), never sysctl directly"; else bad "rx start: calls hugepages -rx TWICE, never sysctl directly" "$(cat "$SYSCTL_LOG")"; fi
if [[ $(cat "$PROCFILE") == 1200 ]]; then ok "rx start: nr_hugepages actually raised to 1200 by this dispatcher's own call"; else bad "rx start: nr_hugepages actually raised to 1200" "$(cat "$PROCFILE")"; fi

# ---- rx "restarted" (still rx, e.g. a flight-sheet edit that keeps the algo) -> record already exists, so
#      note_rx_hugepages_start returns immediately without calling hugepages itself: only ONE call this time
#      (the rx engine's own unconditional one), not two, and no overwrite of the existing record
hconfig "p:1" "W" "" "" "rx/wow"; : > "$SYSCTL_LOG"; run_h_run
if [[ $(cat "$HUGEFILE" 2>/dev/null) == "$rec1" ]]; then ok "rx restarted: existing record (prior=512/prelim=1200/final=0) NOT overwritten"; else bad "rx restarted: existing record NOT overwritten" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
if [[ $(grep -c '^hugepages -rx$' "$SYSCTL_LOG" 2>/dev/null) == 1 ]]; then ok "rx restarted: hugepages -rx called only ONCE (the engine's own; this dispatcher's own call is skipped)"; else bad "rx restarted: hugepages -rx called only ONCE" "$(cat "$SYSCTL_LOG")"; fi

# ---- verus with final=0 (never finalized yet) -> must NEVER restore, even though current == prelim (1200):
#      Round 5's whole point is that "current == the value right after `hugepages -rx`" is NOT sufficient proof
#      any more - only a finalized "ours" is.
: > "$SYSCTL_LOG"; hconfig "p:1" "W" "" "" ""; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]]; then ok "verus with final=0: never restores, even though current==prelim (1200)"; else bad "verus with final=0: never restores" "$(cat "$SYSCTL_LOG")"; fi
if grep -q "not finalized" "$T/log/bloxminer.log" 2>/dev/null; then ok "verus with final=0: logged as not-yet-finalized"; else bad "verus with final=0: logged as not-yet-finalized" "$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

# ---- NOW finalize (simulating h-stats.sh having proven it - see test_hugepage_finalization.sh) -> verus
#      restores to the ORIGINAL prior (512), record removed, readback verified
finalize_record_for_test
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if grep -q "nr_hugepages=512" "$SYSCTL_LOG" 2>/dev/null; then ok "verus after finalization: restored to the ORIGINAL prior value (512)"; else bad "verus after finalization: restored to the ORIGINAL prior value (512)" "$(cat "$SYSCTL_LOG" 2>/dev/null)"; fi
if [[ ! -e $HUGEFILE ]]; then ok "verus after finalization: ownership record removed (restore verified successful)"; else bad "verus after finalization: ownership record removed" "still present: $(cat "$HUGEFILE")"; fi

# ---- verus again, no record (already consumed above) -> no sysctl call at all
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called; then ok "verus with no record -> no sysctl call"; else bad "verus with no record -> no sysctl call" "$(cat "$SYSCTL_LOG")"; fi

# ---- rx from a 0 baseline, finalized -> verus restores to 0 (not just non-zero values are handled correctly)
echo 0 > "$PROCFILE"; rm -f "$HUGEFILE"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run
finalize_record_for_test
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if grep -q "nr_hugepages=0" "$SYSCTL_LOG" 2>/dev/null; then ok "verus after rx (0 baseline), finalized: restored to 0"; else bad "verus after rx (0 baseline), finalized: restored to 0" "$(cat "$SYSCTL_LOG" 2>/dev/null)"; fi

# ---- something else changes nr_hugepages AFTER finalization (foreign write, e.g. another workload or an
#      operator) -> the next Verus start must NEVER overwrite it: left untouched, the conflict is logged (own
#      log file, not a Hive toast - this is not fatal), and the record is KEPT (not dropped) so a later attempt
#      still has "prior" on file.
echo 0 > "$PROCFILE"; rm -f "$HUGEFILE"; rm -f "$T/log/bloxminer.log"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run   # prior=0, prelim=1200
finalize_record_for_test   # final=1, ours=1200
echo 777 > "$PROCFILE"   # a THIRD party changes it - no longer "ours" (1200)
recorded_before=$(cat "$HUGEFILE")
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ $(cat "$PROCFILE") == 777 ]]; then ok "foreign change after finalization (1200 -> 777): Verus start never overwrites it"; else bad "foreign change after finalization: Verus start never overwrites it" "sysctl_log=$(cat "$SYSCTL_LOG") proc=$(cat "$PROCFILE")"; fi
if [[ -e $HUGEFILE && $(cat "$HUGEFILE") == "$recorded_before" ]]; then ok "foreign change: ownership record KEPT unchanged (prior=0/ours=1200), not dropped"; else bad "foreign change: ownership record KEPT unchanged" "$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo MISSING)"; fi
if [[ -f $T/log/bloxminer.log ]] && grep -q "changed outside this package" "$T/log/bloxminer.log"; then ok "foreign change: conflict logged to this package's own log"; else bad "foreign change: conflict logged" "$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

# ---- nr_hugepages still == ours (no conflict), but the sysctl WRITE itself fails (e.g. permission denied) ->
#      the record must be RETAINED, never dropped on a failed attempt
echo 0 > "$PROCFILE"; rm -f "$HUGEFILE"; rm -f "$T/log/bloxminer.log"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run   # prior=0, prelim=1200 (nr_hugepages is 1200 now)
finalize_record_for_test   # final=1, ours=1200
recorded_before2=$(cat "$HUGEFILE")
SYSCTL_FAIL=1
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
SYSCTL_FAIL=0
if sysctl_called; then ok "failed sysctl write: a restore WAS attempted (nr_hugepages still matched ours)"; else bad "failed sysctl write: a restore WAS attempted" "$(cat "$SYSCTL_LOG")"; fi
if [[ -e $HUGEFILE && $(cat "$HUGEFILE") == "$recorded_before2" ]]; then ok "failed sysctl write: ownership record RETAINED, not dropped"; else bad "failed sysctl write: ownership record RETAINED" "$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo MISSING)"; fi

# ---- Round 3: ANY single missing/corrupt piece of a FINALIZED record, or an unreadable CURRENT value, must
#      NEVER fall through to a restore attempt - the restore fires only when prior, ours, AND the live current
#      value are all valid numbers AND current == ours. Every other case here: no sysctl call, the record is
#      RETAINED (never dropped - a permanently corrupt record just stays on tmpfs until a reboot clears it),
#      and a log line explains why. (final=1 is included in every fixture below - these test the NEXT gate
#      down, not the final=1 gate itself, which section 6's earlier "verus with final=0" case already covers.)
hconfig "p:1" "W" "" "" ""   # a valid verus config throughout this block - only the hugepage record is corrupted
rm -f "$HUGEFILE" "$T/log/bloxminer.log"; printf 'prior=512\nboot=boot-TEST-CONSTANT\nfinal=1\n' > "$HUGEFILE"; echo 512 > "$PROCFILE"   # ours= missing entirely
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "invalid or corrupt" "$T/log/bloxminer.log" 2>/dev/null; then ok "missing ours (final=1) -> no sysctl call, record retained, logged"; else bad "missing ours (final=1) -> no sysctl call, record retained, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo GONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

rm -f "$HUGEFILE" "$T/log/bloxminer.log"; printf 'prior=512\nours=banana\nboot=boot-TEST-CONSTANT\nfinal=1\n' > "$HUGEFILE"; echo 512 > "$PROCFILE"   # ours= non-numeric
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "invalid or corrupt" "$T/log/bloxminer.log" 2>/dev/null; then ok "corrupt ours (non-numeric, final=1) -> no sysctl call, record retained, logged"; else bad "corrupt ours (non-numeric, final=1) -> no sysctl call, record retained, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo GONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

rm -f "$HUGEFILE" "$T/log/bloxminer.log"; printf 'prior=banana\nours=512\nboot=boot-TEST-CONSTANT\nfinal=1\n' > "$HUGEFILE"; echo 512 > "$PROCFILE"   # prior= non-numeric
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "invalid or corrupt" "$T/log/bloxminer.log" 2>/dev/null; then ok "corrupt prior (final=1) -> no sysctl call, record retained, logged"; else bad "corrupt prior (final=1) -> no sysctl call, record retained, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo GONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

rm -f "$HUGEFILE" "$T/log/bloxminer.log"; printf 'prior=512\nours=1200\nboot=boot-TEST-CONSTANT\nfinal=1\n' > "$HUGEFILE"; rm -f "$PROCFILE"   # current value unreadable
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "could not read the current" "$T/log/bloxminer.log" 2>/dev/null; then ok "unreadable current value (final=1) -> no sysctl call, record retained, logged"; else bad "unreadable current value (final=1) -> no sysctl call, record retained, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo GONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi
echo 512 > "$PROCFILE"

# note_rx_hugepages_start itself must never WRITE a record with an invalid "prelim": simulate a `hugepages -rx`
# that leaves the current value unreadable afterwards (e.g. a transient /proc glitch) - no record at all, logged
rm -f "$HUGEFILE" "$T/log/bloxminer.log"
cat > "$FAKEBIN/hugepages" <<'SH'
#!/bin/sh
echo "hugepages $*" >> "$SYSCTL_LOG"
[ "$1" = "-rx" ] && rm -f "$PROCFILE"
exit 0
SH
echo 0 > "$PROCFILE"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run
if [[ ! -e $HUGEFILE ]] && grep -q "no ownership record written" "$T/log/bloxminer.log" 2>/dev/null; then ok "note_rx_hugepages_start: unreadable post-reservation value (prelim) -> no record written, logged"; else bad "note_rx_hugepages_start: unreadable post-reservation value (prelim) -> no record written, logged" "record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo NONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi
cat > "$FAKEBIN/hugepages" <<'SH'
#!/bin/sh
echo "hugepages $*" >> "$SYSCTL_LOG"
if [ "$1" = "-rx" ]; then
	echo "${HUGEPAGES_TARGET:-1200}" > "$PROCFILE"
	printf 'HugePages_Free:  %8d kB\n' "${HUGEPAGES_FREE0:-100}" > "$MEMINFO"
fi
exit 0
SH
chmod +x "$FAKEBIN/hugepages"

# note_rx_hugepages_start must also never WRITE a record with an invalid "free0" (Round 5 - HugePages_Free is
# the other value finalize_rx_hugepages's predicted-total formula needs): simulate a fake `hugepages -rx` that
# leaves meminfo unreadable - no record at all, logged
rm -f "$HUGEFILE" "$T/log/bloxminer.log" "$MEMINFO"
cat > "$FAKEBIN/hugepages" <<'SH'
#!/bin/sh
echo "hugepages $*" >> "$SYSCTL_LOG"
if [ "$1" = "-rx" ]; then
	echo "${HUGEPAGES_TARGET:-1200}" > "$PROCFILE"
	rm -f "$MEMINFO"
fi
exit 0
SH
echo 0 > "$PROCFILE"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run
if [[ ! -e $HUGEFILE ]] && grep -q "no ownership record written" "$T/log/bloxminer.log" 2>/dev/null; then ok "note_rx_hugepages_start: unreadable HugePages_Free (free0) -> no record written, logged"; else bad "note_rx_hugepages_start: unreadable HugePages_Free (free0) -> no record written, logged" "record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo NONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi
cat > "$FAKEBIN/hugepages" <<'SH'
#!/bin/sh
echo "hugepages $*" >> "$SYSCTL_LOG"
if [ "$1" = "-rx" ]; then
	echo "${HUGEPAGES_TARGET:-1200}" > "$PROCFILE"
	printf 'HugePages_Free:  %8d kB\n' "${HUGEPAGES_FREE0:-100}" > "$MEMINFO"
fi
exit 0
SH
chmod +x "$FAKEBIN/hugepages"

# legacy (pre-Round-5) record: only prior=/ours=, no final= line at all - never trusted for a restore (missing
# final never equals "1"), left untouched until the next reboot clears tmpfs; no migration code needed.
hconfig "p:1" "W" "" "" ""   # a verus config, so run_h_run below actually exercises restore_verus_hugepages
rm -f "$T/log/bloxminer.log"; printf 'prior=512\nours=1200\n' > "$HUGEFILE"; echo 1200 > "$PROCFILE"
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "not finalized" "$T/log/bloxminer.log" 2>/dev/null; then ok "legacy pre-Round-5 record (no final=): never restored, kept, logged"; else bad "legacy pre-Round-5 record (no final=): never restored, kept, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$(cat "$HUGEFILE" 2>/dev/null) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi
rm -f "$HUGEFILE"

# ============================================================== 7. stats never from the previous engine
# Neither fixture engine's real API is running here, so each one falls back to its own DEFINED no-API answer
# (see each engine's own gated h-stats.sh): verus (unchanged, gated behaviour) reports empty stats outright;
# rx (unchanged, gated behaviour) still reports a fallback object that echoes config.json's OWN current algo.
# That asymmetry is exactly what makes this a real contamination test: switching rx -> verus must produce
# verus's empty answer, never rx's last (fallback) data, and rx must always echo the CURRENT config's algo,
# never a stale one from before a verus -> rx switch.
setup_pkg
hconfig "p:1" "W" "" "" "rx/wow"   # rx active
res_rx=$(bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg s "$stats" "(\$s | if . == \"\" then null else fromjson end)"' 2>&1)
algo_rx=$(jq -r '.algo // "MISSING"' <<< "$res_rx" 2>/dev/null)
if [[ $algo_rx == "rx/wow" ]]; then ok "h-stats (rx active): reports the current config's own algo (rx/wow)"; else bad "h-stats (rx active): reports the current config's own algo (rx/wow)" "$res_rx"; fi

hconfig "p:1" "W" "" "" ""         # switch to verus
res_verus=$(bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs] stats=[$stats]"' 2>&1)
if [[ $res_verus == "khs=[0] stats=[]" ]]; then
	ok "h-stats (switched to verus): verus's own empty answer, no leftover rx data"
else
	bad "h-stats (switched to verus): verus's own empty answer, no leftover rx data" "$res_verus"
fi

hconfig "p:1" "W" "" "" "rx/arq"   # switch back to rx with a DIFFERENT algo than before
res_rx2=$(bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg s "$stats" "(\$s | if . == \"\" then null else fromjson end)"' 2>&1)
algo_rx2=$(jq -r '.algo // "MISSING"' <<< "$res_rx2" 2>/dev/null)
if [[ $algo_rx2 == "rx/arq" ]]; then ok "h-stats (rx active again): reflects the NEW current algo (rx/arq), not the earlier rx/wow"; else bad "h-stats (rx active again): reflects the NEW current algo (rx/arq), not the earlier rx/wow" "$res_rx2"; fi

# ============================================================== 8. h-run execs the right engine binary path
setup_pkg
hconfig "p:1" "W" "" "" ""
run_out=$(timeout 2 bash "$BLOX_DIR/h-run.sh" 2>&1)
if grep -qF "$BLOX_DIR/bloxminer: No such file" <<< "$run_out"; then ok "h-run on verus execs ./bloxminer"; else bad "h-run on verus execs ./bloxminer" "$run_out"; fi
hconfig "p:1" "W" "" "" "rx/0"
run_out=$(timeout 2 bash "$BLOX_DIR/h-run.sh" 2>&1)
if grep -qF "$BLOX_DIR/xmrig: No such file" <<< "$run_out"; then ok "h-run on rx execs ./xmrig"; else bad "h-run on rx execs ./xmrig" "$run_out"; fi

# ============================================================== 9. Round 4: Hive's REAL sourcing behaviour,
#    end to end. hconfig() above (section 1 onward) already runs h-config.sh SOURCED with non-exported CUSTOM_*
#    vars, which is what actually exercises the fix - but it always starts from a fresh $BLOX_DIR-relative
#    invocation. This section goes one step further and reproduces Hive's own call shape as literally as
#    possible: a wallet.conf-like fixture sourced with `set +a` (CUSTOM_* end up as plain, non-exported
#    variables of the CALLING shell, exactly as /hive/miners/custom/h-config.sh:55's
#    `. $MINER_DIR/$CUSTOM_MINER/h-config.sh` and /hive/bin/miner:386's `source $MINER_DIR/h-config.sh` leave
#    them - see hive-ref/miner and hive-ref/miner-run), from a starting directory that is NOT $BLOX_DIR (Hive
#    never cds us there either), then this dispatcher is sourced directly into that same shell. Proves three
#    things no earlier section does: (a) config.json gets the REAL CUSTOM_URL/CUSTOM_TEMPLATE/CUSTOM_PASS for
#    BOTH engines - the exact cask18 bug (a non-exported CUSTOM_URL, invisible to the OLD code's child-process
#    engine call, produced "the pool URL in the flight sheet is empty" for both engines and no miner ever
#    started); (b) the calling shell SURVIVES a dispatcher-level AND an engine-level error (never killed by an
#    escaping `exit`) - proven by a marker printed immediately after the source call, which can only appear if
#    that call returned control instead of terminating the process; (c) the calling shell's cwd is unchanged.
setup_pkg
WALLET="$T/wallet.conf"
hive_sourced() {   # $1=url $2=template $3=pass $4=extra $5=algo -> sets $out $rc $survived $pwd_after
	printf 'CUSTOM_URL=%q\nCUSTOM_TEMPLATE=%q\nCUSTOM_PASS=%q\nCUSTOM_USER_CONFIG=%q\nCUSTOM_ALGO=%q\n' \
		"$1" "$2" "$3" "$4" "$5" > "$WALLET"
	out=$(BLOX_DIR="$BLOX_DIR" WALLET="$WALLET" STARTDIR="$T" bash -c '
		set +a
		cd "$STARTDIR"                # start somewhere OTHER than BLOX_DIR - Hive never cds us there either
		. "$WALLET"                   # CUSTOM_* now plain, NON-exported vars of THIS shell - never in the env
		. "$BLOX_DIR/h-config.sh"     # the real Hive call shape: sourced, never executed as a subprocess
		rc=$?
		printf "SURVIVED rc=%d pwd=%s\n" "$rc" "$PWD"
	' 2>&1)
	survived=$(grep -q '^SURVIVED rc=' <<< "$out" && echo y)
	rc=$(sed -n 's/^SURVIVED rc=\(-\{0,1\}[0-9]*\) pwd=.*/\1/p' <<< "$out")
	pwd_after=$(sed -n 's/^SURVIVED rc=-\{0,1\}[0-9]* pwd=//p' <<< "$out")
}

# ---- verus: correct config.json from real (non-exported) flight-sheet vars, caller survives, cwd unchanged
hive_sourced "pool.example.com:9001" "WALLET.worker9" "7" "" "verus"
if [[ -n $survived && $rc == 0 && $pwd_after == "$T" ]]; then ok "Hive-sourced verus: dispatcher returns cleanly, caller survives, cwd unchanged"; else bad "Hive-sourced verus: dispatcher returns cleanly, caller survives, cwd unchanged" "$out"; fi
if [[ $(jq -r '.pools[0].url' "$CONF" 2>/dev/null) == "stratum+tcp://pool.example.com:9001" ]]; then ok "Hive-sourced verus: config.json pool URL matches the non-exported CUSTOM_URL"; else bad "Hive-sourced verus: config.json pool URL matches the non-exported CUSTOM_URL" "$(cat "$CONF" 2>/dev/null)"; fi
if [[ $(jq -r '.user' "$CONF" 2>/dev/null) == "WALLET.worker9" ]]; then ok "Hive-sourced verus: config.json user matches the non-exported CUSTOM_TEMPLATE"; else bad "Hive-sourced verus: config.json user matches the non-exported CUSTOM_TEMPLATE" "$(cat "$CONF" 2>/dev/null)"; fi
if [[ $(jq -r '.threads' "$CONF" 2>/dev/null) == 7 ]]; then ok "Hive-sourced verus: config.json threads matches the non-exported CUSTOM_PASS (thread count)"; else bad "Hive-sourced verus: config.json threads matches the non-exported CUSTOM_PASS" "$(cat "$CONF" 2>/dev/null)"; fi

# ---- rx: same, other engine (Pass is a POOL PASSWORD here, not a thread count)
hive_sourced "pool.example.com:9002" "WALLET.worker2" "secretpass" "" "rx/wow"
if [[ -n $survived && $rc == 0 && $pwd_after == "$T" ]]; then ok "Hive-sourced rx: dispatcher returns cleanly, caller survives, cwd unchanged"; else bad "Hive-sourced rx: dispatcher returns cleanly, caller survives, cwd unchanged" "$out"; fi
if [[ $(jq -r '.pools[0].url' "$CONF" 2>/dev/null) == "stratum+tcp://pool.example.com:9002" ]]; then ok "Hive-sourced rx: config.json pool URL matches the non-exported CUSTOM_URL"; else bad "Hive-sourced rx: config.json pool URL matches the non-exported CUSTOM_URL" "$(cat "$CONF" 2>/dev/null)"; fi
if [[ $(jq -r '.pools[0].user' "$CONF" 2>/dev/null) == "WALLET.worker2" ]]; then ok "Hive-sourced rx: config.json user matches the non-exported CUSTOM_TEMPLATE"; else bad "Hive-sourced rx: config.json user matches the non-exported CUSTOM_TEMPLATE" "$(cat "$CONF" 2>/dev/null)"; fi
if [[ $(jq -r '.pools[0].pass' "$CONF" 2>/dev/null) == "secretpass" ]]; then ok "Hive-sourced rx: config.json pass matches the non-exported CUSTOM_PASS"; else bad "Hive-sourced rx: config.json pass matches the non-exported CUSTOM_PASS" "$(cat "$CONF" 2>/dev/null)"; fi

# ---- the calling shell survives a DISPATCHER-level error too (bad algo), not just the success path - and the
#      config.json from the last successful call above is left completely untouched by the failure
before_err_conf=$(cat "$CONF")
hive_sourced "pool.example.com:9003" "W" "" "" "bogus-algo"
if [[ -n $survived && $rc != 0 ]]; then ok "Hive-sourced bad algo: caller survives the error (no exit escapes)"; else bad "Hive-sourced bad algo: caller survives the error (no exit escapes)" "$out"; fi
if [[ $pwd_after == "$T" ]]; then ok "Hive-sourced bad algo: caller cwd unchanged"; else bad "Hive-sourced bad algo: caller cwd unchanged" "pwd_after=$pwd_after out=$out"; fi
if [[ $(cat "$CONF") == "$before_err_conf" ]]; then ok "Hive-sourced bad algo: config.json from the prior good run left untouched"; else bad "Hive-sourced bad algo: config.json left untouched" "changed"; fi

# ---- and survives an ENGINE-level failure too (empty URL): the engine's own h-config.sh fail()/exit 1 runs
#      inside this dispatcher's subshell (see h-config.sh), which must not escape any further than that either
hive_sourced "" "W" "" "" "verus"
if [[ -n $survived && $rc != 0 ]]; then ok "Hive-sourced engine-level failure (empty URL): caller survives"; else bad "Hive-sourced engine-level failure (empty URL): caller survives" "$out"; fi
if [[ $pwd_after == "$T" ]]; then ok "Hive-sourced engine-level failure (empty URL): caller cwd unchanged"; else bad "Hive-sourced engine-level failure (empty URL): caller cwd unchanged" "pwd_after=$pwd_after out=$out"; fi

# ============================================================== 10. Round 5 (Codex test-gap review): h-run.sh
#    SOURCED, exactly as Hive's real supervisor loop does it (hive-ref/miner-run:189-211,247 - `( run_miner )`,
#    a SUBSHELL, calls miner_export_params (source h-manifest.conf + h-config.sh) then `source $MINER_DIR/
#    h-run.sh`, all inside that one subshell per miner-start iteration). Section 8 above only runs h-run.sh
#    EXECUTED (`bash h-run.sh`), which - since the engine binaries are absent in this fixture - never proves
#    more than "the terminal exec targets the right path before failing on ENOENT". This section uses REAL
#    executable engine stubs to prove: a successful sourced run really execs the stub (never a plain child
#    call), the stub's own exit status propagates all the way back through source+exec (exactly what miner-
#    run's own `exitcode=$?` right after `( run_miner )` depends on for its restart-count/backoff logic), AND -
#    the actual Round 4-shaped risk, just in h-run.sh instead of h-config.sh - that an early failure path
#    (missing manifest, engine_from_config unable to resolve) truly `return`s rather than `exit`s when sourced,
#    proven WITHOUT a protective subshell wrapper (a subshell would trivially shield the caller regardless of
#    which one h-run.sh actually uses).
setup_pkg
RUNLOG="$T/run.log"
stub_engine() {   # $1 = bloxminer|xmrig (the binary path h-run.sh execs into for verus/rx respectively) $2 = exit code
	cat > "$BLOX_DIR/$1" <<SH
#!/bin/sh
echo "STUB $BLOX_DIR/$1 \$* PID=\$\$" >> "$RUNLOG"
exit $2
SH
	chmod +x "$BLOX_DIR/$1"
}

# ---- success path, REAL Hive shape: h-run.sh sourced inside a subshell (`( ... )`, exactly like `( run_miner
#      )`) - the terminal `exec` replaces THAT subshell's own process image with the stub, so the stub's exit
#      status becomes the subshell's own $? - proving exec really happened (a forked/backgrounded call could
#      never make the parent's own `$?` reflect the child's status this way) and that it propagates end to end.
hconfig "p:1" "W" "" "" ""   # verus config
stub_engine bloxminer 0
: > "$RUNLOG"
( BLOX_DIR="$BLOX_DIR" BLOX_STATE_DIR="$T/state" bash -c '. "$BLOX_DIR/h-run.sh"' ); rc=$?
if [[ $rc == 0 ]] && grep -qF "STUB $BLOX_DIR/bloxminer" "$RUNLOG" 2>/dev/null; then
	ok "h-run.sh sourced (real Hive '( run_miner )' shape), verus: execs the stub, exit status (0) propagates"
else
	bad "h-run.sh sourced, verus: execs the stub, exit status propagates" "rc=$rc log=$(cat "$RUNLOG" 2>/dev/null)"
fi

hconfig "p:1" "W" "" "" "rx/0"   # rx config
stub_engine xmrig 0
: > "$RUNLOG"
( BLOX_DIR="$BLOX_DIR" BLOX_STATE_DIR="$T/state" bash -c '. "$BLOX_DIR/h-run.sh"' ); rc=$?
if [[ $rc == 0 ]] && grep -qF "STUB $BLOX_DIR/xmrig" "$RUNLOG" 2>/dev/null; then
	ok "h-run.sh sourced (real Hive shape), rx: execs the stub, exit status (0) propagates"
else
	bad "h-run.sh sourced, rx: execs the stub, exit status propagates" "rc=$rc log=$(cat "$RUNLOG" 2>/dev/null)"
fi

# ---- the stub's own NON-zero exit status also propagates all the way back through source+exec
stub_engine bloxminer 17
hconfig "p:1" "W" "" "" ""
: > "$RUNLOG"
( BLOX_DIR="$BLOX_DIR" BLOX_STATE_DIR="$T/state" bash -c '. "$BLOX_DIR/h-run.sh"' ); rc=$?
if [[ $rc == 17 ]]; then ok "h-run.sh sourced: the engine's own non-zero exit status (17) propagates all the way back"; else bad "h-run.sh sourced: engine exit status propagates" "rc=$rc"; fi

# ---- failure paths must `return`, not `exit`, when sourced - proven WITHOUT a subshell wrapper (see the
#      section header for why), exactly like section 9's hive_sourced() proves the same thing for h-config.sh.
run_h_run_survives() {   # $1 = test label -> asserts the caller prints its own marker AFTER sourcing, with a
	# non-zero rc (h-run.sh's own early failure), proving `return` (not `exit`) really ran
	out=$(BLOX_DIR="$BLOX_DIR" BLOX_STATE_DIR="$T/state" bash -c '
		. "$BLOX_DIR/h-run.sh"
		rc=$?
		printf "SURVIVED rc=%d\n" "$rc"
	' 2>&1)
	if grep -q '^SURVIVED rc=' <<< "$out" && [[ $(sed -n 's/^SURVIVED rc=//p' <<< "$out") != 0 ]]; then
		ok "h-run.sh sourced (no subshell), $1: returns (not exits) - caller survives, non-zero rc"
	else
		bad "h-run.sh sourced (no subshell), $1: returns (not exits) - caller survives" "$out"
	fi
}
mv "$BLOX_DIR/h-manifest.conf" "$T/h-manifest.conf.aside"
run_h_run_survives "missing h-manifest.conf"
mv "$T/h-manifest.conf.aside" "$BLOX_DIR/h-manifest.conf"

hconfig "p:1" "W" "" "" ""; rm -f "$CONF"
run_h_run_survives "engine_from_config cannot resolve (missing config.json)"

# ============================================================== 11. Round 5 (Codex test-gap review): h-stats.sh
#    SOURCED REPEATEDLY IN ONE CALLER SHELL (never a fresh bash -c per poll, which is exactly what section 7
#    above does and exactly why it could never have caught a variable/function leaking from one poll into the
#    next - a brand-new shell has no leftover state to leak in the first place). Hive's own agent sources this
#    file on the same long-lived interval, never restarting between polls - this reproduces that shape and
#    checks for retained variables/functions, port contamination, and stale khs/stats surviving an engine
#    switch, across a real rx (working API, non-zero khs) -> verus -> rx (different algo, API down) -> verus
#    sequence, entirely inside ONE bash process.
setup_pkg
S11_PROC="$T/proc11"; mkdir -p "$S11_PROC/net"
: > "$BLOX_DIR/xmrig"; chmod +x "$BLOX_DIR/xmrig"   # placeholder: only its resolved /proc/<pid>/exe path is compared
python3 - "$S11_PROC" "$BLOX_DIR/xmrig" <<'PY'
import os, sys
root, xmrig_path = sys.argv[1], sys.argv[2]
pid = "8801"
fddir = os.path.join(root, pid, "fd"); os.makedirs(fddir, exist_ok=True)
os.symlink("socket:[313131]", os.path.join(fddir, "5"))
os.symlink(xmrig_path, os.path.join(root, pid, "exe"))
with open(os.path.join(root, "net", "tcp"), "w") as f:
	f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n")
	f.write("   0: 0100007F:1105 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 313131 1 0000000000000000 100 0 0 10 0\n")
PY
S11_API_CFG="$T/s11_replies.json"
jq -n '{summary: {uptime:60, connection:{accepted:3,rejected:0}, algo:"rx/0", version:"6.26.0"},
        backends: [{type:"cpu", threads:[{affinity:0, hashrate:[500000.0,null,null]}]}]}' > "$S11_API_CFG"
python3 "$HERE/fake_xmrig_api.py" 4357 "$S11_API_CFG" > "$T/s11_api.out" 2>&1 & S11_API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/s11_api.out" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$T/s11_api.out" 2>/dev/null || bad "one shell, step B setup: fake API failed to start" "$(cat "$T/s11_api.out" 2>/dev/null)"
# "ready" (printed right after HTTPServer's own bind()+listen()) only confirms the LISTENING socket exists,
# never that the server's accept loop is actually spun up and answering - a curl that lands in that startup
# gap gets "Empty reply from server"/a connection reset, purely a fake-server race with NOTHING to do with
# h-stats.sh itself (test_rx_hive_scripts.sh's own stats_case() hit this exact race and added this exact
# round-trip confirmation loop for it - this section never had the same fix, on a slow/cold-start CI runner
# where Python's own interpreter/module-import startup can stretch that gap wide enough to matter). Confirm a
# REAL round-trip before step B (or any step) ever calls poll() against this port.
for _ in $(seq 20); do curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:4357/2/summary" && break; sleep 0.05; done

hconfig "p:1" "W" "" "" "rx/0"   # step A/B config: rx/0
MULTI="$T/multi_poll.sh"
cat > "$MULTI" <<'EOF'
set -u
poll() { . "$BLOX_DIR/h-stats.sh"; }

# ---- A: rx active, API DOWN (unreachable port) -> fallback: khs=0, stats.algo reflects CURRENT config (rx/0)
BLOX_API_PORT=1 poll
printf 'A khs=[%s] algo=%s PORT=[%s]\n' "$khs" "$(jq -r '.algo // "NONE"' <<< "$stats" 2>/dev/null)" "${PORT:-unset}"

# ---- B: rx active, API UP, ownership-verified -> REAL non-zero khs this time
BLOX_API_PORT=4357 poll
printf 'B khs=[%s] algo=%s PORT=[%s]\n' "$khs" "$(jq -r '.algo // "NONE"' <<< "$stats" 2>/dev/null)" "${PORT:-unset}"

# ---- C: switch to verus -> must be verus's OWN empty answer (khs=0, stats=""), NEVER step B's non-zero khs
#      or algo leaking through, and $PORT is never read by verus at all (only checked here for visibility)
printf '{"algo":"verus"}' > "$CUSTOM_CONFIG_FILENAME"
poll
printf 'C khs=[%s] stats=[%s] PORT=[%s]\n' "$khs" "$stats" "${PORT:-unset}"

# ---- D: back to rx, a DIFFERENT algo AND a different (still down) port than step A - proves neither the OLD
#      algo (rx/0) nor the OLD dead port (1) linger
printf '{"pools":[{"algo":"rx/arq"}],"randomx":{}}' > "$CUSTOM_CONFIG_FILENAME"
BLOX_API_PORT=2 poll
printf 'D khs=[%s] algo=%s PORT=[%s]\n' "$khs" "$(jq -r '.algo // "NONE"' <<< "$stats" 2>/dev/null)" "${PORT:-unset}"

# ---- E: verus again -> still verus's own empty answer, not step D's rx fallback object
printf '{"algo":"verus"}' > "$CUSTOM_CONFIG_FILENAME"
poll
printf 'E khs=[%s] stats=[%s]\n' "$khs" "$stats"
EOF
# BLOX_HSTATS_DEBUG_LOG (see engines/rx/h-stats.sh's own dbg()): opt-in trace of the ownership check's raw
# inputs, every curl's exit code + response body, and each phase's budget/decision - never touched by a real
# Hive rig (nothing here sets this var in production), only by this test's own diagnostics-on-failure below.
S11_DEBUG_LOG="$T/s11_debug.log"; : > "$S11_DEBUG_LOG"
res=$(BLOX_DIR="$BLOX_DIR" BLOX_STATE_DIR="$T/state" BLOX_PROCFS_ROOT="$S11_PROC" BLOX_HSTATS_DEBUG_LOG="$S11_DEBUG_LOG" bash "$MULTI" 2>&1)
kill "$S11_API_PID" 2>/dev/null; wait "$S11_API_PID" 2>/dev/null

lineA=$(grep '^A ' <<< "$res"); lineB=$(grep '^B ' <<< "$res"); lineC=$(grep '^C ' <<< "$res")
lineD=$(grep '^D ' <<< "$res"); lineE=$(grep '^E ' <<< "$res")
s11_fail=0
# On any failure below, the FULL rx debug trace from THIS EXACT run (ownership check inputs, every curl's exit
# code + response, per-phase budget/decision - see engines/rx/h-stats.sh's dbg() calls) plus the fake API's own
# stdout/stderr are dumped to stderr, once, after all 5 assertions - not per-assertion (this run only executes
# once; re-running it would not reproduce a timing-sensitive CI-only failure, only the ORIGINAL run's own trace
# can ever show what actually happened) and not on success (keeps a green CI log quiet).
s11_dump_diagnostics() {
	{
		echo "---- one shell, steps A-E: FULL raw output ----"; printf '%s\n' "$res"
		echo "---- fake_xmrig_api.py (port 4357) stdout/stderr ----"; cat "$T/s11_api.out" 2>/dev/null
		echo "---- rx h-stats.sh debug trace (BLOX_HSTATS_DEBUG_LOG) ----"
		if [[ -s $S11_DEBUG_LOG ]]; then cat "$S11_DEBUG_LOG"; else echo "(empty - dbg() never fired: BLOX_HSTATS_DEBUG_LOG itself did not reach the sourced h-stats.sh, or every dbg call site was skipped)"; fi
		echo "---- end diagnostics ----"
	} >&2
}
if [[ $lineA == "A khs=[0] algo=rx/0 PORT=[1]" ]]; then ok "one shell, step A (rx, API down): khs=0, algo=rx/0, PORT=1"; else bad "one shell, step A" "$lineA"; s11_fail=1; fi
if [[ $lineB == "B khs=[500.00] algo=rx/0 PORT=[4357]" ]]; then ok "one shell, step B (rx, API up): REAL khs=500.00, PORT updated to 4357"; else bad "one shell, step B (rx, API up): real khs, PORT=4357" "$lineB"; s11_fail=1; fi
if [[ $lineC == "C khs=[0] stats=[] PORT=[4357]" ]]; then
	ok "one shell, step C (-> verus): verus's OWN empty answer - step B's khs=500.00/algo NEVER leaked through"
else
	bad "one shell, step C (-> verus): no leftover from step B (khs=500.00, algo rx/0)" "$lineC"; s11_fail=1
fi
if [[ $lineD == "D khs=[0] algo=rx/arq PORT=[2]" ]]; then
	ok "one shell, step D (rx/arq, API down again): reflects the NEW algo/port, not step A's (rx/0, PORT=1) or step B's (PORT=4357)"
else
	bad "one shell, step D: reflects new algo/port only, no staleness" "$lineD"; s11_fail=1
fi
if [[ $lineE == "E khs=[0] stats=[]" ]]; then ok "one shell, step E (-> verus again): still verus's own empty answer, no leftover from step D"; else bad "one shell, step E: no leftover from step D" "$lineE"; s11_fail=1; fi
(( s11_fail )) && s11_dump_diagnostics

if [[ -n $S11_API_PID ]] && kill -0 "$S11_API_PID" 2>/dev/null; then
	bad "no leaked fake-API child process at suite end" "still alive: $S11_API_PID"
	kill -9 "$S11_API_PID" 2>/dev/null
else
	ok "no leaked fake-API child process at suite end"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
