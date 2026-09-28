#!/usr/bin/env bash
# Builds and runs bloxsense's tests (Linux: needs g++ with C++17 and jq).
#  1. Function-level: test_sys.cpp against blox_sys.cpp's topology/temperature/RAPL API (fake $BLOX_SYSFS_ROOT
#     trees), adapted from bloxminer's tests/engine/test_sys.cpp - same fixtures: AMD Vermeer 1/2-CCD, Zen 2
#     (unvalidated), Tctl-only, multi-socket AMD, Intel coretemp + psys, RAPL wrap/gap/unreadable, no sensors.
#  2. CLI-level: the actual bloxsense --json binary against a few of the same fake trees, checking the JSON
#     contract end to end (including a real ~0.55 s two-read power sample).
# Usage: tests/bloxsense/run_tests.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../bloxsense" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-56s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-56s FAIL: %s\n' "$1" "$2"; }

# ------------------------------------------------------------------ function-level: blox_sys.cpp unit tests
if g++ -std=c++17 -Wall -Wextra -I"$SRC" "$HERE/test_sys.cpp" "$SRC/blox_sys.cpp" -o "$T/test_sys" 2>"$T/build.log"; then
	out=$("$T/test_sys" 2>&1); rc=$?
	if [[ $rc == 0 ]]; then ok "blox_sys.cpp unit tests ($(tail -1 <<< "$out"))"; else bad "blox_sys.cpp unit tests" "$out"; fi
else
	bad "blox_sys.cpp unit tests (build)" "$(cat "$T/build.log")"
fi

# ------------------------------------------------------------------ build bloxsense itself for the CLI tests
if ! g++ -std=c++17 -Wall -Wextra -I"$SRC" "$SRC/bloxsense.cpp" "$SRC/blox_sys.cpp" -o "$T/bloxsense" 2>"$T/build2.log"; then
	bad "bloxsense (build)" "$(cat "$T/build2.log")"
	echo "$pass passed, $fail failed"
	exit 1
fi

put() { local p="$T/root$1"; mkdir -p "$(dirname "$p")"; printf '%s\n' "$2" > "$p"; }
cpu() {   # cpu id pkg core [l3]
	put "/sys/devices/system/cpu/cpu$1/topology/physical_package_id" "$2"
	put "/sys/devices/system/cpu/cpu$1/topology/core_id" "$3"
	if [[ -n ${4:-} ]]; then
		put "/sys/devices/system/cpu/cpu$1/cache/index3/level" 3
		put "/sys/devices/system/cpu/cpu$1/cache/index3/id" "$4"
	fi
}
run_bloxsense() { BLOX_SYSFS_ROOT="$T/root" "$T/bloxsense" --json; }

# ---- AMD Ryzen 9 5950X: validated 2-CCD profile, RAPL present -> ccd temps, package temp, plausible power
rm -rf "$T/root"
put "/proc/cpuinfo" "$(printf 'processor\t: 0\nvendor_id\t: AuthenticAMD\ncpu family\t: 25\nmodel\t\t: 33\nmodel name\t: AMD Ryzen 9 5950X 16-Core Processor')"
for c in $(seq 0 31); do core=$((c % 16)); l3=$(( core < 8 ? 0 : 1 )); cpu "$c" 0 "$core" "$l3"; done
put "/sys/class/hwmon/hwmon0/name" k10temp
put "/sys/class/hwmon/hwmon0/temp1_label" Tctl;  put "/sys/class/hwmon/hwmon0/temp1_input" 70000
put "/sys/class/hwmon/hwmon0/temp2_label" Tccd1; put "/sys/class/hwmon/hwmon0/temp2_input" 61000
put "/sys/class/hwmon/hwmon0/temp3_label" Tccd2; put "/sys/class/hwmon/hwmon0/temp3_input" 66000
put "/sys/class/powercap/intel-rapl:0/name" package-0
put "/sys/class/powercap/intel-rapl:0/energy_uj" 1000000
put "/sys/class/powercap/intel-rapl:0/max_energy_range_uj" 262143328850
( sleep 0.25; put "/sys/class/powercap/intel-rapl:0/energy_uj" 51000000 ) &   # +50 J across bloxsense's own ~0.55 s sample (~91 W)
json=$(run_bloxsense); rc=$?
wait
if [[ $rc == 0 ]] && jq -e '.cpus | length == 32' <<< "$json" > /dev/null 2>&1; then ok "5950X: 32 cpu rows"; else bad "5950X: 32 cpu rows" "$json"; fi
if jq -e '.cpus[3].src == "ccd" and .cpus[3].temp == 61' <<< "$json" > /dev/null 2>&1; then ok "5950X: cpu3 -> Tccd1"; else bad "5950X: cpu3 -> Tccd1" "$json"; fi
if jq -e '.pkg_temp == 70' <<< "$json" > /dev/null 2>&1; then ok "5950X: pkg_temp = Tctl"; else bad "5950X: pkg_temp = Tctl" "$json"; fi
if jq -e '.power_w >= 50 and .power_w <= 140' <<< "$json" > /dev/null 2>&1; then ok "5950X: power_w plausible (~91 W over ~0.55 s)"; else bad "5950X: power_w plausible (~91 W over ~0.55 s)" "$json"; fi
if jq -e '.ccd_reason | test("validated profile")' <<< "$json" > /dev/null 2>&1; then ok "5950X: ccd_reason names the profile"; else bad "5950X: ccd_reason names the profile" "$json"; fi

# ---- Intel i9-10900K: coretemp per core, no RAPL package domain -> power_w null
rm -rf "$T/root"
put "/proc/cpuinfo" "$(printf 'processor\t: 0\nvendor_id\t: GenuineIntel\ncpu family\t: 6\nmodel\t\t: 165\nmodel name\t: Intel(R) Core(TM) i9-10900K CPU @ 3.70GHz')"
for c in $(seq 0 9); do cpu "$c" 0 "$c" 0; done
put "/sys/class/hwmon/hwmon2/name" coretemp
put "/sys/class/hwmon/hwmon2/temp1_label" "Package id 0"; put "/sys/class/hwmon/hwmon2/temp1_input" 70000
for c in $(seq 0 9); do n=$((c + 2)); put "/sys/class/hwmon/hwmon2/temp${n}_label" "Core $c"; put "/sys/class/hwmon/hwmon2/temp${n}_input" $((60000 + c * 1000)); done
json=$(run_bloxsense); rc=$?
if [[ $rc == 0 ]] && jq -e '.cpus[4].src == "core" and .cpus[4].temp == 64' <<< "$json" > /dev/null 2>&1; then ok "10900K: core 4 temp via coretemp"; else bad "10900K: core 4 temp via coretemp" "$json"; fi
if jq -e '.power_w == null' <<< "$json" > /dev/null 2>&1; then ok "10900K: no RAPL -> power_w null"; else bad "10900K: no RAPL -> power_w null" "$json"; fi

# ---- no sensors at all: temps/src null/none, pkg_temp and power_w null, cpus still listed
rm -rf "$T/root"
put "/proc/cpuinfo" "$(printf 'processor\t: 0\nvendor_id\t: GenuineIntel\ncpu family\t: 6\nmodel\t\t: 1\nmodel name\t: Some CPU')"
cpu 0 0 0; cpu 1 0 1
json=$(run_bloxsense); rc=$?
if [[ $rc == 0 ]] && jq -e '.cpus | length == 2' <<< "$json" > /dev/null 2>&1; then ok "no sensors: cpus still listed"; else bad "no sensors: cpus still listed" "$json"; fi
if jq -e '(.cpus | map(.temp) | unique) == [null] and (.cpus | map(.src) | unique) == ["none"] and .pkg_temp == null and .power_w == null' <<< "$json" > /dev/null 2>&1; then
	ok "no sensors: everything null/none"
else
	bad "no sensors: everything null/none" "$json"
fi

# ---- 2-socket AMD, only one RAPL package domain present -> unusable, never a partial total
rm -rf "$T/root"
put "/proc/cpuinfo" "$(printf 'processor\t: 0\nvendor_id\t: AuthenticAMD\ncpu family\t: 25\nmodel\t\t: 1\nmodel name\t: AMD EPYC')"
cpu 0 0 0; cpu 1 1 0
put "/sys/class/powercap/intel-rapl:0/name" package-0
put "/sys/class/powercap/intel-rapl:0/energy_uj" 1000
put "/sys/class/powercap/intel-rapl:0/max_energy_range_uj" 262143328850
json=$(run_bloxsense); rc=$?
if [[ $rc == 0 ]] && jq -e '.power_w == null' <<< "$json" > /dev/null 2>&1; then ok "one RAPL domain of two -> power_w null"; else bad "one RAPL domain of two -> power_w null" "$json"; fi

# ---- bad invocation
if "$T/bloxsense" > /dev/null 2>&1; then bad "no args -> non-zero exit" "exit 0"; else ok "no args -> non-zero exit"; fi

# ------------------------------------------------------------------ ASan/UBSan build (plan R7, needed for X3)
# shellcheck disable=SC2054   # the comma is part of -fsanitize's own argument, not an array separator
SANFLAGS=(-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all)
if g++ -std=c++17 -O1 -g -Wall -Wextra "${SANFLAGS[@]}" -I"$SRC" "$HERE/test_sys.cpp" "$SRC/blox_sys.cpp" -o "$T/test_sys_san" 2>"$T/build_san.log"; then
	out=$(ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1 "$T/test_sys_san" 2>&1); rc=$?
	if [[ $rc == 0 ]]; then ok "blox_sys.cpp unit tests under ASan+UBSan ($(tail -1 <<< "$out"))"; else bad "blox_sys.cpp unit tests under ASan+UBSan" "$out"; fi
else
	bad "blox_sys.cpp unit tests under ASan+UBSan (build)" "$(cat "$T/build_san.log")"
fi

if g++ -std=c++17 -O1 -g -Wall -Wextra "${SANFLAGS[@]}" -I"$SRC" "$SRC/bloxsense.cpp" "$SRC/blox_sys.cpp" -o "$T/bloxsense_san" 2>"$T/build_san2.log"; then
	rm -rf "$T/root"; put "/proc/cpuinfo" "$(printf 'processor\t: 0\nvendor_id\t: GenuineIntel\ncpu family\t: 6\nmodel\t\t: 1\nmodel name\t: Some CPU')"
	cpu 0 0 0; cpu 1 0 1   # no RAPL configured: no 1 s sample, keeps the sanitizer run fast
	out=$(ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=print_stacktrace=1 BLOX_SYSFS_ROOT="$T/root" "$T/bloxsense_san" --json 2>&1); rc=$?
	if [[ $rc == 0 ]] && jq -e '.cpus | length == 2' <<< "$out" > /dev/null 2>&1; then
		ok "bloxsense --json under ASan+UBSan"
	else
		bad "bloxsense --json under ASan+UBSan" "$out"
	fi
else
	bad "bloxsense --json under ASan+UBSan (build)" "$(cat "$T/build_san2.log")"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
