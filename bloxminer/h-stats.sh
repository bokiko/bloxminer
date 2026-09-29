#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs and $stats, and must NEVER exit that agent process on any failure
# of its own (every early-out below is a plain `return 0 2>/dev/null || exit 0`, the same convention both
# gated engine scripts already use for being sourced). Engine selection failing here - a corrupt manifest, a
# missing h-common.sh, or engine_from_config unable to identify the active engine (missing/unreadable/
# unrecognised config.json, or jq unavailable) - still has to produce a defined, safe answer rather than crash
# or guess: it falls back to $khs=0 with empty stats, exactly like "no API answer" already does in both
# engines. This never defaults to either engine on an unverified guess - see h-common.sh's engine_from_config.
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
BLOX_HP_T0=$(date +%s.%N 2>/dev/null)   # Round 5c: this poll's own start, so finalization can be bounded to
	# whatever remains of the SHARED ~3.0 s poll budget once the engine's own collection below has run - see
	# h-common.sh's finalize_rx_hugepages_bounded.
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}
if ! . "$BLOX_DIR/h-manifest.conf" 2>/dev/null || ! . "$BLOX_DIR/h-common.sh" 2>/dev/null; then
	khs=0; stats=""; return 0 2>/dev/null || exit 0
fi
export BLOX_DIR

engine=$(engine_from_config) || { khs=0; stats=""; return 0 2>/dev/null || exit 0; }

# shellcheck disable=SC1090   # $engine is one of exactly two known, fixed values (verus|rx), never external input
. "$BLOX_DIR/engines/$engine/h-stats.sh"

# Huge-page ownership finalization (rx only, see h-common.sh's "Huge-page ownership" section): must run AFTER
# the engine h-stats.sh above so $khs (and rx's own exported PORT/PROC/PKG) are set - and must never touch
# $khs/$stats itself or make this script fail/print, or overrun the shared poll budget, on any outcome.
# Round 5c: bounded to whatever is LEFT of BLOX_HP_TOTAL_BUDGET_S (default 3.0 s, matching the engine's own
# documented target) after the engine collection above - finalize_rx_hugepages_bounded defers to a later poll
# on a timeout rather than ever let this poll run long; engine scripts stay completely untouched.
if [[ $engine == rx ]]; then
	BLOX_HP_REMAINING=$(awk -v t0="${BLOX_HP_T0:-0}" -v now="$(date +%s.%N 2>/dev/null)" \
		-v budget="${BLOX_HP_TOTAL_BUDGET_S:-3.0}" 'BEGIN{
			if (t0 == 0) { print budget; exit }
			r = budget - (now - t0); if (r < 0) r = 0; printf "%.2f", r
		}' 2>/dev/null)
	finalize_rx_hugepages_bounded "${BLOX_HP_REMAINING:-0}"
fi
true
