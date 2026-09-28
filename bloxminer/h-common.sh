# shellcheck shell=bash
# Sourced by the top-level dispatcher scripts only (h-config.sh, h-run.sh, h-stats.sh) - never by the gated
# per-engine scripts under engines/verus/ or engines/rx/, which stay unaware that a dispatcher exists.
# Engine selection (flight-sheet CUSTOM_ALGO) and the engine state file (single source of truth for h-run and
# h-stats, so they never re-derive the choice differently than h-config committed it) live here once.
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}

STATEDIR=${BLOX_STATE_DIR:-}
if [[ -z $STATEDIR ]]; then [[ -d /run/hive ]] && STATEDIR=/run/hive || STATEDIR=$BLOX_DIR; fi
ENGINE_STATE_FILE="$STATEDIR/.bloxminer-engine"

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

# write_engine_state <verus|rx> - atomic tmp+mv, exactly like every config.json write in this package. Called
# ONLY after that engine's own h-config.sh has already succeeded (config.json rewritten first): a reader can
# never observe a state file naming an engine whose config.json was not actually regenerated for it.
write_engine_state() {
	local tmp="$ENGINE_STATE_FILE.tmp.$$"
	{ printf '%s\n' "$1" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$ENGINE_STATE_FILE" 2>/dev/null
}

# infer_engine_from_config - recovers the engine from $CUSTOM_CONFIG_FILENAME's own content when the state
# file is missing, unreadable, or holds anything other than "verus"/"rx" (stale/corrupt). The rx engine's
# config always has a top-level "randomx" object; the verus engine's always has "algo":"verus". Falls back to
# verus - the safe default (backward compatible with 2.1.0, and the engine that reserves no host resources).
infer_engine_from_config() {
	if [[ -n ${CUSTOM_CONFIG_FILENAME:-} && -r $CUSTOM_CONFIG_FILENAME ]] && command -v jq > /dev/null 2>&1; then
		if jq -e 'has("randomx")' "$CUSTOM_CONFIG_FILENAME" > /dev/null 2>&1; then echo rx; return; fi
		if jq -e '.algo == "verus"' "$CUSTOM_CONFIG_FILENAME" > /dev/null 2>&1; then echo verus; return; fi
	fi
	echo verus
}

# read_engine_state - the single source of truth h-run and h-stats both use, so they can never disagree with
# each other or with what h-config last committed. Prints exactly "verus" or "rx", always.
read_engine_state() {
	local e=""
	[[ -r $ENGINE_STATE_FILE ]] && e=$(<"$ENGINE_STATE_FILE")
	e=$(tr -d '[:space:]' <<< "$e")
	if [[ $e == verus || $e == rx ]]; then echo "$e"; return; fi
	infer_engine_from_config
}
