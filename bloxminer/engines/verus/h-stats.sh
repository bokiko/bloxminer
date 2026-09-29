#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs (total kH/s) and $stats (JSON). The miner does the work (topology,
# temperatures, power, freshness); this script only reads its local API and checks the reply is complete.
# Rows: one per physical core (SMT threads summed) when every thread is bound and the topology resolves,
# else one per thread (both from the `cores` command); else a single FRESHKHS row; else 0.
# A stalled miner (every thread overdue, STALL=1) reports 0, never its last rate.
#
# PR #2 review (round 2): an earlier version of this file cached the last positive $khs and served it on a
# missed deadline, gated by a short liveness probe. Codex correctly rejected that: a live process (even the
# SAME instance, confirmed) proves nothing about whether it is still hashing, "any nonempty reply" is a weak
# gate (it does not even notice STALL=1/FRESHKHS=0 in the cached sample), and the probe's own extra time ran
# past the total deadline. Redesign: the hashrate is NEVER cached. Each poll is split into
#   Phase A (mandatory, cheap): one `summary` call - already gives STALL, FRESHKHS, ACC/REJ/UPTIME/POWER/TEMP.
#     This alone is enough to answer honestly every time: STALL=1 -> 0 immediately; otherwise FRESHKHS as a
#     single-row total. Written to $OUTFILE the moment it is ready.
#   Phase B (optional, whatever budget remains): the `cores` call, for a real per-core breakdown - overwrites
#     Phase A's answer with a richer one if it validates in time, but Phase A's answer already sitting in
#     $OUTFILE means a kill during Phase B never loses it.
# So a poll's answer is always either genuinely fresh (this exact call, this exact poll) or the defined 0 - not
# a cache with an age bound, because there is no cache left to bound.
#
# The whole collection (both `nc` calls plus the `field()` parsing loop below, one per API field AND per
# `cores` row - tr+grep+cut, three forks each, would have been - see field() below, now fork-free) runs inside
# a single, ONE-absolute-deadline, killable child, the same proven mechanism the RandomX engine's own
# h-stats.sh already uses (see that file's header for the full rationale): on a rig with many physical cores
# the per-row parsing loop runs `field()` many times, and on a small/saturated cpuset that cost alone was
# measured to push the WHOLE script multiple seconds past its budget with nothing to show for it
# (tests/hive/test_verus_under_load.sh: taskset -c 0 with the CPU fully saturated reproduced 8+ s runs with no
# result at all, before field() was made fork-free). `api()`'s own `timeout nc` runs with `--foreground` so it
# stays in the SAME process group as this whole collection (a bare `timeout` would otherwise start `nc` in a
# NEW group of its own, which the outer group-kill below could not reach - the exact class of bug rx's own
# bloxsense call already guards against the same way).
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
. "${BLOX_DIR:-/hive/miners/custom/bloxminer}/h-manifest.conf"   # BLOX_DIR: tests only
ENGINE_VERSION=3.0.0   # the frozen ccminer engine's own release version (this file never rebuilds it)

VPORT=${BLOX_API_PORT:-4068}   # a distinct name from the rx engine's own top-level $PORT - both
	# engines are sourced in the SAME shell across dispatcher polls (see tests/hive/test_dispatcher.sh's
	# "one shell" cases), and a name collision would leak one engine's last value into the other's.
export VPORT CUSTOM_VERSION CUSTOM_CONFIG_FILENAME ENGINE_VERSION

LIB=$(mktemp "${TMPDIR:-/tmp}/bloxminer-verus-hstats-lib.XXXXXX") || {
	khs=0; stats=""
	return 0 2>/dev/null || exit 0
}
cat > "$LIB" <<'LIBEOF'
# Budget arithmetic below is pure bash - NO FORK AT ALL (was `date` + `awk` on every single check). See the
# RandomX engine's own h-stats.sh for the full rationale (same real-Hive evidence, same fix, applied here too
# for consistency and extra margin even though this engine's own field()-fork removal already measured well
# within budget on a real saturated rig).
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
us_to_secstr() {   # $1 = microseconds -> $REPLY = "S.ffffff", for the `timeout` below - no fork
	local us=$1 f
	printf -v f '%06d' $(( us % 1000000 ))
	REPLY="$(( us / 1000000 )).$f"
}
num()  { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
int()  { [[ $1 =~ ^[0-9]+$ ]]; }
# --foreground: see the file header - keeps `nc` in this collection's own process group so the outer group-kill
# (below) can always reach it, even though `timeout` would otherwise isolate it into a new group of its own.
api() {
	remaining_us; have_budget_us "$REPLY" || return 1
	cap_us "$REPLY" 600000; us_to_secstr "$REPLY"
	echo -n "$1" | timeout --foreground "$REPLY" nc 127.0.0.1 "$VPORT" 2>/dev/null | tr -d '\0'
}
# field <"KEY=val;KEY=val|..."> <KEY> - the first "KEY=" segment's value (";" and "|" both act as separators),
# or empty if absent. Pure parameter expansion - NO fork at all (was `tr ';|' '\n\n' | grep -m1 "^$2=" | cut
# -d= -f2-`, three forks every single call). first-match-wins, matching grep -m1's semantics.
field() {
	local s=$1 key=$2 tok
	while [[ -n $s ]]; do
		tok=${s%%[;|]*}
		if [[ ${#tok} -lt ${#s} ]]; then s=${s:$((${#tok}+1))}; else s=""; fi
		if [[ $tok == "$key="* ]]; then printf '%s' "${tok#"$key"=}"; return 0; fi
	done
}

# write_result <khs> <stats-json> - atomic (tmp+rename) write of this poll's answer to $OUTFILE. Called once
# after Phase A (the mandatory, always-fresh single-row answer) and again after Phase B if it improves on it -
# never the other way around, and never with anything but data this exact poll just collected.
write_result() {
	local tmp="$OUTFILE.w.$$"
	{ printf '%s' "$(jq -nc --arg k "$1" --arg s "$2" '{khs: $k, stats: $s}')" > "$tmp" && mv -f "$tmp" "$OUTFILE"; } 2>/dev/null
}

# Sets $khs/$stats and writes $OUTFILE at least once (Phase A) - identical field/API logic to BloxMiner
# 2.1.0/3.0.0's original design, split into a mandatory fresh-rate phase and an optional enrichment phase.
run() {
	local sum acc rej up ver stall fresh power ptemp cores head gen age rows cov pstall percore want
	local ok hs temps n k t id pk co cpus ncpu r

	sum=$(api summary)
	if [[ -z $sum ]]; then khs=0; stats=""; write_result "$khs" "$stats"; return 0; fi
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

	# ---- Phase A (mandatory): honest, THIS-POLL answer from summary alone - STALL=1 -> 0, else FRESHKHS as a
	# single row. Written now, before Phase B (the `cores` call) is even attempted, so a kill during Phase B can
	# never lose it.
	if [[ $stall == 1 ]]; then
		khs=0; hs=(0); temps=("${ptemp:-null}")
	else
		num "$fresh" || fresh=0                             # the miner's freshness-aware total, never raw KHS
		khs=$fresh; hs=("$fresh"); temps=("${ptemp:-null}")
	fi
	n=${#hs[@]}
	stats=$(jq -nc \
		--argjson hs "$(printf '%s\n' "${hs[@]}" | jq -cs 'map(tonumber)')" \
		--argjson temp "$(printf '%s\n' "${temps[@]}" | jq -cs '.')" \
		--argjson fan "$(jq -nc --argjson n "$n" '[range($n)] | map(0)')" \
		--argjson bus "$(jq -nc --argjson n "$n" '[range($n)] | map(null)')" \
		--argjson uptime "${up%.*}" --argjson acc "$acc" --argjson rej "$rej" --arg ver "$ver" --arg w "$power" \
		'{hs: $hs, hs_units: "khs", temp: $temp, fan: $fan, bus_numbers: $bus, uptime: $uptime, ar: [$acc, $rej],
		  algo: "verushash", ver: $ver}
		 + (if ($w | test("^[0-9]+$")) then {cpu_power: ($w | tonumber)} else {} end)')
	write_result "$khs" "$stats"
	(( stall == 1 )) && return 0   # a real stall never attempts Phase B - nothing more to show, honestly
	local khs_a=$khs   # Phase A's own total, kept aside - Phase B may add detail rows but may only ever
		# REPLACE this with its own total when that total is complete AND consistent with it (never a
		# validly-formatted-but-zero cores reply quietly outvoting a positive, fresher summary rate)

	# ---- Phase B (optional): per-core breakdown, whatever budget remains. Only ever OVERWRITES Phase A's
	# answer with a richer one built from data collected THIS SAME poll - never a substitute for it.
	[[ -n ${BLOX_HSTATS_TEST_PHASEB_DELAY:-} ]] && sleep "$BLOX_HSTATS_TEST_PHASEB_DELAY"   # tests only
	remaining_us; have_budget_us "$REPLY" || return 0
	cores=$(api cores)
	[[ -z $cores ]] && return 0
	head=${cores%%|*}
	gen=$(field "$head" GEN); age=$(field "$head" AGE); rows=$(field "$head" ROWS); cov=$(field "$head" THREADS)
	pstall=$(field "$head" STALL); percore=$(field "$head" PERCORE)
	want=$(jq -r '.threads // empty' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null)
	if [[ $pstall == 1 ]]; then
		# A stall seen in THIS reply (even though summary's own STALL said 0) is real, fresh information from
		# the SAME poll - a stall detected by either reply always counts (unchanged from the original,
		# pre-redesign semantics). It must OVERWRITE Phase A's FRESHKHS-based answer with an honest 0, never
		# silently leave a positive number standing just because Phase A ran first.
		khs=0; hs=(0); temps=("${ptemp:-null}")
		stats=$(jq -nc --argjson hs "$(printf '%s\n' "${hs[@]}" | jq -cs 'map(tonumber)')" \
			--argjson temp "$(printf '%s\n' "${temps[@]}" | jq -cs '.')" \
			--argjson fan "$(jq -nc '[0]')" --argjson bus "$(jq -nc '[null]')" \
			--argjson uptime "${up%.*}" --argjson acc "$acc" --argjson rej "$rej" --arg ver "$ver" --arg w "$power" \
			'{hs: $hs, hs_units: "khs", temp: $temp, fan: $fan, bus_numbers: $bus, uptime: $uptime, ar: [$acc, $rej],
			  algo: "verushash", ver: $ver}
			 + (if ($w | test("^[0-9]+$")) then {cpu_power: ($w | tonumber)} else {} end)')
		write_result "$khs" "$stats"
		return 0
	fi
	ok=0
	if int "$gen" && (( gen > 0 )) && num "$age" && awk -v a="$age" 'BEGIN{exit !(a <= 6)}' &&
	   int "$want" && (( want > 0 )) && int "$rows" && (( rows > 0 && rows <= want )) &&
	   [[ $cov == "$want/$want" && $pstall == 0 && ( $percore == 0 || $percore == 1 ) ]] &&
	   { [[ $percore == 1 ]] || (( rows == want )); }; then
		ok=1; declare -A seen=() seencpu=(); ncpu=0; n=0; hs=(); temps=()
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
	(( ok )) || return 0   # Phase B did not validate - Phase A's answer (already written) stands, unchanged

	local khs_b; khs_b=$(printf '%s\n' "${hs[@]}" | awk '{s+=$1} END{printf "%.2f", s}')
	# consistent := not (Phase B's total is 0 while Phase A's, from the SAME poll, was positive) - a complete,
	# validly-formatted cores reply summing to exactly 0 right after summary reported a positive FRESHKHS is
	# the false-zero this review caught, not a fresher answer, so Phase A's total stands; the per-core rows are
	# still shown (they are structurally valid), just not trusted to override the top-level rate.
	if awk -v b="$khs_b" -v a="$khs_a" 'BEGIN{ exit !(b+0 == 0 && a+0 > 0) }'; then
		khs=$khs_a
	else
		khs=$khs_b
	fi
	n=${#hs[@]}
	stats=$(jq -nc \
		--argjson hs "$(printf '%s\n' "${hs[@]}" | jq -cs 'map(tonumber)')" \
		--argjson temp "$(printf '%s\n' "${temps[@]}" | jq -cs '.')" \
		--argjson fan "$(jq -nc --argjson n "$n" '[range($n)] | map(0)')" \
		--argjson bus "$(jq -nc --argjson n "$n" '[range($n)] | map(null)')" \
		--argjson uptime "${up%.*}" --argjson acc "$acc" --argjson rej "$rej" --arg ver "$ver" --arg w "$power" \
		'{hs: $hs, hs_units: "khs", temp: $temp, fan: $fan, bus_numbers: $bus, uptime: $uptime, ar: [$acc, $rej],
		  algo: "verushash", ver: $ver}
		 + (if ($w | test("^[0-9]+$")) then {cpu_power: ($w | tonumber)} else {} end)')
	write_result "$khs" "$stats"
}
LIBEOF

# shellcheck disable=SC1090   # $LIB is a script this file just generated into a temp file, not a fixed path
. "$LIB"

BUDGET_US=2400000  # of the shared 3.0 s deadline - integer microseconds, for the forkless budget arithmetic
                    # both this parent and the child (run(), via remaining_us) derive every timer from
KILL_GRACE=0.3
# ONE absolute deadline, computed HERE, before the child is even launched - process setup (setsid, exec, LIB
# sourcing) counts against the budget, not just the child's own post-launch work, and the parent's own alarm
# below derives its sleep from the SAME value, not a second, independently-drifting 2.4 s timer of its own.
now_us; DEADLINE_US=$(( REPLY + BUDGET_US ))

# $OUTFILE is written to DIRECTLY by run() (via write_result), atomically, at least once after Phase A and
# again after Phase B if that also completes - never captured from the child's stdout (collect()/a single
# final print is gone): a kill mid-Phase-B must never erase Phase A's already-written, honest answer.
OUTFILE=$(mktemp "${TMPDIR:-/tmp}/bloxminer-verus-hstats-out.XXXXXX") || OUTFILE=""
HANDSHAKE=$(mktemp "${TMPDIR:-/tmp}/bloxminer-verus-hstats-hs.XXXXXX") || HANDSHAKE=""
PARENT_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')
export OUTFILE

if [[ -n $OUTFILE && -n $HANDSHAKE ]]; then
	# shellcheck disable=SC2016   # $1/$2 are the child bash's own positional parameters, not this shell's
	BUDGET_US="$BUDGET_US" DEADLINE_US="$DEADLINE_US" setsid bash -c '
		[[ -n ${BLOX_HSTATS_TEST_HANDSHAKE_DELAY:-} ]] && sleep "$BLOX_HSTATS_TEST_HANDSHAKE_DELAY"   # tests only
		{ printf "%s" "$(ps -o pgid= -p $$ 2>/dev/null | tr -d "[:space:]")"; } > "$2" 2>/dev/null
		. "$1"
		run
	' _ "$LIB" "$HANDSHAKE" > /dev/null 2>&1 &
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

	# Sleep duration is whatever remains of the SAME $DEADLINE_US right now, not a fresh $BUDGET_US - the
	# setsid+exec above already spent some of the shared budget, and this alarm must not hand it back.
	remaining_us; us_to_secstr "$REPLY"; ALARM_SLEEP=$REPLY
	{ sleep "$ALARM_SLEEP"; } > /dev/null 2>&1 & ALARM=$!
	wait -n "$CPID" "$ALARM" 2>/dev/null
	if still_running; then
		escalate TERM
		kill "$ALARM" 2>/dev/null; wait "$ALARM" 2>/dev/null
		sleep "$KILL_GRACE"
		still_running && escalate KILL
		wait "$CPID" 2>/dev/null
	else
		kill "$ALARM" 2>/dev/null; wait "$ALARM" 2>/dev/null
	fi
	result=$(cat "$OUTFILE" 2>/dev/null)
	rm -f "$OUTFILE" "$HANDSHAKE"
else
	result=""
fi
rm -f "$LIB"

# Whatever $OUTFILE holds - Phase A's answer, or Phase B's richer one, or nothing at all if the child was
# killed before Phase A even finished writing - is used as-is: no cache, no age bound, no re-verification,
# because there is nothing here that was not collected THIS poll. Nothing written at all (killed too early, or
# the LIB/OUTFILE/HANDSHAKE temp files themselves could not even be created) is the only case that falls back
# to the defined, honest 0.
if jq -e 'type == "object" and (.khs | type) == "string" and has("stats")' > /dev/null 2>&1 <<< "$result"; then
	khs=$(jq -r '.khs' <<< "$result")
	stats=$(jq -r '.stats' <<< "$result")
else
	khs=0; stats=""
fi
