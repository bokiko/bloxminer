#!/usr/bin/env bash
# Top-level dispatcher: starts whichever engine config.json's own content says is active (engine_from_config in
# h-common.sh - see there for why there is no separate state file). The engines never run at once - Hive stops
# the previous miner process before calling h-config/h-run again on an algo switch, and this package has only
# one screen/log for either engine.
#
# Hive SOURCES this script too (hive-ref/miner-run: `source $MINER_DIR/h-run.sh`), so the same rule as
# h-config.sh applies: no `cd` (nothing below needs one - every path is absolute via $BLOX_DIR), and no `exit`
# on any early failure - `return 1 2>/dev/null || exit 1`, bare, at the top level, stops sourcing here without
# killing whatever sourced us. The one place this script does end in `exec` (below) is intentionally
# unconditional and safe in both sourced and executed contexts: `exec` replaces the current process image
# outright regardless of how it was reached, exactly like engines/verus/h-run.sh and engines/rx/h-run.sh's own
# terminal `exec` already do (Hive supervises the resulting miner process itself, sourced or not) - and neither
# engine's h-run.sh needs any flight-sheet variable from this shell (CUSTOM_CONFIG_FILENAME/CUSTOM_LOG_BASENAME
# come from h-manifest.conf, which each engine's own h-run.sh re-sources itself), so there is no non-exported-
# variable problem here the way there was in h-config.sh.
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}
. "$BLOX_DIR/h-manifest.conf" || { return 1 2>/dev/null || exit 1; }
. "$BLOX_DIR/h-common.sh" || { return 1 2>/dev/null || exit 1; }

fail() { echo "$1"; message error "$1" 2>/dev/null; }

# Fail closed: never default to either engine. A missing/unreadable/unrecognised config.json (or jq itself
# missing) means h-config.sh never ran, or something corrupted the file it wrote - starting ANY engine on an
# unverified guess would be worse than refusing to start at all.
if ! engine=$(engine_from_config); then
	fail "BloxMiner: cannot start - $CUSTOM_CONFIG_FILENAME is missing, unreadable, or not a recognised BloxMiner/BloxMiner-X config (jq required to check); run h-config.sh again"
	return 1 2>/dev/null || exit 1
fi

# Host hygiene: the RandomX engine reserves ~1200 x 2 MB huge pages on start (its own h-run.sh, via Hive's own
# `hugepages -rx` helper when present) and nothing ever releases them on a switch - custom miners have no stop
# hook. Track only the reservation THIS package made (see h-common.sh): record the pre-rx value once before rx
# starts, restore it once before verus starts next. A fresh install, or a foreign reservation this package
# never touched, is left exactly as found either way.
#
# PR #2 review (Codex): this used to call note_rx_hugepages_start (which reserves ~2.4 GiB via `hugepages -rx`)
# UNCONDITIONALLY, before the rx engine's own h-run.sh ever got a chance to reject a host without AES-NI - and
# because XMRig then never ran, that reservation's ownership record could never finalize, permanently pinning
# the memory until reboot (engines/rx/h-run.sh's own CPU gate rejects the start, but only AFTER this dispatcher
# had already reserved).
#
# PR #2 follow-up review (Codex): an earlier fix here sourced engines/rx/h-run.sh ITSELF, in a special env-var-
# gated "preflight-only" mode, relying on that file's own early `return` to stop before its other side effects
# (including the EXIT trap it installs) - correct, but harder to verify by inspection than it needed to be.
# Fixed to remove that whole class of question: engines/rx/cpu-gate.sh is nothing but cpu_ok()'s own definition
# - sourcing it can never have a side effect beyond defining that one function, so there is no "does the early
# return actually fire first" for a reviewer to have to trust. cpu_ok() is then called directly, in plain
# sight, right here, BEFORE note_rx_hugepages_start - reusing that one function (also called by engines/rx/
# h-run.sh's own, unchanged, defense-in-depth check before ITS OWN `hugepages -rx`) is what makes it impossible
# for the two checks to ever drift apart. No reservation is made at all on a rejected host: `hugepages -rx` is
# never called, no record is ever written. engines/rx/h-run.sh's own general EXIT-trap rollback (see its own
# header) is the remaining safety net for any OTHER reason an rx start might fail after this dispatcher's own
# reservation.
if [[ $engine == rx ]]; then
	. "$BLOX_DIR/engines/rx/cpu-gate.sh"   # cpu_ok() only - no other side effect at all, see that file's header
	if ! cpu_ok; then
		fail "BloxMiner (RandomX engine) needs an x86-64 CPU with AES-NI (RandomX requires AES acceleration)"
		sleep 60
		return 1 2>/dev/null || exit 1
	fi
	note_rx_hugepages_start
elif [[ $engine == verus ]]; then
	restore_verus_hugepages
fi

export BLOX_DIR
exec "$BLOX_DIR/engines/$engine/h-run.sh"
