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
	out=$(CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 CUSTOM_ALGO=$5 \
		bash "$BLOX_DIR/h-config.sh" 2>&1); rc=$?
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

# ============================================================== 4. engine derivation: config.json is the SOLE
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

# ============================================================== 5. huge-page ownership handoff: ONLY the
#    reservation this package itself made is ever touched - never a blind host-wide reset.
setup_pkg
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
echo "sysctl $*" >> "$SYSCTL_LOG"
exit 0
SH
chmod +x "$FAKEBIN/sysctl"
SYSCTL_LOG="$T/sysctl.log"; export SYSCTL_LOG
PROCROOT="$T/proc"; mkdir -p "$PROCROOT/sys/vm"
run_h_run() { PATH="$FAKEBIN:$PATH" BLOX_PROCFS_ROOT="$PROCROOT" timeout 2 bash "$BLOX_DIR/h-run.sh" > /dev/null 2>&1; }   # engine binary absent -> exec fails after the hugepage step, harmless here

# ---- fresh verus start, a foreign reservation already on the box (512), no ownership record -> untouched
echo 512 > "$PROCROOT/sys/vm/nr_hugepages"
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if [[ ! -s $SYSCTL_LOG && ! -e $HUGEFILE ]]; then
	ok "fresh verus start, foreign reservation (512), no record -> untouched, no sysctl call"
else
	bad "fresh verus start, foreign reservation (512), no record -> untouched, no sysctl call" "sysctl_log=$(cat "$SYSCTL_LOG" 2>/dev/null) hugefile=$([[ -e $HUGEFILE ]] && cat "$HUGEFILE")"
fi
if [[ $(cat "$PROCROOT/sys/vm/nr_hugepages") == 512 ]]; then ok "fresh verus start: host's own nr_hugepages value (512) left as-is"; else bad "fresh verus start: host's own nr_hugepages value (512) left as-is" "$(cat "$PROCROOT/sys/vm/nr_hugepages")"; fi

# ---- rx start (from the 512 baseline) -> records 512 as the prior value, makes no sysctl call itself
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run
if [[ $(cat "$HUGEFILE" 2>/dev/null) == 512 ]]; then ok "rx start: records the pre-rx nr_hugepages (512) as the prior value"; else bad "rx start: records the pre-rx nr_hugepages (512) as the prior value" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
if [[ ! -s $SYSCTL_LOG ]]; then ok "rx start: no sysctl call (only records; never raises/lowers anything itself)"; else bad "rx start: no sysctl call" "$(cat "$SYSCTL_LOG")"; fi
echo 1200 > "$PROCROOT/sys/vm/nr_hugepages"   # simulate Hive's own `hugepages -rx` having raised it (engines/rx/h-run.sh's own concern, untouched by this package)

# ---- rx "restarted" (still rx, e.g. a flight-sheet edit that keeps the algo) -> must NOT overwrite the record
hconfig "p:1" "W" "" "" "rx/wow"; : > "$SYSCTL_LOG"; run_h_run
if [[ $(cat "$HUGEFILE" 2>/dev/null) == 512 ]]; then ok "rx restarted: existing record (512) NOT overwritten by rx's own raised value"; else bad "rx restarted: existing record (512) NOT overwritten by rx's own raised value" "$(cat "$HUGEFILE" 2>/dev/null)"; fi
echo 1200 > "$PROCROOT/sys/vm/nr_hugepages"   # (still simulating rx's own reservation being active)

# ---- verus after two rx starts -> restored to the ORIGINAL prior (512), record removed
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if grep -q "nr_hugepages=512" "$SYSCTL_LOG" 2>/dev/null; then ok "verus after rx (restarted twice): restored to the ORIGINAL prior value (512)"; else bad "verus after rx (restarted twice): restored to the ORIGINAL prior value (512)" "$(cat "$SYSCTL_LOG" 2>/dev/null)"; fi
if [[ ! -e $HUGEFILE ]]; then ok "verus after rx: ownership record removed"; else bad "verus after rx: ownership record removed" "still present: $(cat "$HUGEFILE")"; fi

# ---- verus again, no record (already consumed above) -> no sysctl call at all
: > "$SYSCTL_LOG"; run_h_run
if [[ ! -s $SYSCTL_LOG ]]; then ok "verus with no record -> no sysctl call"; else bad "verus with no record -> no sysctl call" "$(cat "$SYSCTL_LOG")"; fi

# ---- rx from a 0 baseline -> verus restores to 0 (not just non-zero values are handled correctly)
echo 0 > "$PROCROOT/sys/vm/nr_hugepages"; rm -f "$HUGEFILE"
hconfig "p:1" "W" "" "" "rx/0"; : > "$SYSCTL_LOG"; run_h_run
echo 1200 > "$PROCROOT/sys/vm/nr_hugepages"
hconfig "p:1" "W" "" "" ""; : > "$SYSCTL_LOG"; run_h_run
if grep -q "nr_hugepages=0" "$SYSCTL_LOG" 2>/dev/null; then ok "verus after rx (0 baseline): restored to 0"; else bad "verus after rx (0 baseline): restored to 0" "$(cat "$SYSCTL_LOG" 2>/dev/null)"; fi

# ============================================================== 6. stats never from the previous engine
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

# ============================================================== 7. h-run execs the right engine binary path
setup_pkg
hconfig "p:1" "W" "" "" ""
run_out=$(timeout 2 bash "$BLOX_DIR/h-run.sh" 2>&1)
if grep -qF "$BLOX_DIR/bloxminer: No such file" <<< "$run_out"; then ok "h-run on verus execs ./bloxminer"; else bad "h-run on verus execs ./bloxminer" "$run_out"; fi
hconfig "p:1" "W" "" "" "rx/0"
run_out=$(timeout 2 bash "$BLOX_DIR/h-run.sh" 2>&1)
if grep -qF "$BLOX_DIR/xmrig: No such file" <<< "$run_out"; then ok "h-run on rx execs ./xmrig"; else bad "h-run on rx execs ./xmrig" "$run_out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
