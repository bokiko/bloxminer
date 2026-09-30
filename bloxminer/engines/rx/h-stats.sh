#!/usr/bin/env bash
# shellcheck disable=SC2034   # khs and stats (set far below) are read by the Hive agent that sources this
	# file - this directive must stay file-level (before any code at all) to cover both, so it moved up here
	# when the deadline fallback block below became the file's first actual statement.
# Sourced by the Hive agent: must set $khs (total kH/s) and $stats (JSON). ONE shared 3.0 s deadline for the
# whole run.
#
# PR #2 review (round 2): an earlier version of this file cached the last positive $khs and served it on a
# missed deadline, keyed by the owning process's pid + its own /proc start time. Codex correctly rejected that:
# process identity proves the SAME xmrig instance is still running, never that it is still HASHING - seed a
# positive sample, then let the miner stall or the API go unreachable while the collector keeps missing its
# deadline (contention alone can do that), and the same pid/start/exe would go on serving a stale positive rate
# for up to the cache's own age bound. Redesign: the hashrate is NEVER cached. Each poll is split into
#   Phase A (mandatory, cheap): ownership check (unchanged) + ONE curl to /2/summary alone. XMRig's own
#     `hashrate.total[0]` there is already the aggregate rate, `connection.accepted/rejected` and `uptime` are
#     right there too - no need for /2/backends just to answer "how fast, right now, honestly". Written to
#     $OUTFILE the moment it is ready, as a single row.
#   Phase B (optional, whatever budget remains): /2/backends + bloxsense + per-core binding verification - a
#     richer per-core (or per-thread) breakdown, still recomputed from data collected THIS SAME poll, never a
#     substitute for Phase A's answer if it does not finish in time. Only a display detail is allowed to age:
#     the single row's temperature, when Phase B does not run this poll, may reuse the last real temperature
#     Phase B measured for this exact xmrig instance (pid + /proc start time), bounded to ENRICH_MAX_AGE_S -
#     never the rate, which is either fresh this poll or 0.
# So a poll's answer is always either genuinely fresh (this exact API call, this exact poll) or the defined 0 -
# there is no cache of the number that actually matters left to reason about an age bound for.
#
# The whole collection still runs inside a single, ONE-absolute-deadline, killable child: a /proc scan on a rig
# with an unusually large process table, or any other step, can never make this script overrun its budget,
# because the whole child is killed outright if it does not finish in time. Both /proc scans (ownership,
# task-mask) do ONE fork total each, regardless of how many fds/tasks exist: `find -lname` and a single `awk`
# do their own comparisons in-process instead of forking readlink/sed per item - a per-item loop here
# previously cost a real rig a hard fallback (~870 fds, all 32 threads mining, budget blown mid-scan under that
# fork load; an idle dev box never showed it).
# That child runs via `setsid`, its own dedicated session/process group, with an explicit TERM-then-KILL
# escalation below targeting that whole group (SIGTERM at 2.4 s, SIGKILL at 2.7 s if that is ignored -
# unmaskable, so nothing outlives it) - plain `timeout` was tried first and found NOT reliable here: when the
# collection nests its own `timeout` call for bloxsense, GNU timeout's own signal only ever reaches its direct
# child, not that nested timeout's descendants, so a bloxsense (or curl) that ignores SIGTERM could survive as
# an orphan after this script returns. `setsid` plus our own `kill -- -$pgid` reaches every descendant, tested.
# That pgid is NEVER read by this script itself via `ps` right after backgrounding the child - immediately
# after fork, the new process can still be running with our OWN (inherited) pgid for a brief window before it
# reaches its own setsid() call, and a group-kill against a pgid read during that window could hit our own
# caller instead of the collection. Instead, the child reports its OWN pgid into a handshake file, written
# only after its setsid has taken effect; a kill is only ever sent to a group when that handshake has arrived
# and reads back exactly the child's own pid, and differs from our own pgid and from 0/1 - anything else,
# including the handshake simply not having arrived yet, signals the child's own pid alone, never a group.
# $OUTFILE is written to DIRECTLY by run() (atomically, tmp+rename) at each phase boundary - never captured
# from the child's stdout - so a kill mid-Phase-B can never erase Phase A's already-written, honest answer;
# read back from a temp file rather than a pipe, so a would-be survivor holding a pipe open can never hang it.
# Inside the child, the remaining time is still recomputed before every step, and each step is additionally
# capped at its own nominal ceiling (curl 0.5 s, bloxsense 1.0 s) so a slow but not-yet-killed step cannot
# starve the ones after it more than necessary.
# Before trusting 127.0.0.1:$API_PORT at all, this checks that the listening socket belongs to OUR xmrig
# (its pid's /proc/<pid>/exe is this package's ./xmrig) - a foreign miner bound to the same port is never read.
# Both API replies are schema-checked before use (object/array shape, numeric affinity, array hashrate) -
# a reply that merely looks like JSON but not like XMRig's own shape is treated the same as no reply. Even a
# schema-valid rate is clamped to 0 if it is not a finite, non-negative number: hs is never negative.
# Rows: one per physical core (SMT threads summed from /2/backends' per-thread affinity + hashrate[0], 10 s
# window) when every thread reports a real affinity to a CPU bloxsense's topology also knows, AND the xmrig
# process's own task list (/proc/<pid>/task/*/status) shows that exact multiset of single-CPU-pinned tasks -
# i.e. the binding is independently confirmed, not just asserted by the API. Otherwise one row per thread
# (Phase B, unverified binding) or one row = the total (Phase A only, no per-core breakdown collected this
# poll) with the package temperature. A row's rate is XMRig's own 10 s average; it drops to 0 within ~10-20 s
# of hashing stopping - this is not a "completed work" stamp. khs is always the sum of rows.
# State changes (unavailable / shallow / affinity not verified / recovered) get one timestamped line in this
# package's OWN log, $CUSTOM_LOG_BASENAME.stats.log - never in XMRig's own log file, and never on stdout (this
# file is sourced by Hive's agent, not run as a standalone script). XMRig's FileLogWriter opens its log with
# O_CREAT|O_WRONLY (no O_APPEND) and tracks its own write offset from the size at open time: anything else
# appended to that same file is silently overwritten by XMRig's own next write, so a second writer's lines
# never survive there - confirmed on a live rig (state transitions really happened, per the state file, but no
# diagnostic line was ever found in XMRig's log or its rotated copies). The stats log is bounded to its last
# ~200 lines once it passes 1 MiB.
# Reset $khs/$stats UNCONDITIONALLY, before any other work - the very first thing this poll does. Hive's
# real agent sources this file repeatedly in the SAME shell, poll after poll; $khs/$stats are plain global
# variables, so anything that leaves them untouched (rather than explicitly assigning, even to the honest 0)
# would let a PREVIOUS poll's values silently stand as THIS poll's answer - a positive rate surviving a
# stalled/dead poll right after it. Cleared here means the rest of this file can never "forget" to answer.
khs=""; stats=""
# ONE absolute deadline for the WHOLE poll, inherited from the top-level dispatcher (bloxminer/h-stats.sh),
# which computes it at the TRUE poll entry - before even engine selection, let alone anything below. Only
# computed here as a fallback, for when this file is sourced standalone (every test in this repo, and any
# direct invocation with no dispatcher above it) - either way, manifest parsing, PORT/PKG derivation and the
# LIB heredoc all happen AFTER this point, so they count against the budget too, never for free.
if [[ -z ${DEADLINE_US:-} ]]; then
	__t=${EPOCHREALTIME:-}; [[ -n $__t ]] || __t=$(date +%s.%N)
	__t_us="${__t%%.*}${__t#*.}"
	DEADLINE_US=$(( __t_us + 2400000 ))
	unset __t __t_us
fi

. "${BLOX_DIR:-/hive/miners/custom/bloxminer}/h-manifest.conf"   # BLOX_DIR: tests only

PROC=${BLOX_PROCFS_ROOT:-/proc}          # /proc path prefix; tests only
PKG=${BLOX_DIR:-/hive/miners/custom/bloxminer}
PORT=${BLOX_API_PORT:-${API_PORT:-4069}}
VER="$CUSTOM_VERSION (xmrig 6.26.0)"
algo=$(jq -r '.pools[0].algo // empty' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null)
# Validated against the exact shape every real rx algo has (h-common.sh's RX_ALGOS: rx/0, rx/wow, rx/arq,
# rx/graft, rx/sfx, rx/yada) rather than trusted as-is: config.json is normally written by our OWN h-config.sh,
# which already validates against that list, but this file reads it back independently and must not assume
# that write path is the only way config.json could ever come to hold this field - a corrupt/hand-edited file
# is not a threat model this cares about, but $algo is interpolated RAW (no jq --arg) into the plain-printf
# emergency fallback JSON below (fallback(), and the mktemp-failure block just after this), which must never
# depend on jq being available - so anything containing a `"` or `\` there would hand back invalid JSON right
# when a valid, honest answer matters most. A fixed, always-safe default replaces anything that does not match.
[[ $algo =~ ^rx/[a-z0-9]+$ ]] || algo="rx/0"

STATEDIR=${BLOX_STATE_DIR:-}
if [[ -z $STATEDIR ]]; then [[ -d /run/hive ]] && STATEDIR=/run/hive || STATEDIR=$PKG; fi
STATEFILE="$STATEDIR/.bloxminer-rx-hstats-state"
# ENRICHFILE: the last real TEMPERATURE Phase B measured for a given xmrig instance (pid + /proc start time) -
# never a hashrate. Read by Phase A only to fill in a single row's temperature when Phase B does not run this
# poll; a wrong-by-a-poll-or-two cached temperature has no watchdog-reboot consequence, unlike a cached rate.
ENRICHFILE="$STATEDIR/.bloxminer-rx-hstats-enrich"
export PROC PKG PORT VER algo STATEFILE ENRICHFILE CUSTOM_LOG_BASENAME

# The whole collection lives in one function library file so the parent's own fallback path (used only when
# the LIB/OUTFILE/HANDSHAKE temp files themselves cannot be created) and the timed child (the real work) run
# the exact same code - nothing is duplicated or re-typed.
# dbg <msg> - appends a timestamped line to $BLOX_HSTATS_DEBUG_LOG, iff that variable is set (never on a real
# Hive rig - opt-in only, for a test/CI investigation). A plain `>>` append, no subshell; short-circuits to a
# single [[ ]] test (no fork at all) when unset, so this can be called freely without a production-path cost.
# Defined twice (here, for the parent's own pre/post-launch decisions, and again inside LIBEOF below for run()
# itself, which executes in an isolated child that does not inherit this shell's functions) - not exported,
# since bash cannot export a function across an exec'd `bash -c` the way it can a plain fork; both copies are
# kept in lockstep by hand, deliberately tiny, so that is not a maintenance burden.
dbg() { [[ -n ${BLOX_HSTATS_DEBUG_LOG:-} ]] && printf '%s rx[%s] %s\n' "${EPOCHREALTIME:-?}" "$$" "$*" >> "$BLOX_HSTATS_DEBUG_LOG" 2>/dev/null; return 0; }
export BLOX_HSTATS_DEBUG_LOG   # so the setsid'd child below inherits it too - unset is a no-op either way

LIB=$(mktemp "${TMPDIR:-/tmp}/bloxminer-rx-hstats-lib.XXXXXX") || {
	dbg "LIB mktemp FAILED - emergency fallback, no fork"
	# printf -v, not stats=$(printf ...): a command substitution forks a subshell regardless of the command
	# run inside it being a builtin - and this whole block exists BECAUSE mktemp (a fork) just failed, i.e.
	# exactly the resource-pressure state a further fork here could fail in too, leaving $stats empty rather
	# than this defined fallback. printf -v assigns in the current shell, no fork at all.
	khs=0
	printf -v stats '{"hs":[0],"hs_units":"khs","temp":[null],"ar":[0,0],"uptime":0,"ver":"%s","algo":"%s"}' "$VER" "$algo"
	return 0 2>/dev/null || exit 0
}
cat > "$LIB" <<'LIBEOF'
# Budget arithmetic below is pure bash - NO FORK AT ALL (was `date` + `awk`, forked on every single check).
# Real-Hive evidence (cask18, 5950X, all 32 threads saturating the one CPU the collector itself was pinned to
# alongside them): the OLD design's per-check date+awk forks were themselves a meaningful share of why the
# whole collection could not finish in time - every fork here is scheduling latency spent finding out how much
# time is left, on the exact box where scheduling latency is what is actually scarce. EPOCHREALTIME (bash 5
# builtin, "SECONDS.ffffff") turns into a plain integer microsecond count via string slicing; every subsequent
# check is `$(( ))` arithmetic. Out-parameter convention ($REPLY), never `$(...)` - a command substitution
# forks a subshell regardless of whether the function body itself does.
dbg() { [[ -n ${BLOX_HSTATS_DEBUG_LOG:-} ]] && printf '%s rx[%s] %s\n' "${EPOCHREALTIME:-?}" "$$" "$*" >> "$BLOX_HSTATS_DEBUG_LOG" 2>/dev/null; return 0; }   # see the parent's own copy of this function for the full rationale

now_us() {   # sets $REPLY = now, integer microseconds since epoch
	local t=${EPOCHREALTIME:-}
	[[ -n $t ]] || t=$(date +%s.%N)   # bash < 5 fallback (forks) - never expected on Ubuntu 22.04+/HiveOS
	REPLY="${t%%.*}${t#*.}"
}
remaining_us() {   # sets $REPLY = microseconds left until the ONE absolute $DEADLINE_US, floored at 0 -
	# DEADLINE_US is computed exactly once, by the PARENT, before the child is even launched (process
	# setup/exec time counts against the budget, not just the child's own post-launch work), and passed
	# through launch/collection/enrichment/cleanup as a single shared value - never re-derived from a fresh
	# "now" partway through, which would silently grant extra time on top of what was already spent.
	local n; now_us; n=$REPLY
	REPLY=$(( DEADLINE_US - n ))
	(( REPLY < 0 )) && REPLY=0
}
have_budget_us() { (( $1 > 50000 )); }   # < 50 ms left is not worth attempting
cap_us() { (( $1 < $2 )) && REPLY=$1 || REPLY=$2; }   # min(remaining, nominal per-step ceiling), both in us
us_to_secstr() {   # $1 = microseconds -> $REPLY = "S.ffffff", for curl --max-time / timeout - no fork
	local us=$1 f
	printf -v f '%06d' $(( us % 1000000 ))
	REPLY="$(( us / 1000000 )).$f"
}

# ENRICH_MAX_AGE_S: how old a cached TEMPERATURE (see ENRICHFILE) may be before Phase A stops using it and
# shows null instead. This bounds a cosmetic detail only - see the file header for why khs is never bounded
# this way at all (there is no cached khs to bound).
ENRICH_MAX_AGE_S=90

# _rx_pid_start <pid> - sets $REPLY to that pid's own starttime field (22nd field of /proc/<pid>/stat, robust
# to spaces or parens inside the comm field by scanning from the LAST ')'), or empty if unreadable. No fork:
# `read` is a builtin, the here-string does not exec anything either, and (out-parameter via $REPLY, not
# stdout) neither does the caller capturing it. Used to tell a genuinely still-running xmrig instance apart
# from a DIFFERENT process that later reused the same pid (a real occurrence on a long-running rig) - a plain
# pid match alone would not be enough to trust a cached temperature against.
_rx_pid_start() {
	local f="$PROC/$1/stat" line rest arr
	REPLY=""
	[[ -r $f ]] || return 0
	read -r line < "$f" 2>/dev/null || return 0
	rest=${line##*) }
	read -r -a arr <<< "$rest"
	REPLY="${arr[19]:-}"
}

int() { [[ $1 =~ ^[0-9]+$ ]]; }

note_state() {   # $1 = ok | unverified | shallow | unavailable; logs only on a transition, never to stdout,
                 # and never into XMRig's own log file (see the top comment: XMRig writes it at its own
                 # tracked offset with no O_APPEND, so anything else appended there is silently overwritten by
                 # XMRig's next write). Own file instead: $CUSTOM_LOG_BASENAME.stats.log, timestamped, bounded
                 # to ~200 lines.
	local prev="" cur=$1 msg="" statslog="$CUSTOM_LOG_BASENAME.stats.log" sz
	[[ -f $STATEFILE ]] && prev=$(<"$STATEFILE")
	[[ $prev == "$cur" ]] && return 0
	case $cur in
		unavailable) msg="bloxminer-x: stats API unavailable" ;;
		unverified)  msg="bloxminer-x: affinity not verified, showing per-thread rows" ;;
		shallow)     msg="bloxminer-x: showing total only this poll (no per-core breakdown collected in time)" ;;
		ok)          [[ -n $prev ]] && msg="bloxminer-x: recovered" ;;
	esac
	if [[ -n $msg ]]; then
		{
			sz=$(wc -c < "$statslog" 2>/dev/null | tr -d '[:space:]'); [[ $sz =~ ^[0-9]+$ ]] || sz=0
			if (( sz > 1048576 )); then
				tail -n 200 "$statslog" > "$statslog.tmp" 2>/dev/null && mv -f "$statslog.tmp" "$statslog"
			fi
			printf '%s %s\n' "$(date '+%F %T')" "$msg" >> "$statslog"
		} 2>/dev/null
	fi
	{ printf '%s' "$cur" > "$STATEFILE"; } 2>/dev/null
}

fallback() {   # $1 = a single row's temperature (bloxsense pkg_temp, JSON number or the literal "null"), default
	# null - shell-only (printf -v, a builtin, assigning with NO subshell/fork at all - not even `$(printf ...)`,
	# which forks a subshell to capture output regardless of printf itself being a builtin): this is the safety
	# net called when things are ALREADY going wrong (including under the exact resource pressure that can make
	# a fork itself fail), so it must not itself depend on jq being installed/working (see the LIB-creation-
	# failure path above, which uses this exact same plain-printf-v pattern for the same reason), nor on a fork
	# succeeding. $VER is built from CUSTOM_VERSION, a fixed constant in this package's own shipped
	# h-manifest.conf, never user/pool-controlled; $algo is regex-validated at the top of this file (see its
	# own assignment) to match rx's fixed algo shape before it ever reaches here - both safe to interpolate raw
	# into this hand-built JSON.
	khs=0
	printf -v stats '{"hs":[0],"hs_units":"khs","temp":[%s],"ar":[0,0],"uptime":0,"ver":"%s","algo":"%s"}' \
		"${1:-null}" "$VER" "$algo"
}

# write_result <khs> <stats-json> - atomic (tmp+rename) write of this poll's answer to $OUTFILE. Called once
# after Phase A and again after Phase B if it improves on it - see the file header. No fork: every caller
# passes a khs that is already a plain, validated numeric string (never attacker/API-controlled text - it is
# always the output of `%.2f`-style awk formatting or a jq `round`), so the wrapper JSON is built with `printf`
# instead of forking jq a second time to do only string interpolation jq would do anyway; $2 is always already
# valid JSON text produced by this same file's own jq calls.
write_result() {
	local tmp="$OUTFILE.w.$$"
	{ printf '{"khs":"%s","stats":%s}' "$1" "$2" > "$tmp" && mv -f "$tmp" "$OUTFILE"; } 2>/dev/null
}

# schema validators: a reply that parses as JSON but does not look like XMRig's own shape is not used
valid_summary() { jq -e 'type == "object" and (.version | type == "string")' > /dev/null 2>&1 <<< "$1"; }
valid_backends() {
	jq -e '
		type == "array" and
		(map(select(.type == "cpu")) as $c | ($c | length) <= 1 and
		 ($c | all(.threads == null or (
		   (.threads | type) == "array" and
		   (.threads | all(type == "object" and (.affinity | type == "number") and (.hashrate | type == "array")))
		 ))))
	' > /dev/null 2>&1 <<< "$1"
}

# Collects everything and sets $khs/$stats, writing $OUTFILE at each phase boundary. Every early exit writes
# an honest result first (via write_result, or fallback()+write_result) - this always runs as a function,
# whether called directly (LIB creation failure path) or, normally, inside the timed child.
run() {
	local port_hex inode owner_pid owned fd_dir sum uptime acc rej khs_fresh pidstart enrich_temp
	local back threads naff sense pkg_temp power_raw percore task_set api_set rows
	local exe_link curl_rc

	remaining_us; dbg "run() entry: remaining_us=$REPLY"
	have_budget_us "$REPLY" || { dbg "run() entry: OUT OF BUDGET before even the ownership check"; note_state unavailable; fallback ""; write_result "$khs" "$stats"; return 0; }

	# ---- API ownership: /proc/net/tcp -> inode -> pid -> exe (the whole scan is inside the timed child)
	port_hex=$(printf '%04X' "$PORT")
	inode=$(awk -v p="$port_hex" 'NR > 1 { split($2, a, ":"); if (a[1] == "0100007F" && a[2] == p && $4 == "0A") print $10 }' \
		"$PROC/net/tcp" 2>/dev/null | head -n1)
	owner_pid=""
	if [[ -n $inode ]]; then
		# ONE fork total, whatever the size of the process table: `find -lname` compares every fd's symlink
		# target internally (no readlink child process per fd).
		fd_dir=$(find "$PROC" -mindepth 3 -maxdepth 3 -path "$PROC/[0-9]*/fd/*" -lname "socket:\[$inode\]" \
			-printf '%h\n' 2>/dev/null | head -n1)
		if [[ -n $fd_dir ]]; then
			owner_pid=${fd_dir#"$PROC"/}; owner_pid=${owner_pid%%/*}
		fi
	fi
	owned=0; exe_link=""
	if [[ -n $owner_pid ]]; then
		exe_link=$(readlink "$PROC/$owner_pid/exe" 2>/dev/null)
		[[ $exe_link == "$PKG/xmrig" ]] && owned=1
	fi
	dbg "ownership: PORT=$PORT port_hex=$port_hex inode=${inode:-<none>} owner_pid=${owner_pid:-<none>} exe_link=${exe_link:-<none>} expected=$PKG/xmrig owned=$owned"
	if (( ! owned )); then note_state unavailable; fallback ""; write_result "$khs" "$stats"; return 0; fi

	# ================================================================ PHASE A (mandatory, cheap, this poll)
	# The ONLY network call and the ONLY jq invocation this phase needs: one GET (parse+validate+extract are a
	# SINGLE jq call, not three) to /2/summary, which already carries the aggregate hashrate, accepted/rejected
	# and uptime - real-Hive evidence (1 CPU, 32 threads all saturating it) is that every avoided fork here
	# matters, so this phase forks only what curl/find/awk/readlink/jq themselves cannot be done without.
	remaining_us; dbg "phase A: entry remaining_us=$REPLY"
	have_budget_us "$REPLY" || { dbg "phase A: OUT OF BUDGET before the curl call"; note_state unavailable; fallback ""; write_result "$khs" "$stats"; return 0; }
	cap_us "$REPLY" 500000; us_to_secstr "$REPLY"   # 0.5 s ceiling
	sum=$(curl -fsS --max-time "$REPLY" "http://127.0.0.1:$PORT/2/summary" 2>/dev/null); curl_rc=$?
	dbg "phase A: curl --max-time $REPLY /2/summary rc=$curl_rc len=${#sum} body=${sum:0:300}"

	local parsed
	parsed=$(jq -r '
		if (type == "object") and (.version | type == "string") then
			def n0: if (type == "number") and (isnan | not) and (isinfinite | not) and (. >= 0) then . else 0 end;
			[ ((.uptime // 0) | n0), ((.connection.accepted // 0) | n0), ((.connection.rejected // 0) | n0),
			  ((((.hashrate.total[0]?) // 0) | n0) / 1000 * 100 | round / 100) ] | @tsv
		else empty end
	' <<< "$sum" 2>/dev/null)
	dbg "phase A: jq parsed=${parsed:-<empty>}"
	if [[ -z $parsed ]]; then note_state unavailable; fallback ""; write_result "$khs" "$stats"; return 0; fi
	IFS=$'\t' read -r uptime acc rej khs_fresh <<< "$parsed"
	int "$uptime" || uptime=${uptime%%.*}; int "$uptime" || uptime=0
	int "$acc" || acc=0
	int "$rej" || rej=0
	[[ $khs_fresh =~ ^[0-9]+(\.[0-9]+)?$ ]] || khs_fresh=0
	printf -v khs_fresh '%.2f' "$khs_fresh"   # jq's own number formatting drops trailing/all zeros ("1.6", "1")
		# - always exactly 2 decimals here, matching Phase B's `awk '%.2f'` convention elsewhere in this file.
		# `printf` is a bash builtin: no fork.

	_rx_pid_start "$owner_pid"; pidstart=$REPLY
	enrich_temp="null"
	if [[ -n $pidstart && -f $ENRICHFILE ]]; then
		local e_ts="" e_pid="" e_start="" e_temp="" e_age
		while IFS='=' read -r ek ev; do
			case $ek in ts) e_ts=$ev ;; pid) e_pid=$ev ;; start) e_start=$ev ;; temp) e_temp=$ev ;; esac
		done < "$ENRICHFILE" 2>/dev/null
		if [[ -n $e_ts && $e_pid == "$owner_pid" && $e_start == "$pidstart" ]]; then
			now_us; e_age=$(( (REPLY - e_ts) / 1000000 )); (( e_age < 0 )) && e_age=0
			[[ -n $e_temp && $e_age -le $ENRICH_MAX_AGE_S ]] && enrich_temp=$e_temp
		fi
	fi

	khs=$khs_fresh
	stats=$(jq -nc --argjson k "$khs_fresh" --argjson t "$enrich_temp" --argjson a "$acc" --argjson r "$rej" \
		--argjson up "$uptime" --arg ver "$VER" --arg algo "$algo" \
		'{hs: [$k], hs_units: "khs", temp: [$t], ar: [$a, $r], uptime: $up, ver: $ver, algo: $algo}')
	write_result "$khs" "$stats"
	dbg "phase A: DONE khs=$khs stats=${stats:0:200}"
	# note_state is NOT called here: Phase A's write is provisional (Phase B usually improves on it in the
	# very same poll), and logging "shallow" unconditionally on every poll - even ones where Phase B goes on to
	# succeed exactly as it did last poll too - would turn "logs only on a real transition" into "logs twice a
	# poll" (shallow, then ok/unverified again) even in a fully steady state. Every exit below that settles for
	# Phase A's answer calls note_state shallow explicitly, once, at the point that becomes final for real.

	# ================================================================ PHASE B (optional enrichment)
	[[ -n ${BLOX_HSTATS_TEST_PHASEB_DELAY:-} ]] && sleep "$BLOX_HSTATS_TEST_PHASEB_DELAY"   # tests only
	remaining_us; dbg "phase B: entry remaining_us=$REPLY"
	have_budget_us "$REPLY" || { dbg "phase B: SKIPPED - out of budget, Phase A's khs=$khs stands"; note_state shallow; return 0; }
	cap_us "$REPLY" 500000; us_to_secstr "$REPLY"
	back=$(curl -fsS --max-time "$REPLY" "http://127.0.0.1:$PORT/2/backends" 2>/dev/null); curl_rc=$?
	dbg "phase B: curl --max-time $REPLY /2/backends rc=$curl_rc len=${#back} body=${back:0:300}"
	jq -e . > /dev/null 2>&1 <<< "$back" && valid_backends "$back" || { dbg "phase B: SKIPPED - backends reply not valid JSON/shape, Phase A's khs=$khs stands"; note_state shallow; return 0; }

	threads=$(jq -c '[.[] | select(.type == "cpu") | .threads[]?] // []' <<< "$back" 2>/dev/null)
	[[ -n $threads ]] || threads='[]'
	naff=$(jq 'length' <<< "$threads" 2>/dev/null); int "$naff" || naff=0
	dbg "phase B: naff=$naff"
	if (( naff == 0 )); then dbg "phase B: SKIPPED - naff==0 (no pool job yet), Phase A's khs=$khs stands"; note_state shallow; return 0; fi   # legitimate: no pool job yet, benign - Phase A's total stands

	# ---- sensors: whatever is left, capped at min(remaining, 1.0 s) - bloxsense's own RAPL sample is ~0.55 s
	remaining_us
	if have_budget_us "$REPLY"; then
		# --foreground: keep bloxsense in the SAME process group as this script (and the outer timeout wrapping
		# the whole run below) instead of a new one of its own - otherwise a bloxsense that ignores SIGTERM
		# could end up in a process group the outer timeout's kill never reaches, and survive as an orphan.
		cap_us "$REPLY" 1000000; us_to_secstr "$REPLY"
		sense=$(timeout --foreground "$REPLY" "$PKG/bloxsense" --json 2>&1); dbg "phase B: bloxsense rc=$? len=${#sense} body=${sense:0:200}"
	else
		note_state shallow; return 0
	fi
	jq -e . > /dev/null 2>&1 <<< "$sense" || sense='{"cpus":[],"pkg_temp":null,"power_w":null,"ccd_reason":""}'
	pkg_temp=$(jq -c '.pkg_temp' <<< "$sense")
	# A jq failure (e.g. a transient fork/exec failure under resource pressure - the exact class of bug Codex's
	# review of a714388 already found once, in the final result-reading step) would otherwise leave $pkg_temp
	# empty, which is NOT valid JSON - and $pkg_temp is fed into `--argjson` below (both branches of the
	# percore/rows split), where jq treats an invalid --argjson value as a FATAL argument error: the entire
	# `rows=` computation would then silently produce nothing, cascading into $complete/$phaseb_total also
	# being empty two steps later (exactly the GH-CI-only symptom this round's diagnostics caught: "phase B:
	# complete= phaseb_total=" - both empty, not "true"/"false" or a number). Defined default: this cosmetic
	# detail (a single row's temperature, in the unverified/per-thread path) is worth losing to a transient jq
	# hiccup; the RATE Phase B is here to compute is never allowed to depend on this succeeding (see below).
	[[ $pkg_temp =~ ^(null|[0-9.]+)$ ]] || { dbg "phase B: pkg_temp invalid/empty (jq failure?) - forcing null, was: $pkg_temp"; pkg_temp=null; }
	power_raw=$(jq -c '.power_w' <<< "$sense")
	[[ $power_raw =~ ^(null|[0-9.]+)$ ]] || { dbg "phase B: power_raw invalid/empty (jq failure?) - forcing null, was: $power_raw"; power_raw=null; }

	# ---- binding verification, budget permitting (the /proc task scan is also inside the timed child)
	percore=0
	remaining_us
	if have_budget_us "$REPLY" && jq -e --argjson s "$sense" 'all(.affinity >= 0) and (map(.affinity as $a | ($s.cpus | any(.cpu == $a))) | all)' \
		<<< "$threads" > /dev/null 2>&1
	then
		task_set='[]'
		if [[ -d $PROC/$owner_pid/task ]]; then
			task_set=$(awk '
				/^Cpus_allowed_list:/ {
					val = $0
					sub(/^Cpus_allowed_list:[ \t]*/, "", val)
					gsub(/[ \t\r]/, "", val)
					if (val == "") next
					n = split(val, parts, ",")
					count = 0; last = ""; bad = 0
					for (i = 1; i <= n && !bad; i++) {
						if (parts[i] ~ /^[0-9]+-[0-9]+$/) {
							split(parts[i], rg, "-")
							count += (rg[2] + 0) - (rg[1] + 0) + 1
							last = rg[1] + 0
						} else if (parts[i] ~ /^[0-9]+$/) {
							count += 1
							last = parts[i] + 0
						} else {
							bad = 1
						}
						if (count > 1) break
					}
					if (!bad && count == 1) print last
				}
			' "$PROC/$owner_pid"/task/*/status 2>/dev/null | jq -R 'select(length > 0) | tonumber' | jq -s 'sort')
		fi
		api_set=$(jq -c '[.[].affinity] | sort' <<< "$threads")
		jq -e -n --argjson t "$task_set" --argjson a "$api_set" '$t == $a' > /dev/null 2>&1 && percore=1
	fi

	# rate0 is null (never a fabricated 0) for any thread whose own hashrate[0] is missing/invalid - a row
	# built from such a thread is INCOMPLETE, and its own khs is null too, never a summed-in-a-zero number.
	# Phase B's total may only ever replace Phase A's khs_fresh when EVERY row is complete (no null anywhere)
	# AND the two totals agree on hashing-or-not: a complete-but-zero Phase B total contradicting a positive
	# Phase A total is exactly the false-zero this review caught (null-as-0 rows quietly outvoting a real,
	# fresh, positive summary rate) - so it is treated as inconsistent, not as a fresher answer.
	if (( percore )); then
		note_state ok
		rows=$(jq -c --argjson s "$sense" '
			def rate0: (.hashrate[0]) as $r | if ($r == null or ($r | type) != "number" or ($r | isnan) or ($r | isinfinite)) then null elif $r < 0 then 0 else $r end;
			($s.cpus | map({key: (.cpu | tostring), value: {pkg: .pkg, core: .core, temp: .temp}}) | from_entries) as $topo
			| map(. + {pc: $topo[(.affinity | tostring)], r0: rate0})
			| group_by([.pc.pkg, .pc.core])
			| map(
				(map(.r0)) as $rates
				| if any($rates[]; . == null) then {khs: null, temp: .[0].pc.temp}
				  else {khs: ((map(.r0 / 1000) | add) * 100 | round / 100), temp: .[0].pc.temp} end)' <<< "$threads")
	else
		note_state unverified
		rows=$(jq -c --argjson pt "$pkg_temp" '
			def rate0: (.hashrate[0]) as $r | if ($r == null or ($r | type) != "number" or ($r | isnan) or ($r | isinfinite)) then null elif $r < 0 then 0 else $r end;
			map(rate0 as $r0 | if $r0 == null then {khs: null, temp: $pt} else {khs: (($r0 / 1000) * 100 | round / 100), temp: $pt} end)' <<< "$threads")
	fi
	dbg "phase B: percore=$percore rows=${rows:0:300}"

	complete=$(jq -r 'all(.[]; .khs != null)' <<< "$rows")
	phaseb_total=$(jq -r '[.[].khs] | map(select(. != null)) | add // 0' <<< "$rows" | awk '{printf "%.2f", $1}')
	# $complete/$phaseb_total must come out exactly "true"/"false" and a plain non-negative number,
	# respectively - anything else (typically empty: a transient jq fork/exec failure under resource pressure,
	# or $rows itself being malformed/empty from the step above) is a FAILED computation, not a legitimate
	# "incomplete" or "zero" reading, and must be logged as such rather than silently falling through - relying
	# on bash's `[[ "" == true ]]` being false (which happens to also reject Phase B here, but for the wrong
	# reason, unlogged) is exactly the class of silent failure that made the GH-CI-only version of this bug take
	# two full round-trips to even see. Forcing both to their safe values here makes the fallback explicit AND
	# guarantees `khs=$phaseb_total` below can never be assigned something non-numeric even if some future edit
	# moves that assignment before the $complete check.
	if [[ $complete != true && $complete != false ]]; then
		dbg "phase B: FAILED - \$complete came back invalid/empty (was: '$complete') - Phase A's khs=$khs stands"
		complete=false
	fi
	if [[ ! $phaseb_total =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		dbg "phase B: FAILED - \$phaseb_total came back invalid/empty (was: '$phaseb_total') - Phase A's khs=$khs stands"
		complete=false; phaseb_total=0
	fi
	# consistent := Phase A itself has no confident positive rate (khs_fresh == 0 - nothing to protect a
	# complete Phase B reading from), OR the two totals agree within 10% of Phase A's own value. A near-zero
	# Phase B total quietly replacing a HEALTHY (positive) Phase A rate is exactly the false-zero this rule
	# exists to catch - an exact-zero special case alone is not enough, hence the proportional tolerance.
	consistent=0
	awk -v b="$phaseb_total" -v a="$khs_fresh" 'BEGIN{
		if (a+0 == 0) { exit 0 }
		d = b - a; if (d < 0) d = -d
		exit !(d <= 0.10 * a)
	}' && consistent=1
	dbg "phase B: complete=$complete phaseb_total=$phaseb_total khs_fresh(phaseA)=$khs_fresh consistent=$consistent -> $([[ $complete == true && $consistent == 1 ]] && echo 'REPLACING with phase B' || echo 'Phase A khs stands')"
	if [[ $complete == true && $consistent == 1 ]]; then
		# Phase B's total AND its own stats replace Phase A's - never a mixed payload (Phase A's number with
		# Phase B's rows, or vice versa): either Phase B is trusted whole, or Phase A's whole result stands.
		# Built into a LOCAL variable first, validated, and only THEN assigned to $khs/$stats and written -
		# never straight into the globals/$OUTFILE. This composition is 4 jq forks deep (the outer call plus
		# 3 nested command substitutions for hs/temp/ar) - any one of them failing (the same transient
		# fork/exec-under-resource-pressure class Codex's review already found twice elsewhere in this file)
		# would otherwise leave $stats empty/malformed while $khs already held a real, positive number:
		# write_result would then atomically overwrite Phase A's own already-good, already-written OUTFILE
		# with `{"khs":"500.00","stats":}` - syntactically invalid JSON - and the PARENT's own read-back guard
		# (which only ever sees $OUTFILE, never these in-process variables) would have no choice but to
		# discard the whole thing and report the safe fallback 0, destroying a real positive rate Phase A had
		# already safely captured. Validating here, before ever touching $khs/$stats/$OUTFILE, is what
		# actually prevents that - a caught failure below leaves BOTH the globals and the file exactly as
		# Phase A already left them.
		local new_stats
		[[ -n ${BLOX_HSTATS_TEST_FORCE_STATS_FAIL:-} ]] && power_raw='BROKEN'   # tests only: not valid JSON,
			# so the --argjson below fails fatally - simulates the transient jq/fork failure this whole
			# validate-before-write guard exists for, without weakening anything it guards against
		new_stats=$(jq -nc --argjson hs "$(jq -c '[.[].khs]' <<< "$rows")" --argjson temp "$(jq -c '[.[].temp]' <<< "$rows")" \
			--argjson ar "$(jq -nc --argjson a "$acc" --argjson r "$rej" '[$a, $r]')" --argjson uptime "$uptime" \
			--arg ver "$VER" --arg algo "$algo" --argjson power "$power_raw" \
			'{hs: $hs, hs_units: "khs", temp: $temp, ar: $ar, uptime: $uptime, ver: $ver, algo: $algo}
			 + (if ($power | type) == "number" and $power > 0 then {cpu_power: $power} else {} end)')
		if jq -e 'type == "object" and (.hs | type) == "array" and (.hs | length) > 0 and
			(.hs | all(type == "number")) and (.temp | type) == "array"' > /dev/null 2>&1 <<< "$new_stats"
		then
			khs=$phaseb_total
			stats=$new_stats
			write_result "$khs" "$stats"
		else
			dbg "phase B: FAILED - final stats composition invalid/empty (was: '$new_stats') - Phase A's khs=$khs_fresh stands, OUTFILE left untouched"
		fi
	fi   # else: Phase A's already-written result (khs_fresh + its own stats) stands, completely untouched

	# enrichment cache: TEMPERATURE only, keyed by this xmrig instance (pid + its own /proc start time) - see
	# the file header. Never khs.
	if [[ -n $pidstart ]]; then
		now_us   # $REPLY = integer microseconds, the SAME unit the read-back age check (above) expects
		{ printf 'ts=%s\npid=%s\nstart=%s\ntemp=%s\n' "$REPLY" "$owner_pid" "$pidstart" "$pkg_temp" \
			> "$ENRICHFILE.tmp" && mv -f "$ENRICHFILE.tmp" "$ENRICHFILE"; } 2>/dev/null
	fi
	dbg "run() EXIT: final khs=$khs stats=${stats:0:200}"
}
LIBEOF

# shellcheck disable=SC1090   # $LIB is a script this file just generated into a temp file, not a fixed path
. "$LIB"   # the parent also gets fallback()/note_state()/write_result() from here, for the LIB-creation-failure path

BUDGET_US=2400000  # of the shared 3.0 s deadline - integer microseconds, for the forkless budget arithmetic
                    # both this parent and the child (run(), via remaining_us) derive every timer from
KILL_GRACE=0.3      # extra time after SIGTERM before SIGKILL - bounds the hard kill at 2.7 s, leaving 0.3 s of
                    # slack for this wrapper, so the whole run stays under 3.0 s even in the worst case
                    # (SIGTERM ignored, waits out the full grace period, then an unmaskable SIGKILL).
# $DEADLINE_US itself was already computed at the very top of this file (inherited from the dispatcher, or a
# standalone fallback) - not re-derived here, which would silently grant back whatever the manifest/PORT/LIB
# setup above already spent.
# $OUTFILE is written to DIRECTLY by run() (via write_result), atomically, at each phase boundary - never
# captured from the child's stdout. Never a pipe: a command-substitution pipe only reaches EOF once every
# process that ever held its write end (including an orphan that somehow escaped the kill) has closed it, so a
# survivor could hang this parent forever. Reading a plain file back never blocks on a stale writer.
OUTFILE=$(mktemp "${TMPDIR:-/tmp}/bloxminer-rx-hstats-out.XXXXXX") || OUTFILE=""
# The child reports its OWN pgid, AFTER its setsid has taken effect, into this handshake file - this script
# never reads the child's pgid via `ps` itself. Right after backgrounding, the new process may still be
# running with the FORK-INHERITED pgid (ours, or whatever our own caller's is) for a brief window before it
# reaches its own setsid() call; reading `ps -o pgid=` at that instant would see that inherited pgid, and a
# later group-kill against it could hit our own caller instead of the collection. Only a value the child
# itself reports, once it truly is isolated, is ever trusted for a group-wide signal.
HANDSHAKE=$(mktemp "${TMPDIR:-/tmp}/bloxminer-rx-hstats-hs.XXXXXX") || HANDSHAKE=""
PARENT_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')
export OUTFILE

if [[ -n $OUTFILE && -n $HANDSHAKE ]]; then
	# shellcheck disable=SC2016   # $1/$2 are the child bash's own positional parameters, not this shell's
	BUDGET_US="$BUDGET_US" DEADLINE_US="$DEADLINE_US" setsid bash -c '
		[[ -n ${BLOX_HSTATS_TEST_HANDSHAKE_DELAY:-} ]] && sleep "$BLOX_HSTATS_TEST_HANDSHAKE_DELAY"   # tests only
		{ printf "%s" "$(ps -o pgid= -p $$ 2>/dev/null | tr -d "[:space:]")"; } > "$2" 2>/dev/null
		. "$1"
		run
	' _ "$LIB" "$HANDSHAKE" > /dev/null 2>>"${BLOX_HSTATS_DEBUG_LOG:-/dev/null}" &
	# stderr from EVERYTHING inside run() (every jq/awk/curl call's own error text, otherwise completely
	# invisible - a jq argument/parse failure prints there, not to $OUTFILE) goes to $BLOX_HSTATS_DEBUG_LOG
	# when debugging, /dev/null otherwise (unchanged production behavior: this file is sourced by Hive's own
	# agent, which must never see anything on this script's stdout/stderr - see the file header). A plain
	# redirect, evaluated once right here in the parent, before the fork - no extra process, debugging or not.
	CPID=$!

	# A group-kill is only ever attempted against a pgid that: came from the handshake (so it is what the
	# child itself measured, post-setsid, not a guess made from out here), equals $CPID (confirming the child
	# became its own session/process-group leader), and differs from our own pgid and from 0/1 (confirming
	# real isolation, not an accidental no-op or a kernel/init group). Anything else - including the
	# handshake simply not having arrived yet - falls back to signalling $CPID alone, never a group.
	validated_pgid() {
		local hs=""
		[[ -s $HANDSHAKE ]] && hs=$(cat "$HANDSHAKE" 2>/dev/null)
		[[ $hs =~ ^[0-9]+$ ]] || return 1
		[[ $hs == "$CPID" && $hs != "$PARENT_PGID" ]] || return 1
		(( hs > 1 )) || return 1
		echo "$hs"
	}
	still_running() {   # true if the (validated) group, or else just $CPID, still has anything alive
		local g; g=$(validated_pgid)
		if [[ -n $g ]]; then pgrep -g "$g" > /dev/null 2>&1; else kill -0 "$CPID" 2>/dev/null; fi
	}
	escalate() {   # $1 = signal name
		local g; g=$(validated_pgid)
		if [[ -n $g ]]; then kill -"$1" -- "-$g" 2>/dev/null; else kill -"$1" "$CPID" 2>/dev/null; fi
	}

	# Bounded poll for $CPID, NOT `wait -n "$CPID" "$ALARM"` on a background alarm sleep: that construct can
	# block for the FULL remaining budget even when $CPID has ALREADY exited, specifically when the invoking
	# shell was itself started via `bash -c` (exactly how every poll in tests/hive/test_rx_under_load.sh and
	# tests/hive/test_dispatcher.sh's "one shell" section invoke this file) rather than as a script file - a
	# real, reproducible bash job-control quirk, isolated in an earlier round (see git history for
	# finalize_rx_hugepages_bounded in h-common.sh, the first place this was found and fixed the same way).
	# A poll loop against $DEADLINE_US directly (via the same forkless remaining_us/have_budget_us this whole
	# file already uses for every other timing decision) has no such invocation-context dependency: it costs
	# nothing extra when $CPID finishes promptly (the loop's very first check exits it) and never waits any
	# longer than the alarm-based version would have in the worst case either way. No alarm process at all any
	# more, so the "must never inherit this script's own stdout/stderr" hazard the old alarm sleep carried
	# (an orphaned background job holding a command-substitution pipe's write end open, hanging the CALLER even
	# after everything else finished - reproduced once in practice) cannot recur either.
	dbg "parent: launched CPID=$CPID, entering bounded poll"
	while still_running; do
		remaining_us; have_budget_us "$REPLY" || break
		sleep 0.05
	done
	remaining_us; dbg "parent: poll loop exited, remaining_us=$REPLY still_running=$(still_running && echo yes || echo no)"
	# Checked by whether ANYTHING remains (in the validated group, or else just $CPID), not just whether
	# $CPID itself is still alive: $CPID is a plain bash process that dies immediately from a TERM, even when
	# a SIGTERM-ignoring descendant of its (e.g. a stuck bloxsense) does not - checking only $CPID would look
	# like "done" while such a descendant survives as an orphan.
	if still_running; then
		dbg "parent: still_running=true after the poll loop - out of budget, escalating TERM"
		# the budget ran out, not the collection itself: escalate against the validated group when one is
		# available (reaching every descendant, including a nested `timeout --foreground` and whatever it is
		# guarding), else against $CPID alone - never a guessed or unconfirmed group
		escalate TERM
		sleep "$KILL_GRACE"
		still_running && escalate KILL
		wait "$CPID" 2>/dev/null   # $CPID was still unreaped here - reap it
	fi
	result=$(cat "$OUTFILE" 2>/dev/null)
	rm -f "$OUTFILE" "$HANDSHAKE"
else
	result=""
fi
rm -f "$LIB"

# Whatever $OUTFILE holds - Phase A's answer, or Phase B's richer one, or nothing at all if the child was
# killed before Phase A even finished writing - is used as-is: no cache, no age bound, no re-verification for
# the rate itself, because there is nothing here that was not collected THIS poll (only the single row's
# temperature, inside Phase A's own result, may already reflect ENRICHFILE - see run()). Nothing written at
# all is the only case that falls back to the defined, honest 0.
# ONE jq call, not three (validate + extract $khs + extract $stats together): under heavy, GH-CI-runner-scale
# resource pressure a jq PROCESS SPAWN itself (not just a parse) can transiently fail - three separate calls
# leave a window where the first (validate) succeeds but a later one silently returns empty, leaving $khs/
# $stats empty rather than either the real answer or the defined fallback (observed on a slower GH runner:
# {"khs":"","stats":null}). A single call has no such window - it either parses out both together, or neither.
# khs must be a finite, non-negative NUMBER (as a JSON string) and .stats must have the expected shape (an
# object with an "hs" array) - a nonempty-string guard alone would accept {"khs":"abc","stats":null} (both
# "abc" and jq's own stringified "null" are nonempty strings) as if they were real, honest answers.
parsed=$(jq -r '
	if (type == "object") and (.khs | type) == "string" and (.khs | test("^[0-9]+(\\.[0-9]+)?$"))
	   and (.stats | type) == "object" and ((.stats.hs | type) == "array")
	then [.khs, (.stats | tojson)] | @tsv else empty end' <<< "$result" 2>/dev/null)
if [[ -n $parsed ]]; then
	IFS=$'\t' read -r khs stats <<< "$parsed"
fi
# Final, unconditional bash-level guard (belt and suspenders, independent of the jq filter above): $khs must
# match a finite non-negative number, exactly what Hive itself needs - if it does not, THIS poll's answer is
# discarded and replaced with the same honest, defined fallback as a genuine "nothing collected" poll, never
# an old value left standing from whatever poll ran before this one in the same shell (see the top-of-file
# reset) and never a non-numeric string a looser guard would have let through.
if [[ ! ${khs:-} =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ -z ${stats:-} ]]; then
	note_state unavailable
	fallback ""
fi
