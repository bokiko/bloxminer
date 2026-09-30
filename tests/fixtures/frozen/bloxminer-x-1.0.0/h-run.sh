#!/usr/bin/env bash
cd "${BLOX_DIR:-/hive/miners/custom/bloxminer-x}" || exit 1   # BLOX_DIR: tests only
. ./h-manifest.conf || exit 1
mkdir -p "$(dirname "$CUSTOM_LOG_BASENAME")" || exit 1

# CPU gate: x86-64 + AES-NI (XMRig's build adds -maes globally, cmake/flags.cmake) + SSE2 baseline
cpu_ok() {   # CPUINFO overridable for testing
	local f; f=" $(grep -m1 '^flags' "${CPUINFO:-/proc/cpuinfo}" | cut -d: -f2) "
	for x in aes sse2; do [[ $f == *" $x "* ]] || return 1; done
}
if ! cpu_ok; then
	msg="BloxMiner-X needs an x86-64 CPU with AES-NI (RandomX requires AES acceleration)"
	echo "$msg" | tee -a "$CUSTOM_LOG_BASENAME.log"
	message error "$msg" 2>/dev/null
	sleep 60; exit 1
fi

# Huge pages: reserve 2 MB pages before the miner starts, the same way Hive's own xmrig-new integration does
# (/hive/miners/xmrig-new/h-run.sh) - run Hive's own `hugepages -rx` tool if it exists on this rig. If it is
# not present (older Hive, or running outside Hive for a test), do nothing here - XMRig reserves its own 2 MB
# pages as root on startup either way. 1 GB pages are XMRig's own concern: h-config.sh only ever passes
# "randomx": {"1gb-pages": true} after its own NUMA free-memory check, and XMRig reserves/falls back to 2 MB
# pages itself at runtime (R5') - h-run.sh takes no separate action for it.
if command -v hugepages > /dev/null 2>&1; then
	hugepages -rx
fi

# XMRig runs directly on the HiveOS screen terminal; its own console output is plain lines + SGR colour. Its
# log file (config "log-file" = $CUSTOM_LOG_BASENAME.log) is append-only - XMRig itself never rotates it; the
# size bound comes from Hive's own start-time gzip rotation plus its 15-minute `logtruncateall` cron (20 MB).
# exec: Hive supervises the miner process itself and gets its exit status.
exec ./xmrig -c "$CUSTOM_CONFIG_FILENAME"
