#!/usr/bin/env bash
# Top-level dispatcher: picks the mining engine (Verus/VerusHash or RandomX) from the flight-sheet algo
# (CUSTOM_ALGO), then delegates to that engine's own gated h-config.sh (engines/verus or engines/rx) to build
# config.json exactly as it always has. There is no separate engine-state file to keep in step: h-run.sh and
# h-stats.sh both derive the active engine straight from config.json's own content (engine_from_config in
# h-common.sh), which this script's delegate just wrote atomically (tmp+mv) - one write, one source of truth,
# no window where a second file could name a different engine than the config that was actually just produced.
#
# Hive SOURCES this script - it never runs it as a subprocess (hive-ref/miner's miner_config_gen():
# `. $MINER_DIR/$CUSTOM_MINER/h-config.sh`; hive-ref/miner-run: `source $MINER_DIR/h-config.sh`). That means
# every flight-sheet variable (CUSTOM_URL, CUSTOM_TEMPLATE, CUSTOM_PASS, CUSTOM_USER_CONFIG, CUSTOM_ALGO, ...)
# from /hive-config/wallet.conf reaches this script as a plain, NON-exported shell variable of the CALLER -
# never in the process environment. Proven on cask18: with CUSTOM_URL non-exported (as Hive always leaves it),
# the old `CUSTOM_ALGO=$NORM_ALGO "$BLOX_DIR/engines/$ENGINE/h-config.sh"` below ran the engine script as a
# plain CHILD PROCESS, which only ever sees exported variables - CUSTOM_URL was invisible to it, so every
# config.json came out with an empty pool URL ("BloxMiner: the pool URL in the flight sheet is empty") and no
# miner started, for both engines. Two consequences this file has to respect:
#   1. The engine's own h-config.sh must be run SOURCED too - in a subshell, `( ...; . engine/h-config.sh )` -
#      a subshell is a fork of THIS shell, so it inherits every variable of it, exported or not, exactly like
#      Hive sourcing that same script directly used to (2.1.0/1.0.0, before this dispatcher existed - see
#      engines/verus/h-config.sh and engines/rx/h-config.sh, proven sourced-safe on Hive already). The subshell
#      also contains that script's own `exit`/`cd` (its fail() still does a plain `exit 1`): neither can escape
#      to this shell, let alone to Hive's.
#   2. This script itself must never `exit` or `cd` the caller's shell - `exit` would kill whatever sourced us
#      (miner-run, or the `miner` config-gen command), `cd` would change that process's directory for the rest
#      of its life. There is no `cd` at all below: every path is already absolute via $BLOX_DIR, so a working-
#      directory change was never actually needed. Every early-out is the bare statement
#      `return 1 2>/dev/null || exit 1`, executed directly at the top level (never from inside a function - a
#      `return` inside a function only unwinds that function, not the whole sourced file, so fail() below
#      never tries to end the script itself): `return` wins and stops sourcing here when Hive sources this
#      file, `exit` wins when this file is run directly (tests).
#   CUSTOM_ALGO   empty or "verus"/"verushash" -> Verus engine (backward compatible with 2.1.0 flight sheets,
#                 which never had an algo field); "randomx" or "rx/0" -> RandomX engine, default variant;
#                 "rx/wow", "rx/arq", "rx/graft", "rx/sfx", "rx/yada" -> RandomX engine, that variant;
#                 anything else -> Hive error message, exit 1 (config.json is left exactly as it was - no
#                 half-switch).
# Every other flight-sheet field (CUSTOM_URL, CUSTOM_TEMPLATE, CUSTOM_PASS, CUSTOM_USER_CONFIG) is read
# unchanged by whichever engine script runs; see engines/verus/h-config.sh and engines/rx/h-config.sh for
# what each one means for that engine (Pass is a THREAD COUNT for Verus, a POOL PASSWORD for RandomX).
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}
. "$BLOX_DIR/h-manifest.conf" || { return 1 2>/dev/null || exit 1; }
. "$BLOX_DIR/h-common.sh" || { return 1 2>/dev/null || exit 1; }

# fail() only reports (Hive message + local echo) - see the top comment for why it must never itself try to
# stop the script. Every call site follows it with the same bare `return ... || exit ...`.
fail() { echo "$1"; message error "$1" 2>/dev/null; }

if ! select_engine "${CUSTOM_ALGO:-}"; then
	fail "BloxMiner: Algorithm must be empty (Verus/VerusHash), \"verus\"/\"verushash\", \"randomx\", or one of rx/0 rx/wow rx/arq rx/graft rx/sfx rx/yada (got \"${CUSTOM_ALGO:-}\")"
	return 1 2>/dev/null || exit 1
fi

# Reject Extra config that carries the OTHER engine's own config.json marker BEFORE the engine's own
# h-config.sh ever runs, so a rejection leaves config.json completely untouched (not just "correct but
# ambiguous" - see engine_from_config/reject_foreign_selector in h-common.sh for why this key specifically,
# and why it can only ever come from Extra config, never from either engine's own fixed output).
if ! reject_foreign_selector "$ENGINE" "${CUSTOM_USER_CONFIG:-}"; then
	fail "BloxMiner: Extra config \"$FOREIGN_SELECTOR_KEY\" selects the other engine and cannot be combined with the $ENGINE engine (Algorithm=\"${CUSTOM_ALGO:-}\")"
	return 1 2>/dev/null || exit 1
fi

export BLOX_DIR
# Sourced, inside a subshell (see point 1 above): inherits this shell's full variable table, exported or not,
# while containing the engine script's own exit/cd. $NORM_ALGO is set only inside the subshell, so it never
# leaks into this dispatcher's own environment either.
# shellcheck disable=SC1090   # $ENGINE is one of exactly two known, fixed values (verus|rx), never external input
( CUSTOM_ALGO=$NORM_ALGO; . "$BLOX_DIR/engines/$ENGINE/h-config.sh" )
status=$?
if [[ $status -ne 0 ]]; then
	return "$status" 2>/dev/null || exit "$status"
		# the engine's own h-config.sh already sent the Hive error message on failure and left the previous
		# config.json untouched (tmp+mv) - nothing else to report here.
fi
	# Nothing else to do on success: config.json IS the engine record now (see the top comment).
