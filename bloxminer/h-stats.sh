#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs and $stats, and must NEVER exit that agent process on any failure
# of its own (every early-out below is a plain `return 0 2>/dev/null || exit 0`, the same convention both
# gated engine scripts already use for being sourced). Engine selection failing here - a corrupt manifest, a
# missing h-common.sh, or engine_from_config unable to identify the active engine (missing/unreadable/
# unrecognised config.json, or jq unavailable) - still has to produce a defined, safe answer rather than crash
# or guess: it falls back to $khs=0 with empty stats, exactly like "no API answer" already does in both
# engines. This never defaults to either engine on an unverified guess - see h-common.sh's engine_from_config.
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
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
# $khs/$stats itself or make this script fail/print, on any outcome: finalize_rx_hugepages already returns 0
# on every path (nothing here to check), engine scripts stay completely untouched.
[[ $engine == rx ]] && finalize_rx_hugepages
true
