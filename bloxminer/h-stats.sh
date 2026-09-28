#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs and $stats, and must NEVER exit that agent process on any failure
# of its own (every early-out below is a plain `return 0 2>/dev/null || exit 0`, the same convention both
# gated engine scripts already use for being sourced). Engine selection failing here (a corrupt manifest, a
# missing h-common.sh) still has to produce a defined, safe answer rather than crash the caller - it falls
# back to $khs=0 with empty stats, exactly like "no API answer" already does in both engines.
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}
if ! . "$BLOX_DIR/h-manifest.conf" 2>/dev/null || ! . "$BLOX_DIR/h-common.sh" 2>/dev/null; then
	khs=0; stats=""; return 0 2>/dev/null || exit 0
fi
export BLOX_DIR

engine=$(read_engine_state)
[[ $engine == verus || $engine == rx ]] || engine=verus   # read_engine_state always returns one of these;
                                                            # this is only a defensive final backstop

# shellcheck disable=SC1090   # $engine is one of exactly two known, fixed values (verus|rx), never external input
. "$BLOX_DIR/engines/$engine/h-stats.sh"
