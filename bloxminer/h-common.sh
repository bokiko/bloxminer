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
# updated, or vice versa). The rx engine's config always has a top-level "randomx" OBJECT (even {}, see
# engines/rx/h-config.sh's fixed block - never absent, never any other type); the verus engine's always has
# top-level "algo":"verus" (engines/verus/h-config.sh, "algo" is in its own PROTECTED list, so Extra config can
# never override it). Both markers present - or a "randomx" key present but not an object, which can only ever
# be a hand-placed/corrupt file, never something either engine's own h-config.sh would write - is AMBIGUOUS and
# fails closed exactly like neither marker being present: reject_foreign_selector (below) is what keeps a
# LEGITIMATELY generated config.json from ever reaching this ambiguous state via Extra config, but this
# function stays just as strict on its own for any config.json however it got there. Prints exactly "verus" or
# "rx" and returns 0 on an unambiguously recognised config; returns 1 (prints nothing) and lets the caller
# decide how to fail closed otherwise. Never guesses/defaults to either engine.
engine_from_config() {
	command -v jq > /dev/null 2>&1 || return 1
	[[ -n ${CUSTOM_CONFIG_FILENAME:-} && -r $CUSTOM_CONFIG_FILENAME ]] || return 1
	local has_rx=0 has_verus=0
	jq -e 'has("randomx") and (.randomx | type == "object")' "$CUSTOM_CONFIG_FILENAME" > /dev/null 2>&1 && has_rx=1
	jq -e '.algo == "verus"' "$CUSTOM_CONFIG_FILENAME" > /dev/null 2>&1 && has_verus=1
	[[ $has_rx == 1 && $has_verus == 1 ]] && return 1   # both markers present: ambiguous, never guess
	[[ $has_rx == 1 ]] && { echo rx; return 0; }
	[[ $has_verus == 1 ]] && { echo verus; return 0; }
	return 1
}

# foreign_selector_key <engine> - the OTHER engine's own config.json marker (see engine_from_config above),
# which must never reach a config generated FOR <engine>: "randomx" for verus (RandomX's own always-present
# top-level key - verus's engine binary has no use for it, so nothing protects it from Extra config the way
# "algo" is protected on the verus side); "algo" for rx (Verus's own always-present top-level marker - the rx
# engine's OWN algo lives nested under pools[0].algo, never top-level, so a top-level "algo" in an rx config
# can only ever have come from Extra config, never from anything the rx engine itself needs).
foreign_selector_key() { [[ $1 == verus ]] && echo randomx || echo algo; }

# reject_foreign_selector <engine> <raw CUSTOM_USER_CONFIG members, unwrapped> - returns 1 (and sets
# $FOREIGN_SELECTOR_KEY) if Extra config carries a top-level key that is the OTHER engine's own selector
# marker; the caller (h-config.sh) must call this and fail BEFORE running the engine's own h-config.sh, so a
# rejection leaves config.json completely untouched rather than merely producing a config that would later be
# ruled ambiguous by engine_from_config. Silently returns 0 (nothing to reject) on Extra config that does not
# even parse as JSON members - the engine's own h-config.sh already reports THAT error itself, with its own
# message and exit code; this check only ever adds a NEW rejection, never masks or duplicates that one.
reject_foreign_selector() {
	local engine=$1 raw=$2 key parsed
	[[ -n $raw ]] || return 0
	parsed=$(jq -ce 'if type == "object" then . else error end' <<< "{$raw}" 2>/dev/null) || return 0
	key=$(foreign_selector_key "$engine")
	if jq -e --arg k "$key" 'has($k)' <<< "$parsed" > /dev/null 2>&1; then
		# shellcheck disable=SC2034   # FOREIGN_SELECTOR_KEY is read by the caller (h-config.sh), not here
		FOREIGN_SELECTOR_KEY=$key
		return 1
	fi
	return 0
}

# Huge-page ownership (h-run.sh only): the RandomX engine reserves ~1200 x 2 MB huge pages on start (Hive's own
# `hugepages -rx` helper, see engines/rx/h-run.sh) and nothing ever releases them again - custom miners have no
# stop hook. Rather than unconditionally resetting the host's hugepage count on every Verus start (stomping any
# OTHER reservation on the box - another workload, or an operator's own setting), this package tracks ONLY the
# reservation IT made, in one small ownership file under $STATEDIR (/run/hive when present - tmpfs, so a reboot
# clears this record together with the non-persistent reservation it describes; verified live against Hive's
# own `hugepages` tool on a rig, 2026-09-28: `-rx` computes its own target from NUMA/CPU count and writes
# /proc/sys/vm/nr_hugepages directly - it never reads the prior value and never persists anything to
# /etc/sysctl.conf or any boot-time setting).
# The record holds TWO values, "prior=" (what to restore) and "ours=" (what this package itself last set
# vm.nr_hugepages to - the value it is entitled to overwrite). "ours" has to be the value AFTER rx's own
# reservation runs, not just observed-before-rx, so that a Verus start can tell "the live value is still what
# I set it to, safe to put prior back" apart from "something else changed it since - not mine to touch any
# more". rx's own reservation only happens inside engines/rx/h-run.sh (via Hive's `hugepages -rx`, called AFTER
# this dispatcher already exec'd into it) - engines/rx/h-run.sh is gated and untouched, so this dispatcher
# cannot observe ITS call. Instead, note_rx_hugepages_start runs that same Hive tool itself, once, BEFORE exec
# - `hugepages -rx` is a pure function of NUMA-node count and CPU-core count (see the read-only inspection
# above: no randomness, no prior-value dependency), so calling it here and then again moments later from
# engines/rx/h-run.sh is idempotent - both calls compute and set the identical target. This was chosen over
# duplicating Hive's own reservation arithmetic in this repo (which would silently drift the moment Hive
# changes that tool) and over trying to observe engines/rx/h-run.sh's own call from outside (not possible
# without instrumenting that gated, untouched script).
HUGEPAGES_FILE="$STATEDIR/.bloxminer-hugepages"

# log_hugepages_note <message> - a plain timestamped line in this package's own log (the same file/convention
# engines/*/h-run.sh already use for their own startup diagnostics), never a Hive `message` toast: a skipped
# restore is not fatal and never blocks the miner from starting, so it does not warrant an operator alert.
log_hugepages_note() {
	{ printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$1" >> "${CUSTOM_LOG_BASENAME:-$STATEDIR/bloxminer}.log"; } 2>/dev/null
}

# note_rx_hugepages_start - called just before exec'ing the rx engine. ONLY if no record already exists (an rx
# restart - e.g. a flight-sheet edit that keeps the same algo - must never re-derive "prior"/"ours", or rx's
# own already-raised value would become the "prior" restored on the next Verus start): reads the CURRENT
# vm.nr_hugepages ("prior"), runs Hive's `hugepages -rx` if present (see the top comment for why), then reads
# vm.nr_hugepages again ("ours" - the value this package is now entitled to restore FROM). No-op entirely (no
# sysctl/proc access at all) if the record already exists or the current value cannot be read.
note_rx_hugepages_start() {
	[[ -e $HUGEPAGES_FILE ]] && return 0
	local proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages" prior post tmp
	[[ -r $proc ]] || return 0
	prior=$(<"$proc") 2>/dev/null
	[[ $prior =~ ^[0-9]+$ ]] || return 0
	{ command -v hugepages > /dev/null 2>&1 && hugepages -rx; } > /dev/null 2>&1
	post=$prior
	if [[ -r $proc ]]; then
		local p2; p2=$(<"$proc") 2>/dev/null
		[[ $p2 =~ ^[0-9]+$ ]] && post=$p2
	fi
	tmp="$HUGEPAGES_FILE.tmp.$$"
	{ printf 'prior=%s\nours=%s\n' "$prior" "$post" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$HUGEPAGES_FILE" 2>/dev/null
}

# restore_verus_hugepages - called just before exec'ing the verus engine. ONLY if a record exists (a fresh
# install, or a Verus start never preceded by an rx start under this package's ownership, touches
# vm.nr_hugepages at all): if the CURRENT value no longer matches the recorded "ours" - something else changed
# it since this package's own rx reservation - this is no longer a value this package owns; it is left
# completely untouched, the conflict is logged, and the record is KEPT (not dropped: a later Verus start may
# find the value has settled back to "ours" and can then complete the restore, and dropping the record here
# would silently abandon "prior" forever with no other trace of it). Otherwise restores vm.nr_hugepages to
# "prior" - the record is removed ONLY once that write is confirmed to have succeeded; a failed write (e.g.
# permission denied) leaves the record in place for the next Verus start to retry, rather than silently
# forgetting "prior".
restore_verus_hugepages() {
	[[ -e $HUGEPAGES_FILE ]] || return 0
	local prior ours cur proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages"
	prior=$(sed -n 's/^prior=//p' "$HUGEPAGES_FILE" 2>/dev/null)
	ours=$(sed -n 's/^ours=//p' "$HUGEPAGES_FILE" 2>/dev/null)
	if [[ ! $prior =~ ^[0-9]+$ ]]; then rm -f "$HUGEPAGES_FILE" 2>/dev/null; return 0; fi   # corrupt/unreadable record: nothing usable
	cur=""; [[ -r $proc ]] && cur=$(<"$proc") 2>/dev/null
	if [[ -n $ours && $ours =~ ^[0-9]+$ && -n $cur && $cur != "$ours" ]]; then
		log_hugepages_note "BloxMiner: vm.nr_hugepages changed outside this package (ours=$ours, now=$cur) - left untouched, prior=$prior kept on record"
		return 0
	fi
	if command -v sysctl > /dev/null 2>&1 && sysctl -q -w vm.nr_hugepages="$prior" 2>/dev/null; then
		rm -f "$HUGEPAGES_FILE" 2>/dev/null   # only consumed once the restore is verified to have succeeded
	fi
	true
}
