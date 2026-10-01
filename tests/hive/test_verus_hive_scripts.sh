#!/usr/bin/env bash
# Tests for bloxminer/engines/verus/h-config.sh and h-stats.sh (adapted from BloxMiner 2.1.0's gated
# suite: harness paths + the shared top-level manifest/version + the new "ver" format only - all
# assertions kept). (Linux: needs jq, nc, timeout, python3).
# Usage: tests/hive/test_hive_scripts.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKG=$(cd "$HERE/../../bloxminer/engines/verus" && pwd)
MANIFEST_SRC=$(cd "$HERE/../../bloxminer" && pwd)/h-manifest.conf   # shared top-level manifest (3.0.0)
T=$(mktemp -d)
declare -a ALL_API_PIDS=()   # every fake-API pid THIS script ever started - killed exactly by pid, never by
	# pattern (127.0.0.1:20015 is permanently held by another, lead-owned process on shared build hosts)
cleanup_apis() { local p; for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && kill -9 "$p" 2>/dev/null; done; wait "${ALL_API_PIDS[@]:-}" 2>/dev/null || true; }
trap 'cleanup_apis; rm -rf "$T"' EXIT INT TERM
pass=0; fail=0; API_PID=
ok()  { pass=$((pass+1)); printf '%-52s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-52s FAIL: %s\n' "$1" "$2"; }

export BLOX_DIR=$T/pkg
mkdir -p "$BLOX_DIR"
cp "$PKG"/h-config.sh "$PKG"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer#" "$MANIFEST_SRC" > "$BLOX_DIR/h-manifest.conf"
CONF=$T/config.json
NPROC=$(nproc); (( NPROC > 128 )) && NPROC=128

# ------------------------------------------------------------------ h-config
hc() {  # url template pass extra -> runs h-config, sets $out $rc
	out=$(CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 bash "$BLOX_DIR/h-config.sh" 2>&1); rc=$?
}
jqc() { jq -r "$1" "$CONF"; }
check_cfg() {  # name, jq expression that must be true
	if [[ $rc == 0 ]] && [[ $(jq -r "$2" "$CONF" 2>/dev/null) == true ]]; then ok "$1"; else bad "$1" "rc=$rc out=$out cfg=$(cat "$CONF" 2>/dev/null)"; fi
}
check_out() {  # name, text the h-config output must contain
	if grep -qF -- "$2" <<< "$out"; then ok "$1"; else bad "$1" "out=$out"; fi
}
check_fail() {  # name, expected message
	if [[ $rc != 0 ]] && grep -qF -- "$2" <<< "$out"; then ok "$1"; else bad "$1" "rc=$rc out=$out"; fi
}

hc "pool.example.com:9999" "W.rig" "" ""
check_cfg "host:port gets stratum+tcp://, all CPUs" ".pools[0].url == \"stratum+tcp://pool.example.com:9999\" and .threads == $NPROC and .pass == \"x\""
check_cfg "fixed keys: algo, local API, log file" '.algo == "verus" and ."api-bind" == "127.0.0.1:4068" and ."api-allow" == "127.0.0.1" and (."log-file" | endswith("/log/bloxminer.log")) and ."ccd-temp-map" == "auto"'
hc $'stratum+tcp://a:1\nstratum+tcp://b:2' "W.rig" "" ""
check_cfg "only the first URL line" '.pools[0].url == "stratum+tcp://a:1"'
hc "" "W.rig" "" "";                    check_fail "empty URL rejected" "pool URL in the flight sheet is empty"
hc "p:1" "W.rig" "8" "";                check_cfg  "Pass 8 = 8 threads, pool pass x" '.threads == 8 and .pass == "x"'
hc "p:1" "W.rig" "08" "";               check_cfg  "Pass 08 = 8 (decimal, not octal)" '.threads == 8'
hc "p:1" "W.rig" "032" "";              check_cfg  "Pass 032 = 32" '.threads == 32'
hc "p:1" "W.rig" "128" "";              check_cfg  "Pass 128 accepted" '.threads == 128'
hc "p:1" "W.rig" "" "";                 check_cfg  "dashboard off by default" '."no-dashboard" == true and (has("dashboard") | not)'
hc "p:1" "W.rig" "" '"dashboard": true';  check_cfg "dashboard true: header on, key stripped" '(has("no-dashboard") | not) and (has("dashboard") | not)'
check_out "dashboard true: Miner log warning" 'Miner log'
hc "p:1" "W.rig" "" '"dashboard": false'; check_cfg "dashboard false = default" '."no-dashboard" == true and (has("dashboard") | not)'
hc "p:1" "W.rig" "" '"dashboard": "true"'; check_fail "dashboard \"true\" (string) rejected" '"dashboard" must be true or false (got "true")'
hc "p:1" "W.rig" "" '"dashboard": 1';     check_fail "dashboard 1 rejected" '"dashboard" must be true or false (got 1)'
hc "p:1" "W.rig" "" '"dashboard": null';  check_fail "dashboard null rejected" '"dashboard" must be true or false (got null)'
hc "p:1" "W.rig" "" '"no-dashboard": false'; check_cfg "raw no-dashboard false ignored (still off)" '."no-dashboard" == true'
check_out "raw no-dashboard: ignored message" 'ignored (set by BloxMiner): no-dashboard'
hc "p:1" "W.rig" "" '"no-dashboard": true, "dashboard": true'; check_cfg "dashboard true wins over raw no-dashboard" '(has("no-dashboard") | not)'
hc "p:1" "W.rig" "0" "";                check_fail "Pass 0 rejected" "must be 1-128"
hc "p:1" "W.rig" "129" "";              check_fail "Pass 129 rejected" "must be 1-128"
hc "p:1" "W.rig" "99999" "";            check_fail "Pass 99999 rejected" "must be 1-128"
hc "p:1" "W.rig" "s3cret" "";           check_cfg  "text Pass = pool password" ".pass == \"s3cret\" and .threads == $NPROC"
hc "p:1" "W.rig" "" '"threads": 12';    check_cfg  "Extra threads 12" '.threads == 12'
hc "p:1" "W.rig" "" '"threads": "16"';  check_cfg  "Extra threads \"16\"" '.threads == 16'
hc "p:1" "W.rig" "4" '"threads": 12';   check_cfg  "Extra threads wins over Pass" '.threads == 12'
hc "p:1" "W.rig" "" '"threads": 12.5';  check_fail "Extra threads 12.5 rejected" "must be 1-128"
hc "p:1" "W.rig" "" '"threads": 0';     check_fail "Extra threads 0 rejected" "must be 1-128"
hc "p:1" "W.rig" "" '"threads": false'; check_fail "Extra threads false rejected" "must be 1-128"
hc "p:1" "W.rig" "" '"threads": null';  check_fail "Extra threads null rejected" "must be 1-128"
hc "p:1" "W.rig" "" '"ccd-temp-map": 2'; check_fail "Extra ccd-temp-map 2 rejected" "must be \"auto\""
hc "p:1" "W.rig" "" '"ccd-temp-map": 1'; check_cfg "Extra ccd-temp-map 1 (number) normalised" '."ccd-temp-map" == "1"'
hc "p:1" "W.rig" "" '"pass": "1234"';   check_cfg  "numeric pool password via Extra" '.pass == "1234"'
hc "p:1" "W.rig" "" '"ccd-temp-map": "1"'; check_cfg "Extra ccd-temp-map overrides" '."ccd-temp-map" == "1"'
hc "p:1" "W.rig" "" '"algo": "x11", "api-bind": "0.0.0.0:4068", "api-allow": "0/0", "log-file": "/tmp/x"'
check_cfg "protected keys stay fixed" '.algo == "verus" and ."api-bind" == "127.0.0.1:4068" and ."api-allow" == "127.0.0.1" and (."log-file" | endswith("bloxminer.log"))'
if grep -qF "ignored" <<< "$out"; then ok "ignored keys are reported"; else bad "ignored keys are reported" "$out"; fi
# user text containing quotes and command substitutions must end up as literal JSON strings, never executed
evil_user="W.rig\"; touch $T/pwned1; \""
evil_extra="\"user2\": \"\$(touch $T/pwned2)\""
hc "p:1" "$evil_user" "" "$evil_extra"
if [[ ! -e $T/pwned1 && ! -e $T/pwned2 && $(jqc .user) == "$evil_user" && $(jqc .user2) == "\$(touch $T/pwned2)" ]]; then
	ok "quotes/command text stay literal JSON"
else
	bad "quotes/command text stay literal JSON" "$(cat "$CONF")"
fi
echo '{"old":true}' > "$CONF"
hc "p:1" "W.rig" "" 'not json at all'
if [[ $rc != 0 && $(cat "$CONF") == '{"old":true}' ]]; then ok "bad Extra config leaves old config intact"; else bad "bad Extra config leaves old config intact" "rc=$rc $(cat "$CONF")"; fi
if ls "$T"/config.json.tmp.* >/dev/null 2>&1; then bad "no temp file left behind" "$(ls "$T")"; else ok "no temp file left behind"; fi

# ------------------------------------------------------------------ h-stats (fake API)
PORT=$((20000 + RANDOM % 20000)); export BLOX_API_PORT=$PORT
echo '{"threads": 4}' > "$CONF"
SUM_OK='NAME=bloxminer;VER=2.1.0;API=1.9;ALGO=verus;GPUS=1;KHS=12000.00;SOLV=0;ACC=15;REJ=1;ACCMN=1.0;DIFF=1;NETKHS=0;POOLS=1;WAIT=0;UPTIME=321;TS=1;LASTWORK=5;STALL=0;FRESHKHS=11900.00;POWER=136;TEMP=64;CORES=2;ENGINE=ccminer-3.8.3|'
CORES_OK='GEN=9;AGE=1.2;ROWS=2;THREADS=4/4;PERCORE=1;STALL=0|ROW=0;PKG=0;CORE=0;CPUS=0,2;KHS=6000.00;TEMP=61;SRC=ccd|ROW=1;PKG=0;CORE=1;CPUS=1,3;KHS=5900.00;TEMP=;SRC=none|'

stats_case() {  # name summary cores jq-assertion
	kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
	PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT       # a fresh port per case: no rebind races
	jq -n --arg s "$2" --arg c "$3" '{summary: $s, cores: $c}' > "$T/replies.json"
	: > "$T/api.out"
	python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
	for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
	grep -q ready "$T/api.out" || { bad "$1" "fake API did not start: $(cat "$T/api.out")"; return; }
	local res; res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	if [[ $(jq -r "$4" <<< "$res" 2>/dev/null) == true ]]; then ok "$1"; else bad "$1" "$res"; fi
}

stats_case "complete per-core reply" "$SUM_OK" "$CORES_OK" \
	'.khs == "11900.00" and .stats.hs == [6000, 5900] and .stats.temp == [61, 64] and .stats.ar == [15, 1] and .stats.uptime == 321 and .stats.cpu_power == 136 and .stats.ver == "3.0.0 (verus, engine 2.1.0)" and .stats.algo == "verushash"'

# PR #2 follow-up review (Codex): "exec {fd}... 2>/dev/null" with no command after it is a bare redirection,
# applied to the CURRENT SHELL PERMANENTLY, not scoped to that one statement - see the RandomX engine's own
# test_rx_hive_scripts.sh for the full rationale (identical pattern, same review). The poll loop's own fd-open/
# close run unconditionally on every poll that reaches this code, so an unscoped version would have silently
# redirected THIS WHOLE SHELL's stderr to /dev/null from the very first poll onward - Hive sources h-stats.sh
# repeatedly in one long-lived shell. Proven directly: a message written to stderr, in the SAME shell,
# immediately after a normal poll, must still be visible afterward.
out=$(bash -c '. "$BLOX_DIR/h-stats.sh" > /dev/null; echo "STDERR_SURVIVES_AFTER_WAIT_FD" >&2' 2>&1)
if grep -q "STDERR_SURVIVES_AFTER_WAIT_FD" <<< "$out"; then
	ok "poll loop's own wait-fd open/close never silently redirects this shell's stderr afterward"
else
	bad "poll loop's own wait-fd open/close never silently redirects stderr afterward" "$out"
fi
stats_case "numbers are JSON numbers" "$SUM_OK" "$CORES_OK" \
	'(.stats.ar | map(type) | unique) == ["number"] and (.stats.uptime | type) == "number" and (.stats.hs | map(type) | unique) == ["number"]'
stats_case "stale cores reply -> FRESHKHS" "$SUM_OK" "${CORES_OK/AGE=1.2/AGE=9.5}" '.khs == "11900.00" and .stats.hs == [11900]'
stats_case "truncated reply -> FRESHKHS" "$SUM_OK" "${CORES_OK%ROW=1*}" '.stats.hs == [11900]'
stats_case "threads not all covered -> FRESHKHS" "$SUM_OK" "${CORES_OK/THREADS=4\/4/THREADS=3\/4}" '.stats.hs == [11900]'
stats_case "duplicate core rows -> FRESHKHS" "$SUM_OK" "${CORES_OK/PKG=0;CORE=1;/PKG=0;CORE=0;}" '.stats.hs == [11900]'
stats_case "no sample yet (GEN=0) -> FRESHKHS" "$SUM_OK" 'GEN=0;ROWS=0|' '.stats.hs == [11900]'
stats_case "stalled miner -> 0" "${SUM_OK/STALL=0/STALL=1}" "$CORES_OK" '.khs == "0" and .stats.hs == [0]'
stats_case "per-thread rows (PERCORE=0) accepted" "$SUM_OK" 'GEN=3;AGE=0.5;ROWS=4;THREADS=4/4;PERCORE=0;STALL=0|ROW=0;PKG=-1;CORE=-1;CPUS=-1;KHS=3000;TEMP=;SRC=pkg|ROW=1;PKG=-1;CORE=-1;CPUS=-1;KHS=3000;TEMP=;SRC=pkg|ROW=2;PKG=-1;CORE=-1;CPUS=-1;KHS=3000;TEMP=;SRC=pkg|ROW=3;PKG=-1;CORE=-1;CPUS=-1;KHS=2900;TEMP=;SRC=pkg|' \
	'.stats.hs == [3000, 3000, 3000, 2900] and .khs == "11900.00"'
stats_case "no power -> no cpu_power key" "${SUM_OK/POWER=136/POWER=}" "$CORES_OK" '(.stats | has("cpu_power")) == false'
stats_case "no temps at all -> null temps" "${SUM_OK/TEMP=64/TEMP=}" "${CORES_OK/TEMP=61/TEMP=}" '.stats.temp == [null, null]'
stats_case "non-numeric KHS in a row -> FRESHKHS" "$SUM_OK" "${CORES_OK/KHS=6000.00/KHS=abc}" '.stats.hs == [11900]'
stats_case "no API answer -> khs 0, empty stats" "" "" '.khs == "0" and .stats == null'
PT='GEN=3;AGE=0.5;ROWS=4;THREADS=4/4;PERCORE=0;STALL=0|'
R0='ROW=0;PKG=-1;CORE=-1;CPUS=-1;KHS=3000;TEMP=;SRC=pkg|'; R1='ROW=1;PKG=-1;CORE=-1;CPUS=-1;KHS=3000;TEMP=;SRC=pkg|'
R2='ROW=2;PKG=-1;CORE=-1;CPUS=-1;KHS=3000;TEMP=;SRC=pkg|'; R3='ROW=3;PKG=-1;CORE=-1;CPUS=-1;KHS=2900;TEMP=;SRC=pkg|'
stats_case "per-thread: duplicate ROW -> FRESHKHS" "$SUM_OK" "$PT$R0$R1$R1$R3" '.stats.hs == [11900]'
stats_case "per-thread: 3 rows for 4 threads -> FRESHKHS" "$SUM_OK" "${PT/ROWS=4/ROWS=3}$R0$R1$R2" '.stats.hs == [11900]'
stats_case "PERCORE=7 -> FRESHKHS" "$SUM_OK" "${CORES_OK/PERCORE=1/PERCORE=7}" '.stats.hs == [11900]'
stats_case "per-core CPUS cover 3 of 4 threads -> FRESHKHS" "$SUM_OK" "${CORES_OK/CPUS=1,3/CPUS=1}" '.stats.hs == [11900]'
stats_case "per-core duplicate CPU ids -> FRESHKHS" "$SUM_OK" "${CORES_OK/CPUS=0,2/CPUS=0,0}" '.stats.hs == [11900]'
stats_case "per-core bad PKG -> FRESHKHS" "$SUM_OK" "${CORES_OK/PKG=0;CORE=1;/PKG=x;CORE=1;}" '.stats.hs == [11900]'
stats_case "stall only in cores reply -> 0" "$SUM_OK" "${CORES_OK/STALL=0/STALL=1}" '.khs == "0" and .stats.hs == [0]'
CORES_ZERO="${CORES_OK/KHS=6000.00/KHS=0.00}"; CORES_ZERO="${CORES_ZERO/KHS=5900.00/KHS=0.00}"
stats_case "positive FRESHKHS + structurally-valid but all-zero (non-stalled) cores reply -> Phase A's WHOLE result kept" \
	"$SUM_OK" "$CORES_ZERO" '.khs == "11900.00" and .stats.hs == [11900]'
CORES_NEARZERO="${CORES_OK/KHS=6000.00/KHS=10.00}"; CORES_NEARZERO="${CORES_NEARZERO/KHS=5900.00/KHS=10.00}"
stats_case "positive FRESHKHS + complete-but-near-zero cores total (>10% off) -> Phase A's WHOLE result kept" \
	"$SUM_OK" "$CORES_NEARZERO" '.khs == "11900.00" and .stats.hs == [11900]'
stats_case "2.0.0 engine (no cores command) -> FRESHKHS" "${SUM_OK%%;POWER=*}|" "" '.stats.hs == [11900] and (.stats | has("cpu_power")) == false'
stats_case "engine VER matches package -> plain form" "${SUM_OK/VER=2.1.0/VER=3.0.0}" "$CORES_OK" '.stats.ver == "3.0.0 (verus)"'
stats_case "no VER field -> ENGINE_VERSION fallback == package -> plain form" "${SUM_OK/;VER=2.1.0/}" "$CORES_OK" '.stats.ver == "3.0.0 (verus)"'

# ---- one shell, two polls: a positive rate from poll 1 must NEVER survive as poll 2's answer just because
# poll 2's own attempt to get fresh data fails (dead API) - $khs/$stats are plain global variables, and Hive's
# real agent sources this file repeatedly in the SAME shell, poll after poll.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export API_PID
# shellcheck disable=SC2016
res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; poll1_khs=$khs
	kill "$API_PID" 2>/dev/null   # poll 2: API now dead - a genuine, real failure, not a contrived parse error
	. "$BLOX_DIR/h-stats.sh"
	jq -nc --arg p1 "$poll1_khs" --arg p2 "$khs" "{poll1: \$p1, poll2: \$p2}"' 2>&1)
if [[ $(jq -r '.poll1 == "11900.00" and .poll2 == "0"' <<< "$res" 2>/dev/null) == true ]]; then
	ok "one shell, two polls: poll 2's failure never leaves poll 1's positive rate standing"
else
	bad "one shell, two polls: poll 2's failure never leaves poll 1's positive rate standing" "$res"
fi

# ---- write_result's OWN guard (Codex, review of ec164c8): this used to be
# `printf '%s' "$(jq -nc ...)" > "$tmp" && mv -f "$tmp" "$OUTFILE"` - if jq's OWN command substitution failed
# (a fork/exec failure, independent of whatever the CALLER's own upstream composition did), `$(...)` comes
# back empty, `printf '%s' ""` still writes a trivially-successful zero-byte file, and `mv -f` then
# unconditionally replaced $OUTFILE - an already-good prior result - with that empty file. Tests THIS
# function directly (not through run()'s own upstream validation, which is a separate, shallower guard) via
# BLOX_HSTATS_TEST_FORCE_WRITE_RESULT_FAIL, deterministically the same way on every host: a real positive
# result is written first, then a forced-failing write_result call must leave that exact result standing.
D_DEBUG="$T/write_result_debug.log"; : > "$D_DEBUG"
res=$(BLOX_HSTATS_DEBUG_LOG="$D_DEBUG" bash -c '. "$BLOX_DIR/h-stats.sh"
	write_result "11900.00" "a prior positive result"
	before=$(cat "$OUTFILE" 2>/dev/null)
	BLOX_HSTATS_TEST_FORCE_WRITE_RESULT_FAIL=1 write_result "0" "should never reach OUTFILE"
	after=$(cat "$OUTFILE" 2>/dev/null)
	jq -nc --arg b "$before" --arg a "$after" "{before: \$b, after: \$a}"' 2>&1)
if [[ $(jq -r '.before == .after and (.after | contains("a prior positive result"))' <<< "$res" 2>/dev/null) == true ]] \
	&& grep -q "write_result: REFUSED" "$D_DEBUG"
then
	ok "write_result's own guard: a forced jq failure never overwrites an already-good prior result"
else
	bad "write_result's own guard: a forced jq failure never overwrites an already-good prior result" "res=$res debug=$(cat "$D_DEBUG" 2>/dev/null)"
fi

# ---- PR #2 follow-up review (Codex): "Reject an empty Phase A stats composition" - Phase A's own stats
# composition chains four nested jq calls into one outer jq call; if any one of them failed (a transient
# fork/exec failure under resource pressure - the same class this file's own write_result() guard above
# exists for), $stats came back empty while $khs already held a real, positive number - write_result would
# then wrap that empty $stats as a literal empty JSON string (`"stats":""`), passing write_result's own guard
# (which only checks the OUTER wrap succeeded, not $2's own content) and reaching $OUTFILE: the parent would
# report a positive khs with NO stats at all. Fixed: Phase A's composition is now validated the same way
# Phase B's own final composition already is (non-empty JSON object, hs array of numbers, temp array) before
# ever reaching write_result; on failure, an honest minimal object (khs from the fresh reading + a single
# minimal row) is written instead - never an empty stats. BLOX_HSTATS_TEST_FORCE_PHASEA_STATS_FAIL
# deterministically simulates the nested-jq failure, the same way BLOX_HSTATS_TEST_FORCE_WRITE_RESULT_FAIL
# already does for write_result() itself, above. No cores reply (empty $c, same convention as the "2.0.0
# engine (no cores command)" case above) - Phase B then skips outright (`[[ -z $cores ]] && return 0`), so
# Phase A's own result (the honest minimal fallback, with the fix) is what the parent actually sees, never
# masked by a legitimate Phase B reply overwriting it regardless of whether Phase A's own fix fired.
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
D_DEBUG2="$T/phasea_debug.log"; : > "$D_DEBUG2"
res=$(BLOX_HSTATS_DEBUG_LOG="$D_DEBUG2" BLOX_HSTATS_TEST_FORCE_PHASEA_STATS_FAIL=1 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
if [[ $(jq -r '.khs == "11900.00" and .stats.hs == [11900] and (.stats.temp | type) == "array"' <<< "$res" 2>/dev/null) == true ]] \
	&& grep -q "phase_a_stats_gate: composition invalid/empty" "$D_DEBUG2"
then
	ok "Phase A: forced nested-jq failure -> honest minimal stats object (khs stands, never empty stats)"
else
	bad "Phase A: forced nested-jq failure -> honest minimal stats object (khs stands, never empty stats)" "res=$res debug=$(cat "$D_DEBUG2" 2>/dev/null)"
fi

# ---- PR #2 follow-up review round 3 (Codex): "Normalize the fallback timestamp to microseconds" - now_us()
#      (and this file's own DEADLINE_US fallback, right at the top) used to concatenate the raw fractional
#      string straight onto the whole-seconds part: EPOCHREALTIME's own fraction is always exactly 6 digits
#      (real microseconds), but the `date +%s.%N` FALLBACK's is 9 (nanoseconds) - taken only on bash < 5, but
#      load-bearing if it ever is. Concatenated raw, every "microsecond" value this file computes off that
#      fallback was silently inflated by ~1000x, blowing the whole 2.4 s budget arithmetic by three orders of
#      magnitude. Forces the fallback path (EPOCHREALTIME explicitly unset in a fresh bash) and checks
#      now_us()'s own $REPLY lands within a generous few seconds of a known-good reference (date +%s, scaled
#      to real microseconds) - the pre-fix concatenation would be off by roughly 1000x, nowhere near this
#      tolerance. See the RandomX engine's own test suite for the identical assertion on its copy of now_us().
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
# shellcheck disable=SC2016  # single quotes on purpose: expanded by the inner bash, not here
now_us_fallback=$(BLOX_API_PORT=19999 timeout 5 bash -c '
	unset EPOCHREALTIME
	. "$BLOX_DIR/h-stats.sh" > /dev/null 2>&1
	now_us
	echo "$REPLY"
' 2>/dev/null)
ref_us=$(( $(date +%s) * 1000000 ))
if [[ $now_us_fallback =~ ^[0-9]+$ ]] && (( now_us_fallback > ref_us - 10000000 && now_us_fallback < ref_us + 10000000 )); then
	ok "now_us() fallback path (EPOCHREALTIME unset, date +%s.%N): normalized to real microseconds, not nanosecond-inflated"
else
	bad "now_us() fallback path: normalized to real microseconds" "now_us=$now_us_fallback ref_us=$ref_us"
fi

# SIGTERM everything tracked, wait for each (a no-op if already reaped), THEN check for survivors - a real
# leak is one that outlives its own SIGTERM, not one merely still alive before anything has tried to stop it.
for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null; done
for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && wait "$p" 2>/dev/null; done
leaked=()
for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && kill -0 "$p" 2>/dev/null && leaked+=("$p"); done
if [[ ${#leaked[@]} -eq 0 ]]; then
	ok "no leaked fake-API child processes at suite end"
else
	bad "no leaked fake-API child processes at suite end" "still alive: ${leaked[*]}"
	cleanup_apis
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
