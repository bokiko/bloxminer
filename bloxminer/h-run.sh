#!/usr/bin/env bash
# Top-level dispatcher: starts whichever engine config.json's own content says is active (engine_from_config in
# h-common.sh - see there for why there is no separate state file). The engines never run at once - Hive stops
# the previous miner process before calling h-config/h-run again on an algo switch, and this package has only
# one screen/log for either engine.
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}
cd "$BLOX_DIR" || exit 1
. "$BLOX_DIR/h-manifest.conf" || exit 1
. "$BLOX_DIR/h-common.sh" || exit 1

fail() { echo "$1"; message error "$1" 2>/dev/null; exit 1; }

# Fail closed: never default to either engine. A missing/unreadable/unrecognised config.json (or jq itself
# missing) means h-config.sh never ran, or something corrupted the file it wrote - starting ANY engine on an
# unverified guess would be worse than refusing to start at all.
engine=$(engine_from_config) || fail "BloxMiner: cannot start - $CUSTOM_CONFIG_FILENAME is missing, unreadable, or not a recognised BloxMiner/BloxMiner-X config (jq required to check); run h-config.sh again"

# Host hygiene: the RandomX engine reserves ~1200 x 2 MB huge pages on start (its own h-run.sh, via Hive's own
# `hugepages -rx` helper when present) and nothing ever releases them on a switch - custom miners have no stop
# hook. Track only the reservation THIS package made (see h-common.sh): record the pre-rx value once before rx
# starts, restore it once before verus starts next. A fresh install, or a foreign reservation this package
# never touched, is left exactly as found either way.
if [[ $engine == rx ]]; then
	note_rx_hugepages_start
elif [[ $engine == verus ]]; then
	restore_verus_hugepages
fi

export BLOX_DIR
exec "$BLOX_DIR/engines/$engine/h-run.sh"
