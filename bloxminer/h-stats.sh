#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs (total kH/s) and $stats (JSON).
# Rows: one per PHYSICAL core (SMT sibling threads summed) when the patched `threads` API answers completely
# and every thread's bound cpu resolves in sysfs; else one per thread; else a single total row.
# Temps: Intel = per-core coretemp; AMD = temperature of the core's CCD (AMD has no per-core sensor) when the
# CCD map applies (CCD_TEMP_MAP=auto|1|0 in h-manifest.conf), else package temp.
# Power: total CPU package power from RAPL powercap (no kernel modules loaded). Unavailable => omitted, never 0.
# A stalled miner (every thread overdue, STALL=1 from the miner) reports 0 hashrate, never its last rate.
. /hive/miners/custom/bloxminer/h-manifest.conf
STALL_SECS=600
SYS=/sys/devices/system/cpu

deadline=$(( $(date +%s) + 3 ))
api() { local left=$(( deadline - $(date +%s) )); (( left < 1 )) && return 1
        echo -n "$1" | timeout $left nc 127.0.0.1 4068 2>/dev/null | tr -d '\0'; }
sum=$(api summary)
if [[ -z $sum ]]; then khs=0; stats=""; return 0 2>/dev/null || exit 0; fi

get() { tr ';|' '\n\n' <<< "$sum" | grep "^$1=" | head -1 | cut -d= -f2; }
tkhs=$(get KHS); acc=$(get ACC); rej=$(get REJ); up=$(get UPTIME); ver=$(get VER); lastwork=$(get LASTWORK)

pkg_temp=$(cpu-temp 2>/dev/null); [[ $pkg_temp =~ ^[0-9]+$ ]] || pkg_temp=0

# ---- temperature for a cpu number
hwmon_by_name() { local h; for h in /sys/class/hwmon/hwmon*; do [[ $(cat $h/name 2>/dev/null) == "$1" ]] && echo $h; done; }
K10=$(hwmon_by_name k10temp | head -1)
# CCD temp map (L3 id n <-> Tccd n+1) validated by per-CCD load test on a Ryzen 9 5950X (family 25 model 33), 2026-09-26.
# auto = only that CPU model with matching #L3 / #Tccd; 1 = force on; 0 = off (package temp).
CCD_OK=0
if [[ -n $K10 ]]; then
  case ${CCD_TEMP_MAP:-auto} in
    1) CCD_OK=1 ;;
    auto)
      fam=$(awk -F: '/^cpu family/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
      mdl=$(awk -F: '/^model[[:space:]]*:/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
      nl3=$(cat $SYS/cpu[0-9]*/cache/index3/id 2>/dev/null | sort -u | wc -l)
      ntccd=$(grep -l '^Tccd' $K10/temp*_label 2>/dev/null | wc -l)
      # only the topology validated by load test (Ryzen 5000 "Vermeer": family 25 model 33, 1-2 CCDs)
      [[ $fam == 25 && $mdl == 33 && $nl3 -ge 1 && $nl3 -le 2 && $nl3 == $ntccd ]] && CCD_OK=1 ;;
  esac
fi
cpu_temp_for() { # $1 cpu -> temp C or empty
  local pk cid h lab l3 idx
  if [[ -n $K10 ]]; then
    [[ $CCD_OK == 1 ]] || return
    l3=$(cat $SYS/cpu$1/cache/index3/id 2>/dev/null) || return
    idx=$(( l3 + 1 ))                                   # validated: L3 id n <-> Tccd(n+1) for this topology
    for lab in $K10/temp*_label; do
      if [[ $(cat $lab) == "Tccd$idx" ]]; then echo $(( $(cat ${lab%_label}_input) / 1000 )); return; fi
    done
    return
  fi
  pk=$(cat $SYS/cpu$1/topology/physical_package_id 2>/dev/null) || return
  cid=$(cat $SYS/cpu$1/topology/core_id 2>/dev/null) || return
  for h in $(hwmon_by_name coretemp); do
    grep -qx "Package id $pk" $h/temp1_label 2>/dev/null || continue
    for lab in $h/temp*_label; do
      if grep -qx "Core $cid" $lab; then echo $(( $(cat ${lab%_label}_input) / 1000 )); return; fi
    done
  done
}

# ---- total CPU package power (W) from RAPL energy counter, sampled between agent ticks
cpu_power() {
  local z=/sys/class/powercap/intel-rapl:0 st=/run/hive/bloxminer.energy e now range prev_e prev_t dt de maxdt
  [[ -r $z/energy_uj ]] || return
  exec 9>/run/hive/bloxminer.energy.lock 2>/dev/null || return
  flock -n 9 || { exec 9>&-; return; }
  e=$(cat $z/energy_uj 2>/dev/null); range=$(cat $z/max_energy_range_uj 2>/dev/null)
  now=$(cut -d' ' -f1 /proc/uptime)                      # monotonic seconds
  if [[ -f $st ]]; then read -r prev_t prev_e < $st; fi
  echo "$now $e" > $st.tmp && mv -f $st.tmp $st
  exec 9>&-
  [[ $e =~ ^[0-9]+$ && $range =~ ^[0-9]+$ && $prev_e =~ ^[0-9]+$ ]] || return
  awk -v t0="$prev_t" -v t1="$now" -v e0="$prev_e" -v e1="$e" -v r="$range" 'BEGIN{
    dt=t1-t0; maxdt=r/(1000*1e6); if (dt<=0.5 || dt>maxdt) exit 1
    de=e1-e0; if (de<0) de+=r; w=de/1e6/dt; if (w<=0 || w>1000) exit 1; printf "%.0f", w }'
}

# stall = every miner thread overdue against its own batch length (computed by the miner, STALL=1);
# older builds without STALL: fall back to LASTWORK > STALL_SECS
stall=$(get STALL); stalled=0
if [[ $stall =~ ^[01]$ ]]; then stalled=$stall
elif [[ $lastwork =~ ^-?[0-9]+$ ]] && (( lastwork < 0 || lastwork > STALL_SECS )); then stalled=1; fi

hs=(); temps=(); ok=0
thr=$(api threads)
if [[ -n $thr && $stalled == 0 ]]; then
  ok=1; declare -A seen=() rate=() aff=()
  IFS='|' read -ra rows <<< "$thr"
  for r in "${rows[@]}"; do
    [[ -z $r ]] && continue
    id=$(grep -o 'CPU=[0-9]*' <<< "$r" | cut -d= -f2); k=$(grep -o 'KHS=[0-9.]*' <<< "$r" | cut -d= -f2)
    a=$(grep -o 'AFF=-\?[0-9]*' <<< "$r" | cut -d= -f2)
    [[ $id =~ ^[0-9]+$ && $k =~ ^[0-9]+(\.[0-9]+)?$ && -z ${seen[$id]} ]] || { ok=0; break; }
    seen[$id]=1; rate[$id]=$k; aff[$id]=$a
  done
  n=${#seen[@]}
  (( n == 0 )) && ok=0
  # the reply must cover exactly the configured number of threads (a truncated prefix is rejected)
  want=$(jq -r '.threads // empty' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null)
  [[ $want =~ ^[0-9]+$ ]] && (( n == want )) || ok=0
  (( ok )) && for (( i=0; i<n; i++ )); do [[ -n ${rate[$i]} ]] || { ok=0; break; }; done
fi

if (( ok )); then
  # physical-core rows when every thread is bound and its (package, core) resolves
  percore=1; declare -A core_khs=() core_cpu=(); order=()
  for (( i=0; i<n; i++ )); do
    a=${aff[$i]}
    if [[ ! $a =~ ^[0-9]+$ ]]; then percore=0; break; fi
    pk=$(cat $SYS/cpu$a/topology/physical_package_id 2>/dev/null); cid=$(cat $SYS/cpu$a/topology/core_id 2>/dev/null)
    [[ $pk =~ ^[0-9]+$ && $cid =~ ^[0-9]+$ ]] || { percore=0; break; }
    key="$pk:$cid"
    [[ -z ${core_khs[$key]} ]] && { order+=("$key"); core_cpu[$key]=$a; core_khs[$key]=0; }
    core_khs[$key]=$(awk -v x="${core_khs[$key]}" -v y="${rate[$i]}" 'BEGIN{printf "%.2f", x+y}')
  done
  if (( percore )); then
    IFS=$'\n' order=($(printf '%s\n' "${order[@]}" | sort -t: -k1,1n -k2,2n)); unset IFS
    for key in "${order[@]}"; do t=$(cpu_temp_for ${core_cpu[$key]}); hs+=("${core_khs[$key]}"); temps+=("${t:-$pkg_temp}"); done
  else
    for (( i=0; i<n; i++ )); do t=""; [[ ${aff[$i]} =~ ^[0-9]+$ ]] && t=$(cpu_temp_for ${aff[$i]}); hs+=("${rate[$i]}"); temps+=("${t:-$pkg_temp}"); done
  fi
  # total = sum of the fresh rows (an overdue thread reports 0), so a partial stall never shows a stale total
  khs=$(printf '%s\n' "${hs[@]}" | awk '{s+=$1} END{printf "%.2f", s}')
elif (( stalled )); then
  khs=0; hs=(0); temps=($pkg_temp)
else
  # thread list unavailable: use the miner's freshness-aware total (only threads that worked recently);
  # builds without FRESHKHS: report unavailable (0) rather than a possibly stale summary total
  fk=$(get FRESHKHS)
  [[ $fk =~ ^[0-9]+(\.[0-9]+)?$ ]] || fk=0
  khs=$fk; hs=($fk); temps=($pkg_temp)
fi

watts=$(cpu_power)
rows=${#hs[@]}
stats=$(jq -nc \
  --argjson hs "$(printf '%s\n' "${hs[@]}" | jq -cs 'map(tonumber)')" \
  --argjson temp "$(printf '%s\n' "${temps[@]}" | jq -cs 'map(tonumber)')" \
  --argjson fan "$(yes 0 | head -n $rows | jq -cs .)" \
  --argjson bus "$(yes null | head -n $rows | jq -cs .)" \
  --arg uptime "${up:-0}" --arg acc "${acc:-0}" --arg rej "${rej:-0}" --arg ver "$ver" --arg w "$watts" \
  '{hs: $hs, hs_units: "khs", temp: $temp, fan: $fan, bus_numbers: $bus, uptime: $uptime, ar: [$acc, $rej], algo: "verushash", ver: $ver}
   + (if $w != "" then {cpu_power: ($w|tonumber)} else {} end)')
