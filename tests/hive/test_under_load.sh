#!/usr/bin/env bash
# "Does the collector still answer honestly and inside budget when every CPU in a small cpuset is fully
# saturated?" for bloxminer/h-stats.sh. Before the 2.1.1 redesign, h-stats.sh had NO setsid/timeout-wrapped
# child and no overall kill: every field it read went through field() (tr+grep+cut, three forks per call), and
# on a rig with many physical cores (one row per core) the per-row parsing loop ran field() several times per
# row - with nothing bounding that loop once the two `nc` calls themselves returned (only they had their own
# deadline-derived cap). This test's taskset -c 0 case reproduced 8+ s runs with no result at all before the
# fix; h-stats.sh now uses a budgeted, killable-child pattern instead. This test stays as the regression guard
# for that fix, at a realistic 16-row/32-thread reply size.
#
# LOAD MODEL (host-independent by design): each taskset-constrained tier launches LOAD_K busy loops PER CPU IN
# THAT TIER, all pinned to that exact cpuset - NOT `nproc` loops regardless of tier size. The old "nproc loops,
# all pinned to the tested CPUs" model made severity scale with the HOST's total core count, not the tier being
# tested: on a 24-core box the "1 CPU" tier was a 24x squeeze, on a 2-4 vCPU GitHub runner the same tier was
# only 2-4x - neither one is a stand-in for a real Hive rig, where every core runs roughly ONE miner thread at
# normal scheduling priority, not an arbitrary multiple of unrelated competing processes. LOAD_K=4 (~4x a real
# rig's own per-core pressure - a deliberate margin above normal operation, not a worst-case-imaginable value)
# applies identically to every taskset tier, so severity depends only on how many CPUs that tier constrains to,
# never on the host running this suite. Overridable via BLOX_LOAD_K for a one-off stress comparison (e.g.
# BLOX_LOAD_K=24 reproduces the OLD per-core harshness on today's 24-core ai02, as information only - the
# suite's own pass/fail bar, zero false zeros and the hard cap, is never loosened regardless of K).
# Usage: tests/hive/test_under_load.sh (needs jq, nc, timeout, python3, bash, nproc, taskset)
set -u
LOAD_K=${BLOX_LOAD_K:-4}
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
# Idempotent (safe to call more than once): every `kill -9` targets a pid that may already be dead/reaped
# (silently fails under 2>/dev/null), and `rm -rf` on an already-removed $T is a no-op. That matters now that
# INT/TERM each call this AND THEN exit (which fires the EXIT trap too, a second call to the SAME function) -
# see the three traps below.
cleanup() {
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	[[ -n $API_PID ]] && kill -9 "$API_PID" 2>/dev/null
	[[ -n ${API_WF_PID:-} ]] && kill -9 "$API_WF_PID" 2>/dev/null
	[[ -n ${API_WD_PID:-} ]] && kill -9 "$API_WD_PID" 2>/dev/null
	rm -rf "$T"
}
# P2 (bot finding): a single `trap cleanup EXIT INT TERM` with no explicit `exit` runs cleanup on a real INT/
# TERM and then RETURNS to wherever the script was interrupted - the suite keeps running afterward against
# fixtures cleanup() just deleted, and could even start NEW busy loops (saturate_cpus()) on top of whatever
# this trap just killed. EXIT stays cleanup-only (it fires exactly once, at the point this script is already
# ending, by whatever means); INT/TERM each call cleanup THEN exit with the conventional 128+signal code
# (130/143) so the process actually terminates instead of resuming.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }

HAVE_TASKSET=1; command -v taskset > /dev/null 2>&1 || HAVE_TASKSET=0

# ---- P2 (bot finding): the taskset tiers below used to be built as "0-$((want-1))" - CPU IDs 0..want-1,
# assuming this process's own affinity starts at CPU 0 and is contiguous. That breaks wherever it is not: this
# suite itself run under a restricted affinity (e.g. `taskset -c 2-4 bash tests/hive/test_under_load.sh`, the
# bot's own review environment, or any container with a sparse/non-zero-based --cpuset-cpus) can be denied CPU
# 0 entirely - `taskset -c 0 ...` then simply fails (EINVAL: you cannot widen your own affinity), not "runs on
# a different CPU than intended". Fixed: $AVAIL_CPUS holds THIS process's own real, current affinity (parsed
# from /proc/self/status's Cpus_allowed_list, falling back to `taskset -pc $$`'s own output if that proc field
# is ever unavailable) - every tier below asks cpu_tier() for its CPU IDs from THAT list, never assumes 0..N-1,
# and SKIPs (not fails) a tier that needs more CPUs than are actually available to pin to.
AVAIL_CPUS=()
cpu_list_expand() {   # $1 = "2-4,7,9-10" style list (as /proc/self/status or taskset -pc print it) -> appends
	# each individual CPU number it names to $AVAIL_CPUS. Malformed tokens are skipped, not fatal - an empty
	# $AVAIL_CPUS afterward is exactly what every cpu_tier() call below already treats as "not enough CPUs,
	# SKIP this tier", never a hard error.
	local tok lo hi c toks
	IFS=',' read -ra toks <<< "$1"
	for tok in "${toks[@]}"; do
		[[ -z $tok ]] && continue
		if [[ $tok == *-* ]]; then
			lo=${tok%-*}; hi=${tok#*-}
			[[ $lo =~ ^[0-9]+$ && $hi =~ ^[0-9]+$ ]] || continue
			for ((c = lo; c <= hi; c++)); do AVAIL_CPUS+=("$c"); done
		elif [[ $tok =~ ^[0-9]+$ ]]; then
			AVAIL_CPUS+=("$tok")
		fi
	done
}
if [[ -r /proc/self/status ]]; then
	cpus_line=$(awk -F'\t' '/^Cpus_allowed_list:/{print $2}' /proc/self/status 2>/dev/null)
	[[ -n ${cpus_line:-} ]] && cpu_list_expand "$cpus_line"
fi
if [[ ${#AVAIL_CPUS[@]} -eq 0 && $HAVE_TASKSET == 1 ]]; then
	cpus_line=$(taskset -pc $$ 2>/dev/null | sed -n 's/.*affinity list: *//p')
	[[ -n ${cpus_line:-} ]] && cpu_list_expand "$cpus_line"
fi
if [[ ${#AVAIL_CPUS[@]} -gt 0 ]]; then
	mapfile -t AVAIL_CPUS < <(printf '%s\n' "${AVAIL_CPUS[@]}" | sort -nu)   # ascending, deduped
fi

cpu_tier() {   # $1 = how many CPUs this tier needs -> sets $REPLY to a taskset -c argument (a comma-separated
	# list, which taskset accepts exactly as well as a contiguous range and handles non-contiguous sets
	# correctly) built from the FIRST $1 entries of $AVAIL_CPUS. Returns 1 (REPLY left empty) when fewer than
	# $1 CPUs are actually available in THIS process's own affinity - the caller's job to SKIP that tier, never
	# this function's to fail loudly for a perfectly legitimate "this host doesn't have that many CPUs for us"
	# case.
	local n=$1 i
	REPLY=""
	(( ${#AVAIL_CPUS[@]} >= n )) || return 1
	for ((i = 0; i < n; i++)); do REPLY+="${AVAIL_CPUS[i]},"; done
	REPLY=${REPLY%,}
}

saturate_cpus() {   # $1 = cpuset ("" = unconstrained, representing a generally busy host - `nproc` loops
	# system-wide, NOT scaled by LOAD_K: that is not a "taskset tier" in the host-independent sense this file's
	# own header explains, it is a separate "the whole box is busy" baseline). A real cpuset - a contiguous
	# range ("0-2"), a comma list ("2,4,7" - what cpu_tier() above actually hands this, possibly
	# non-contiguous), or a single CPU ("3", no "-" or ",") - launches LOAD_K busy loops PER CPU named in that
	# cpuset - never `nproc` loops regardless of how many CPUs the tier itself constrains to.
	local n ncpus=0 tok lo hi toks
	if [[ -n ${1:-} && $HAVE_TASKSET == 1 ]]; then
		IFS=',' read -ra toks <<< "$1"
		for tok in "${toks[@]}"; do
			if [[ $tok == *-* ]]; then lo=${tok%-*}; hi=${tok#*-}; ncpus=$(( ncpus + hi - lo + 1 ))
			else ncpus=$(( ncpus + 1 )); fi
		done
		n=$(( LOAD_K * ncpus ))
	else
		n=$(nproc)
	fi
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
	# poll running a couple of seconds past its own internal budget, under this test's LOAD_K-per-CPU squeeze
	# (margin above a real rig's own per-core pressure, deliberately, not a worst-case-imaginable value), is not
	# in the same universe as either trigger as long as it is never a false zero. Staying under the nominal
	# 3.0 s budget is additionally enforced from 3 CPUs up (a realistic
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

run_case "h-stats.sh, unconstrained CPUs" "" 20
if [[ $HAVE_TASKSET == 1 ]]; then
	for want in 1 2 3; do
		if ! cpu_tier "$want"; then
			echo "SKIP: h-stats.sh, $want CPU(s) - fewer than $want CPUs available in this process's own affinity (${#AVAIL_CPUS[@]} available)"
			continue
		fi
		eb=1; (( want < 3 )) && eb=0   # budget enforced from 3 CPUs up - see run_case's own comment
		run_case "h-stats.sh, taskset $REPLY ($want CPU(s))" "$REPLY" 10 "$eb"
	done
	# ---- sustained: a >90 s run, not just a handful of polls, to guard against a failure mode that only shows
	# up over time (a leak, a slow state drift) that a 10-poll burst could miss. 2 CPUs against LOAD_K*2 busy
	# loops (the same squeeze as the 2-CPU tier above, budget not enforced there either) run continuously for
	# at least 90 s of wall time - well past both real Hive watchdog triggers' own polling cadence, with zero
	# cross-poll state to drift in the first place post-redesign, so this is really proving "no false zero,
	# ever, however long this runs", not "state survives".
	if cpu_tier 2; then
		run_case "h-stats.sh, taskset $REPLY (2 CPU(s), sustained)" "$REPLY" 1 0 95
	else
		echo "SKIP: h-stats.sh, 2 CPU(s) sustained - fewer than 2 CPUs available in this process's own affinity (${#AVAIL_CPUS[@]} available)"
	fi
else
	echo "SKIP: taskset not available - only the unconstrained case above ran"
fi

kill "${API_PID:-}" 2>/dev/null; wait "${API_PID:-}" 2>/dev/null

# ================================================================== WAITFIFO regression: the parent's own
# bounded wait (wait_secs(), via `read -t 0.05 -u $waitfd`) must never hang even when the collector child
# exits WHILE that read is in progress. Ported proactively from bloxminer-x (commits a73c80a/751cac1): a real
# GitHub CI run there (2-vCPU) captured a poll where the read was entered ~50ms before the collector child's
# own exit - almost exactly when the read's own timeout and the exit were due to land together - and never
# returned at all; the external `timeout 5` had to kill the whole run at 5.14s. Many FAST, healthy polls
# back-to-back (no artificial delay, no saturation) each complete in well under a second but still pass
# through a handful of the poll loop's own 50ms wait_secs() ticks - across enough iterations, naturally-
# varying poll-to-poll jitter lands the child's own exit at many different phase offsets relative to those
# ticks, including right on top of one, without needing to hand-engineer the exact timing.
PORT=$((20000 + RANDOM % 20000)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies_wf.json"
: > "$T/api_wf.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies_wf.json" > "$T/api_wf.out" 2>&1 & API_WF_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api_wf.out" && break; sleep 0.1; done
grep -q ready "$T/api_wf.out" || bad "WAITFIFO regression: fake API startup" "$(cat "$T/api_wf.out" 2>/dev/null)"
WF_DIR="$T/case-waitfifo"; mkdir -p "$WF_DIR"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$WF_DIR"/
cp "$BLOX_DIR/h-manifest.conf" "$WF_DIR/h-manifest.conf"
export BLOX_DIR="$WF_DIR"
N_POLLS_WF=100; HARD_CAP_WF=4.0
n_bad_wf=0; max_wf=0
for i in $(seq 1 "$N_POLLS_WF"); do
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016   # $BLOX_DIR/$khs expand in the inner bash -c, not here
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
	awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || { n_bad_wf=$((n_bad_wf+1)); echo "  poll $i: ZERO khs ($res)"; }
	awk -v e="$elapsed" -v c="$HARD_CAP_WF" 'BEGIN{exit !(e > c)}' && { n_bad_wf=$((n_bad_wf+1)); echo "  poll $i: HARD CAP EXCEEDED (${elapsed}s > ${HARD_CAP_WF}s)"; }
	awk -v e="$elapsed" -v m="$max_wf" 'BEGIN{exit !(e > m)}' && max_wf=$elapsed
done
if (( n_bad_wf == 0 )); then
	ok "WAITFIFO regression: $N_POLLS_WF fast back-to-back polls, child exit races the poll loop's own wait - no hang, max ${max_wf}s"
else
	bad "WAITFIFO regression: $N_POLLS_WF fast back-to-back polls, child exit races the poll loop's own wait - no hang" \
		"n_bad=$n_bad_wf/$N_POLLS_WF max=${max_wf}s"
fi
kill "$API_WF_PID" 2>/dev/null; wait "$API_WF_PID" 2>/dev/null

# ================================================================== WATCHDOG overhead on the NORMAL (healthy,
# instant-reply, no escalation) path - the WATCHDOG adds one extra fork (itself) plus two further, sequential
# forks of its own (`sleep`, never both alive at once) to EVERY poll, win or lose, not just the escalated ones
# the SIGTERM-ignoring-child tests already cover - this is the overhead's cost on the common case, where it
# should never be visible in the result. Reuses the SAME fixture as the WAITFIFO regression case above
# (healthy, instant, no delay/escalation anywhere in this path); 20 polls, each its own fresh `bash -c`
# process, average AND max reported explicitly so a before/after comparison against a pre-WATCHDOG checkout
# is just a diff of two log lines, not a re-run with different instrumentation.
PORT=$((20000 + RANDOM % 20000)); export BLOX_API_PORT=$PORT
jq -n --arg s "$SUM_OK" --arg c "$CORES_OK" '{summary: $s, cores: $c}' > "$T/replies_wd.json"
: > "$T/api_wd.out"
python3 "$HERE/fake_api.py" "$PORT" "$T/replies_wd.json" > "$T/api_wd.out" 2>&1 & API_WD_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api_wd.out" && break; sleep 0.1; done
grep -q ready "$T/api_wd.out" || bad "WATCHDOG overhead: fake API startup" "$(cat "$T/api_wd.out" 2>/dev/null)"
N_POLLS_WD=20; HARD_CAP_WD=3.0
n_bad_wd=0; max_wd=0; sum_wd=0
for i in $(seq 1 "$N_POLLS_WD"); do
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016   # $BLOX_DIR/$khs expand in the inner bash -c, not here
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b - a}')
	pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
	awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || { n_bad_wd=$((n_bad_wd+1)); echo "  poll $i: ZERO khs ($res)"; }
	awk -v e="$elapsed" -v c="$HARD_CAP_WD" 'BEGIN{exit !(e > c)}' && { n_bad_wd=$((n_bad_wd+1)); echo "  poll $i: OVER BUDGET (${elapsed}s)"; }
	awk -v e="$elapsed" -v m="$max_wd" 'BEGIN{exit !(e > m)}' && max_wd=$elapsed
	sum_wd=$(awk -v s="$sum_wd" -v e="$elapsed" 'BEGIN{printf "%.3f", s + e}')
done
avg_wd=$(awk -v s="$sum_wd" -v n="$N_POLLS_WD" 'BEGIN{printf "%.3f", s / n}')
if (( n_bad_wd == 0 )); then
	ok "WATCHDOG overhead, normal path: $N_POLLS_WD polls, avg ${avg_wd}s, max ${max_wd}s, all khs>0 and < ${HARD_CAP_WD}s"
else
	bad "WATCHDOG overhead, normal path: $N_POLLS_WD polls, all khs>0 and < ${HARD_CAP_WD}s" "n_bad=$n_bad_wd/$N_POLLS_WD avg=${avg_wd}s max=${max_wd}s"
fi
kill "$API_WD_PID" 2>/dev/null; wait "$API_WD_PID" 2>/dev/null

leaked=()
[[ -n $API_PID ]] && kill -0 "$API_PID" 2>/dev/null && leaked+=("$API_PID")
[[ -n ${API_WF_PID:-} ]] && kill -0 "$API_WF_PID" 2>/dev/null && leaked+=("$API_WF_PID")
[[ -n ${API_WD_PID:-} ]] && kill -0 "$API_WD_PID" 2>/dev/null && leaked+=("$API_WD_PID")
if [[ ${#leaked[@]} -eq 0 ]]; then
	ok "no leaked fake-API child processes at suite end"
else
	bad "no leaked fake-API child processes at suite end" "still alive: ${leaked[*]}"
	for p in "${leaked[@]}"; do kill -9 "$p" 2>/dev/null; done
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
