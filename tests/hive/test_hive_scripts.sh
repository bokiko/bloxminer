#!/usr/bin/env bash
# Tests for bloxminer/h-config.sh and bloxminer/h-stats.sh (Linux: needs jq, nc, timeout, python3).
# Usage: tests/hive/test_hive_scripts.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKG=$(cd "$HERE/../../bloxminer" && pwd)
T=$(mktemp -d)
declare -a ALL_API_PIDS=()   # every fake-API pid THIS script ever started - killed exactly by pid, never by
	# pattern (a fixed port could be held by another, unrelated process on a shared build host)
cleanup_apis() { local p; for p in "${ALL_API_PIDS[@]:-}"; do [[ -n $p ]] && kill -9 "$p" 2>/dev/null; done; wait "${ALL_API_PIDS[@]:-}" 2>/dev/null || true; }
# cleanup() is idempotent (safe to call more than once): cleanup_apis() kills already-killed/reaped pids and
# waits on already-reaped ones, both no-ops under 2>/dev/null / || true; rm -rf on an already-removed $T is
# also a no-op. That matters now that INT/TERM each call it AND THEN exit (which fires the EXIT trap too, a
# second call to the SAME function) - see the three traps below.
cleanup() { cleanup_apis; rm -rf "$T"; }
# P2 (bot finding): a single `trap '...' EXIT INT TERM` with no explicit `exit` runs cleanup on a real INT/
# TERM and then RETURNS to wherever the script was interrupted - the suite keeps running afterward against
# fixtures cleanup() just deleted (and, in test_under_load.sh's own case, could even start NEW busy loops).
# EXIT stays cleanup-only (it fires exactly once, at the point this script is already ending, by whatever
# means); INT/TERM each call cleanup THEN exit with the conventional 128+signal code (130/143) so the
# process actually terminates instead of resuming.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
pass=0; fail=0; API_PID=
ok()  { pass=$((pass+1)); printf '%-52s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-52s FAIL: %s\n' "$1" "$2"; }

export BLOX_DIR=$T/pkg
mkdir -p "$BLOX_DIR"
cp "$PKG"/h-config.sh "$PKG"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer#" "$PKG/h-manifest.conf" > "$BLOX_DIR/h-manifest.conf"
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

# NOTE: $CUSTOM_VERSION in this harness's h-manifest.conf is the package's own 2.1.1 - "ver" always reflects
# that, never the engine binary's own VER field (a hotfix package ships an unchanged, already-gated binary; see
# bloxminer/h-stats.sh's own header). SUM_OK below deliberately reports VER=2.1.0 (the real, unchanged 2.1.1
# binary's own report) to prove the package version wins, not just that it happens to match.
stats_case "complete per-core reply" "$SUM_OK" "$CORES_OK" \
	'.khs == "11900.00" and .stats.hs == [6000, 5900] and .stats.temp == [61, 64] and .stats.ar == [15, 1] and .stats.uptime == 321 and .stats.cpu_power == 136 and .stats.ver == "2.1.1" and .stats.algo == "verushash"'
stats_case "engine VER differs from package -> package version still shown" "${SUM_OK/VER=2.1.0/VER=1.9.9}" "$CORES_OK" '.stats.ver == "2.1.1"'
stats_case "no VER field at all -> package version still shown" "${SUM_OK/;VER=2.1.0/}" "$CORES_OK" '.stats.ver == "2.1.1"'

# "exec {fd}... 2>/dev/null" with no command after it is a bare redirection, applied to the CURRENT SHELL
# PERMANENTLY, not scoped to that one statement. The poll loop's own fd-open/close run unconditionally on every
# poll that reaches this code, so an unscoped version would have silently redirected THIS WHOLE SHELL's stderr
# to /dev/null from the very first poll onward - Hive sources h-stats.sh repeatedly in one long-lived shell.
# Proven directly: a message written to stderr, in the SAME shell, immediately after a normal poll, must still
# be visible afterward.
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

# ---- P1: "the answer just got worse" transitions (summary healthy -> cores reply says STALL=1) must publish
# the honest zero IMMEDIATELY, before the richer zero-result composition - CI/bot finding: the composition used
# to run several jq forks BEFORE ever calling write_result(), so a parent-side deadline/kill landing inside
# that window left $OUTFILE exactly as Phase A had already written it: a real positive rate, for a miner this
# exact poll just learned is stalled. BLOX_HSTATS_TEST_PSTALL_DELAY deterministically reproduces that window
# (sleeps right after write_result_fast(), before the composition) long enough that the parent's own deadline
# is guaranteed to land and kill the child mid-delay - the fix means the fast write above already landed by
# then; the pre-fix code would still show khs=11900.00 here (Phase A's own earlier, now-stale positive answer).
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "${CORES_OK/STALL=0/STALL=1}" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
t0=$(date +%s.%N)
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(BLOX_HSTATS_TEST_PSTALL_DELAY=5 timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
t1=$(date +%s.%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
khs_got=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
if [[ $khs_got == "0" ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 4.0)}'; then
	ok "Phase B stall, enrichment killed mid-composition: honest 0 published early, never Phase A's stale positive (${elapsed}s)"
else
	bad "Phase B stall, enrichment killed mid-composition: honest 0 published early, never Phase A's stale positive" \
		"khs_got=$khs_got elapsed=${elapsed}s res=$res"
fi

stats_case "2.0.0 engine (no cores command) -> FRESHKHS" "${SUM_OK%%;POWER=*}|" "" '.stats.hs == [11900] and (.stats | has("cpu_power")) == false'
CORES_ZERO="${CORES_OK/KHS=6000.00/KHS=0.00}"; CORES_ZERO="${CORES_ZERO/KHS=5900.00/KHS=0.00}"
stats_case "positive FRESHKHS + structurally-valid but all-zero (non-stalled) cores reply -> Phase A's WHOLE result kept" \
	"$SUM_OK" "$CORES_ZERO" '.khs == "11900.00" and .stats.hs == [11900]'
CORES_NEARZERO="${CORES_OK/KHS=6000.00/KHS=10.00}"; CORES_NEARZERO="${CORES_NEARZERO/KHS=5900.00/KHS=10.00}"
stats_case "positive FRESHKHS + complete-but-near-zero cores total (>10% off) -> Phase A's WHOLE result kept" \
	"$SUM_OK" "$CORES_NEARZERO" '.khs == "11900.00" and .stats.hs == [11900]'

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

# ---- write_result's OWN guard: this used to be
# `printf '%s' "$(jq -nc ...)" > "$tmp" && mv -f "$tmp" "$OUTFILE"` - if jq's OWN command substitution failed
# (a fork/exec failure, independent of whatever the CALLER's own upstream composition did), `$(...)` comes
# back empty, `printf '%s' ""` still writes a trivially-successful zero-byte file, and `mv -f` then
# unconditionally replaced $OUTFILE - an already-good prior result - with that empty file. Tests THIS function
# directly (not through run()'s own upstream validation, which is a separate, shallower guard) via
# BLOX_HSTATS_TEST_FORCE_WRITE_RESULT_FAIL, deterministically the same way on every host: a real positive
# result is written first, then a forced-failing write_result call must leave that exact result standing.
D_DEBUG="$T/write_result_debug.log"; : > "$D_DEBUG"
# $OUTFILE is pointed at a directory THIS test owns and keeps alive for its own duration, not the one the
# `. h-stats.sh` sourcing below sets up internally: that one lives under its own per-poll $WORKDIR, which the
# poll's own cleanup removes (rm -rf) by the time sourcing returns - a later call to write_result() reusing
# that (by then nonexistent) path would silently fail to write anywhere at all, not exercise the guard this
# case means to test.
mkdir -p "$T/wr_test"
res=$(BLOX_HSTATS_DEBUG_LOG="$D_DEBUG" bash -c '. "$BLOX_DIR/h-stats.sh"
	OUTFILE="$1/out"
	write_result "11900.00" "a prior positive result"
	before=$(cat "$OUTFILE" 2>/dev/null)
	BLOX_HSTATS_TEST_FORCE_WRITE_RESULT_FAIL=1 write_result "0" "should never reach OUTFILE"
	after=$(cat "$OUTFILE" 2>/dev/null)
	jq -nc --arg b "$before" --arg a "$after" "{before: \$b, after: \$a}"' _ "$T/wr_test" 2>&1)
if [[ $(jq -r '.before == .after and (.after | contains("a prior positive result"))' <<< "$res" 2>/dev/null) == true ]] \
	&& grep -q "write_result: REFUSED" "$D_DEBUG"
then
	ok "write_result's own guard: a forced jq failure never overwrites an already-good prior result"
else
	bad "write_result's own guard: a forced jq failure never overwrites an already-good prior result" "res=$res debug=$(cat "$D_DEBUG" 2>/dev/null)"
fi

# ---- write_result_fast: malformed-JSON regression (CI/bot finding on the saturation case, root cause
# of what earlier looked like a nested-docker-only artifact). bash's `printf` builtin interprets backslash
# escapes - including `\"` - IN ITS OWN FORMAT STRING regardless of shell quoting (single quotes only stop
# the SHELL from touching them, not printf), silently dropping the backslash; a first version of this
# function wrote `\"` directly in stats_inner's format string meaning to pre-escape it for nesting, and got
# back a plain, UNESCAPED `"` instead - then nested that raw into outer's "stats":"%s" unescaped, producing
# e.g. `{"khs":"100","stats":"{"hs":[100],...}"}"` - malformed JSON every reader (jq, and the parent's own
# read-back) correctly refuses. Fixed via bash parameter expansion (not printf) to escape stats_inner
# EXPLICITLY - backslash first, then quote - before nesting. This case calls write_result_fast and
# write_result directly (not through a full poll) with the SAME representative inputs, and requires: (1)
# write_result_fast's own output is valid JSON on its own (`jq -e .` succeeds - this alone catches the
# regression), and (2) it is byte-identical to write_result's real jq-composed output for the same inputs -
# the "byte-identical in shape" claim in write_result_fast's own header, made a hard requirement here, not
# just prose.
mkdir -p "$T/wrf_test1"
res=$(bash -c '. "$BLOX_DIR/h-stats.sh"
	OUTFILE="$1/out"
	write_result_fast "11900.00" "15" "1" "321"
	fast_out=$(cat "$OUTFILE" 2>/dev/null)
	write_result "11900.00" "{\"hs\":[11900.00],\"hs_units\":\"khs\",\"temp\":[null],\"fan\":[0],\"bus_numbers\":[null],\"uptime\":321,\"ar\":[15,1],\"algo\":\"verushash\"}"
	real_out=$(cat "$OUTFILE" 2>/dev/null)
	if jq -e . > /dev/null 2>&1 <<< "$fast_out" && [[ "$fast_out" == "$real_out" ]]; then
		echo "RESULT=PASS"
	else
		valid=no; jq -e . > /dev/null 2>&1 <<< "$fast_out" && valid=yes
		echo "RESULT=FAIL valid=$valid fast=[$fast_out] real=[$real_out]"
	fi' _ "$T/wrf_test1" 2>&1)
if [[ $res == RESULT=PASS* ]]; then
	ok "write_result_fast: valid JSON, byte-identical in shape to write_result for the same inputs"
else
	bad "write_result_fast: valid JSON, byte-identical in shape to write_result for the same inputs" "$res"
fi

# ---- write_result_fast's escaping mechanism, in isolation from its own (numeric-only, already-validated)
# callers: k/a/r/u are int()/num()-gated by run() before this function is ever called (see the SECURITY audit
# above and this function's own header), so NONE of them can ever actually carry a quote or backslash today -
# unlike a dynamic API-sourced string field (e.g. a hypothetical `ver` taken from the miner's own API reply,
# which this package's `ver` is NOT - see run()'s own comment: it is always $CUSTOM_VERSION, a fixed local
# string, never the engine's API VER field). The escape step itself is still tested directly here, against a
# value engineered to contain BOTH a quote and a backslash, so correctness does not rest on "nothing today
# happens to need it" - replicates write_result_fast's own two-line transform (backslash first, then quote -
# order matters, or a `"` already turned into `\"` would itself be wrongly re-escaped by a later backslash
# pass) and round-trips the result back through jq to confirm the decoded value is byte-identical to the
# original, untouched input.
res=$(bash -c '
	raw="algo\"inject\\x"
	esc=${raw//\\/\\\\}
	esc=${esc//\"/\\\"}
	printf -v wrapped "{\"stats\":\"%s\"}" "$esc"
	decoded=$(jq -r ".stats" <<< "$wrapped" 2>/dev/null)
	if jq -e . > /dev/null 2>&1 <<< "$wrapped" && [[ "$decoded" == "$raw" ]]; then
		echo "RESULT=PASS"
	else
		echo "RESULT=FAIL wrapped=[$wrapped] decoded=[$decoded] raw=[$raw]"
	fi' 2>&1)
if [[ $res == RESULT=PASS* ]]; then
	ok "write_result_fast's escape order (backslash then quote): a value with both stays valid JSON and round-trips exactly"
else
	bad "write_result_fast's escape order (backslash then quote): a value with both stays valid JSON and round-trips exactly" "$res"
fi

# ---- write_result_fast under the SAME forced-failure path write_result's own guard test (above) uses for
# write_result() directly - but reached through a REAL poll (full run(), not a synthetic direct call), to
# prove the production path the parent actually depends on: a healthy summary, with write_result() (Phase
# A/B's own richer composition write) forced to fail for the rest of the poll, must leave the PARENT reading
# back write_result_fast's own earlier publish - a positive $khs, not the false-zero this exact bug produced
# before the fix once write_result_fast's own malformed output stopped the parent's read-back jq from
# accepting it at all.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(BLOX_HSTATS_TEST_FORCE_WRITE_RESULT_FAIL=1 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
khs_got=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
if awk -v k="${khs_got:-0}" 'BEGIN{exit !(k>0)}'; then
	ok "write_result forced to fail after the fast write: the poll still returns the fast result (khs>0)"
else
	bad "write_result forced to fail after the fast write: the poll still returns the fast result (khs>0)" "khs_got=$khs_got res=$res"
fi

# ---- "Reject an empty Phase A stats composition": Phase A's own stats composition chains four nested jq calls
# into one outer jq call; if any one of them failed (a transient fork/exec failure under resource pressure -
# the same class this file's own write_result() guard above exists for), $stats came back empty while $khs
# already held a real, positive number - write_result would then wrap that empty $stats as a literal empty
# JSON string (`"stats":""`), passing write_result's own guard (which only checks the OUTER wrap succeeded, not
# $2's own content) and reaching $OUTFILE: the parent would report a positive khs with NO stats at all. Fixed:
# Phase A's composition is now validated the same way Phase B's own final composition already is (non-empty
# JSON object, hs array of numbers, temp array) before ever reaching write_result; on failure, an honest
# minimal object (khs from the fresh reading + a single minimal row) is written instead - never an empty
# stats. BLOX_HSTATS_TEST_FORCE_PHASEA_STATS_FAIL deterministically simulates the nested-jq failure, the same
# way BLOX_HSTATS_TEST_FORCE_WRITE_RESULT_FAIL already does for write_result() itself, above. No cores reply
# (empty $c, same convention as the "2.0.0 engine (no cores command)" case above) - Phase B then skips outright
# (`[[ -z $cores ]] && return 0`), so Phase A's own result (the honest minimal fallback, with the fix) is what
# the parent actually sees, never masked by a legitimate Phase B reply overwriting it regardless of whether
# Phase A's own fix fired.
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

# ---- "Normalize the fallback timestamp to microseconds": now_us() (and this file's own DEADLINE_US fallback,
# right at the top) used to concatenate the raw fractional string straight onto the whole-seconds part:
# EPOCHREALTIME's own fraction is always exactly 6 digits (real microseconds), but the `date +%s.%N` FALLBACK's
# is 9 (nanoseconds) - taken only on bash < 5, but load-bearing if it ever is. Concatenated raw, every
# "microsecond" value this file computes off that fallback was silently inflated by ~1000x, blowing the whole
# 2.4 s budget arithmetic by three orders of magnitude. Forces the fallback path (EPOCHREALTIME explicitly
# unset in a fresh bash) and checks now_us()'s own $REPLY lands within a generous few seconds of a known-good
# reference (date +%s, scaled to real microseconds) - the pre-fix concatenation would be off by roughly 1000x,
# nowhere near this tolerance.
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

# ---- P1 (2df9b2d): Hive's real agent sources h-stats.sh REPEATEDLY in the SAME long-lived shell, poll after
# poll - this file IS the one and only poll entry point in a single-engine package (no dispatcher recomputes a
# shared DEADLINE_US once per poll the way the multi-engine 3.0.0 line's dispatcher does). An earlier version of
# this file ported that line's `if [[ -z ${DEADLINE_US:-} ]]` guard verbatim: DEADLINE_US is a plain shell
# global, so poll 1 set it and the guard then kept THAT value on every later poll in the same shell forever -
# poll 2 onward started with an already-expired deadline, never even attempted the `nc` call, and reported
# khs=0 with a perfectly healthy API, indistinguishable on a real rig from a dead miner. Proves BOTH halves:
# every poll (back-to-back AND separated by real gaps past the 2.4 s budget) returns a positive khs with valid
# stats, AND the repeated sourcing leaves no growing fd or child-process trail behind in that same shell.
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
grep -q ready "$T/api.out" || bad "sourced repeatedly in one shell" "fake API did not start: $(cat "$T/api.out" 2>/dev/null)"
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(timeout 20 bash -c '
	before_fds=$(ls /proc/$$/fd 2>/dev/null | wc -l)
	. "$BLOX_DIR/h-stats.sh"; r1="$khs|$stats"            # poll 1
	. "$BLOX_DIR/h-stats.sh"; r2="$khs|$stats"             # poll 2, back-to-back (same second)
	sleep 2.6                                              # > the 2.4 s budget poll 1 computed its deadline from
	. "$BLOX_DIR/h-stats.sh"; r3="$khs|$stats"             # poll 3, after a real gap
	sleep 2.6
	. "$BLOX_DIR/h-stats.sh"; r4="$khs|$stats"             # poll 4, after another real gap
	after_fds=$(ls /proc/$$/fd 2>/dev/null | wc -l)
	# Fork-free, via a bash builtin `read` redirected from /proc - NOT `pgrep -P $$ | wc -l` (tried first):
	# pgrep itself is a NEWLY FORKED child of $$ at the exact moment it runs, with PPID=$$ until it execs away
	# its own identity - a classic self-match, confirmed directly (pgrep -P $$ inside `$(...)` matched its own
	# PID, with zero real children present per `ps --ppid`). /proc/$$/task/$$/children (Linux, direct children
	# of $$) read via the `read` builtin never forks at all, so there is no reader process left for it to see.
	# Guarded with -r first: CONFIG_PROC_CHILDREN can be off, or this file can simply be absent in some
	# containers - an unreadable path fails the REDIRECTION itself, not just `read`, and that error is NOT
	# something "2>/dev/null" on the read command alone stops from reaching this whole bash -c''s own stderr
	# (this case used to capture that merged in via 2>&1, corrupting every field below, not just this one -
	# fixed below too). children_na=1 marks "could not determine" so the caller SKIPs only the child-count
	# half of this assertion, never fails the whole case over an absent kernel feature.
	children=""; children_na=0
	if [[ -r /proc/$$/task/$$/children ]]; then
		read -r children < /proc/$$/task/$$/children 2>/dev/null
	else
		children_na=1
	fi
	after_children=0; [[ -n $children ]] && after_children=$(wc -w <<< "$children")
	jq -nc --arg a "$r1" --arg b "$r2" --arg c "$r3" --arg d "$r4" \
		--arg bf "$before_fds" --arg af "$after_fds" --arg ac "$after_children" --argjson na "$children_na" \
		"{p1:\$a,p2:\$b,p3:\$c,p4:\$d,before_fds:(\$bf|tonumber),after_fds:(\$af|tonumber),after_children:(\$ac|tonumber),children_na:\$na}"
' 2>"$T/sourced_repeatedly_stderr.log")
all_positive=true
for key in p1 p2 p3 p4; do
	k=$(jq -r --arg k "$key" '.[$k] // "" | split("|")[0]' <<< "$res" 2>/dev/null)
	s=$(jq -r --arg k "$key" '.[$k] // "" | split("|")[1] // ""' <<< "$res" 2>/dev/null)
	awk -v x="${k:-0}" 'BEGIN{exit !(x>0)}' || all_positive=false
	[[ -n $s && $s == "{"*"}" ]] || all_positive=false
done
bf=$(jq -r '.before_fds // -1' <<< "$res" 2>/dev/null); af=$(jq -r '.after_fds // -1' <<< "$res" 2>/dev/null)
ac=$(jq -r '.after_children // -1' <<< "$res" 2>/dev/null); na=$(jq -r '.children_na // 0' <<< "$res" 2>/dev/null)
if $all_positive && [[ $bf == "$af" ]] && { [[ $na == 1 ]] || [[ $ac == 0 ]]; }; then
	if [[ $na == 1 ]]; then
		ok "sourced repeatedly in one shell (back-to-back + >2.4s gaps): every poll khs>0 w/ stats, no fd leak (child-count check SKIPPED: /proc/\$\$/task/\$\$/children unavailable)"
	else
		ok "sourced repeatedly in one shell (back-to-back + >2.4s gaps): every poll khs>0 w/ stats, no fd/child leak"
	fi
else
	bad "sourced repeatedly in one shell (back-to-back + >2.4s gaps): every poll khs>0 w/ stats, no fd/child leak" \
		"res=$res before_fds=$bf after_fds=$af after_children=$ac children_na=$na"
fi

# ---- unbounded-reap fix (ported from bloxminer-x commit 9a3778a, same bug): a SIGTERM-ignoring child, with a
# HEALTHY positive API reply underneath it, must still have its already-written Phase A/B answer read back and
# returned PROMPTLY (well under the 3.0 s budget / 4.0 s hard cap tests/hive/test_under_load.sh enforces) - the
# parent must never block behind an untimed `wait "$CPID"` waiting for a SIGKILLed-but-not-yet-reaped child.
#
# No test-only branch in the shipped script for this (an earlier version of this file had
# BLOX_HSTATS_TEST_FORCE_SIGTERM_IGNORE directly in bloxminer/h-stats.sh - removed): the SAME forced
# TERM-then-KILL path is produced from the TEST side instead, via a PATH stub standing in for the one external
# command this collector actually calls during collection, `nc` - X achieves the equivalent through a
# SIGTERM-ignoring bloxsense call; this engine has no such tool, so the stub plays that role for `nc` instead.
# The stub forwards every command EXCEPT "cores" to the REAL nc (against the SAME fake API below), so Phase A's
# own `summary` call still gets a genuine, healthy reply and run() writes a real positive result before
# anything hangs - exactly "AFTER Phase A's result has been written". Only "cores" (Phase B, optional) traps/
# ignores SIGTERM and sleeps well past the deadline: api()'s own inner `timeout --foreground` sends ONE SIGTERM
# to the stub at ITS OWN short cap and then just waits (GNU timeout never escalates on its own without -k), so
# that nc call - and therefore run() itself, still waiting on its own `cores=$(api cores)` - never returns on
# its own; the collector's setsid child is still alive when the PARENT's poll loop gives up at the deadline and
# has to escalate, the exact path a real GitHub CI run once measured stalling to 5.01 s with an EMPTY result
# (the external test timeout killing the whole poll before this file ever got to answer).
REAL_NC=$(command -v nc)
STUBBIN="$T/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/nc" <<STUBEOF
#!/usr/bin/env bash
cmd=\$(cat)
if [[ \$cmd == cores ]]; then
	trap '' TERM
	sleep 30
	exit 0
fi
printf '%s' "\$cmd" | "$REAL_NC" "\$@"
STUBEOF
chmod +x "$STUBBIN/nc"
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
t0=$(date +%s.%N)
# Captures stdout ONLY (not 2>&1): with the unbounded reap removed (the fix under test), bash's OWN job
# control reports the SIGKILLed child asynchronously - "... Killed ... setsid bash -c '...'" - on THIS bash -c
# subshell's own stderr as it exits, since nothing here ever explicitly `wait`s for it (deliberately - see
# h-stats.sh's own comment at that exact point). That notice is expected, harmless, and not something a real
# Hive agent re-parses as data (it only ever reads $khs/$stats as plain bash variables in the same process) -
# but mixing it into $res here (an earlier version of this test used 2>&1) corrupted the JSON this test itself
# expects back. Kept on disk instead, for debugging only.
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(PATH="$STUBBIN:$PATH" timeout 10 bash -c '
	. "$BLOX_DIR/h-stats.sh"
	children=""; children_na=0
	if [[ -r /proc/$$/task/$$/children ]]; then
		read -r children < /proc/$$/task/$$/children 2>/dev/null
	else
		children_na=1
	fi
	jq -nc --arg k "$khs" --arg s "$stats" --arg c "$children" --argjson na "$children_na" \
		"{khs: \$k, stats: \$s, children: \$c, children_na: \$na}"
' 2>"$T/sigterm_ignore_stderr.log")
t1=$(date +%s.%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
khs_got=$(jq -r '.khs // ""' <<< "$res" 2>/dev/null)
children_got=$(jq -r '.children // "" | split(" ") | map(select(. != "")) | length' <<< "$res" 2>/dev/null)
na_got=$(jq -r '.children_na // 0' <<< "$res" 2>/dev/null)
na_note=""; [[ $na_got == 1 ]] && na_note=" (child-count check SKIPPED: /proc/\$\$/task/\$\$/children unavailable)"
if [[ $khs_got == "11900.00" ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.5)}' && { [[ $na_got == 1 ]] || [[ ${children_got:-9} -le 1 ]]; }; then
	ok "SIGTERM-ignoring child, healthy summary: Phase A's fresh total survives escalation, returned promptly (${elapsed}s)$na_note"
else
	bad "SIGTERM-ignoring child, healthy summary: Phase A's fresh total survives escalation, returned promptly" \
		"elapsed=${elapsed}s children=$children_got children_na=$na_got res=$res"
fi
# No explicit reap after SIGKILL (see h-stats.sh's own comment at that exact point) means AT MOST one stale
# zombie can be left behind PER backgrounded-child type, per poll that goes through this escalation path -
# bash's own job control reaps it opportunistically on the NEXT poll's own backgrounding, at the latest.
# WAITFIFO/WATCHDOG update: this shell now backgrounds TWO children per poll (the collector, $CPID, and the
# WATCHDOG, $WATCHDOG_PID) instead of one, and neither is explicitly `wait`-ed on (the collector by
# established design above; the WATCHDOG because it is killed by its own pgid at poll end and the SAME
# "a zombie here is reclaimed by the next poll's own job-control operations at the latest" reasoning applies
# to it too - it is just as disposable). The bound below is widened from <= 1 to <= 2 accordingly: at most one
# lingering zombie PER backgrounded-child type can survive to the next poll under the same opportunistic-
# reaping argument, never unbounded growth either way. Runs 3 MORE polls through the exact same
# forced-escalation path in the SAME shell and checks that count never grows past 2 - proves zombies do not
# accumulate unbounded across repeated pollings, only ever a bounded, small number pending at a time.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
# Stdout only, not 2>&1 - same reason as the single-poll case above (bash's own async "Killed" job-control
# notice, once per poll that escalates here, would otherwise land on stderr mixed into $res and break the
# plain-integer check below).
# Reuses the SAME $STUBBIN/nc stub set up above (still the only thing on PATH ahead of the real nc).
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(PATH="$STUBBIN:$PATH" timeout 20 bash -c '
	max=0; na=0; [[ -r /proc/$$/task/$$/children ]] || na=1
	# Runs all 3 polls (still exercising the real escalation path) regardless of whether the procfs feature is
	# available to MEASURE with - na alone decides whether the caller trusts $max afterward, never whether this
	# loop runs at all.
	for i in 1 2 3; do
		. "$BLOX_DIR/h-stats.sh"
		children=""
		(( na )) || read -r children < /proc/$$/task/$$/children 2>/dev/null
		n=0; [[ -n $children ]] && { read -ra arr <<< "$children"; n=${#arr[@]}; }
		(( n > max )) && max=$n
	done
	echo "$na $max"
' 2>"$T/sigterm_ignore_stderr2.log")
na_got=${res%% *}; max_got=${res#* }
if [[ $na_got == 1 ]]; then
	ok "repeated escalation-path polls: <= 2 unreaped children (collector + watchdog) between polls, never accumulating (SKIPPED: /proc/\$\$/task/\$\$/children unavailable)"
elif [[ $max_got =~ ^[0-9]+$ ]] && (( max_got <= 2 )); then
	ok "repeated escalation-path polls: <= 2 unreaped children (collector + watchdog) between polls, never accumulating (max=$max_got)"
else
	bad "repeated escalation-path polls: <= 2 unreaped children (collector + watchdog) between polls, never accumulating" "res=$res"
fi

# ---- WATCHDOG boundedness proof: WAITFIFO's EOF-era design (and this file's own earlier `<(:)`-only design)
# relied ENTIRELY on `read -t` to ever unblock whenever the collector itself is still alive (blocked on the
# SAME SIGTERM-ignoring `nc cores` stub used above, so its own EXIT trap never fires either) - the real,
# rare CI finding this whole port exists for (see h-stats.sh's own WAITFIFO header) was `-t` itself losing its
# timeout for one single read. BLOX_HSTATS_TEST_NO_TIMEOUT=1 (test-only: h-stats.sh's own wait_secs()) drops
# -t from this read ENTIRELY, so the ONLY thing that can ever wake the main poll loop's wait_secs(0.05) calls
# and the escalation stage's wait_secs($KILL_GRACE) call is a byte actually arriving on $waitfd - simulating
# the WORST version of a lost timeout (not just losing ONE, but having NONE at all, for the whole poll)
# without needing to reproduce whatever rare bash/kernel condition causes a real loss. Combined with the
# SIGTERM-ignoring `nc cores` stub (so the collector genuinely never exits on its own, meaning its own EXIT
# trap - WAITFIFO's OTHER writer - never fires either), NOTHING would ever unblock either read except the
# WATCHDOG's own two independent byte-writes - this isolates the WATCHDOG from the collector's own EXIT trap
# entirely. Must still complete within the 4.0 s hard cap with Phase A's own fresh positive total, and leave
# no survivor process behind - the exact same two properties the existing SIGTERM-ignoring case above already
# proves for the NORMAL (timeout-working) path.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
MARKER_WD="bloxminer_test_watchdog_nc_$$"
STUBBIN_WD="$T/stubbin-watchdog"; mkdir -p "$STUBBIN_WD"
cat > "$STUBBIN_WD/nc" <<STUBEOF
#!/usr/bin/env bash
cmd=\$(cat)
if [[ \$cmd == cores ]]; then
	trap '' TERM
	exec -a $MARKER_WD sleep 30
fi
printf '%s' "\$cmd" | "$REAL_NC" "\$@"
STUBEOF
chmod +x "$STUBBIN_WD/nc"
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
t0=$(date +%s.%N)
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(PATH="$STUBBIN_WD:$PATH" BLOX_HSTATS_TEST_NO_TIMEOUT=1 timeout 10 bash -c '
	. "$BLOX_DIR/h-stats.sh"
	jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: \$s}"
' 2>"$T/watchdog_stderr.log")
rc=$?
t1=$(date +%s.%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
sleep 0.5   # let init reap anything that died, before checking for survivors
survivors_wd=$(pgrep -f "$MARKER_WD" || true)
khs_got=$(jq -r '.khs // ""' <<< "$res" 2>/dev/null)
if [[ $rc == 0 ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 4.0)}' && [[ $khs_got == "11900.00" ]] && [[ -z $survivors_wd ]]; then
	ok "WATCHDOG boundedness: read -t permanently lost + SIGTERM-ignoring nc 'cores' -> still < 4.0 s, Phase A's positive total survives, no survivors (${elapsed}s)"
else
	bad "WATCHDOG boundedness: read -t permanently lost + SIGTERM-ignoring nc 'cores' -> still < 4.0 s, Phase A's positive total survives, no survivors" \
		"rc=$rc elapsed=${elapsed}s survivors=[$survivors_wd] res=$res"
fi
pkill -9 -f "$MARKER_WD" 2>/dev/null   # safety net: never leak a process into the host even if this test fails

# ---- P2: a mktemp failure (e.g. /tmp runs out of inodes/quota) must still fall back honestly and leak
# nothing. LIB/OUTFILE/HANDSHAKE now share ONE mktemp -d'd working directory (fixed names inside it) rather
# than one mktemp call each - see that mktemp -d's own header - so there is no longer a "one of several calls
# fails" split to engineer: a PATH stub that fails `mktemp` outright (any call, any args) exercises the single
# remaining failure point directly, caught by the emergency-fallback block at the very top of the file.
STUBBIN_MKTEMP="$T/stubbin-mktemp"; mkdir -p "$STUBBIN_MKTEMP"
cat > "$STUBBIN_MKTEMP/mktemp" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
chmod +x "$STUBBIN_MKTEMP/mktemp"
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
before_wd=$(ls -d "${TMPDIR:-/tmp}"/bloxminer-hstats.* 2>/dev/null)
# One line per value, not "khs=[..]|stats=[..]" on one line: $stats is itself JSON and can contain "]" - a
# single-line greedy sed capture for khs would (and once did, caught while verifying this very test) grab up to
# the LAST "]" in the whole line, swallowing part of $stats into what was supposed to be just the khs value.
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(PATH="$STUBBIN_MKTEMP:$PATH" timeout 10 bash -c '. "$BLOX_DIR/h-stats.sh"; printf "KHS=%s\nSTATS=%s\n" "$khs" "$stats"' 2>"$T/mktemp_fail_stderr.log")
after_wd=$(ls -d "${TMPDIR:-/tmp}"/bloxminer-hstats.* 2>/dev/null)
leaked_wd=$(comm -13 <(sort <<< "$before_wd") <(sort <<< "$after_wd") 2>/dev/null)
khs_got=$(sed -n 's/^KHS=//p' <<< "$res")
if [[ $khs_got == "0" ]] && [[ -z $leaked_wd ]]; then
	ok "mktemp -d failure: honest fallback, no leaked working directory"
else
	bad "mktemp -d failure: honest fallback, no leaked working directory" "res=$res leaked=[$leaked_wd]"
fi

# ---- P1/P2 (bot finding): a sourcing caller running with `set -e` must survive every normal fallback path in
# this file, not just the ones with their own explicit `return`/`if` guard already visible at a glance. Two
# cases, both sourcing h-stats.sh from INSIDE a `set -e` bash -c and printing a marker line AFTER the sourcing
# returns - if `set -e` ever killed the shell mid-sourcing (any of the bare, unguarded statements the audit
# found: `remaining_us`'s own trailing `(( ))`, `result=$(cat "$OUTFILE")` when OUTFILE never existed, several
# more), the marker would never print and the whole $res capture would be empty/truncated instead of showing
# the expected khs value.
#
# Case 1: a delayed handshake long enough that the DEADLINE passes before the child ever gets to write
# anything - OUTFILE never created at all, exactly the scenario the bot's own P1 finding named explicitly.
# BLOX_HSTATS_TEST_HANDSHAKE_DELAY (5s) comfortably exceeds BUDGET_US+KILL_GRACE (2.4+0.3=2.7s), so the
# parent's own poll loop gives up and escalates TERM/KILL on the child while it is still sleeping in that
# delay - it never reaches `. "$1"; run()`, so $OUTFILE is never written. Must survive AND report khs=0.
# The outer `timeout` here is a safety net ONLY, not part of what this case measures (h-stats.sh's own
# 2.7 s internal budget is) - widened from 10s to 20s after an intermittent false FAIL on a heavily loaded
# docker host running the full suite back-to-back (reproduced ~1/3 runs there; never in isolation or
# natively) where the outer margin, not the fix itself, was too tight.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(BLOX_HSTATS_TEST_HANDSHAKE_DELAY=5 timeout 20 bash -c '
	set -e
	. "$BLOX_DIR/h-stats.sh"
	echo "SURVIVED khs=[$khs]"
' 2>"$T/errexit_delayed_stderr.log")
if [[ $res == "SURVIVED khs=[0]" ]]; then
	ok "set -e caller survives a delayed-handshake poll (OUTFILE never created): honest khs=0, no abort"
else
	bad "set -e caller survives a delayed-handshake poll (OUTFILE never created): honest khs=0, no abort" \
		"res=[$res] stderr=$(cat "$T/errexit_delayed_stderr.log" 2>/dev/null)"
fi
# Case 2: the SAME `set -e` caller, but a normal healthy poll - must ALSO survive (every bare statement the
# audit fixed is exercised on this path too: remaining_us(), write_result_fast()/write_result(), the Phase A
# composition, the stall==1 check taking its FALSE branch, cores non-empty taking its FALSE branch, cat
# "$OUTFILE" actually succeeding this time) and report the real positive rate, not just "didn't crash".
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
# Same outer-margin widening as case 1 above, for consistency - this one normally completes in well under a
# second, but costs nothing to give the same safety net.
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(timeout 20 bash -c '
	set -e
	. "$BLOX_DIR/h-stats.sh"
	echo "SURVIVED khs=[$khs]"
' 2>"$T/errexit_healthy_stderr.log")
if [[ $res == "SURVIVED khs=[11900.00]" ]]; then
	ok "set -e caller survives a normal healthy poll: real positive khs, no abort"
else
	bad "set -e caller survives a normal healthy poll: real positive khs, no abort" \
		"res=[$res] stderr=$(cat "$T/errexit_healthy_stderr.log" 2>/dev/null)"
fi

# ---- P1: the MANDATORY `summary` call used to be capped at a flat 600 ms, same as the OPTIONAL `cores` call -
# under real CPU pressure a perfectly healthy ccminer can legitimately take longer than that just to get its
# own stats thread scheduled and answer, and the old flat cap killed that `nc` call and reported a false zero
# with most of the 2.4 s budget still unused. api()'s own fake_api.py reply can now answer a given command only
# after a configurable delay (re-read per connection) - exercises this directly rather than just by inspection.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" --argjson d 1.3 '{summary: $s, cores: $c, delay: {summary: $d}}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
t0=$(date +%s.%N)
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>"$T/slow_summary_stderr.log")
t1=$(date +%s.%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
khs_got=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
if awk -v k="${khs_got:-0}" 'BEGIN{exit !(k>0)}' && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}'; then
	ok "summary answers after 1.3s (healthy, under heavy load): khs>0 within budget (${elapsed}s)"
else
	bad "summary answers after 1.3s (healthy, under heavy load): khs>0 within budget" "elapsed=${elapsed}s res=$res"
fi

# ---- the SAME slow-summary scenario but past the WHOLE 2.4 s budget (never answers in time at all) must still
# be BOUNDED - the mandatory call getting nearly the whole budget must never turn into effectively no cap at
# all; api()'s own cap_us() against the freshly-recomputed remaining_us is what still protects this, and the
# honest 0 fallback (no API answer in time) is correct here, not a hang.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" --argjson d 10 '{summary: $s, cores: $c, delay: {summary: $d}}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
t0=$(date +%s.%N)
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>"$T/slow_summary_stderr2.log")
t1=$(date +%s.%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
khs_got=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
if [[ $khs_got == "0" ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.5)}'; then
	ok "summary never answers (10s, past the whole budget): bounded, honest 0, no hang (${elapsed}s)"
else
	bad "summary never answers (10s, past the whole budget): bounded, honest 0, no hang" "elapsed=${elapsed}s res=$res"
fi

# ---- P1: a summary that answers within D seconds of being REQUESTED (not of poll entry) must always be
# published, even under GENUINE single-CPU saturation (not just this file's own serial test harness). An
# earlier version of this case used a flat 1.85 s and failed 20/20 on GitHub's own 2-4 vCPU runners (and the
# bot's 3-CPU review environment) even though it passed cleanly on ai02: 1.85 s was picked without accounting
# for PARENT-side start-up (mktemp, setsid launch, handshake) ALSO running on a saturated CPU, BEFORE the
# summary request is even sent - on a slower/more contended runner that start-up alone can approach or exceed
# what was left of the budget after a 1.85 s delay, with no reserve value able to fix a delay chosen without
# that in mind. A SECOND version used D=2.0 s (a doubled-for-CI-margin 2x safety factor on a ~60 ms ai02
# measurement) and still showed khs=0 on 20/20 in the bot's OWN review sandbox - clearly slower/more contended
# than even GitHub's own runners - because 2x was too thin a margin for how much slower an unknown host can be,
# and because 2.0 s of a 2.4 s budget leaves only ~0.4 s for start-up + RESERVE_US, razor-thin on a slow host,
# for a delay (2 s) already far beyond anything ccminer's own local API takes to answer in practice.
#
# D is derived from a real measurement, not guessed, with a WIDER safety factor this time: BLOX_HSTATS_DEBUG_LOG
# timestamps bracketing poll entry to the summary request being sent, 20 polls, taskset to ONE CPU with 2
# competing busy loops (the same saturation this case itself applies) - avg ~68 ms on ai02 (max ~70-74 ms
# across several runs; the manifest-sourcing move paired with this change - see h-stats.sh's own "VPORT"
# header - measured within noise of the pre-move baseline: start-up here was already dominated by mktemp/LIB/
# setsid/handshake, cut in the previous round, not by the small manifest file read). A 4x safety factor (not
# 2x) for an unknown host that could be meaningfully slower than both ai02 and GitHub's own runners: D = 2.4 s
# budget - (0.068 s start-up * 4) - 0.15 s RESERVE_US - 0.2 s extra margin = 2.4 - 0.272 - 0.15 - 0.2 = ~1.78 s;
# rounded DOWN (never up) to 1.5 s - this is the "guaranteed-publish window under single-CPU saturation": any
# summary answering within 1.5 s of being requested, under genuine single-CPU saturation, must always publish.
HAVE_TASKSET=1; command -v taskset > /dev/null 2>&1 || HAVE_TASKSET=0
# ---- P2 (bot finding): this used to hardcode `taskset -c 0` - assuming CPU 0 is in this process's own
# affinity, which is not true when the suite itself runs under a restricted affinity (e.g. `taskset -c 2-4
# bash tests/hive/test_hive_scripts.sh`, the bot's own review environment, or a container with a sparse/
# non-zero-based --cpuset-cpus): a hardcoded `taskset -c 0 ...` then simply fails (EINVAL - you cannot widen your own
# affinity), not "runs on a different CPU than intended". Fixed the same way tests/hive/test_under_load.sh's
# own tiers were: pick ONE real CPU from THIS process's own current affinity (parsed from /proc/self/status's
# Cpus_allowed_list, falling back to `taskset -pc $$` if that proc field is ever unavailable), and SKIP this
# whole saturation section (not fail) if even one CPU cannot be determined.
SAT_CPU=""
if [[ $HAVE_TASKSET == 1 ]]; then
	cpus_line=$(awk -F'\t' '/^Cpus_allowed_list:/{print $2}' /proc/self/status 2>/dev/null)
	[[ -z $cpus_line ]] && cpus_line=$(taskset -pc $$ 2>/dev/null | sed -n 's/.*affinity list: *//p')
	SAT_CPU=${cpus_line%%[,-]*}   # first CPU named by the list/range - a single id is always enough here
	[[ $SAT_CPU =~ ^[0-9]+$ ]] || SAT_CPU=""
fi
if [[ $HAVE_TASKSET == 1 && -n $SAT_CPU ]]; then
	exec 8>"${TMPDIR:-/tmp}/bloxminer-load-test.lock"
	if flock -w 300 8; then
		kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
		PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
		jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" --argjson d 1.5 '{summary: $s, cores: $c, delay: {summary: $d}}' > "$T/replies.json"
		: > "$T/api.out"
		python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
		for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
		SAT_PIDS=()
		for _ in 1 2; do taskset -c "$SAT_CPU" sh -c 'while :; do :; done' & SAT_PIDS+=("$!"); done
		sleep 0.3
		n_zero=0; n_over_cap=0; i=0
		for i in $(seq 1 20); do
			t0=$(date +%s.%N)
			# shellcheck disable=SC2016   # expanded by the inner bash, not here
			res=$(timeout 8 taskset -c "$SAT_CPU" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>/dev/null)
			t1=$(date +%s.%N)
			elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
			khs_got=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
			awk -v k="${khs_got:-0}" 'BEGIN{exit !(k>0)}' || { n_zero=$((n_zero+1)); echo "  poll $i: ZERO khs ($res)"; }
			awk -v e="$elapsed" 'BEGIN{exit !(e > 4.0)}' && { n_over_cap=$((n_over_cap+1)); echo "  poll $i: OVER HARD CAP (${elapsed}s)"; }
		done
		for p in "${SAT_PIDS[@]:-}"; do [[ -n $p ]] && kill -9 "$p" 2>/dev/null; done
		for p in "${SAT_PIDS[@]:-}"; do [[ -n $p ]] && wait "$p" 2>/dev/null; done
		if [[ $n_zero == 0 && $n_over_cap == 0 ]]; then
			ok "summary answers within D=1.5s under genuine single-CPU saturation, $i polls: no false zero, within hard cap"
		else
			bad "summary answers within D=1.5s under genuine single-CPU saturation, $i polls: no false zero, within hard cap" \
				"n_zero=$n_zero n_over_cap=$n_over_cap"
		fi

		# ---- the SAME genuine single-CPU saturation, but summary answers PAST the remaining budget (2.3 s -
		# comfortably past D's own 1.5 s guaranteed-publish window, still well short of the full 2.4 s budget) -
		# this must still be BOUNDED with an honest 0, never a hang: api()'s own cap_us() against the
		# freshly-recomputed remaining_us is what protects this regardless of what D above is tuned to.
		kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
		PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
		jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" --argjson d 2.3 '{summary: $s, cores: $c, delay: {summary: $d}}' > "$T/replies.json"
		: > "$T/api.out"
		python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
		for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
		SAT_PIDS=()
		for _ in 1 2; do taskset -c "$SAT_CPU" sh -c 'while :; do :; done' & SAT_PIDS+=("$!"); done
		sleep 0.3
		n_zero_ok=0; n_hardfail=0; i=0
		for i in $(seq 1 10); do
			t0=$(date +%s.%N)
			# shellcheck disable=SC2016   # expanded by the inner bash, not here
			res=$(timeout 8 taskset -c "$SAT_CPU" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>/dev/null)
			t1=$(date +%s.%N)
			elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
			khs_got=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
			[[ $khs_got == "0" ]] && n_zero_ok=$((n_zero_ok+1))
			awk -v e="$elapsed" 'BEGIN{exit !(e > 4.0)}' && { n_hardfail=$((n_hardfail+1)); echo "  poll $i: OVER HARD CAP (${elapsed}s)"; }
		done
		for p in "${SAT_PIDS[@]:-}"; do [[ -n $p ]] && kill -9 "$p" 2>/dev/null; done
		for p in "${SAT_PIDS[@]:-}"; do [[ -n $p ]] && wait "$p" 2>/dev/null; done
		flock -u 8
		if [[ $n_zero_ok == "$i" && $n_hardfail == 0 ]]; then
			ok "summary answers past the budget (2.3s) under genuine single-CPU saturation, $i polls: bounded, honest 0, no hang"
		else
			bad "summary answers past the budget (2.3s) under genuine single-CPU saturation, $i polls: bounded, honest 0, no hang" \
				"n_zero_ok=$n_zero_ok/$i n_hardfail=$n_hardfail"
		fi
	else
		echo "SKIP: could not acquire the shared load-test lock within 300s (stuck holder?)"
	fi
else
	if [[ $HAVE_TASKSET == 1 ]]; then
		echo "SKIP: could not determine this process's own current CPU affinity (SAT_CPU) - saturated-CPU timing cases skipped"
	else
		echo "SKIP: taskset not available - saturated-CPU timing cases skipped"
	fi
fi

# ---- SECURITY: bash arithmetic contexts ($(( )), (( )), array subscripts, -eq/-lt/-gt/...) recursively
# evaluate a variable's VALUE as a further expression, including command substitution - an untrusted
# numeric-looking field reaching ANY of those unvalidated is remote code execution from anything that can
# answer on 127.0.0.1:4068 (a local port race, or whatever sits between this poll and the real miner), not just
# a parsing bug. Poisons every numeric field this file parses - in BOTH the summary and cores replies - with
# the SAME payload and confirms no command it contains ever runs (no file created) and the poll still completes
# promptly with a safe, bounded result rather than hanging or crashing.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PORT=$((PORT + 1)); export BLOX_API_PORT=$PORT
PAYLOAD="a[\$(touch $T/pwned)]"
SUM_EVIL="NAME=bloxminer;VER=2.1.0;API=1.9;ALGO=verus;GPUS=1;KHS=$PAYLOAD;SOLV=0;ACC=$PAYLOAD;REJ=$PAYLOAD;ACCMN=1.0;DIFF=1;NETKHS=0;POOLS=1;WAIT=0;UPTIME=$PAYLOAD;TS=1;LASTWORK=5;STALL=$PAYLOAD;FRESHKHS=$PAYLOAD;POWER=$PAYLOAD;TEMP=$PAYLOAD;CORES=2;ENGINE=ccminer-3.8.3|"
CORES_EVIL="GEN=$PAYLOAD;AGE=$PAYLOAD;ROWS=$PAYLOAD;THREADS=4/4;PERCORE=$PAYLOAD;STALL=$PAYLOAD|ROW=$PAYLOAD;PKG=$PAYLOAD;CORE=$PAYLOAD;CPUS=$PAYLOAD;KHS=$PAYLOAD;TEMP=$PAYLOAD;SRC=ccd|"
jq -n --arg s "$SUM_EVIL" --arg c "$CORES_EVIL" '{summary: $s, cores: $c}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!; ALL_API_PIDS+=("$API_PID")
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
rm -f "$T/pwned"
t0=$(date +%s.%N)
# shellcheck disable=SC2016   # expanded by the inner bash, not here
res=$(timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>"$T/evil_stderr.log")
t1=$(date +%s.%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
if [[ ! -e $T/pwned ]] && [[ $res == "khs=[0]" ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.5)}'; then
	ok "arithmetic-injection payload in every numeric field: no command executed, poll completes safely (${elapsed}s)"
else
	bad "arithmetic-injection payload in every numeric field: no command executed, poll completes safely" \
		"elapsed=${elapsed}s res=$res pwned_exists=$([[ -e $T/pwned ]] && echo yes || echo no)"
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
