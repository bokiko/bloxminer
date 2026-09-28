#!/usr/bin/env bash
# Tests for the top-level dispatcher (bloxminer/h-config.sh, h-run.sh, h-stats.sh, h-common.sh): engine
# selection from the flight-sheet algo (every mapping, including empty/unknown/mixed-case), the engine state
# file (atomicity, and its missing/stale fallback), the rx->verus hugepage release on switch, that an unknown
# algo fails cleanly without ever touching config.json or the state file (no restart storm), and that h-stats
# never reports the previous engine's data after a switch.
# Usage: tests/hive/test_dispatcher.sh (Linux: needs jq, bash)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-68s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-68s FAIL: %s\n' "$1" "$2"; }

# a stub 'message' so the dispatcher's fail() never hits the real (absent) Hive binary
message() { :; }
export -f message

setup_pkg() {
	rm -rf "$T/pkg" "$T/state" "$T/log"; mkdir -p "$T/pkg" "$T/state" "$T/log"
	cp -r "$PKGSRC"/* "$T/pkg/"
	chmod +x "$T/pkg"/*.sh "$T/pkg"/engines/*/*.sh
	sed -i.bak \
		-e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
		-e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer#" \
		"$T/pkg/h-manifest.conf"; rm -f "$T/pkg/h-manifest.conf.bak"
	export BLOX_DIR=$T/pkg BLOX_STATE_DIR=$T/state
}
CONF=$T/config.json
STATEFILE=$T/state/.bloxminer-engine

hconfig() {   # url template pass extra algo -> runs the dispatcher h-config.sh, sets $out $rc
	out=$(CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 CUSTOM_ALGO=$5 \
		bash "$BLOX_DIR/h-config.sh" 2>&1); rc=$?
}
state() { cat "$STATEFILE" 2>/dev/null; }

# ============================================================== 1. engine selection: every algo mapping
setup_pkg
declare -A CASES=(
	[verus]=verus [VERUS]=verus [verushash]=verus [VerusHash]=verus
	[randomx]=rx [RANDOMX]=rx [RandomX]=rx ["rx/0"]=rx ["rx/wow"]=rx ["rx/arq"]=rx ["rx/graft"]=rx ["rx/sfx"]=rx ["rx/yada"]=rx
	["RX/WOW"]=rx
)
hconfig "pool.example.com:1" "W.rig" "" "" ""   # empty algo, tested separately: bash assoc arrays reject a
if [[ $rc == 0 && $(state) == verus ]]; then ok "algo '' (empty) -> engine verus"; else bad "algo '' (empty) -> engine verus" "rc=$rc state=$(state) out=$out"; fi
for algo in "${!CASES[@]}"; do
	hconfig "pool.example.com:1" "W.rig" "" "" "$algo"
	want=${CASES[$algo]}
	if [[ $rc == 0 && $(state) == "$want" ]]; then
		ok "algo '$algo' -> engine $want"
	else
		bad "algo '$algo' -> engine $want" "rc=$rc state=$(state) out=$out"
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
hconfig "p:1" "W" "" "" ""; before_state=$(state)   # establish a known-good baseline (verus) first
for algo in sha256 x11 "rx/9" "verushash2" "  "; do
	hconfig "p:1" "W" "4" "" "$algo"
	ok1=$([[ $rc != 0 ]] && echo y)
	ok2=$([[ -z ${out##*Algorithm must be*} ]] && echo y)
	if [[ -n $ok1 && -n $ok2 ]]; then ok "unknown algo '$algo' -> Hive error, exit 1"; else bad "unknown algo '$algo' -> Hive error, exit 1" "rc=$rc out=$out"; fi
done
# repeat 5x: every attempt fails the same clean way (no crash loop, no hang, no state/config drift) - the
# "no restart storm" gate: bounded, deterministic, always the same result, never escalating.
n=0; for _ in 1 2 3 4 5; do hconfig "p:1" "W" "" "" "bogus"; [[ $rc == 1 ]] && n=$((n+1)); done
if [[ $n == 5 && $(state) == "$before_state" ]]; then ok "unknown algo: 5x repeated calls all fail the same way, state untouched"; else bad "unknown algo: 5x repeated calls all fail the same way, state untouched" "n=$n state=$(state) before=$before_state"; fi

# ============================================================== 3. state file atomicity: only committed AFTER
#    the engine's own h-config.sh succeeds; a failing engine call leaves BOTH config.json and the state file
#    exactly as they were
setup_pkg
hconfig "pool.example.com:1" "W.rig" "4" "" ""   # verus, succeeds
good_conf=$(cat "$CONF"); good_state=$(state)
hconfig "" "W.rig" "4" "" ""                     # empty URL: the verus engine's own h-config.sh fails
if [[ $rc != 0 && $(cat "$CONF") == "$good_conf" && $(state) == "$good_state" ]]; then
	ok "engine h-config failure leaves config.json and state file untouched"
else
	bad "engine h-config failure leaves config.json and state file untouched" "rc=$rc conf_changed=$([[ $(cat "$CONF") != "$good_conf" ]] && echo yes) state=$(state)"
fi
# same for a failing rx call (invalid extra config breaks jq parsing) after a good rx run
hconfig "pool.example.com:1" "W.rig" "" "" "rx/0"
good_conf2=$(cat "$CONF"); good_state2=$(state)
hconfig "pool.example.com:1" "W.rig" "" 'not json' "rx/0"
if [[ $rc != 0 && $(cat "$CONF") == "$good_conf2" && $(state) == "$good_state2" ]]; then
	ok "rx engine h-config failure leaves config.json and state file untouched"
else
	bad "rx engine h-config failure leaves config.json and state file untouched" "rc=$rc state=$(state)"
fi

# ============================================================== 4. state file missing/stale -> inferred from
#    config.json content, defaulting to verus
setup_pkg
infer() { bash -c '. "$BLOX_DIR/h-manifest.conf"; . "$BLOX_DIR/h-common.sh"; read_engine_state'; }

hconfig "p:1" "W" "" "" "rx/0"   # config.json is now an rx config
rm -f "$STATEFILE"
inferred=$(infer)
if [[ $inferred == rx ]]; then ok "state file missing, rx config -> inferred rx"; else bad "state file missing, rx config -> inferred rx" "$inferred"; fi

hconfig "p:1" "W" "" "" ""       # config.json is now a verus config
rm -f "$STATEFILE"
inferred=$(infer)
if [[ $inferred == verus ]]; then ok "state file missing, verus config -> inferred verus"; else bad "state file missing, verus config -> inferred verus" "$inferred"; fi

echo garbage > "$STATEFILE"
inferred=$(infer)
if [[ $inferred == verus ]]; then ok "state file has garbage -> inferred from config.json (verus)"; else bad "state file has garbage -> inferred from config.json (verus)" "$inferred"; fi

rm -f "$CONF" "$STATEFILE"
inferred=$(infer)
if [[ $inferred == verus ]]; then ok "state file AND config.json both missing -> defaults verus"; else bad "state file AND config.json both missing -> defaults verus" "$inferred"; fi

# ============================================================== 5. hugepage release on switch to verus
setup_pkg
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
echo "sysctl $*" >> "$SYSCTL_LOG"
exit 0
SH
chmod +x "$FAKEBIN/sysctl"
SYSCTL_LOG="$T/sysctl.log"; export SYSCTL_LOG
hconfig "p:1" "W" "" "" "rx/0"   # engine = rx first
: > "$SYSCTL_LOG"
PATH="$FAKEBIN:$PATH" timeout 2 bash "$BLOX_DIR/h-run.sh" > /dev/null 2>&1   # ./xmrig is absent -> exec fails after the hugepage step, harmless here
if ! grep -q "nr_hugepages" "$SYSCTL_LOG" 2>/dev/null; then ok "h-run on rx: hugepages NOT released"; else bad "h-run on rx: hugepages NOT released" "$(cat "$SYSCTL_LOG")"; fi

hconfig "p:1" "W" "" "" ""       # switch to verus
: > "$SYSCTL_LOG"
PATH="$FAKEBIN:$PATH" timeout 2 bash "$BLOX_DIR/h-run.sh" > /dev/null 2>&1   # ./bloxminer is absent -> exec fails after the hugepage step
if grep -q "nr_hugepages=0" "$SYSCTL_LOG" 2>/dev/null; then ok "h-run on verus: hugepages released via sysctl vm.nr_hugepages=0"; else bad "h-run on verus: hugepages released via sysctl vm.nr_hugepages=0" "$(cat "$SYSCTL_LOG" 2>/dev/null)"; fi

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
