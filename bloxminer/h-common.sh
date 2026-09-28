# shellcheck shell=bash
# Sourced by the top-level dispatcher scripts only (h-config.sh, h-run.sh, h-stats.sh) - never by the gated
# per-engine scripts under engines/verus/ or engines/rx/, which stay unaware that a dispatcher exists.
# Engine selection (flight-sheet CUSTOM_ALGO, used only by h-config.sh to build a fresh config.json) and the
# huge-page ownership record (used only by h-run.sh, see below) live here once.
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}

STATEDIR=${BLOX_STATE_DIR:-}
if [[ -z $STATEDIR ]]; then [[ -d /run/hive ]] && STATEDIR=/run/hive || STATEDIR=$BLOX_DIR; fi

RX_ALGOS=(rx/0 rx/wow rx/arq rx/graft rx/sfx rx/yada)

# select_engine <algo> -> on a recognised algo (case-insensitive), sets $ENGINE (verus|rx) and $NORM_ALGO (the
# canonical algo string passed on to that engine's own h-config.sh) and returns 0. Empty = verus (backward
# compatible with 2.1.0 flight sheets, which never had an algo field). Anything else returns 1 - the caller
# decides how to fail. Generic aliases are normalised (randomx -> rx/0, verus -> verushash) so an engine's own
# script always receives one of its own canonical values, never a generic alias it does not itself recognise.
select_engine() {
	local a x
	a=$(tr '[:upper:]' '[:lower:]' <<< "$1")
	case $a in
		""|verus|verushash) ENGINE=verus; NORM_ALGO=verushash; return 0 ;;
		randomx|rx|rx/0)     ENGINE=rx;    NORM_ALGO=rx/0;      return 0 ;;
	esac
	for x in "${RX_ALGOS[@]}"; do
		# shellcheck disable=SC2034   # ENGINE/NORM_ALGO are read by the caller (h-config.sh), not here
		if [[ $a == "$x" ]]; then ENGINE=rx; NORM_ALGO=$a; return 0; fi
	done
	return 1
}

# engine_from_config - the ONLY source of truth for which engine is currently active, used by h-run.sh and
# h-stats.sh. There is deliberately no separate "engine state" file to read: each engine's own h-config.sh
# already writes $CUSTOM_CONFIG_FILENAME atomically (tmp+mv, see engines/verus/h-config.sh and
# engines/rx/h-config.sh), so config.json is always one consistent generation - a reader can never observe a
# half-written config, and there is no second file that could ever fall out of step with it (the race a
# separate state file would reintroduce: config.json rewritten for the new engine but the state file not yet
# updated, or vice versa). The rx engine's config always has a top-level "randomx" object; the verus engine's
# always has "algo":"verus" (see both engines' h-config.sh). Prints exactly "verus" or "rx" and returns 0 on a
# recognised config; returns 1 (prints nothing) and lets the caller decide how to fail closed otherwise -
# config.json missing, unreadable, invalid JSON, valid JSON with neither marker, or jq itself unavailable.
# Never guesses/defaults to either engine.
engine_from_config() {
	command -v jq > /dev/null 2>&1 || return 1
	[[ -n ${CUSTOM_CONFIG_FILENAME:-} && -r $CUSTOM_CONFIG_FILENAME ]] || return 1
	if jq -e 'has("randomx")' "$CUSTOM_CONFIG_FILENAME" > /dev/null 2>&1; then echo rx; return 0; fi
	if jq -e '.algo == "verus"' "$CUSTOM_CONFIG_FILENAME" > /dev/null 2>&1; then echo verus; return 0; fi
	return 1
}

# Huge-page ownership (h-run.sh only): the RandomX engine reserves ~1200 x 2 MB huge pages on start (Hive's own
# `hugepages -rx` helper, see engines/rx/h-run.sh) and nothing ever releases them again - custom miners have no
# stop hook. Rather than unconditionally resetting the host's hugepage count on every Verus start (stomping any
# OTHER reservation on the box - another workload, or an operator's own setting), this package tracks ONLY the
# reservation IT made, in one small ownership file under $STATEDIR (/run/hive when present - tmpfs, so a reboot
# clears this record together with the non-persistent reservation it describes; verified live against Hive's
# own `hugepages` tool on a rig, 2026-09-28: `-rx` computes its own target from NUMA/CPU count and writes
# /proc/sys/vm/nr_hugepages directly - it never reads the prior value and never persists anything to
# /etc/sysctl.conf or any boot-time setting, so a plain "put back what was there before" is the complete fix).
HUGEPAGES_FILE="$STATEDIR/.bloxminer-hugepages"

# note_rx_hugepages_start - called just before exec'ing the rx engine. Records the CURRENT vm.nr_hugepages
# ONLY if no record already exists: an rx restart (rx -> rx, e.g. a flight-sheet edit that keeps the same
# algo) must never overwrite an existing record with rx's own already-raised value, or that raised value would
# become the "prior" value restored on the next Verus start. No-op (and no sysctl/proc access at all) if the
# record already exists or the current value cannot be read.
note_rx_hugepages_start() {
	[[ -e $HUGEPAGES_FILE ]] && return 0
	local proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages" cur tmp
	[[ -r $proc ]] || return 0
	cur=$(<"$proc") 2>/dev/null
	[[ $cur =~ ^[0-9]+$ ]] || return 0
	tmp="$HUGEPAGES_FILE.tmp.$$"
	{ printf '%s\n' "$cur" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$HUGEPAGES_FILE" 2>/dev/null
}

# restore_verus_hugepages - called just before exec'ing the verus engine. Restores vm.nr_hugepages to the
# recorded prior value and removes the record, ONLY if a record exists - a fresh install, or a Verus start
# that was never preceded by an rx start under this package's ownership, touches vm.nr_hugepages at all (no
# sysctl call), so a foreign/manual reservation is left exactly as found.
restore_verus_hugepages() {
	[[ -e $HUGEPAGES_FILE ]] || return 0
	local prior; prior=$(<"$HUGEPAGES_FILE") 2>/dev/null
	if [[ $prior =~ ^[0-9]+$ ]]; then
		{ command -v sysctl > /dev/null 2>&1 && sysctl -q -w vm.nr_hugepages="$prior"; } 2>/dev/null
	fi
	rm -f "$HUGEPAGES_FILE" 2>/dev/null
	true
}
