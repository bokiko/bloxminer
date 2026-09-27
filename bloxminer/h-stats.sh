#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs (total kH/s) and $stats (JSON). The miner does the work (topology,
# temperatures, power, freshness); this script only reads its local API and checks the reply is complete.
# Rows: one per physical core (SMT threads summed) when every thread is bound and the topology resolves,
# else one per thread (both from the `cores` command); else a single FRESHKHS row; else 0.
# A stalled miner (every thread overdue, STALL=1) reports 0, never its last rate.
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
. "${BLOX_DIR:-/hive/miners/custom/bloxminer}/h-manifest.conf"   # BLOX_DIR: tests only

deadline=$(( $(date +%s) + 3 ))                 # one 3 s budget for every API call together
api() { local left=$(( deadline - $(date +%s) )); (( left < 1 )) && return 1
        echo -n "$1" | timeout "$left" nc 127.0.0.1 "${BLOX_API_PORT:-4068}" 2>/dev/null | tr -d '\0'; }
num()  { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
int()  { [[ $1 =~ ^[0-9]+$ ]]; }

sum=$(api summary)
if [[ -z $sum ]]; then khs=0; stats=""; return 0 2>/dev/null || exit 0; fi
field() { tr ';|' '\n\n' <<< "$1" | grep -m1 "^$2=" | cut -d= -f2-; }
acc=$(field "$sum" ACC); rej=$(field "$sum" REJ); up=$(field "$sum" UPTIME); ver=$(field "$sum" VER)
stall=$(field "$sum" STALL); fresh=$(field "$sum" FRESHKHS); power=$(field "$sum" POWER); ptemp=$(field "$sum" TEMP)
int "$acc" || acc=0; int "$rej" || rej=0; num "$up" || up=0; [[ -n $ver ]] || ver=$CUSTOM_VERSION
int "$ptemp" || ptemp=""

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
stats=$(jq -nc \
	--argjson hs "$(printf '%s\n' "${hs[@]}" | jq -cs 'map(tonumber)')" \
	--argjson temp "$(printf '%s\n' "${temps[@]}" | jq -cs '.')" \
	--argjson fan "$(yes 0 | head -n "$n" | jq -cs .)" \
	--argjson bus "$(yes null | head -n "$n" | jq -cs .)" \
	--argjson uptime "${up%.*}" --argjson acc "$acc" --argjson rej "$rej" --arg ver "$ver" --arg w "$power" \
	'{hs: $hs, hs_units: "khs", temp: $temp, fan: $fan, bus_numbers: $bus, uptime: $uptime, ar: [$acc, $rej],
	  algo: "verushash", ver: $ver}
	 + (if ($w | test("^[0-9]+$")) then {cpu_power: ($w | tonumber)} else {} end)')
