#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs and $stats, and must NEVER exit that agent process on any failure
# of its own (every early-out below is a plain `return 0 2>/dev/null || exit 0`, the same convention both
# gated engine scripts already use for being sourced). Engine selection failing here - a corrupt manifest, a
# missing h-common.sh, or engine_from_config unable to identify the active engine (missing/unreadable/
# unrecognised config.json, or jq unavailable) - still has to produce a defined, safe answer rather than crash
# or guess: it falls back to $khs=0 with empty stats, exactly like "no API answer" already does in both
# engines. This never defaults to either engine on an unverified guess - see h-common.sh's engine_from_config.
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
BLOX_HP_T0=${EPOCHREALTIME:-$(date +%s.%N 2>/dev/null)}   # Round 5c: this poll's own start, so finalization
	# can be bounded to whatever remains of the SHARED ~3.0 s poll budget once the engine's own collection below
	# has run - see h-common.sh's finalize_rx_hugepages_bounded. Round 5e: bash 5's own builtin EPOCHREALTIME
	# (no fork), falling back to `date +%s.%N` only if unset (an older bash).
# ONE absolute deadline for the WHOLE poll, computed at the true entry point - before manifest/config parsing,
# engine selection, or anything else below, all of which count against the shared budget just as much as the
# engine's own collection does. Exported so the engine h-stats.sh sourced below inherits this SAME value
# (its own DEADLINE_US computation is only a fallback for when it is sourced standalone, e.g. by a test, with
# no dispatcher entry point above it to have set this already).
# Round 5f (Codex): EPOCHREALTIME's own fraction is always exactly 6 digits (real microseconds) already, but
# the `date +%s.%N` FALLBACK above (bash < 5 only) is 9 (nanoseconds) - concatenating it raw, as before,
# silently inflated DEADLINE_US by 1000x whenever that fallback path was ever taken. Pad with trailing zeros
# first, then keep only the first 6 digits - normalizes either source (6-digit already, 9-digit, or anything
# shorter) to exactly 6 real microsecond digits, no fork.
BLOX_HP_T0_FRAC="${BLOX_HP_T0#*.}000000"
BLOX_HP_T0_US="${BLOX_HP_T0%%.*}${BLOX_HP_T0_FRAC:0:6}"
unset BLOX_HP_T0_FRAC
export DEADLINE_US=$(( BLOX_HP_T0_US + 2400000 ))   # 2.4 s of the shared 3.0 s budget - matches both engines' BUDGET_US
# A minimal, valid, engine-agnostic stats object - not an empty string - for the two failure points below.
# Neither engine's own VER/algo is reliably known at this level (the manifest/config that would provide them
# is exactly what failed to load), and this must not depend on jq (the failure could BE jq missing) - plain
# printf, a shell builtin, matches the same jq-free convention both engines' own last-resort fallbacks use.
DISPATCH_FALLBACK_STATS='{"hs":[0],"hs_units":"khs","temp":[null],"ar":[0,0],"uptime":0}'
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}
if ! . "$BLOX_DIR/h-manifest.conf" 2>/dev/null || ! . "$BLOX_DIR/h-common.sh" 2>/dev/null; then
	khs=0; stats="$DISPATCH_FALLBACK_STATS"; return 0 2>/dev/null || exit 0
fi
export BLOX_DIR

engine=$(engine_from_config) || { khs=0; stats="$DISPATCH_FALLBACK_STATS"; return 0 2>/dev/null || exit 0; }

# shellcheck disable=SC1090   # $engine is one of exactly two known, fixed values (verus|rx), never external input
. "$BLOX_DIR/engines/$engine/h-stats.sh"

# Huge-page ownership finalization (rx only, see h-common.sh's "Huge-page ownership" section): must run AFTER
# the engine h-stats.sh above so $khs (and rx's own exported PORT/PROC/PKG) are set - and must never touch
# $khs/$stats itself or make this script fail/print, or overrun the shared poll budget, on any outcome.
# Round 5c: bounded to whatever is LEFT of BLOX_HP_TOTAL_BUDGET_S (default 3.0 s, matching the engine's own
# documented target) after the engine collection above - finalize_rx_hugepages_bounded defers to a later poll
# on a timeout rather than ever let this poll run long; engine scripts stay completely untouched.
# Round 5e: passes an ABSOLUTE deadline (this poll's own start, $BLOX_HP_T0, plus the total budget) computed
# ONCE here, rather than a "seconds remaining" snapshot - a snapshot goes stale the instant any further time
# passes after it is computed, which is exactly what let Round 5c's own escalation overrun this budget (see
# h-common.sh's finalize_rx_hugepages_bounded for the full explanation and the fix).
# ROUND 5f (Codex, PR #2 follow-up review): "Compare the deadline without launching another process" - this
# used to compute BLOX_HP_DEADLINE via awk even though $BLOX_HP_T0_US just above is already this exact same
# instant in forkless integer microseconds; finalize_rx_hugepages_bounded's own deadline parameter is now
# integer microseconds throughout (the same DEADLINE_US convention both engines' own h-stats.sh already use
# for every other timing decision two lines above), so this becomes plain bash arithmetic - no fork.
# BLOX_HP_TOTAL_BUDGET_S is a plain seconds string (a test-only override of the real 3.0 s budget) -
# _hp_secs_to_us converts it the same forkless way. No special-casing needed for a degenerate BLOX_HP_T0_US of
# "0" (EPOCHREALTIME AND the date fallback both failing) either: that naturally yields a deadline far in the
# past relative to any real "now", so finalize_rx_hugepages_bounded's own budget check already bails out
# immediately on it - exactly like the old awk special case did, and exactly how DEADLINE_US's own
# unconditional computation two lines above already handles the identical degenerate case, with no code needed.
if [[ $engine == rx ]]; then
	_hp_secs_to_us "${BLOX_HP_TOTAL_BUDGET_S:-3.0}"
	finalize_rx_hugepages_bounded "$(( BLOX_HP_T0_US + REPLY ))"
fi
true
