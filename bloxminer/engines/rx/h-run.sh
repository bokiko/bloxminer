#!/usr/bin/env bash
# CPU gate: x86-64 + AES-NI (XMRig's build adds -maes globally, cmake/flags.cmake) + SSE2 baseline
cpu_ok() {   # CPUINFO overridable for testing
	local f; f=" $(grep -m1 '^flags' "${CPUINFO:-/proc/cpuinfo}" | cut -d: -f2) "
	for x in aes sse2; do [[ $f == *" $x "* ]] || return 1; done
}

# BLOX_RX_PREFLIGHT_ONLY: set by the top-level dispatcher (bloxminer/h-run.sh) to validate this EXACT CPU gate
# BEFORE it reserves any huge pages for rx (note_rx_hugepages_start, h-common.sh). PR #2 review (Codex):
# the dispatcher used to call note_rx_hugepages_start - which reserves ~2.4 GiB via `hugepages -rx` - before
# this file ever got a chance to reject a no-AES-NI host below; because XMRig then never ran, the reservation's
# ownership record could never finalize (finalize_rx_hugepages needs a live, owned XMRig reporting hashrate -
# see h-common.sh), so a later Verus start's own restore_verus_hugepages saw final=0 and refused to touch it,
# leaving the memory pinned until reboot. Reusing cpu_ok() - defined immediately above, nothing else in this
# file evaluated yet - rather than a second, hand-copied flag check in the dispatcher is what makes it
# impossible for the two to drift apart. This file otherwise stays completely unaware a dispatcher exists (see
# h-common.sh's own header comment) - it merely supports being SOURCED, instead of exec'd as a whole process,
# for this one purpose: run cpu_ok() and return its exact exit status before any of this file's own side
# effects (cd, manifest sourcing, mkdir, hugepages, exec) ever happen. Never set by Hive itself - a real start
# always execs this file whole, exactly as before this was added.
if [[ -n ${BLOX_RX_PREFLIGHT_ONLY:-} ]]; then
	cpu_ok; rc=$?
	return $rc 2>/dev/null || exit $rc
fi

# Undoes the top-level dispatcher's own just-made huge-page reservation if THIS start fails anywhere below
# before XMRig ever execs. The CPU preflight the dispatcher now runs (above) should already prevent the
# specific case PR #2's review found; this is a general safety net for any OTHER reason this file exits
# without reaching its own final `exec` (a missing log directory, a future added check, ...) - "provably ours,
# still safe to touch" is checked the exact same way h-common.sh's own restore_verus_hugepages checks it
# before ITS OWN restore: a known "prior", a live vm.nr_hugepages that still exactly equals THIS reservation's
# own "prelim" (nothing else has touched it since - the same class of proof, one step earlier: prelim here is
# what ours becomes only once XMRig itself gets confirmed), and the SAME boot_id the record was written in.
# Deliberately NOT sourcing h-common.sh for this (see its own header: engine scripts stay unaware a dispatcher
# exists) - reads the same small, stable key=value record format directly instead. That on-disk shape is a
# stable contract between the two (four decades-old key=value lines), not logic that can drift the way a CPU
# flag comparison could - every field name/semantics below matches h-common.sh's own _hp_field reader exactly.
rollback_rx_hugepages_reservation() {
	local rc=$?
	(( rc == 0 )) && return 0   # only ever rolls back a FAILING start - a successful `exec` below replaces
		# this process outright and this trap never runs at all in that case
	local statedir=${BLOX_STATE_DIR:-}
	[[ -n $statedir ]] || { [[ -d /run/hive ]] && statedir=/run/hive || statedir=${BLOX_DIR:-/hive/miners/custom/bloxminer}; }
	local f="$statedir/.bloxminer-hugepages"
	[[ -r $f ]] || return 0
	local k v prior="" prelim="" boot="" final=""
	while IFS='=' read -r k v; do
		case $k in prior) prior=$v ;; prelim) prelim=$v ;; boot) boot=$v ;; final) final=$v ;; esac
	done < "$f" 2>/dev/null
	[[ $final == 0 ]] || return 0   # only an UNFINALIZED record is ever touched here - final=1 already belongs
		# to restore_verus_hugepages (a later Verus start), "conflict" is already a terminal state either way
	local cur_boot=""; read -r cur_boot < "${BLOX_PROCFS_ROOT:-/proc}/sys/kernel/random/boot_id" 2>/dev/null
	[[ -n $boot && $boot == "$cur_boot" ]] || return 0
	[[ $prior =~ ^[0-9]+$ && $prelim =~ ^[0-9]+$ ]] || return 0
	local proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages" cur=""
	[[ -r $proc ]] && cur=$(<"$proc") 2>/dev/null
	[[ $cur =~ ^[0-9]+$ && $cur == "$prelim" ]] || return 0   # anything else already changed it since this
		# reservation - never a blind "restore anyway" on partial/stale information
	if command -v sysctl > /dev/null 2>&1 && sysctl -q -w vm.nr_hugepages="$prior" 2>/dev/null; then
		local verify=""; [[ -r $proc ]] && verify=$(<"$proc") 2>/dev/null
		if [[ $verify == "$prior" ]]; then
			rm -f "$f" 2>/dev/null   # only consumed once the restore is verified, by readback, to have succeeded -
				# same convention as every other write in this record's lifecycle (h-common.sh)
			{ printf '%s BloxMiner: rx start aborted before XMRig ever ran - rolled back vm.nr_hugepages to %s (was %s), record removed\n' \
				"$(date '+%F %T' 2>/dev/null)" "$prior" "$prelim" >> "${CUSTOM_LOG_BASENAME:-$statedir/bloxminer}.log"; } 2>/dev/null
		fi
	fi
	true
}
trap rollback_rx_hugepages_reservation EXIT

cd "${BLOX_DIR:-/hive/miners/custom/bloxminer}" || exit 1   # BLOX_DIR: tests only
. ./h-manifest.conf || exit 1
mkdir -p "$(dirname "$CUSTOM_LOG_BASENAME")" || exit 1

# Same CPU gate as the dispatcher's own preflight above - kept here too, unchanged, as defense-in-depth for a
# direct/standalone invocation of this file (bypassing the dispatcher entirely) and for anything that could in
# principle change between the dispatcher's check and this one (there is nothing today, but this file must
# never simply trust that it already passed elsewhere) - reuses the exact same cpu_ok(), never a second copy.
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

# A missing/non-executable binary is checked explicitly, rather than just letting `exec` below fail on its
# own, because a bash `exec` that fails to find its target (non-interactively) exits WITHOUT ever running this
# script's own EXIT trap - confirmed directly (a minimal repro: `trap ... EXIT; exec ./missing` never prints
# the trap's own output) - so rollback_rx_hugepages_reservation would silently never fire for exactly the
# "binary missing" case it exists to cover. An explicit `exit 1` here, by contrast, DOES run EXIT traps
# normally (confirmed the same way) - this check exists to reach that ordinary, trap-firing exit path, not
# for the message itself (kept in the exact "$BLOX_DIR/xmrig: No such file or directory" shape the OLD,
# exec-produced message had, so this stays a drop-in behavioural match for anything already parsing it).
if [[ ! -x ./xmrig ]]; then
	msg="$PWD/xmrig: No such file or directory"
	echo "$msg" | tee -a "$CUSTOM_LOG_BASENAME.log"
	message error "$msg" 2>/dev/null
	exit 1
fi

# XMRig runs directly on the HiveOS screen terminal; its own console output is plain lines + SGR colour. Its
# log file (config "log-file" = $CUSTOM_LOG_BASENAME.log) is append-only - XMRig itself never rotates it; the
# size bound comes from Hive's own start-time gzip rotation plus its 15-minute `logtruncateall` cron (20 MB).
# exec: Hive supervises the miner process itself and gets its exit status. On SUCCESS this replaces the
# process image outright, so rollback_rx_hugepages_reservation's own EXIT trap above never runs; on the rare
# remaining FAILURE mode (exec itself fails for a reason the executability check above did not catch, e.g. a
# corrupt binary format) it does, for one more chance to roll back cleanly.
exec ./xmrig -c "$CUSTOM_CONFIG_FILENAME"
