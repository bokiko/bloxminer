#!/usr/bin/env bash
# Option and config parsing checks against a built binary: bad values are rejected with a message before any
# thread starts; good values (including legitimate fractional ones) start the miner.
# Usage: tests/cli_test.sh /path/to/bloxminer
set -u
BIN=$1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
POOL=(-o stratum+tcp://127.0.0.1:9 -u test.worker -p x -b 0 --no-dashboard)

run() { timeout 4 "$BIN" "$@" </dev/null 2>&1; }

expect() {  # name, expected substring, args...
	local name=$1 want=$2; shift 2
	local out; out=$(run "$@")
	if grep -qF -- "$want" <<< "$out" && ! grep -qE "AddressSanitizer|runtime error:" <<< "$out"; then
		pass=$((pass+1)); printf '%-40s ok\n' "$name"
	else
		fail=$((fail+1)); printf '%-40s FAIL (want: %s)\n' "$name" "$want"; tail -3 <<< "$out" | sed 's/^/    | /'
	fi
}

cfg() { printf '%s' "$1" > "$T/c.json"; echo "$T/c.json"; }
BASE='"url":"stratum+tcp://127.0.0.1:9","user":"test.worker","pass":"x","api-bind":"0","no-dashboard":true'

# --- threads on the command line
expect "t=1 starts"                "1 miner thread started"      "${POOL[@]}" -t 1
expect "t=140 starts"              "140 miner threads started"   "${POOL[@]}" -t 140
expect "t=141 rejected"            "threads must be 1..140"      "${POOL[@]}" -t 141
expect "t=0 rejected"              "threads must be 1..140"      "${POOL[@]}" -t 0
expect "t=-5 rejected"             "threads must be 1..140"      "${POOL[@]}" -t -5
expect "t=12abc rejected"          "invalid number '12abc'"      "${POOL[@]}" -t 12abc
expect "t=huge rejected"           "invalid number"              "${POOL[@]}" -t 99999999999999999999
expect "t=empty rejected"          "invalid number"              "${POOL[@]}" -t ""
# --- threads in the config file (JSON int / real / string / huge)
expect "cfg threads 8"             "8 miner threads started"     -c "$(cfg "{$BASE,\"threads\":8}")"
expect "cfg threads 8.0 accepted"  "8 miner threads started"     -c "$(cfg "{$BASE,\"threads\":8.0}")"
expect "cfg threads 12.5 rejected" "invalid number '12.5'"       -c "$(cfg "{$BASE,\"threads\":12.5}")"
expect "cfg threads 1e20 rejected" "invalid number"              -c "$(cfg "{$BASE,\"threads\":1e20}")"
expect "cfg threads huge int"      "invalid number"              -c "$(cfg "{$BASE,\"threads\":9223372036854775807}")"
expect "cfg threads \"abc\""       "invalid number 'abc'"        -c "$(cfg "{$BASE,\"threads\":\"abc\"}")"
expect "cfg threads 141"           "threads must be 1..140"      -c "$(cfg "{$BASE,\"threads\":141}")"
expect "cfg real 1e300 (no crash)" "invalid number"              -c "$(cfg "{$BASE,\"threads\":1e300}")"
# --- conflicting CLI + config: the config file is applied after the command line (upstream ccminer order)
expect "cfg 8 wins over cli t=4"   "8 miner threads started"     -t 4 -c "$(cfg "{$BASE,\"threads\":8}")"
expect "cli t=200 + cfg 8"         "threads must be 1..140"      -t 200 -c "$(cfg "{$BASE,\"threads\":8}")"
# --- algorithm
expect "no -a = verus"             "using 'verus' algorithm"     "${POOL[@]}" -t 1
expect "-a verus"                  "using 'verus' algorithm"     "${POOL[@]}" -t 1 -a verus
expect "-a x11 rejected"           "VerusHash only"              "${POOL[@]}" -t 1 -a x11
expect "cfg algo lbry rejected"    "VerusHash only"              -c "$(cfg "{$BASE,\"threads\":1,\"algo\":\"lbry\"}")"
expect "-a nonsense rejected"      "Unknown algo parameter"      "${POOL[@]}" -t 1 -a nonsense
# --- float options: legitimate fractions work, garbage is rejected
expect "diff-factor 0.5 ok"        "1 miner thread started"      "${POOL[@]}" -t 1 --diff-factor 0.5
expect "diff-factor abc rejected"  "invalid number 'abc'"        "${POOL[@]}" -t 1 --diff-factor abc
expect "diff-factor inf rejected"  "invalid number"              "${POOL[@]}" -t 1 --diff-factor inf
# --- BloxMiner options
expect "ccd-temp-map 2 rejected"   "ccd-temp-map must be auto"   "${POOL[@]}" -t 1 --ccd-temp-map 2
expect "stats-interval -1"         "stats-interval must be"      "${POOL[@]}" -t 1 --stats-interval -1
expect "log-file bad dir (fail open)" "continuing without a log file" "${POOL[@]}" -t 1 --log-file /nonexistent/dir/x.log
expect "--sensors exits"           "Topology"                    --sensors
expect "--version"                 "bloxminer v"                 -V
# --- GPU list options stay bounded (200 entries)
LIST=$(printf '1,%.0s' {1..200})1
expect "-L 201 entries (bounded)"  "1 miner thread started"      "${POOL[@]}" -t 1 -L "$LIST"

# --- header never wider than the terminal (worst-case states rendered by the BLOX_UI_SELFTEST hook)
for cols in 60 80 120; do
	out=$(BLOX_UI_SELFTEST=$cols timeout 10 "$BIN" "${POOL[@]}" -t 1 </dev/null 2>&1)
	widest=$(grep -v '^## ' <<< "$out" | grep '^[+|]' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
	if (( widest > 0 && widest <= cols )) && grep -q "STALLED" <<< "$out" && grep -q "^## starting" <<< "$out"; then
		pass=$((pass+1)); printf '%-40s ok\n' "header fits $cols columns (widest $widest)"
	else
		fail=$((fail+1)); printf '%-40s FAIL (widest %s)\n' "header fits $cols columns" "$widest"; head -12 <<< "$out" | sed 's/^/    | /'
	fi
done
# --- time limit: a normal exit with the time-limit code (0), bounded time, from main()'s own shutdown path
t0=$(date +%s); timeout 60 "$BIN" --benchmark --time-limit 3 -t 1 -b 0 --no-dashboard </dev/null >/dev/null 2>&1; rc=$?; t1=$(date +%s)
if [[ $rc == 0 ]] && (( t1 - t0 < 30 )); then pass=$((pass+1)); printf '%-40s ok\n' "time limit exits 0 ($((t1 - t0)) s)"
else fail=$((fail+1)); printf '%-40s FAIL rc=%s after %ss\n' "time limit exits 0" "$rc" "$((t1 - t0))"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
