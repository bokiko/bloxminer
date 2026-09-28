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
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
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
run_h_stats_fail_closed() {   # $1 = test label; must NEVER crash the sourcing agent: khs=0, stats="", clean return
	res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; echo "rc=$? khs=[$khs] stats=[$stats]"' 2>&1); rc=$?
	if [[ $rc == 0 && $res == "rc=0 khs=[0] stats=[]" ]]; then
		ok "h-stats.sh: $1 -> returns cleanly (khs=0, empty stats, never crashes)"
	else
		bad "h-stats.sh: $1 -> returns cleanly (khs=0, empty stats, never crashes)" "rc=$rc res=$res"
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
if [[ $rc == 0 && $res == "rc=0 khs=[0] stats=[]" ]]; then
	ok "h-stats.sh: jq unavailable -> returns cleanly (khs=0, empty stats, never crashes)"
else
	bad "h-stats.sh: jq unavailable -> returns cleanly (khs=0, empty stats, never crashes)" "rc=$rc res=$res"
fi

# ============================================================== 6. huge-page ownership handoff: ONLY the
#    reservation this package itself made is ever touched - never a blind host-wide reset, and never restored
#    over the top of a change something else made since. The record holds "prior" (what to restore) AND
#    "ours" (the value this package itself last set, captured by calling the same idempotent `hugepages -rx`
#    Hive tool the rx engine's own h-run.sh calls - see h-common.sh's top-of-section comment for why) - a
#    Verus start only ever restores when the CURRENT value still equals "ours"; otherwise it is left alone, a
#    conflict is logged, and the record is KEPT (never silently dropped) for a later attempt. A failed restore
#    write also keeps the record - it is consumed ONLY on a verified, successful restore.
setup_pkg
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
PROCROOT="$T/proc"; mkdir -p "$PROCROOT/sys/vm"
PROCFILE="$PROCROOT/sys/vm/nr_hugepages"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
echo "sysctl $*" >> "$SYSCTL_LOG"
[ "${SYSCTL_FAIL:-0}" = "1" ] && exit 1
exit 0
SH
chmod +x "$FAKEBIN/sysctl"
cat > "$FAKEBIN/hugepages" <<'SH'
#!/bin/sh
echo "hugepages $*" >> "$SYSCTL_LOG"
[ "$1" = "-rx" ] && echo "${HUGEPAGES_TARGET:-1200}" > "$PROCFILE"
exit 0
SH
chmod +x "$FAKEBIN/hugepages"
SYSCTL_LOG="$T/sysctl.log"; export SYSCTL_LOG PROCFILE
sysctl_called() { grep -q '^sysctl ' "$SYSCTL_LOG" 2>/dev/null; }
hugepages_called() { grep -q '^hugepages ' "$SYSCTL_LOG" 2>/dev/null; }
run_h_run() { PATH="$FAKEBIN:$PATH" BLOX_PROCFS_ROOT="$PROCROOT" HUGEPAGES_TARGET="${HUGEPAGES_TARGET:-1200}" SYSCTL_FAIL="${SYSCTL_FAIL:-0}" timeout 2 bash "$BLOX_DIR/h-run.sh" > /dev/null 2>&1; }   # engine binary absent -> exec fails after the hugepage step, harmless here

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
#      records prior=512 (what was there before) and ours=1200 (what it just set, via the fake tool)
HUGEPAGES_TARGET=1200
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run
if [[ $(sed -n 's/^prior=//p' "$HUGEFILE" 2>/dev/null) == 512 && $(sed -n 's/^ours=//p' "$HUGEFILE" 2>/dev/null) == 1200 ]]; then
	ok "rx start: records prior=512 (pre-rx) and ours=1200 (post-rx, via hugepages -rx)"
else
	bad "rx start: records prior=512 (pre-rx) and ours=1200 (post-rx, via hugepages -rx)" "$(cat "$HUGEFILE" 2>/dev/null)"
fi
# a FRESH rx start calls `hugepages -rx` TWICE: once from note_rx_hugepages_start itself (to observe "ours"),
# once more from engines/rx/h-run.sh's own unchanged, unconditional call right after exec - both hit the same
# fake tool here, so counting (not just presence) is what actually distinguishes a fresh start from a restart
# below. Never sysctl directly (that only ever happens on a Verus start).
if [[ $(grep -c '^hugepages -rx$' "$SYSCTL_LOG" 2>/dev/null) == 2 ]] && ! sysctl_called; then ok "rx start: calls hugepages -rx TWICE (this dispatcher's own + the rx engine's own), never sysctl directly"; else bad "rx start: calls hugepages -rx TWICE, never sysctl directly" "$(cat "$SYSCTL_LOG")"; fi
if [[ $(cat "$PROCFILE") == 1200 ]]; then ok "rx start: nr_hugepages actually raised to 1200 by this dispatcher's own call"; else bad "rx start: nr_hugepages actually raised to 1200" "$(cat "$PROCFILE")"; fi

# ---- rx "restarted" (still rx, e.g. a flight-sheet edit that keeps the algo) -> record already exists, so
#      note_rx_hugepages_start returns immediately without calling hugepages itself: only ONE call this time
#      (the rx engine's own unconditional one), not two, and no overwrite of the existing record
hconfig "p:1" "W" "" "" "rx/wow"; : > "$SYSCTL_LOG"; run_h_run
if [[ $(sed -n 's/^prior=//p' "$HUGEFILE" 2>/dev/null) == 512 && $(sed -n 's/^ours=//p' "$HUGEFILE" 2>/dev/null) == 1200 ]]; then ok "rx restarted: existing record (prior=512/ours=1200) NOT overwritten"; else bad "rx restarted: existing record NOT overwritten" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
if [[ $(grep -c '^hugepages -rx$' "$SYSCTL_LOG" 2>/dev/null) == 1 ]]; then ok "rx restarted: hugepages -rx called only ONCE (the engine's own; this dispatcher's own call is skipped)"; else bad "rx restarted: hugepages -rx called only ONCE" "$(cat "$SYSCTL_LOG")"; fi

# ---- verus after two rx starts, nr_hugepages still == ours (1200, nothing else touched it) -> restored to
#      the ORIGINAL prior (512), record removed
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if grep -q "nr_hugepages=512" "$SYSCTL_LOG" 2>/dev/null; then ok "verus after rx (restarted twice): restored to the ORIGINAL prior value (512)"; else bad "verus after rx (restarted twice): restored to the ORIGINAL prior value (512)" "$(cat "$SYSCTL_LOG" 2>/dev/null)"; fi
if [[ ! -e $HUGEFILE ]]; then ok "verus after rx: ownership record removed (restore verified successful)"; else bad "verus after rx: ownership record removed" "still present: $(cat "$HUGEFILE")"; fi

# ---- verus again, no record (already consumed above) -> no sysctl call at all
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called; then ok "verus with no record -> no sysctl call"; else bad "verus with no record -> no sysctl call" "$(cat "$SYSCTL_LOG")"; fi

# ---- rx from a 0 baseline -> verus restores to 0 (not just non-zero values are handled correctly)
echo 0 > "$PROCFILE"; rm -f "$HUGEFILE"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if grep -q "nr_hugepages=0" "$SYSCTL_LOG" 2>/dev/null; then ok "verus after rx (0 baseline): restored to 0"; else bad "verus after rx (0 baseline): restored to 0" "$(cat "$SYSCTL_LOG" 2>/dev/null)"; fi

# ---- NEW: something else changes nr_hugepages AFTER this package's own rx reservation (foreign write, e.g.
#      another workload or an operator) -> the next Verus start must NEVER overwrite it: left untouched, the
#      conflict is logged (own log file, not a Hive toast - this is not fatal), and the record is KEPT (not
#      dropped) so a later attempt still has "prior" on file.
echo 0 > "$PROCFILE"; rm -f "$HUGEFILE"; rm -f "$T/log/bloxminer.log"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run   # prior=0, ours=1200
echo 777 > "$PROCFILE"   # a THIRD party changes it - no longer "ours" (1200)
recorded_before=$(cat "$HUGEFILE")
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ $(cat "$PROCFILE") == 777 ]]; then ok "foreign change after rx start (1200 -> 777): Verus start never overwrites it"; else bad "foreign change after rx start: Verus start never overwrites it" "sysctl_log=$(cat "$SYSCTL_LOG") proc=$(cat "$PROCFILE")"; fi
if [[ -e $HUGEFILE && $(cat "$HUGEFILE") == "$recorded_before" ]]; then ok "foreign change: ownership record KEPT unchanged (prior=0/ours=1200), not dropped"; else bad "foreign change: ownership record KEPT unchanged" "$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo MISSING)"; fi
if [[ -f $T/log/bloxminer.log ]] && grep -q "changed outside this package" "$T/log/bloxminer.log"; then ok "foreign change: conflict logged to this package's own log"; else bad "foreign change: conflict logged" "$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

# ---- NEW: nr_hugepages still == ours (no conflict), but the sysctl WRITE itself fails (e.g. permission
#      denied) -> the record must be RETAINED, never dropped on a failed attempt
echo 0 > "$PROCFILE"; rm -f "$HUGEFILE"; rm -f "$T/log/bloxminer.log"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run   # prior=0, ours=1200 (nr_hugepages is 1200 now)
recorded_before2=$(cat "$HUGEFILE")
SYSCTL_FAIL=1
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
SYSCTL_FAIL=0
if sysctl_called; then ok "failed sysctl write: a restore WAS attempted (nr_hugepages still matched ours)"; else bad "failed sysctl write: a restore WAS attempted" "$(cat "$SYSCTL_LOG")"; fi
if [[ -e $HUGEFILE && $(cat "$HUGEFILE") == "$recorded_before2" ]]; then ok "failed sysctl write: ownership record RETAINED, not dropped"; else bad "failed sysctl write: ownership record RETAINED" "$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo MISSING)"; fi

# ---- NEW (Round 3): ANY single missing/corrupt piece of the record, or an unreadable CURRENT value, must
#      NEVER fall through to a restore attempt - the restore fires only when prior, ours, AND the live current
#      value are all valid numbers AND current == ours. Every other case here: no sysctl call, the record is
#      RETAINED (never dropped - a permanently corrupt record just stays on tmpfs until a reboot clears it),
#      and a log line explains why.
hconfig "p:1" "W" "" "" ""   # a valid verus config throughout this block - only the hugepage record is corrupted
rm -f "$HUGEFILE" "$T/log/bloxminer.log"; printf 'prior=512\n' > "$HUGEFILE"; echo 512 > "$PROCFILE"   # ours= missing entirely
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "invalid or corrupt" "$T/log/bloxminer.log" 2>/dev/null; then ok "missing ours -> no sysctl call, record retained, logged"; else bad "missing ours -> no sysctl call, record retained, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo GONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

rm -f "$HUGEFILE" "$T/log/bloxminer.log"; printf 'prior=512\nours=banana\n' > "$HUGEFILE"; echo 512 > "$PROCFILE"   # ours= non-numeric
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "invalid or corrupt" "$T/log/bloxminer.log" 2>/dev/null; then ok "corrupt ours (non-numeric) -> no sysctl call, record retained, logged"; else bad "corrupt ours (non-numeric) -> no sysctl call, record retained, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo GONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

rm -f "$HUGEFILE" "$T/log/bloxminer.log"; printf 'prior=banana\nours=512\n' > "$HUGEFILE"; echo 512 > "$PROCFILE"   # prior= non-numeric
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "invalid or corrupt" "$T/log/bloxminer.log" 2>/dev/null; then ok "corrupt prior -> no sysctl call, record retained, logged"; else bad "corrupt prior -> no sysctl call, record retained, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo GONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi

rm -f "$HUGEFILE" "$T/log/bloxminer.log"; printf 'prior=512\nours=1200\n' > "$HUGEFILE"; rm -f "$PROCFILE"   # current value unreadable
: > "$SYSCTL_LOG"; run_h_run
if ! sysctl_called && [[ -e $HUGEFILE ]] && grep -q "could not read the current" "$T/log/bloxminer.log" 2>/dev/null; then ok "unreadable current value -> no sysctl call, record retained, logged"; else bad "unreadable current value -> no sysctl call, record retained, logged" "sysctl=$(cat "$SYSCTL_LOG") record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo GONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi
echo 512 > "$PROCFILE"

# note_rx_hugepages_start itself must never WRITE a record with an invalid "ours": simulate a `hugepages -rx`
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
if [[ ! -e $HUGEFILE ]] && grep -q "no ownership record written" "$T/log/bloxminer.log" 2>/dev/null; then ok "note_rx_hugepages_start: unreadable post-reservation value -> no record written, logged"; else bad "note_rx_hugepages_start: unreadable post-reservation value -> no record written, logged" "record=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE" || echo NONE) log=$(cat "$T/log/bloxminer.log" 2>/dev/null)"; fi
cat > "$FAKEBIN/hugepages" <<'SH'
#!/bin/sh
echo "hugepages $*" >> "$SYSCTL_LOG"
[ "$1" = "-rx" ] && echo "${HUGEPAGES_TARGET:-1200}" > "$PROCFILE"
exit 0
SH
chmod +x "$FAKEBIN/hugepages"

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

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
