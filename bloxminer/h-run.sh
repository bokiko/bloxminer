#!/usr/bin/env bash
cd "${BLOX_DIR:-/hive/miners/custom/bloxminer}" || exit 1   # BLOX_DIR: tests only
. ./h-manifest.conf || exit 1
mkdir -p "$(dirname "$CUSTOM_LOG_BASENAME")" || exit 1

# CPU gate: x86-64-v3 (AVX2/BMI2/FMA/...) + AES-NI + PCLMULQDQ, else refuse with a clear Hive message
cpu_ok() {   # CPUINFO / LDSO overridable for testing
  local f; f=" $(grep -m1 '^flags' "${CPUINFO:-/proc/cpuinfo}" | cut -d: -f2) "
  for x in aes pclmulqdq; do [[ $f == *" $x "* ]] || return 1; done
  if "${LDSO:-/lib64/ld-linux-x86-64.so.2}" --help 2>/dev/null | grep -q "x86-64-v3 (supported"; then return 0; fi
  [[ $f == *" sse3 "* || $f == *" pni "* ]] || return 1
  for x in ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do [[ $f == *" $x "* ]] || return 1; done
}
if ! cpu_ok; then
  msg="BloxMiner needs an x86-64-v3 CPU with AES-NI and PCLMUL (AVX2 class, e.g. Ryzen / Intel Haswell or newer)"
  echo "$msg" | tee -a "$CUSTOM_LOG_BASENAME.log"
  message error "$msg" 2>/dev/null
  sleep 60; exit 1
fi

# full clocks for hashing
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done 2>/dev/null

# The miner runs directly on the HiveOS screen terminal and writes its own plain-text log (config "log-file" =
# $CUSTOM_LOG_BASENAME.log, rotated at 10 MB). h-config sets "no-dashboard" unless Extra config has "dashboard": true:
# HiveOS "Miner log" is a tail of the raw screen recording (/run/hive/miner.N), unreadable with header redraws.
# The bundled libomp.so.5 is found via the binary's $ORIGIN rpath.
# exec: Hive supervises the miner process itself and gets its exit status.
exec ./bloxminer -c "$CUSTOM_CONFIG_FILENAME"
