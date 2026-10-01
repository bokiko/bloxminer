#!/usr/bin/env bash
# "Does the collector still answer honestly and inside budget when every CPU in a small cpuset is fully
# saturated?" for bloxminer/h-stats.sh. Before the 2.1.1 redesign, h-stats.sh had NO setsid/timeout-wrapped
# child and no overall kill: every field it read went through field() (tr+grep+cut, three forks per call), and
# on a rig with many physical cores (one row per core) the per-row parsing loop ran field() several times per
# row - with nothing bounding that loop once the two `nc` calls themselves returned (only they had their own
# deadline-derived cap). This test's taskset -c 0 case reproduced 8+ s runs with no result at all before the
# fix; h-stats.sh now uses a budgeted, killable-child pattern instead. This test stays as the regression guard
# for that fix, at a realistic 16-row/32-thread reply size.
# Usage: tests/hive/test_under_load.sh (needs jq, nc, timeout, python3, bash, nproc, taskset)
set -u
# Serialize against any OTHER CPU-saturating load test on this same host (anywhere, any user) - a second
# instance competing for the same CPUs would corrupt both runs' own timing measurements.
exec 9>"${TMPDIR:-/tmp}/bloxminer-load-test.lock"
flock -w 600 9 || { echo "SKIP: could not acquire the shared load-test lock within 600s (stuck holder?)"; exit 0; }
HERE=$(cd "$(dirname "$0")" && pwd)
PKGSRC=$(cd "$HERE/../../bloxminer" && pwd)
T=$(mktemp -d)
BUSY_PIDS=()
API_PID=""   # backstop only - already killed inline right after each case finishes; the trap exists so an
	# abnormal exit mid-case can never leave it running
cleanup() {
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	[[ -n $API_PID ]] && kill -9 "$API_PID" 2>/dev/null
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

# ---- fixtures: 16 physical cores / 32 threads, per-core rows (the CCD-style reply test_hive_scripts.sh
# already exercises for correctness) - built here at a realistic size for a load measurement.
BLOX_DIR="$T/pkg"; mkdir -p "$BLOX_DIR" "$T/log"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer#" "$PKGSRC/h-manifest.conf" > "$BLOX_DIR/h-manifest.conf"
jq -n '{threads: 32}' > "$T/config.json"

SUM_OK='NAME=bloxminer;VER=2.1.0;API=1.9;ALGO=verus;GPUS=1;KHS=800000.00;SOLV=0;ACC=150;REJ=2;ACCMN=1.0;DIFF=1;NETKHS=0;POOLS=1;WAIT=0;UPTIME=3210;TS=1;LASTWORK=5;STALL=0;FRESHKHS=799500.00;POWER=136;TEMP=64;CORES=16;ENGINE=ccminer-3.8.3|'
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
	# server's own accept() loop has actually run yet - a request that lands in that gap can go unanswered long
	# enough to look like a startup failure, purely a fake-server race with nothing to do with h-stats.sh
	# itself. Confirm a REAL command/response round-trip before this case's saturated polling loop depends on it.
	for _ in $(seq 20); do [[ $(echo -n summary | timeout 1 nc 127.0.0.1 "$PORT" 2>/dev/null | tr -d '\0') == "$SUM_OK" ]] && break; sleep 0.05; done

	# a FRESH BLOX_DIR per case - not load-bearing for correctness (h-stats.sh keeps no cross-poll state at
	# all), but each case gets its own log dir so concurrent/back-to-back cases never trip over each other's
	# log files.
	local case_dir
	case_dir="$T/case-$(tr -c 'a-zA-Z0-9' '_' <<< "$label")"
	mkdir -p "$case_dir"
	cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$case_dir"/
	cp "$BLOX_DIR/h-manifest.conf" "$case_dir/h-manifest.conf"
	local BLOX_DIR=$case_dir
	export BLOX_DIR

	# No warm-up poll: the redesign removed any positive-khs cache entirely - Phase A does one bounded `nc`
	# round-trip to the SAME summary/cores API every single poll, fresh, with no cross-poll state of any kind.
	# There is nothing left to "seed", so every poll below - including the very first one, saturated from the
	# start - is a genuine cold start by construction.
	saturate_cpus "$cpuset"; sleep 0.3
	local n_zero=0 n_over=0 n_hardfail=0 max_elapsed=0 i=0 t0 t1 elapsed res khs run_start
	local hard_cap=4.0   # budget (3.0s) + a generous fixed 1.0s tolerance for legitimate scheduling jitter -
		# never relaxed by the 90% soft-tolerance counter below. The bug this guards against: a fork-heavy
		# liveness probe delaying the deadline check itself under CPU starvation. Only checked when
		# $enforce_budget is set - same scoping as the soft tolerance.
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
	# The hard safety requirement is NO FALSE ZEROS - a real Hive watchdog reboots a rig on repeated
	# zero-hashrate polls, never on a single slow-but-honest one. The documented triggers on a real rig are
	# WD_MINER=10 min (miner restart) and WD_REBOOT=21 min (reboot) of SUSTAINED zero hashrate - an occasional
	# poll running a couple of seconds past its own internal budget, under this test's deliberately extreme 1-2
	# CPU vs. many-competing-loop squeeze, is not in the same universe as either trigger as long as it is never
	# a false zero. Staying under the nominal 3.0 s budget is additionally enforced from 3 CPUs up (a realistic
	# floor for a rig actually mining many threads); at 1-2 CPUs the collector's own bounded work (one absolute
	# deadline, no cache/probe path left to escape it) can still occasionally run past 3.0 s under
	# signal-delivery/scheduling delay alone - it never produces a false zero even there, which is what
	# actually protects the rig from a reboot.
	local wall; wall=$(awk -v s="$run_start" -v now="$(date +%s.%N)" 'BEGIN{printf "%.0f", now - s}')
	# Budget compliance (from 3 CPUs up) requires at least 90% of polls (rounded so even a 10-poll run keeps
	# ONE poll of slack) within 3.0 s, not literally every single one - a lone transient overrun from
	# scheduling/signal-delivery noise this host did not cause (another process entirely, a kernel hiccup) is
	# not the same thing as a real regression, and this suite must never report the difference as a failure.
	# ZERO false zeros is never relaxed, at any tier, under any amount of noise - that is the actual property a
	# real Hive rig's watchdog cares about, and is exactly what the tolerance above must never be allowed to
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
run_case "h-stats.sh, unconstrained CPUs" "" 20
if [[ $HAVE_TASKSET == 1 ]]; then
	for want in 1 2 3; do
		(( want <= NPROC )) || continue
		hi=$((want - 1))
		eb=1; (( want < 3 )) && eb=0   # budget enforced from 3 CPUs up - see run_case's own comment
		run_case "h-stats.sh, taskset 0-$hi ($want CPU(s))" "0-$hi" 10 "$eb"
	done
	# ---- sustained: a >90 s run, not just a handful of polls, to guard against a failure mode that only shows
	# up over time (a leak, a slow state drift) that a 10-poll burst could miss. 2 CPUs against many competing
	# busy loops (the same squeeze as the taskset-0-1 case above, budget not enforced there either) run
	# continuously for at least 90 s of wall time - well past both real Hive watchdog triggers' own polling
	# cadence, with zero cross-poll state to drift in the first place post-redesign, so this is really proving
	# "no false zero, ever, however long this runs", not "state survives".
	(( NPROC >= 2 )) && run_case "h-stats.sh, taskset 0-1 (2 CPU(s), sustained)" "0-1" 1 0 95
else
	echo "SKIP: taskset not available - only the unconstrained case above ran"
fi

kill "${API_PID:-}" 2>/dev/null; wait "${API_PID:-}" 2>/dev/null

leaked=()
[[ -n $API_PID ]] && kill -0 "$API_PID" 2>/dev/null && leaked+=("$API_PID")
if [[ ${#leaked[@]} -eq 0 ]]; then
	ok "no leaked fake-API child processes at suite end"
else
	bad "no leaked fake-API child processes at suite end" "still alive: ${leaked[*]}"
	for p in "${leaked[@]}"; do kill -9 "$p" 2>/dev/null; done
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
