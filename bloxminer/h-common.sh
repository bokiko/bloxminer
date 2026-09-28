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

# Huge-page ownership (h-run.sh + h-stats.sh): the RandomX engine reserves ~1200 x 2 MB huge pages on start
# (Hive's own `hugepages -rx` helper, see engines/rx/h-run.sh) and nothing ever releases them again - custom
# miners have no stop hook. Rather than unconditionally resetting the host's hugepage count on every Verus
# start (stomping any OTHER reservation on the box - another workload, or an operator's own setting), this
# package tracks ONLY the reservation IT made, in one small ownership file under $STATEDIR (/run/hive when
# present - tmpfs, so a reboot clears this record together with the non-persistent reservation it describes;
# verified live against Hive's own `hugepages` tool on a rig, 2026-09-28: `-rx` computes its own target from
# NUMA/CPU count and writes /proc/sys/vm/nr_hugepages directly - it never reads the prior value and never
# persists anything to /etc/sysctl.conf or any boot-time setting).
#
# ROUND 5 - "ours" is not simply "the value right after `hugepages -rx`". Proven live on cask18, 2026-09-28
# (C4-CASK18-RESULT.md FINDING): Hive's `-rx` set nr_hugepages to 1200, this package recorded THAT as "ours",
# but XMRig itself (running as root) then raised nr_hugepages again on its own, to 1201, once it discovered
# `-rx`'s target still left it short of what its own dataset+scratchpad allocations actually need. The next
# Verus start's "current(1201) != ours(1200)" check correctly refused to touch it (never restored the WRONG
# value) - but that also means it never restores AT ALL on a rig whose prior baseline was 0: ~2.3 GB of huge
# pages stay pinned forever. The fix is not to guess XMRig's own arithmetic ourselves - it is to POSITIVELY
# CONFIRM, from XMRig's own reported numbers, that the live value is entirely what XMRig itself raised (never
# a foreign change), and only then adopt that live value as "ours".
#
# How XMRig raises nr_hugepages (confirmed by reading the exact xmrig source this package's build/build-rx.sh
# compiles, ~/projects/bloxminer-work/xmrig-src, xmrig 6.26.0):
#   - xmrig.crypto.common.VirtualMemory_unix.cpp:236 - every 2 MB-page scratchpad/dataset allocation
#     (`VirtualMemory::allocateLargePagesMemory()`) calls `LinuxMemory::reserve(m_size, m_node, hugePageSize())`
#     BEFORE actually mmap'ing it. (VirtualMemory_unix.cpp:259 is the SEPARATE 1 GB-pages path - see the
#     documented limitation below.)
#   - xmrig.crypto.common.LinuxMemory.cpp:106-118 (`LinuxMemory::reserve`) - for each such allocation:
#     `required = align(size, 2MiB) / 2MiB`; `available = free_hugepages(node)` (reads the live
#     `.../hugepages-2048kB/free_hugepages` sysfs counter); if `available >= required` it returns WITHOUT
#     writing anything (there is already enough free); otherwise it writes
#     `nr_hugepages(node) + (required - available)` to `.../hugepages-2048kB/nr_hugepages` (LinuxMemory.cpp:78-
#     84, `write_nr_hugepages` - per NUMA-node sysfs path first, falling back to the global
#     `/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages`, which is the SAME global counter Hive's
#     `hugepages -rx` and this package's own restore both read/write via `/proc/sys/vm/nr_hugepages` - proven on
#     cask18: XMRig's write there was what `/proc/sys/vm/nr_hugepages` showed afterward). Every call is
#     serialised by a single process-wide mutex (LinuxMemory.cpp:33/108), so however many threads allocate
#     concurrently, these reserve() calls behave as one strictly sequential sequence for arithmetic purposes -
#     this is what makes the closed-form predicted-total formula below exact, not an approximation:
#     sum_i max(0, required_i - free_i) telescopes to max(0, sum(required_i) - free_at_start), because each
#     write both raises nr_hugepages by exactly the shortfall AND immediately consumes that allocation's own
#     `required_i` pages from what is free (mmap follows the same reserve() call).
#   - xmrig.crypto.common.HugePagesInfo.cpp:24-36 - the TOTAL number of 2 MB pages XMRig's allocations need in
#     aggregate (dataset + every thread's scratchpad) is exactly `sum(required_i)` above, in 2 MB-page units,
#     PROVIDED none of those allocations used 1 GB pages (a 1 GB-page allocation reports its total in 1 GB-page
#     units instead - HugePagesInfo.cpp:26-30 - and HugePagesInfo::operator+= (HugePagesInfo.h:47-54) sums those
#     into the SAME counter as 2 MB-page allocations with no unit conversion; this package's build only ever
#     requests 1 GB pages opt-in, per-config, see engines/rx/h-config.sh:11/51-65 - the documented limitation
#     below is exactly this case).
#   - xmrig.backend.cpu.CpuBackend.cpp:439 and :471 expose that total, plus how much of it is CURRENTLY
#     allocated, as `"hugepages": [allocated, total]` on both `/2/backends` (per backend, version hardcoded to 2
#     at line 439) and `/2/summary` (line 471, `REQ_SUMMARY`, using the caller's own API version - rx's
#     engines/rx/h-stats.sh already queries `/2/summary` and `/2/backends` this exact way for ownership-verified
#     stats, so this is the SAME reply shape/port/ownership check this package already trusts elsewhere, not a
#     new interface).
#
# DESIGN: the record now holds, from note_rx_hugepages_start (called before rx's own exec, same as before):
#   prior=<N>    the value observed BEFORE `hugepages -rx` ran (what to restore, unchanged in meaning)
#   prelim=<N>   the value observed immediately AFTER this dispatcher's own `hugepages -rx` call (what the OLD
#                code wrongly called "ours" - now just the STARTING point for XMRig's own further raises)
#   free0=<N>    HugePages_Free (from /proc/meminfo) at that same moment - what XMRig itself sees as "already
#                free" when its first reserve() call runs
#   boot=<uuid>  /proc/sys/kernel/random/boot_id at record time - a record can only ever be finalised/restored
#                within the SAME boot it was written in (belt-and-braces: tmpfs already clears this file on
#                reboot, but a boot_id mismatch is an extra, cheap, explicit guard against acting on it anyway)
#   final=0      not yet finalised - see finalize_rx_hugepages below
# Finalisation (h-stats.sh, every ~10 s poll while engine==rx and final=0 - see finalize_rx_hugepages) waits
# until XMRig's OWN reported numbers positively prove the raising is finished and entirely its own doing:
# ownership of the API port confirmed (the same /proc/net/tcp -> inode -> pid -> exe check rx's own h-stats.sh
# already does), khs>0 (real hashing under way), and hugepages allocated==total (no more reserve() calls
# pending) - only THEN is `live vm.nr_hugepages` compared against the value XMRig's own rule predicts
# (`prelim + max(0, total - free0)`, the closed form derived above). An exact match writes `ours=<live>` and
# `final=1` - THIS is the value a later Verus start is entitled to restore over (restore_verus_hugepages,
# below, now also requires final=1 before it looks at prior/ours at all). A mismatch (something else changed
# nr_hugepages during the startup window - the one case the old code silently mis-attributed to this package)
# is never finalised: logged ONCE (final is set to "conflict", a terminal state this function never revisits,
# so it never spams the log every poll), record kept for a human/reboot to sort out. Backward compatibility: an
# OLD-format record (prior=/ours= only, written by a pre-Round-5 package, still on tmpfs after an in-place
# upgrade with no reboot) has no `final=` line at all - restore_verus_hugepages's `final=1` gate below simply
# never matches an empty/missing value, so such a record is left untouched (never wrongly trusted) until the
# next reboot clears it; no migration code is needed for that, per design.
# DOCUMENTED LIMITATION: if RandomX 1 GB-pages is in effect (engines/rx/h-config.sh's opt-in
# `"randomx":{"1gb-pages":true}`, gated behind its own >=3 GiB/NUMA-node free check), XMRig's reported
# "hugepages" total mixes 1 GB-page and 2 MB-page units (HugePagesInfo.cpp:26-30 vs :32-34, summed with no
# conversion) and no longer corresponds 1:1 to `/proc/sys/vm/nr_hugepages`, so the predicted-value formula above
# does not apply. finalize_rx_hugepages detects this from config.json itself (the same file h-config.sh wrote)
# and refuses to finalize for that session - logged once, record kept, exactly like any other unconfirmed case.
HUGEPAGES_FILE="$STATEDIR/.bloxminer-hugepages"

# _hp_field <name> - one field from the ownership record, or empty if absent/unreadable. A tiny shared reader
# so every gate below (note/finalize/restore) parses the same five-line key=value file the same way.
_hp_field() { [[ -r $HUGEPAGES_FILE ]] && sed -n "s/^$1=//p" "$HUGEPAGES_FILE" 2>/dev/null | tail -n1; }

# _hp_boot_id - current /proc/sys/kernel/random/boot_id (BLOX_PROCFS_ROOT overridable for tests), or empty if
# unreadable. Empty never matches a recorded boot (also possibly empty) unless a test deliberately makes both
# sides empty to exercise that path - see finalize_rx_hugepages's boot-id gate.
_hp_boot_id() { local f="${BLOX_PROCFS_ROOT:-/proc}/sys/kernel/random/boot_id"; [[ -r $f ]] && cat "$f" 2>/dev/null; }

# _hp_free_hugepages - HugePages_Free from /proc/meminfo (BLOX_PROCFS_ROOT overridable for tests). Empty/absent
# on any read failure - callers treat that exactly like any other missing precondition (never finalize).
_hp_free_hugepages() { awk '/^HugePages_Free:/{print $2; exit}' "${BLOX_PROCFS_ROOT:-/proc}/meminfo" 2>/dev/null; }

# _hp_rewrite <final> [ours] - atomically rewrites the record, keeping prior/prelim/free0/boot as they already
# are and setting only `final` (and `ours`, when given - only ever passed on a successful finalisation).
# tmp+mv, same atomicity convention as every other write in this file.
_hp_rewrite() {
	local prior prelim free0 boot tmp
	prior=$(_hp_field prior); prelim=$(_hp_field prelim); free0=$(_hp_field free0); boot=$(_hp_field boot)
	tmp="$HUGEPAGES_FILE.tmp.$$"
	{
		printf 'prior=%s\nprelim=%s\nfree0=%s\nboot=%s\nfinal=%s\n' "$prior" "$prelim" "$free0" "$boot" "$1"
		[[ -n ${2:-} ]] && printf 'ours=%s\n' "$2"
		true   # the group's own exit status must never depend on the conditional printf above (which is FALSE,
		       # i.e. failing, whenever $2 is omitted - every "conflict" call) - without this, that false status
		       # propagated out of the `{ ... }` group and skipped the `&& mv -f` below entirely, so a conflict
		       # was logged but NEVER ACTUALLY PERSISTED: final stayed "0" forever, and every later poll re-ran
		       # the whole ownership+API check and re-logged the same conflict again - exactly the "spam every
		       # 10 s" this design explicitly forbids. Caught by tests/hive/test_hugepage_finalization.sh.
	} > "$tmp" 2>/dev/null && mv -f "$tmp" "$HUGEPAGES_FILE" 2>/dev/null
}

# log_hugepages_note <message> - a plain timestamped line in this package's own log (the same file/convention
# engines/*/h-run.sh already use for their own startup diagnostics), never a Hive `message` toast: a skipped
# restore is not fatal and never blocks the miner from starting, so it does not warrant an operator alert.
log_hugepages_note() {
	{ printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$1" >> "${CUSTOM_LOG_BASENAME:-$STATEDIR/bloxminer}.log"; } 2>/dev/null
}

# note_rx_hugepages_start - called just before exec'ing the rx engine. ONLY if no record already exists (an rx
# restart - e.g. a flight-sheet edit that keeps the same algo - must never re-derive "prior"/"prelim", or rx's
# own already-raised value would become the "prior" restored on the next Verus start): reads the CURRENT
# vm.nr_hugepages ("prior"), runs Hive's `hugepages -rx` if present (see the top comment for why), then reads
# vm.nr_hugepages ("prelim") and HugePages_Free ("free0") again, plus the current boot_id. No-op entirely (no
# record written) if the record already exists, "prior" cannot be read, "prelim" cannot be read afterwards, or
# "free0" cannot be read - a record is only ever written when all three are known-good numbers; finalize_rx_
# hugepages (h-stats.sh) needs every one of them to compute XMRig's own predicted total, and writing a record
# with any of them missing would let that check never fire safely, so this function simply never produces that
# record in the first place. `final=0` marks it not yet finalized; `ours` is deliberately NOT written here any
# more (Round 5 - see the top-of-section comment for why "the value right after `hugepages -rx`" was wrong) -
# it is only ever written by finalize_rx_hugepages, once XMRig's own reported numbers confirm what it is.
note_rx_hugepages_start() {
	[[ -e $HUGEPAGES_FILE ]] && return 0
	local proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages" prior prelim free0 boot tmp
	[[ -r $proc ]] || return 0
	prior=$(<"$proc") 2>/dev/null
	[[ $prior =~ ^[0-9]+$ ]] || return 0
	{ command -v hugepages > /dev/null 2>&1 && hugepages -rx; } > /dev/null 2>&1
	prelim=""
	[[ -r $proc ]] && prelim=$(<"$proc") 2>/dev/null
	if [[ ! $prelim =~ ^[0-9]+$ ]]; then
		log_hugepages_note "BloxMiner: could not read vm.nr_hugepages after reserving for rx ($proc unreadable/invalid) - no ownership record written; the next Verus start will leave vm.nr_hugepages untouched"
		return 0
	fi
	free0=$(_hp_free_hugepages)
	if [[ ! $free0 =~ ^[0-9]+$ ]]; then
		log_hugepages_note "BloxMiner: could not read HugePages_Free after reserving for rx (/proc/meminfo unreadable/invalid) - no ownership record written; the next Verus start will leave vm.nr_hugepages untouched"
		return 0
	fi
	boot=$(_hp_boot_id)
	tmp="$HUGEPAGES_FILE.tmp.$$"
	{ printf 'prior=%s\nprelim=%s\nfree0=%s\nboot=%s\nfinal=0\n' "$prior" "$prelim" "$free0" "$boot" > "$tmp"; } 2>/dev/null \
		&& mv -f "$tmp" "$HUGEPAGES_FILE" 2>/dev/null
}

# finalize_rx_hugepages - called from the TOP-LEVEL h-stats.sh (never from here, never from h-run.sh), once per
# poll while engine==rx, AFTER the rx engine's own h-stats.sh has already run and set $khs (its exported PORT/
# PROC/PKG also become plain vars of this same shell once sourced - reused here rather than re-deriving them,
# so this never contradicts what the engine's own ownership check just used). Every gate below is ordered
# cheapest-and-most-likely-to-short-circuit first, so the steady-state cost (final already 1 or conflict, the
# overwhelming majority of polls over a rig's uptime) is one file read; only the few polls during an rx start's
# own ramp-up window ever reach the curl call, and that call carries the same 0.5 s cap engines/rx/h-stats.sh's
# own API calls already use.
# Never finalizes on merely "not ready yet" (record missing, boot_id not yet matching, API not yet owned, no
# hashrate yet, or hugepages not yet fully allocated) - those are the NORMAL early polls of a fresh rx start,
# silently retried, never logged. Only once readiness is fully proven (ownership confirmed, khs>0, XMRig's own
# hugepages count shows allocated==total, i.e. no more of ITS OWN reserve() calls are still pending) does a
# predicted-vs-live mismatch mean something else changed nr_hugepages during the startup window - THAT is
# logged once (final set to "conflict", a terminal, non-retried state) rather than on every subsequent poll.
finalize_rx_hugepages() {
	[[ -e $HUGEPAGES_FILE ]] || return 0
	[[ $(_hp_field final) == 0 ]] || return 0   # anything but exactly "0" (1, conflict, or missing/legacy) is done

	local rec_boot cur_boot
	rec_boot=$(_hp_field boot); cur_boot=$(_hp_boot_id)
	[[ -n $rec_boot && $rec_boot == "$cur_boot" ]] || return 0   # different/unreadable boot_id: not this boot's
		# record (or boot_id unreadable on both sides) - never act on it; tmpfs will clear it on the next reboot

	[[ ${khs:-} =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v k="${khs:-0}" 'BEGIN{exit !(k>0)}' || return 0   # no hashrate yet

	command -v jq > /dev/null 2>&1 || return 0
	command -v curl > /dev/null 2>&1 || return 0

	# ---- ownership: the SAME /proc/net/tcp -> inode -> pid -> exe check engines/rx/h-stats.sh's own run()
	# already does, independently re-derived here since that script's internals never leave its own subshell -
	# only $khs/$stats (its documented contract) and its exported PORT/PROC/PKG survive into this shell.
	local api_proc=${PROC:-/proc} api_pkg=${PKG:-$BLOX_DIR} api_port=${PORT:-4069}
	local port_hex inode owner_pid fd_dir owned=0
	port_hex=$(printf '%04X' "$api_port")
	inode=$(awk -v p="$port_hex" 'NR>1{split($2,a,":"); if(a[1]=="0100007F" && a[2]==p && $4=="0A") print $10}' \
		"$api_proc/net/tcp" 2>/dev/null | head -n1)
	if [[ -n $inode ]]; then
		fd_dir=$(find "$api_proc" -mindepth 3 -maxdepth 3 -path "$api_proc/[0-9]*/fd/*" -lname "socket:\[$inode\]" \
			-printf '%h\n' 2>/dev/null | head -n1)
		[[ -n $fd_dir ]] && owner_pid=${fd_dir#"$api_proc"/} && owner_pid=${owner_pid%%/*}
	fi
	[[ -n ${owner_pid:-} && $(readlink "$api_proc/$owner_pid/exe" 2>/dev/null) == "$api_pkg/xmrig" ]] && owned=1
	(( owned )) || return 0

	local sum
	sum=$(curl -fsS --max-time 0.5 "http://127.0.0.1:$api_port/2/summary" 2>/dev/null)
	jq -e 'type == "object"' > /dev/null 2>&1 <<< "$sum" || return 0

	local hp_allocated hp_total
	hp_allocated=$(jq -r '(.hugepages[0]) // empty' <<< "$sum" 2>/dev/null)
	hp_total=$(jq -r '(.hugepages[1]) // empty' <<< "$sum" 2>/dev/null)
	[[ $hp_allocated =~ ^[0-9]+$ && $hp_total =~ ^[0-9]+$ && $hp_total -gt 0 ]] || return 0
	(( hp_allocated == hp_total )) || return 0   # dataset/scratchpads still being allocated - retry next poll

	# ---- documented limitation: 1 GB-pages mixes units into the same "hugepages" total (see the top-of-section
	# comment) - this package's arithmetic below does not apply; never finalize this session.
	if [[ $(jq -r '(.randomx["1gb-pages"] // false)' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null) == true ]]; then
		log_hugepages_note "BloxMiner: RandomX 1gb-pages is enabled - XMRig's reported hugepage total mixes 1GB/2MB units, so this package's finalization arithmetic does not apply; never finalizing this rx session, ownership record kept"
		_hp_rewrite conflict
		return 0
	fi

	local prior prelim free0
	prior=$(_hp_field prior); prelim=$(_hp_field prelim); free0=$(_hp_field free0)
	[[ $prior =~ ^[0-9]+$ && $prelim =~ ^[0-9]+$ && $free0 =~ ^[0-9]+$ ]] || return 0   # corrupt record - never finalize

	local proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages" cur
	cur=""; [[ -r $proc ]] && cur=$(<"$proc") 2>/dev/null
	[[ $cur =~ ^[0-9]+$ ]] || return 0

	local short=$(( hp_total - free0 )); (( short < 0 )) && short=0
	local predicted=$(( prelim + short ))

	if [[ $cur != "$predicted" ]]; then
		log_hugepages_note "BloxMiner: vm.nr_hugepages ($cur) does not match XMRig's own predicted reservation (prelim $prelim + max(0, need $hp_total - free0 $free0) = $predicted) once the dataset finished allocating - something else changed it during the startup window; never finalizing this rx session, record kept"
		_hp_rewrite conflict
		return 0
	fi

	_hp_rewrite 1 "$cur"   # everything XMRig itself raised, positively confirmed, nothing foreign involved
}

# restore_verus_hugepages - called just before exec'ing the verus engine. ONLY if a record exists (a fresh
# install, or a Verus start never preceded by an rx start under this package's ownership, touches
# vm.nr_hugepages at all) AND that record has final=1 (finalize_rx_hugepages, above, positively confirmed
# "ours" from XMRig's own reported numbers - final=0/"conflict"/missing, including an OLD pre-Round-5 record
# that only ever had prior=/ours= and no final= line at all, is never trusted here; see the top-of-section
# comment on backward compatibility). Given final=1, the restore fires ONLY when ALL THREE of "prior", "ours"
# (both from the record) and the CURRENT value (read fresh, right now) are valid, non-negative integers AND
# current == ours - i.e. this package can positively confirm the live value is still exactly what it itself
# last set. Any single one of those being missing, non-numeric, or unreadable - a corrupt record, an unreadable
# /proc - is treated exactly like a live mismatch: vm.nr_hugepages is left COMPLETELY untouched, never a
# "restore anyway" fallback on partial information. In every one of those non-restoring cases the record is
# KEPT, never dropped: a permanently corrupt record has nowhere better to go than staying on tmpfs (STATEDIR is
# /run/hive when present) until the next reboot clears it along with the non-persistent reservation it
# describes - silently deleting it would erase the one place "prior" is recorded, for no gain. The record is
# removed ONLY once an actual restore write is confirmed to have succeeded, by reading vm.nr_hugepages back and
# verifying it now equals prior (Round 5 - not just trusting `sysctl`'s own exit status); a failed write, or one
# whose readback does not match, also keeps it, for the next Verus start to retry.
restore_verus_hugepages() {
	[[ -e $HUGEPAGES_FILE ]] || return 0
	local final; final=$(_hp_field final)
	if [[ $final != 1 ]]; then
		log_hugepages_note "BloxMiner: huge-page ownership record not finalized (final=${final:-<missing>}) - this package cannot positively confirm what it is entitled to restore; left vm.nr_hugepages untouched, record kept"
		return 0
	fi

	local prior ours cur proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages"
	prior=$(_hp_field prior)
	ours=$(_hp_field ours)
	cur=""; [[ -r $proc ]] && cur=$(<"$proc") 2>/dev/null

	if [[ ! $prior =~ ^[0-9]+$ || ! $ours =~ ^[0-9]+$ ]]; then
		log_hugepages_note "BloxMiner: huge-page ownership record is invalid or corrupt despite final=1 (prior=${prior:-<missing>}, ours=${ours:-<missing>}) - left vm.nr_hugepages untouched, record kept"
		return 0
	fi
	if [[ ! $cur =~ ^[0-9]+$ ]]; then
		log_hugepages_note "BloxMiner: could not read the current vm.nr_hugepages ($proc unreadable) - left untouched, record kept (ours=$ours, prior=$prior)"
		return 0
	fi
	if [[ $cur != "$ours" ]]; then
		log_hugepages_note "BloxMiner: vm.nr_hugepages changed outside this package (ours=$ours, now=$cur) - left untouched, prior=$prior kept on record"
		return 0
	fi

	if command -v sysctl > /dev/null 2>&1 && sysctl -q -w vm.nr_hugepages="$prior" 2>/dev/null; then
		local verify=""; [[ -r $proc ]] && verify=$(<"$proc") 2>/dev/null
		if [[ $verify == "$prior" ]]; then
			rm -f "$HUGEPAGES_FILE" 2>/dev/null   # only consumed once the restore is verified, by readback, to have succeeded
		else
			log_hugepages_note "BloxMiner: restore write to $prior did not read back correctly (now=${verify:-<unreadable>}) - record kept for a later attempt"
		fi
	else
		log_hugepages_note "BloxMiner: failed to restore vm.nr_hugepages to $prior - record kept for a later attempt"
	fi
	true
}
