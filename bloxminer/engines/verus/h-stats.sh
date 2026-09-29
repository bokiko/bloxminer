#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs (total kH/s) and $stats (JSON). The miner does the work (topology,
# temperatures, power, freshness); this script only reads its local API and checks the reply is complete.
# Rows: one per physical core (SMT threads summed) when every thread is bound and the topology resolves,
# else one per thread (both from the `cores` command); else a single FRESHKHS row; else 0.
# A stalled miner (every thread overdue, STALL=1) reports 0, never its last rate.
#
# The whole collection (both `nc` calls plus the `field()` parsing loop below, one per API field AND per
# `cores` row - tr+grep+cut, three forks each) runs inside a single 3.0 s-budgeted, killable child, the same
# proven mechanism the RandomX engine's own h-stats.sh already uses (see that file's header for the full
# rationale): on a rig with many physical cores this parsing loop forks a LOT of small processes, and on a
# small/saturated cpuset that fork/exec cost alone was measured to make the WHOLE script - which previously had
# no overall kill, only each individual `nc` call's own deadline-derived cap - run for multiple seconds past
# its budget with nothing to show for it (tests/hive/test_verus_under_load.sh: taskset -c 0 with the CPU fully
# saturated reproduced 8+ s runs with no result at all). If the timed child still misses its deadline, this
# poll answers from the last real sample instead of a hard 0 (bounded to CACHE_MAX_AGE_S seconds old, and only
# after a cheap, short-capped liveness probe of the API confirms SOMETHING is still answering right now - the
# same trust level this script's normal path already extends to whatever answers on $VPORT, never weaker) -
# never for a genuine stall (STALL=1 is a real, fast, honest 0 collected well inside budget, on the success
# path below, and that 0 becomes the next cached value) or a truly unreachable API (the liveness probe fails
# too, same as "no API answer" always has).
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
. "${BLOX_DIR:-/hive/miners/custom/bloxminer}/h-manifest.conf"   # BLOX_DIR: tests only
ENGINE_VERSION=3.0.0   # the frozen ccminer engine's own release version (this file never rebuilds it)

VPORT=${BLOX_API_PORT:-4068}   # a distinct name from the rx engine's own top-level $PORT - both
	# engines are sourced in the SAME shell across dispatcher polls (see tests/hive/test_dispatcher.sh's
	# "one shell" cases), and a name collision would leak one engine's last value into the other's.

VSTATEDIR=${BLOX_STATE_DIR:-}
if [[ -z $VSTATEDIR ]]; then [[ -d /run/hive ]] && VSTATEDIR=/run/hive || VSTATEDIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}; fi
VSTATEFILE="$VSTATEDIR/.bloxminer-verus-hstats-state"
VCACHEFILE="$VSTATEDIR/.bloxminer-verus-hstats-cache"   # last-known-good sample; see the header comment above
export VPORT VSTATEFILE VCACHEFILE CUSTOM_VERSION CUSTOM_CONFIG_FILENAME CUSTOM_LOG_BASENAME ENGINE_VERSION

CACHE_MAX_AGE_S=90   # see the RandomX engine's own h-stats.sh for the rationale behind this exact bound

LIB=$(mktemp "${TMPDIR:-/tmp}/bloxminer-verus-hstats-lib.XXXXXX") || {
	khs=0; stats=""
	return 0 2>/dev/null || exit 0
}
cat > "$LIB" <<'LIBEOF'
now() { date +%s.%N; }
num()  { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
int()  { [[ $1 =~ ^[0-9]+$ ]]; }
api() { local left=$(( deadline - $(date +%s) )); (( left < 1 )) && return 1
        echo -n "$1" | timeout "$left" nc 127.0.0.1 "$VPORT" 2>/dev/null | tr -d '\0'; }
# field <"KEY=val;KEY=val|..."> <KEY> - the first "KEY=" segment's value (";" and "|" both act as separators),
# or empty if absent. Pure parameter expansion - NO fork at all (was `tr ';|' '\n\n' | grep -m1 "^$2=" | cut
# -d= -f2-`, three forks every single call). With one 16-physical-core reply that field() is called roughly a
# hundred times a poll (8 summary fields + 6 header fields + up to 6 per `cores` row) - on a small/saturated
# cpuset those ~300 forks alone were measured to push the WHOLE script multiple seconds past its budget (see
# this file's header and tests/hive/test_verus_under_load.sh). first-match-wins, matching grep -m1's semantics.
field() {
	local s=$1 key=$2 tok
	while [[ -n $s ]]; do
		tok=${s%%[;|]*}
		if [[ ${#tok} -lt ${#s} ]]; then s=${s:$((${#tok}+1))}; else s=""; fi
		if [[ $tok == "$key="* ]]; then printf '%s' "${tok#"$key"=}"; return 0; fi
	done
}

note_state() {   # $1 = ok | cached; logs only on a transition, never to stdout - own file, never ccminer's log
	local prev="" cur=$1 msg="" statslog="$CUSTOM_LOG_BASENAME.stats.log" sz
	[[ -f $VSTATEFILE ]] && prev=$(<"$VSTATEFILE")
	[[ $prev == "$cur" ]] && return 0
	case $cur in
		cached) msg="bloxminer: stats collector missed its deadline under CPU load - showing the last known-good sample (${2:-?}s old) until a fresh one is collected" ;;
		ok)     [[ -n $prev ]] && msg="bloxminer: recovered" ;;
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
	{ printf '%s' "$cur" > "$VSTATEFILE"; } 2>/dev/null
}

# Collects everything and sets $khs/$stats - identical logic to BloxMiner 2.1.0/3.0.0's original flat script,
# just wrapped in a function so the timed child below (the real, normal case) and the parent's own
# no-temp-file fallback path (LIB itself failed to create) run the exact same code.
run() {
	local deadline sum acc rej up ver stall fresh power ptemp cores head gen age rows cov pstall percore want
	local ok hs temps n k t id pk co cpus ncpu r

	deadline=$(( $(date +%s) + 3 ))                 # one 3 s budget for every API call together
	sum=$(api summary)
	if [[ -z $sum ]]; then khs=0; stats=""; return 0; fi
	acc=$(field "$sum" ACC); rej=$(field "$sum" REJ); up=$(field "$sum" UPTIME); ver=$(field "$sum" VER)
	stall=$(field "$sum" STALL); fresh=$(field "$sum" FRESHKHS); power=$(field "$sum" POWER); ptemp=$(field "$sum" TEMP)
	int "$acc" || acc=0; int "$rej" || rej=0; num "$up" || up=0; [[ -n $ver ]] || ver=$ENGINE_VERSION
	int "$ptemp" || ptemp=""
	# The engine's own PACKAGE_VERSION (api.cpp's VER field) now tracks the package release 1:1, so the plain
	# "<version> (verus)" form is shown whenever they agree (the common, expected case); if a future package
	# release ever ships a different engine build (skipped engine rebuild, hotfix, etc.) this still shows both,
	# honestly, instead of silently collapsing to one number.
	if [[ $ver == "$CUSTOM_VERSION" ]]; then
		ver="$CUSTOM_VERSION (verus)"
	else
		ver="$CUSTOM_VERSION (verus, engine $ver)"
	fi

	hs=(); temps=(); ok=0
	if [[ $stall != 1 ]]; then
		cores=$(api cores)
		head=${cores%%|*}
		gen=$(field "$head" GEN); age=$(field "$head" AGE); rows=$(field "$head" ROWS); cov=$(field "$head" THREADS)
		pstall=$(field "$head" STALL); percore=$(field "$head" PERCORE)
		want=$(jq -r '.threads // empty' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null)
		[[ $pstall == 1 ]] && stall=1                               # a stall seen by either reply counts
		# accept only a fresh, complete reply that covers every configured thread exactly once
		if [[ $stall != 1 ]] && int "$gen" && (( gen > 0 )) && num "$age" && awk -v a="$age" 'BEGIN{exit !(a <= 6)}' &&
		   int "$want" && (( want > 0 )) && int "$rows" && (( rows > 0 && rows <= want )) &&
		   [[ $cov == "$want/$want" && $pstall == 0 && ( $percore == 0 || $percore == 1 ) ]] &&
		   { [[ $percore == 1 ]] || (( rows == want )); }; then
			ok=1; declare -A seen=() seencpu=(); ncpu=0; n=0
			IFS='|' read -ra parts <<< "${cores#*|}"
			for r in "${parts[@]}"; do
				[[ -z $r ]] && continue
				k=$(field "$r" KHS); t=$(field "$r" TEMP); id=$(field "$r" ROW)
				if ! [[ $id == "$n" ]] || ! num "$k"; then ok=0; break; fi   # rows numbered 0,1,2,... in order
				if [[ $percore == 1 ]]; then
					pk=$(field "$r" PKG); co=$(field "$r" CORE); cpus=$(field "$r" CPUS)
					if ! int "$pk" || ! int "$co" || ! [[ $cpus =~ ^[0-9]+(,[0-9]+)*$ && -z ${seen[$pk:$co]} ]]; then ok=0; break; fi
					seen[$pk:$co]=1
					for c in ${cpus//,/ }; do                          # every CPU exactly once across all rows
						[[ -z ${seencpu[$c]} ]] || { ok=0; break 2; }
						seencpu[$c]=1; ncpu=$((ncpu + 1))
					done
				fi
				int "$t" || t=$ptemp                          # no per-row sensor: package temperature
				hs+=("$k"); temps+=("${t:-null}"); n=$((n+1))
			done
			(( n == rows )) || ok=0                         # a truncated reply is not used
			[[ $percore == 1 ]] && (( ncpu != want )) && ok=0   # per-core rows must cover every thread's CPU
		fi
	fi

	if (( ok )); then
		khs=$(printf '%s\n' "${hs[@]}" | awk '{s+=$1} END{printf "%.2f", s}')
	elif [[ $stall == 1 ]]; then
		khs=0; hs=(0); temps=("${ptemp:-null}")
	else
		num "$fresh" || fresh=0                             # the miner's freshness-aware total, never raw KHS
		khs=$fresh; hs=("$fresh"); temps=("${ptemp:-null}")
	fi

	n=${#hs[@]}
	# fan/bus: n-long placeholder arrays (this engine reports neither). Built with jq's own range(), never a
	# `yes | head` pipe: `yes` never stops on its own, so head closing the pipe early relies on `yes` dying from
	# SIGPIPE - a shell/runner that ignores SIGPIPE (observed on some GitHub Actions runners) leaves `yes` alive
	# long enough to hit EPIPE on write() and print "yes: standard output: Broken pipe" to stderr instead, which
	# also had no reason to fork two extra processes per h-stats poll (yes, head) for two constant-length arrays.
	stats=$(jq -nc \
		--argjson hs "$(printf '%s\n' "${hs[@]}" | jq -cs 'map(tonumber)')" \
		--argjson temp "$(printf '%s\n' "${temps[@]}" | jq -cs '.')" \
		--argjson fan "$(jq -nc --argjson n "$n" '[range($n)] | map(0)')" \
		--argjson bus "$(jq -nc --argjson n "$n" '[range($n)] | map(null)')" \
		--argjson uptime "${up%.*}" --argjson acc "$acc" --argjson rej "$rej" --arg ver "$ver" --arg w "$power" \
		'{hs: $hs, hs_units: "khs", temp: $temp, fan: $fan, bus_numbers: $bus, uptime: $uptime, ar: [$acc, $rej],
		  algo: "verushash", ver: $ver}
		 + (if ($w | test("^[0-9]+$")) then {cpu_power: ($w | tonumber)} else {} end)')

	# last-known-good cache: written on every complete collection that reaches this point (including a real,
	# honest STALL=1 -> khs=0 - see the header comment: that is exactly the value that must be cached, so a
	# later timeout can never show a stale POSITIVE number over a real stall). Never written on the "no API
	# answer" early return above.
	note_state ok
	{ printf 'ts=%s\nkhs=%s\nstats=%s\n' "$(now)" "$khs" "$stats" > "$VCACHEFILE.tmp" && mv -f "$VCACHEFILE.tmp" "$VCACHEFILE"; } 2>/dev/null
}

collect() {
	run
	printf '%s' "$(jq -nc --arg k "$khs" --arg s "$stats" '{khs: $k, stats: $s}')"
}
LIBEOF

# shellcheck disable=SC1090   # $LIB is a script this file just generated into a temp file, not a fixed path
. "$LIB"

CHILD_BUDGET=2.4   # of the shared 3.0 s deadline - same constants as the RandomX engine's own h-stats.sh
KILL_GRACE=0.3

OUTFILE=$(mktemp "${TMPDIR:-/tmp}/bloxminer-verus-hstats-out.XXXXXX") || OUTFILE=""
HANDSHAKE=$(mktemp "${TMPDIR:-/tmp}/bloxminer-verus-hstats-hs.XXXXXX") || HANDSHAKE=""
PARENT_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')

if [[ -n $OUTFILE && -n $HANDSHAKE ]]; then
	# shellcheck disable=SC2016   # $1/$2 are the child bash's own positional parameters, not this shell's
	BUDGET="$CHILD_BUDGET" setsid bash -c '
		[[ -n ${BLOX_HSTATS_TEST_HANDSHAKE_DELAY:-} ]] && sleep "$BLOX_HSTATS_TEST_HANDSHAKE_DELAY"   # tests only
		{ printf "%s" "$(ps -o pgid= -p $$ 2>/dev/null | tr -d "[:space:]")"; } > "$2" 2>/dev/null
		. "$1"; collect
	' _ "$LIB" "$HANDSHAKE" > "$OUTFILE" 2>/dev/null &
	CPID=$!

	validated_pgid() {   # see the RandomX engine's own h-stats.sh for the full rationale (identical pattern)
		local hs=""
		[[ -s $HANDSHAKE ]] && hs=$(cat "$HANDSHAKE" 2>/dev/null)
		[[ $hs =~ ^[0-9]+$ ]] || return 1
		[[ $hs == "$CPID" && $hs != "$PARENT_PGID" ]] || return 1
		(( hs > 1 )) || return 1
		echo "$hs"
	}
	still_running() {
		local g; g=$(validated_pgid)
		if [[ -n $g ]]; then pgrep -g "$g" > /dev/null 2>&1; else kill -0 "$CPID" 2>/dev/null; fi
	}
	escalate() {
		local g; g=$(validated_pgid)
		if [[ -n $g ]]; then kill -"$1" -- "-$g" 2>/dev/null; else kill -"$1" "$CPID" 2>/dev/null; fi
	}

	{ sleep "$CHILD_BUDGET"; } > /dev/null 2>&1 & ALARM=$!
	wait -n "$CPID" "$ALARM" 2>/dev/null
	rc=$?
	if still_running; then
		escalate TERM
		kill "$ALARM" 2>/dev/null; wait "$ALARM" 2>/dev/null
		sleep "$KILL_GRACE"
		still_running && escalate KILL
		wait "$CPID" 2>/dev/null
		rc=$?
	else
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
	stats=$(jq -r '.stats' <<< "$result")
else
	# The timed child was killed, crashed, or produced garbage - almost always the field-parsing loop itself
	# (see the file header) losing to CPU contention on a small cpuset, not the miner being down: a genuinely
	# unreachable API resolves inside the child, fast (the "no API answer" early return in run()), and lands in
	# the rc==0 branch above with an honest stats="" - it never reaches here. Answer from the last real sample
	# instead of a hard 0, bounded to CACHE_MAX_AGE_S seconds old and only after a short, cheap liveness probe
	# of the SAME API confirms something is still answering right now (never a stronger trust bar than this
	# script's own normal path already applies to that answer).
	cache_used=0
	if [[ -f $VCACHEFILE ]]; then
		c_ts="" c_khs="" c_stats=""
		while IFS='=' read -r ck cv; do
			case $ck in ts) c_ts=$cv ;; khs) c_khs=$cv ;; stats) c_stats=$cv ;; esac
		done < "$VCACHEFILE" 2>/dev/null
		if [[ -n $c_ts && -n $c_khs && -n $c_stats ]]; then
			age=$(awk -v t="$c_ts" -v n="$(now)" 'BEGIN{a=n-t; if (a<0) a=0; printf "%.0f", a}')
			if (( age <= CACHE_MAX_AGE_S )); then
				# Two attempts, not one: this probe itself competes for the same starved CPUs that made the
				# main collection miss its deadline in the first place, and a single 0.4 s attempt was
				# observed (test_verus_under_load.sh, 1-2 CPU cases) to occasionally lose that race on its
				# own and report "no answer" even though the API was, in fact, still up - which would have
				# produced exactly the false zero this whole mechanism exists to prevent. A second attempt
				# after the first comes back empty costs nothing when the API is genuinely gone (both attempts
				# just spend their own short timeout) and meaningfully closes that race when it is not.
				probe=""
				for _probe_try in 1 2; do
					probe=$(echo -n summary | timeout 0.5 nc 127.0.0.1 "$VPORT" 2>/dev/null | tr -d '\0')
					[[ -n $probe ]] && break
				done
				if [[ -n $probe ]]; then
					khs=$c_khs; stats=$c_stats; cache_used=1
					note_state cached "$age"
				fi
			fi
		fi
	fi
	(( cache_used )) || { khs=0; stats=""; }
fi
