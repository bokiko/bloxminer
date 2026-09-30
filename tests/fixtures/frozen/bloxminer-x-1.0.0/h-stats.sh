#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs (total kH/s) and $stats (JSON). ONE shared 3.0 s deadline for the
# whole run, enforced by running the ENTIRE collection (the /proc ownership scan, both API calls, the /proc
# task-mask scan, bloxsense, and the jq row assembly) inside a single child process, not just individual
# steps: a /proc scan on a rig with an unusually large process table, or any other step, can never make this
# script overrun its budget, because the whole child is killed outright if it does not finish in time. Both
# /proc scans (ownership, task-mask) do ONE fork total each, regardless of how many fds/tasks exist: `find
# -lname` and a single `awk` do their own comparisons in-process instead of forking readlink/sed per item - a
# per-item loop here previously cost a real rig a hard fallback (~870 fds, all 32 threads mining, budget blown
# mid-scan under that fork load; an idle dev box never showed it).
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
# The parent (this file) always has a defined answer ready (the fallback below) for when the child is killed,
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
# i.e. the binding is independently confirmed, not just asserted by the API. Otherwise one row per thread with
# the package temperature (the core mapping is "unbound"). A row's rate is XMRig's own 10 s average; it drops
# to 0 within ~10-20 s of hashing stopping - this is not a "completed work" stamp. khs is always the sum of rows.
# State changes (API unavailable / affinity not verified / recovered) get one timestamped line in this
# package's OWN log, $CUSTOM_LOG_BASENAME.stats.log - never in XMRig's own log file, and never on stdout (this
# file is sourced by Hive's agent, not run as a standalone script). XMRig's FileLogWriter opens its log with
# O_CREAT|O_WRONLY (no O_APPEND) and tracks its own write offset from the size at open time: anything else
# appended to that same file is silently overwritten by XMRig's own next write, so a second writer's lines
# never survive there - confirmed on a live rig (state transitions really happened, per the state file, but no
# diagnostic line was ever found in XMRig's log or its rotated copies). The stats log is bounded to its last
# ~200 lines once it passes 1 MiB.
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
. "${BLOX_DIR:-/hive/miners/custom/bloxminer-x}/h-manifest.conf"   # BLOX_DIR: tests only

PROC=${BLOX_PROCFS_ROOT:-/proc}          # /proc path prefix; tests only
PKG=${BLOX_DIR:-/hive/miners/custom/bloxminer-x}
PORT=${BLOX_API_PORT:-${API_PORT:-4069}}
VER="bloxminer-x $CUSTOM_VERSION (xmrig 6.26.0)"
algo=$(jq -r '.pools[0].algo // empty' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null); [[ -n $algo ]] || algo="rx/0"

STATEDIR=${BLOX_STATE_DIR:-}
if [[ -z $STATEDIR ]]; then [[ -d /run/hive ]] && STATEDIR=/run/hive || STATEDIR=$PKG; fi
STATEFILE="$STATEDIR/.bloxminer-x-hstats-state"
export PROC PKG PORT VER algo STATEFILE CUSTOM_LOG_BASENAME

# The whole collection lives in one function library file so the parent (for its own fallback-on-timeout path)
# and the timed child (for the real work) run the exact same code - nothing is duplicated or re-typed.
LIB=$(mktemp "${TMPDIR:-/tmp}/bloxminer-x-hstats-lib.XXXXXX") || {
	khs=0; stats=$(printf '{"hs":[0],"hs_units":"khs","temp":[null],"ar":[0,0],"uptime":0,"ver":"%s","algo":"%s"}' "$VER" "$algo")
	return 0 2>/dev/null || exit 0
}
cat > "$LIB" <<'LIBEOF'
now() { date +%s.%N; }
remaining() { awk -v s="$t0" -v n="$(now)" -v b="$BUDGET" 'BEGIN{r=b-(n-s); if (r<0) r=0; printf "%.2f", r}'; }
have_budget() { awk -v r="$1" 'BEGIN{exit !(r > 0.05)}'; }   # < 50 ms left is not worth attempting
cap() { awk -v r="$1" -v c="$2" 'BEGIN{print (r<c)?r:c}'; }   # min(remaining, nominal per-step ceiling)

int() { [[ $1 =~ ^[0-9]+$ ]]; }

note_state() {   # $1 = ok | unverified | unavailable; logs only on a transition, never to stdout, and never
                 # into XMRig's own log file (see the top comment: XMRig writes it at its own tracked offset
                 # with no O_APPEND, so anything else appended there is silently overwritten by XMRig's next
                 # write). Own file instead: $CUSTOM_LOG_BASENAME.stats.log, timestamped, bounded to ~200 lines.
	local prev="" cur=$1 msg="" statslog="$CUSTOM_LOG_BASENAME.stats.log" sz
	[[ -f $STATEFILE ]] && prev=$(<"$STATEFILE")
	[[ $prev == "$cur" ]] && return 0
	case $cur in
		unavailable) msg="bloxminer-x: stats API unavailable" ;;
		unverified)  msg="bloxminer-x: affinity not verified, showing per-thread rows" ;;
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

fallback() {   # $1 = a single row's temperature (bloxsense pkg_temp, JSON number or null), default null
	khs=0
	stats=$(jq -nc --arg ver "$VER" --arg algo "$algo" --argjson temp "${1:-null}" \
		'{hs: [0], hs_units: "khs", temp: [$temp], ar: [0, 0], uptime: 0, ver: $ver, algo: $algo}')
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

# Collects everything and sets $khs/$stats. Every early exit is a plain `return 0` (this always runs as a
# function, whether called directly by the parent's own fallback path or, normally, inside the timed child).
run() {
	local r port_hex inode owner_pid owned fd_dir sum back uptime acc rej threads naff sense pkg_temp power_raw
	local percore task_set api_set rows

	r=$(remaining); have_budget "$r" || { note_state unavailable; fallback ""; return 0; }

	# ---- API ownership: /proc/net/tcp -> inode -> pid -> exe (the whole scan is inside the timed child)
	port_hex=$(printf '%04X' "$PORT")
	inode=$(awk -v p="$port_hex" 'NR > 1 { split($2, a, ":"); if (a[1] == "0100007F" && a[2] == p && $4 == "0A") print $10 }' \
		"$PROC/net/tcp" 2>/dev/null | head -n1)
	owner_pid=""
	if [[ -n $inode ]]; then
		# ONE fork total, whatever the size of the process table: `find -lname` compares every fd's symlink
		# target internally (no readlink child process per fd). A per-fd `readlink` loop here previously forked
		# once per fd - on a busy rig with hundreds of processes and thousands of fds, and every CPU already
		# saturated by mining, those forks alone were slow enough to blow the whole child's budget outright
		# (seen for real on a 5950X mining on all 32 threads: ~870 fds, budget expired mid-scan, hard fallback).
		fd_dir=$(find "$PROC" -mindepth 3 -maxdepth 3 -path "$PROC/[0-9]*/fd/*" -lname "socket:\[$inode\]" \
			-printf '%h\n' 2>/dev/null | head -n1)
		if [[ -n $fd_dir ]]; then
			owner_pid=${fd_dir#"$PROC"/}; owner_pid=${owner_pid%%/*}
		fi
	fi
	owned=0
	if [[ -n $owner_pid ]] && [[ $(readlink "$PROC/$owner_pid/exe" 2>/dev/null) == "$PKG/xmrig" ]]; then owned=1; fi
	if (( ! owned )); then note_state unavailable; fallback ""; return 0; fi

	# ---- the two API calls, each capped at min(remaining, 0.5 s)
	r=$(remaining); have_budget "$r" || { note_state unavailable; fallback ""; return 0; }
	sum=$(curl -fsS --max-time "$(cap "$r" 0.5)" "http://127.0.0.1:$PORT/2/summary" 2>/dev/null)

	r=$(remaining); have_budget "$r" || { note_state unavailable; fallback ""; return 0; }
	back=$(curl -fsS --max-time "$(cap "$r" 0.5)" "http://127.0.0.1:$PORT/2/backends" 2>/dev/null)

	if ! jq -e . > /dev/null 2>&1 <<< "$sum" || ! valid_summary "$sum" || ! jq -e . > /dev/null 2>&1 <<< "$back" || ! valid_backends "$back"; then
		note_state unavailable; fallback ""; return 0
	fi

	uptime=$(jq -r '.uptime // 0' <<< "$sum"); int "$uptime" || uptime=0
	acc=$(jq -r '.connection.accepted // 0' <<< "$sum"); int "$acc" || acc=0
	rej=$(jq -r '.connection.rejected // 0' <<< "$sum"); int "$rej" || rej=0

	threads=$(jq -c '[.[] | select(.type == "cpu") | .threads[]?] // []' <<< "$back" 2>/dev/null)
	[[ -n $threads ]] || threads='[]'
	naff=$(jq 'length' <<< "$threads" 2>/dev/null); int "$naff" || naff=0
	if (( naff == 0 )); then fallback ""; return 0; fi   # legitimate: no pool job yet, benign, not logged

	# ---- sensors: whatever is left, capped at min(remaining, 1.0 s) - bloxsense's own RAPL sample is ~0.55 s
	r=$(remaining)
	if have_budget "$r"; then
		# --foreground: keep bloxsense in the SAME process group as this script (and the outer timeout wrapping
		# the whole run below) instead of a new one of its own - otherwise a bloxsense that ignores SIGTERM
		# could end up in a process group the outer timeout's kill never reaches, and survive as an orphan.
		sense=$(timeout --foreground "$(cap "$r" 1.0)" "$PKG/bloxsense" --json 2>/dev/null)
	else
		sense=""
	fi
	jq -e . > /dev/null 2>&1 <<< "$sense" || sense='{"cpus":[],"pkg_temp":null,"power_w":null,"ccd_reason":""}'
	pkg_temp=$(jq -c '.pkg_temp' <<< "$sense")
	power_raw=$(jq -c '.power_w' <<< "$sense")

	# ---- binding verification, budget permitting (the /proc task scan is also inside the timed child)
	percore=0
	r=$(remaining)
	if have_budget "$r" && jq -e --argjson s "$sense" 'all(.affinity >= 0) and (map(.affinity as $a | ($s.cpus | any(.cpu == $a))) | all)' \
		<<< "$threads" > /dev/null 2>&1
	then
		# ONE awk fork over every task's status file, whatever their count: a task is "single-CPU" when its
		# Cpus_allowed_list expands to exactly one CPU. (Previously a per-task loop forked sed+tr+a subshell
		# for every task - the same class of bug as the fd scan above, fixed the same way: one process reads
		# every file instead of one process per file.)
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

	if (( percore )); then
		note_state ok
		rows=$(jq -c --argjson s "$sense" '
			def rate0: (.hashrate[0]) as $r | if ($r == null or ($r | type) != "number" or ($r | isnan) or ($r | isinfinite) or $r < 0) then 0 else $r end;
			($s.cpus | map({key: (.cpu | tostring), value: {pkg: .pkg, core: .core, temp: .temp}}) | from_entries) as $topo
			| map(. + {pc: $topo[(.affinity | tostring)], r0: rate0})
			| group_by([.pc.pkg, .pc.core])
			| map({khs: ((map(.r0 / 1000) | add) * 100 | round / 100), temp: .[0].pc.temp})' <<< "$threads")
	else
		note_state unverified
		rows=$(jq -c --argjson pt "$pkg_temp" '
			def rate0: (.hashrate[0]) as $r | if ($r == null or ($r | type) != "number" or ($r | isnan) or ($r | isinfinite) or $r < 0) then 0 else $r end;
			map({khs: ((rate0 / 1000) * 100 | round / 100), temp: $pt})' <<< "$threads")
	fi

	khs=$(jq -r '[.[].khs] | add // 0' <<< "$rows" | awk '{printf "%.2f", $1}')
	stats=$(jq -nc --argjson hs "$(jq -c '[.[].khs]' <<< "$rows")" --argjson temp "$(jq -c '[.[].temp]' <<< "$rows")" \
		--argjson ar "$(jq -nc --argjson a "$acc" --argjson r "$rej" '[$a, $r]')" --argjson uptime "$uptime" \
		--arg ver "$VER" --arg algo "$algo" --argjson power "$power_raw" \
		'{hs: $hs, hs_units: "khs", temp: $temp, ar: $ar, uptime: $uptime, ver: $ver, algo: $algo}
		 + (if ($power | type) == "number" and $power > 0 then {cpu_power: $power} else {} end)')
}

# The only stdout this whole library ever produces: one JSON line, printed once run() has set $khs/$stats.
collect() {
	run
	printf '%s' "$(jq -nc --arg k "$khs" --argjson s "$stats" '{khs: $k, stats: $s}')"
}
LIBEOF

# shellcheck disable=SC1090   # $LIB is a script this file just generated into a temp file, not a fixed path
. "$LIB"   # the parent also gets fallback()/note_state() from here, for when the timed child below is killed

CHILD_BUDGET=2.4   # of the shared 3.0 s deadline
KILL_GRACE=0.3      # extra time after SIGTERM before SIGKILL - bounds the hard kill at 2.7 s, leaving 0.3 s of
                    # slack for this wrapper + jq parsing, so the whole run stays under 3.0 s even in the worst
                    # case (SIGTERM ignored, waits out the full grace period, then an unmaskable SIGKILL).
# Captured via a temp file, never a pipe: a command-substitution pipe only reaches EOF once every process that
# ever held its write end (including an orphan that somehow escaped the kill) has closed it, so a survivor
# could hang this parent forever. Reading a plain file back never blocks on a stale writer.
OUTFILE=$(mktemp "${TMPDIR:-/tmp}/bloxminer-x-hstats-out.XXXXXX") || OUTFILE=""
# The child reports its OWN pgid, AFTER its setsid has taken effect, into this handshake file - this script
# never reads the child's pgid via `ps` itself. Right after backgrounding, the new process may still be
# running with the FORK-INHERITED pgid (ours, or whatever our own caller's is) for a brief window before it
# reaches its own setsid() call; reading `ps -o pgid=` at that instant would see that inherited pgid, and a
# later group-kill against it could hit our own caller instead of the collection. Only a value the child
# itself reports, once it truly is isolated, is ever trusted for a group-wide signal.
HANDSHAKE=$(mktemp "${TMPDIR:-/tmp}/bloxminer-x-hstats-hs.XXXXXX") || HANDSHAKE=""
PARENT_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')

if [[ -n $OUTFILE && -n $HANDSHAKE ]]; then
	# shellcheck disable=SC2016   # $1/$2 are the child bash's own positional parameters, not this shell's
	BUDGET="$CHILD_BUDGET" setsid bash -c '
		[[ -n ${BLOX_HSTATS_TEST_HANDSHAKE_DELAY:-} ]] && sleep "$BLOX_HSTATS_TEST_HANDSHAKE_DELAY"   # tests only
		{ printf "%s" "$(ps -o pgid= -p $$ 2>/dev/null | tr -d "[:space:]")"; } > "$2" 2>/dev/null
		. "$1"; t0=$(date +%s.%N); collect
	' _ "$LIB" "$HANDSHAKE" > "$OUTFILE" 2>/dev/null &
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

	# These alarm sleeps must never inherit this script's own stdout/stderr: when h-stats.sh itself is run
	# inside a command substitution (as Hive's agent, and every test here, does), an orphaned background job
	# that still holds that pipe's write end open blocks the CALLER waiting on it, even after everything else
	# has finished - regardless of how carefully it is killed/reaped below. Redirecting away from the start
	# closes that hole outright, and was needed in practice (an un-redirected alarm reproduced exactly this).
	{ sleep "$CHILD_BUDGET"; } > /dev/null 2>&1 & ALARM=$!
	wait -n "$CPID" "$ALARM" 2>/dev/null
	rc=$?
	# Checked by whether ANYTHING remains (in the validated group, or else just $CPID), not just whether
	# $CPID itself is still alive: $CPID is a plain bash process that dies immediately from a TERM, even when
	# a SIGTERM-ignoring descendant of its (e.g. a stuck bloxsense) does not - checking only $CPID would look
	# like "done" while such a descendant survives as an orphan.
	if still_running; then
		# the budget alarm fired first, not the collection itself: escalate against the validated group when
		# one is available (reaching every descendant, including a nested `timeout --foreground` and whatever
		# it is guarding), else against $CPID alone - never a guessed or unconfirmed group
		escalate TERM
		kill "$ALARM" 2>/dev/null; wait "$ALARM" 2>/dev/null
		sleep "$KILL_GRACE"
		still_running && escalate KILL
		wait "$CPID" 2>/dev/null   # $CPID was still unreaped here - reap it, get its real exit status
		rc=$?
	else
		# $CPID (not $ALARM) is what the first wait -n above reaped: $rc already holds its real exit status
		kill "$ALARM" 2>/dev/null; wait "$ALARM" 2>/dev/null
	fi
	result=$(cat "$OUTFILE" 2>/dev/null)
	rm -f "$OUTFILE" "$HANDSHAKE"
else
	rc=1; result=""
fi
rm -f "$LIB"

if [[ $rc == 0 ]] && jq -e 'type == "object" and (.khs | type) == "string" and has("stats")' > /dev/null 2>&1 <<< "$result"; then
	khs=$(jq -r '.khs' <<< "$result")
	stats=$(jq -c '.stats' <<< "$result")
else
	note_state unavailable   # the child was killed, crashed, or produced garbage - always land on the defined fallback
	fallback ""
fi
