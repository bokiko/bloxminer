#!/usr/bin/env bash
# Top-level dispatcher: picks the mining engine (Verus/VerusHash or RandomX) from the flight-sheet algo
# (CUSTOM_ALGO), then delegates to that engine's own gated h-config.sh (engines/verus or engines/rx) to build
# config.json exactly as it always has. There is no separate engine-state file to keep in step: h-run.sh and
# h-stats.sh both derive the active engine straight from config.json's own content (engine_from_config in
# h-common.sh), which this script's delegate just wrote atomically (tmp+mv) - one write, one source of truth,
# no window where a second file could name a different engine than the config that was actually just produced.
#   CUSTOM_ALGO   empty or "verus"/"verushash" -> Verus engine (backward compatible with 2.1.0 flight sheets,
#                 which never had an algo field); "randomx" or "rx/0" -> RandomX engine, default variant;
#                 "rx/wow", "rx/arq", "rx/graft", "rx/sfx", "rx/yada" -> RandomX engine, that variant;
#                 anything else -> Hive error message, exit 1 (config.json is left exactly as it was - no
#                 half-switch).
# Every other flight-sheet field (CUSTOM_URL, CUSTOM_TEMPLATE, CUSTOM_PASS, CUSTOM_USER_CONFIG) is read
# unchanged by whichever engine script runs; see engines/verus/h-config.sh and engines/rx/h-config.sh for
# what each one means for that engine (Pass is a THREAD COUNT for Verus, a POOL PASSWORD for RandomX).
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}
cd "$BLOX_DIR" || exit 1
. "$BLOX_DIR/h-manifest.conf" || exit 1
. "$BLOX_DIR/h-common.sh" || exit 1

fail() { echo "$1"; message error "$1" 2>/dev/null; exit 1; }

if ! select_engine "${CUSTOM_ALGO:-}"; then
	fail "BloxMiner: Algorithm must be empty (Verus/VerusHash), \"verus\"/\"verushash\", \"randomx\", or one of rx/0 rx/wow rx/arq rx/graft rx/sfx rx/yada (got \"${CUSTOM_ALGO:-}\")"
fi

export BLOX_DIR
CUSTOM_ALGO=$NORM_ALGO "$BLOX_DIR/engines/$ENGINE/h-config.sh" || exit 1   # the engine's own h-config.sh
	# already sent the Hive error message on failure and left the previous config.json untouched (tmp+mv).
	# Nothing else to do on success: config.json IS the engine record now (see the top comment).
