#!/usr/bin/env bash
# Companion to tests/hive/test_rx_under_load.sh: the same "does the collector still answer honestly and inside
# budget when every CPU in a small cpuset is fully saturated" question, for the VERUS engine's own h-stats.sh
# (bloxminer/engines/verus/h-stats.sh) and the top-level dispatcher (bloxminer/h-stats.sh) that sources it -
# see PR #2 finding 1, which asked both engines (and the dispatcher) be measured, not just rx. Before this test
# was added, verus's h-stats.sh had NO setsid/timeout-wrapped child and no overall kill: every field it reads
# goes through `field()` (tr+grep+cut, three forks per call), and on a rig with many physical cores (one row
# per core) the per-row parsing loop runs `field()` several times per row - with nothing bounding that loop
# once the two `nc` calls themselves returned (only they had their own deadline-derived cap). This test's
# taskset -c 0 case reproduced 8+ s runs with no result at all before the fix; verus/h-stats.sh now uses the
# exact same budgeted, killable-child pattern as the RandomX engine's own h-stats.sh (see that file's header).
# This test stays as the regression guard for that fix, at a realistic 16-row/32-thread reply size.
# Usage: tests/hive/test_verus_under_load.sh (needs jq, nc, timeout, python3, bash, nproc, taskset)
set -u
# Serialize against any OTHER CPU-saturating load test (this file, or the RandomX engine's own
# test_rx_under_load.sh) already running - anywhere, any user, on this same host: see that file's own header
# for the full rationale. Same well-known lock file, so either engine's load test excludes the other too.
exec 9>"${TMPDIR:-/tmp}/bloxminer-load-test.lock"
flock -w 600 9 || { echo "SKIP: could not acquire the shared load-test lock within 600s (stuck holder?)"; exit 0; }
HERE=$(cd "$(dirname "$0")" && pwd)
PKGSRC=$(cd "$HERE/../../bloxminer/engines/verus" && pwd)
TOPSRC=$(cd "$HERE/../../bloxminer" && pwd)
MANIFEST_SRC="$TOPSRC/h-manifest.conf"
T=$(mktemp -d)
BUSY_PIDS=()
API_PID=""; API3_PID=""   # backstop only - both are already killed inline right after their own case finishes;
	# the trap exists so an abnormal exit mid-case can never leave either running (pids only, never a pattern -
	# 127.0.0.1:20015 is permanently held by another, lead-owned process on shared build hosts)
cleanup() {
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	[[ -n $API_PID ]] && kill -9 "$API_PID" 2>/dev/null
	[[ -n $API3_PID ]] && kill -9 "$API3_PID" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }

HAVE_TASKSET=1; command -v taskset > /dev/null 2>&1 || HAVE_TASKSET=0

saturate_cpus() {   # $1 = cpuset ("" = whatever this process is already confined to) - n busy loops per CPU
	local n; n=$(nproc)
	BUSY_PIDS=()
	for _ in $(seq 1 "$n"); do
		if [[ -n ${1:-} && $HAVE_TASKSET == 1 ]]; then
			taskset -c "$1" sh -c 'while :; do :; done' &
		else
			sh -c 'while :; do :; done' &
		fi
		BUSY_PIDS+=("$!")
	done
}
stop_saturating() { for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done; wait "${BUSY_PIDS[@]}" 2>/dev/null; BUSY_PIDS=(); }

# ---- fixtures: 16 physical cores / 32 threads, per-core rows (the CCD-style reply test_verus_hive_scripts.sh
# already exercises for correctness) - built here at a realistic size for a load measurement.
BLOX_DIR="$T/pkg"; mkdir -p "$BLOX_DIR" "$T/log"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer#" "$MANIFEST_SRC" > "$BLOX_DIR/h-manifest.conf"
jq -n '{threads: 32}' > "$T/config.json"

SUM_OK='NAME=bloxminer;VER=3.0.0;API=1.9;ALGO=verus;GPUS=1;KHS=800000.00;SOLV=0;ACC=150;REJ=2;ACCMN=1.0;DIFF=1;NETKHS=0;POOLS=1;WAIT=0;UPTIME=3210;TS=1;LASTWORK=5;STALL=0;FRESHKHS=799500.00;POWER=136;TEMP=64;CORES=16;ENGINE=ccminer-3.8.3|'
CORES_OK="GEN=9;AGE=1.2;ROWS=16;THREADS=32/32;PERCORE=1;STALL=0|"
for c in $(seq 0 15); do
	CORES_OK+="ROW=$c;PKG=0;CORE=$c;CPUS=$((c*2)),$((c*2+1));KHS=50000.00;TEMP=61;SRC=ccd|"
done

run_case() {   # $1 label, $2 cpuset ("" = none/whatever inherited), $3 n_polls, $4 enforce_budget (1/0, default 1),
               # $5 min_duration_s (0 = poll-count-bounded, default; >0 = keep polling past $3 until this many
               # seconds of WALL time have elapsed since saturation started - for a genuinely sustained run)
	local label=$1 cpuset=$2 n=$3 enforce_budget=${4:-1} min_duration=${5:-0}
	kill "${API_PID:-}" 2>/dev/null; wait "${API_PID:-}" 2>/dev/null
	PORT=$((20000 + RANDOM % 20000)); export BLOX_API_PORT=$PORT
	jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies.json"
	: > "$T/api.out"
	python3 "$HERE/fake_api.py" "$PORT" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
	for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
	grep -q ready "$T/api.out" || { bad "$label: fake API startup" "$(cat "$T/api.out" 2>/dev/null)"; return; }
	# "ready" (printed right after bind()+listen()) only confirms the LISTENING socket exists, never that the
	# server's own accept() loop has actually run yet - a request that lands in that gap can go unanswered
	# long enough to look like a startup failure, purely a fake-server race with nothing to do with h-stats.sh
	# itself (test_rx_hive_scripts.sh's own stats_case() hit the HTTP-side version of this exact race and added
	# this exact round-trip confirmation loop for it). Confirm a REAL command/response round-trip before this
	# case's saturated polling loop ever depends on this port.
	for _ in $(seq 20); do [[ $(echo -n summary | timeout 1 nc 127.0.0.1 "$PORT" 2>/dev/null | tr -d '\0') == "$SUM_OK" ]] && break; sleep 0.05; done

	# a FRESH BLOX_DIR per case - not load-bearing for correctness any more (verus/h-stats.sh keeps no
	# cross-poll state at all post-redesign), but kept for the same isolation tests/hive/test_rx_under_load.sh
	# uses ($T/pkg, $T/pkg2, ...): each case gets its own log dir so concurrent/back-to-back cases never trip
	# over each other's log files.
	local case_dir
	case_dir="$T/case-$(tr -c 'a-zA-Z0-9' '_' <<< "$label")"
	mkdir -p "$case_dir"
	cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$case_dir"/
	cp "$BLOX_DIR/h-manifest.conf" "$case_dir/h-manifest.conf"
	local BLOX_DIR=$case_dir
	export BLOX_DIR

	# No warm-up poll: the redesign (Codex blocker #4) removed verus's positive-khs cache entirely - Phase A
	# does one bounded `nc` round-trip to the SAME summary/cores API every single poll, fresh, with no
	# cross-poll state of any kind. There is nothing left to "seed", so every poll below - including the very
	# first one, saturated from the start - is a genuine cold start by construction. A prior version of this
	# test ran one warm-up poll before saturating, to seed a last-known-good cache sample; that hid exactly the
	# cold-start-under-load failure mode Codex's review called out, so it is gone, not merely disabled.
	saturate_cpus "$cpuset"; sleep 0.3
	local n_zero=0 n_over=0 n_hardfail=0 max_elapsed=0 i=0 t0 t1 elapsed res khs run_start
	local hard_cap=4.0   # PR #2 follow-up (Codex): budget (3.0s) + a generous fixed 1.0s tolerance for
		# legitimate scheduling jitter - never relaxed by the 90% soft-tolerance counter below. See
		# test_rx_under_load.sh's own HARD_CAP comment for the full rationale (the bug this guards against:
		# still_running's own fork-heavy liveness probe delaying the deadline check itself under CPU
		# starvation). Only checked when $enforce_budget is set - same scoping as the soft tolerance.
	run_start=$(date +%s.%N)
	while :; do
		i=$((i+1))
		t0=$(date +%s.%N)
		if [[ -n $cpuset && $HAVE_TASKSET == 1 ]]; then
			# shellcheck disable=SC2016
			res=$(timeout 8 taskset -c "$cpuset" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
		else
			# shellcheck disable=SC2016
			res=$(timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
		fi
		t1=$(date +%s.%N)
		elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
		khs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
		awk -v k="${khs:-0}" 'BEGIN{exit !(k>0)}' || { n_zero=$((n_zero+1)); echo "  $label poll $i: ZERO khs ($res)"; }
		awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' || { n_over=$((n_over+1)); echo "  $label poll $i: OVER BUDGET (${elapsed}s)"; }
		(( enforce_budget )) && { awk -v e="$elapsed" -v c="$hard_cap" 'BEGIN{exit !(e > c)}' && { n_hardfail=$((n_hardfail+1)); echo "  $label poll $i: HARD CAP EXCEEDED (${elapsed}s > ${hard_cap}s)"; }; }
		awk -v e="$elapsed" -v m="$max_elapsed" 'BEGIN{exit !(e > m)}' && max_elapsed=$elapsed
		(( i >= n )) || continue
		(( min_duration == 0 )) && break
		awk -v s="$run_start" -v now="$(date +%s.%N)" -v d="$min_duration" 'BEGIN{exit !(now - s >= d)}' && break
	done
	stop_saturating
	# The hard safety requirement (PR #2 finding 1) is NO FALSE ZEROS - a real Hive watchdog reboots a rig on
	# repeated zero-hashrate polls, never on a single slow-but-honest one. The documented triggers on a real
	# rig (cask10, see the project ledger) are WD_MINER=10 min (miner restart) and WD_REBOOT=21 min (reboot) of
	# SUSTAINED zero hashrate - an occasional poll running a couple of seconds past its own internal budget,
	# under this test's deliberately extreme 1-2 CPU vs. 24-competing-loop squeeze, is not in the same universe
	# as either trigger as long as it is never a false zero. Staying under the nominal 3.0 s budget is
	# additionally enforced from 3 CPUs up (Codex's own reported reproduction, and a realistic floor for a rig
	# actually mining many threads); at 1-2 CPUs the collector's own bounded work (now ONE absolute deadline,
	# no cache/probe path left to escape it) can still occasionally run past 3.0 s under signal-delivery/
	# scheduling delay alone - it never produces a false zero even there, which is what actually protects the
	# rig from a reboot.
	local wall; wall=$(awk -v s="$run_start" -v now="$(date +%s.%N)" 'BEGIN{printf "%.0f", now - s}')
	# Budget compliance (from 3 CPUs up) requires at least 90% of polls (rounded so even a 10-poll run keeps
	# ONE poll of slack) within 3.0 s, not literally every single one - a lone transient overrun from
	# scheduling/signal-delivery noise this host did not cause (another process entirely, a kernel hiccup) is
	# not the same thing as a real regression, and this suite must never report the difference as a failure.
	# ZERO false zeros is never relaxed, at any tier, under any amount of noise - that is the actual property
	# a real Hive rig's watchdog cares about, and is exactly what the tolerance above must never be allowed to
	# paper over. Neither is $n_hardfail (when budget is enforced at all) - the 90% counter is a STATISTICAL
	# tolerance for jitter, never a licence for a single poll to run arbitrarily long.
	local n_ok=$((i - n_over)) n_need=0
	((enforce_budget)) && n_need=$(( (i * 9 + 9) / 10 ))   # ceil(90% of i)
	if [[ $n_zero == 0 && $n_hardfail == 0 ]] && (( ! enforce_budget || n_ok >= n_need )); then
		ok "$label ($i polls over ${wall}s, 16-row/32-thread reply): no false zeros$( ((enforce_budget)) && echo ", $n_ok/$i under 3.0 s (need >= $n_need/$i)" ) (max ${max_elapsed}s, n_over=$n_over)"
	else
		bad "$label ($i polls over ${wall}s): no false zeros, $( ((enforce_budget)) && echo "$n_ok/$i under budget (need >= $n_need/$i), 0 hard-cap failures" )" "n_zero=$n_zero n_over=$n_over n_hardfail=$n_hardfail max=${max_elapsed}s"
	fi
}

NPROC=$(nproc)
run_case "verus engine h-stats.sh, unconstrained CPUs" "" 20
if [[ $HAVE_TASKSET == 1 ]]; then
	for want in 1 2 3; do
		(( want <= NPROC )) || continue
		hi=$((want - 1))
		eb=1; (( want < 3 )) && eb=0   # budget enforced from 3 CPUs up - see run_case's own comment
		run_case "verus engine h-stats.sh, taskset 0-$hi ($want CPU(s))" "0-$hi" 10 "$eb"
	done
	# ---- sustained: Codex blocker #4 asked for a >90 s run, not just a handful of polls, to guard against a
	# failure mode that only shows up over time (a leak, a slow state drift) that a 10-poll burst could miss.
	# 2 CPUs against 24 competing busy loops (the same squeeze as the taskset-0-1 case above, budget not
	# enforced there either) run continuously for at least 90 s of wall time - well past both real Hive
	# watchdog triggers' own polling cadence, with zero cross-poll state to drift in the first place post-
	# redesign, so this is really proving "no false zero, ever, however long this runs", not "state survives".
	(( NPROC >= 2 )) && run_case "verus engine h-stats.sh, taskset 0-1 (2 CPU(s), sustained)" "0-1" 1 0 95
else
	echo "SKIP: taskset not available - only the unconstrained case above ran"
fi

kill "${API_PID:-}" 2>/dev/null; wait "${API_PID:-}" 2>/dev/null

# ---- top-level dispatcher (bloxminer/h-stats.sh sourcing the verus engine) under a small cpuset - proves the
# dispatcher's own engine-selection overhead (h-common.sh, engine_from_config) adds no meaningful cost on top
# of the engine's own collection measured above.
BLOX_DIR3="$T/pkg3"; mkdir -p "$BLOX_DIR3" "$T/log3"
cp -r "$TOPSRC"/* "$BLOX_DIR3/"
chmod +x "$BLOX_DIR3"/*.sh "$BLOX_DIR3"/engines/*/*.sh
CONF3="$T/config3.json"
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$CONF3#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log3/bloxminer#" "$MANIFEST_SRC" > "$BLOX_DIR3/h-manifest.conf"
jq -n '{algo: "verus", threads: 32}' > "$CONF3"   # "algo":"verus" is engine_from_config's own verus marker -
	# without it the dispatcher never even reaches the verus engine's h-stats.sh (see h-common.sh)
PORT=$((20000 + RANDOM % 20000)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies3.json"
: > "$T/api3.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies3.json" > "$T/api3.out" 2>&1 & API3_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api3.out" && break; sleep 0.1; done
grep -q ready "$T/api3.out" || bad "dispatcher: fake API startup" "$(cat "$T/api3.out" 2>/dev/null)"
# see run_case()'s own comment for the full rationale - "ready" alone does not prove a real round-trip works
for _ in $(seq 20); do [[ $(echo -n summary | timeout 1 nc 127.0.0.1 "$PORT" 2>/dev/null | tr -d '\0') == "$SUM_OK" ]] && break; sleep 0.05; done
export BLOX_DIR="$BLOX_DIR3"

run_dispatcher_case() {   # $1 cpuset ("" = none), $2 n_polls, $3 enforce_budget (1/0)
	local cpuset=$1 n=$2 enforce_budget=$3
	saturate_cpus "$cpuset"; sleep 0.3
	local n_zero=0 n_over=0 n_hardfail=0 max_elapsed=0 i t0 t1 elapsed khs
	local hard_cap=4.0   # see run_case()'s own comment for the full rationale - never relaxed by the 90%
		# soft-tolerance counter below, only checked when $enforce_budget is set.
	for i in $(seq 1 "$n"); do
		t0=$(date +%s.%N)
		if [[ -n $cpuset ]]; then
			# shellcheck disable=SC2016
			res=$(timeout 8 taskset -c "$cpuset" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
		else
			# shellcheck disable=SC2016
			res=$(timeout 8 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
		fi
		t1=$(date +%s.%N)
		elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
		khs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
		awk -v k="${khs:-0}" 'BEGIN{exit !(k>0)}' || { n_zero=$((n_zero+1)); echo "  dispatcher poll $i: ZERO khs ($res)"; }
		awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' || { n_over=$((n_over+1)); echo "  dispatcher poll $i: OVER BUDGET (${elapsed}s)"; }
		(( enforce_budget )) && { awk -v e="$elapsed" -v c="$hard_cap" 'BEGIN{exit !(e > c)}' && { n_hardfail=$((n_hardfail+1)); echo "  dispatcher poll $i: HARD CAP EXCEEDED (${elapsed}s > ${hard_cap}s)"; }; }
		awk -v e="$elapsed" -v m="$max_elapsed" 'BEGIN{exit !(e > m)}' && max_elapsed=$elapsed
	done
	stop_saturating
	local label="top-level dispatcher h-stats.sh (verus engine, $n polls${cpuset:+, taskset $cpuset})"
	# Same >= 90% budget-compliance tolerance as run_case() above (see its own comment for the full rationale)
	# - ZERO false zeros is never relaxed, and neither is $n_hardfail.
	local n_ok=$((n - n_over)) n_need=0
	((enforce_budget)) && n_need=$(( (n * 9 + 9) / 10 ))
	if [[ $n_zero == 0 && $n_hardfail == 0 ]] && (( ! enforce_budget || n_ok >= n_need )); then
		ok "$label: no false zeros$( ((enforce_budget)) && echo ", $n_ok/$n under 3.0 s (need >= $n_need/$n)" ) (max ${max_elapsed}s, n_over=$n_over)"
	else
		bad "$label: no false zeros, $( ((enforce_budget)) && echo "$n_ok/$n under budget (need >= $n_need/$n), 0 hard-cap failures" )" "n_zero=$n_zero n_over=$n_over n_hardfail=$n_hardfail max=${max_elapsed}s"
	fi
}

run_dispatcher_case "" 20 1
if [[ $HAVE_TASKSET == 1 ]]; then
	# The ENTIRE sourced call through the dispatcher (manifest parsing, engine_from_config, THEN the verus
	# engine's own collection) under small, stressed cpusets (1-3 CPUs) - proves the single absolute deadline
	# (now computed at this TRUE poll entry, before even manifest parsing) bounds the whole thing end-to-end.
	# Budget enforced from 3 CPUs up only, matching the engine-only case's own documented tolerance policy.
	for want in 1 2 3; do
		(( want <= NPROC )) || continue
		hi=$((want - 1))
		eb=1; (( want < 3 )) && eb=0
		run_dispatcher_case "0-$hi" 10 "$eb"
	done
else
	echo "SKIP: taskset not available - dispatcher stressed-cpuset cases skipped"
fi
kill "$API3_PID" 2>/dev/null; wait "$API3_PID" 2>/dev/null

leaked=()
for p in "$API_PID" "$API3_PID"; do [[ -n $p ]] && kill -0 "$p" 2>/dev/null && leaked+=("$p"); done
if [[ ${#leaked[@]} -eq 0 ]]; then
	ok "no leaked fake-API child processes at suite end"
else
	bad "no leaked fake-API child processes at suite end" "still alive: ${leaked[*]}"
	for p in "${leaked[@]}"; do kill -9 "$p" 2>/dev/null; done
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
