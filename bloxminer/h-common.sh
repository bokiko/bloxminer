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
	# PR #2 follow-up review round 2 (Codex): `-s` (exists AND non-empty), not just `-r` (readable) - a
	# zero-byte config.json used to reach the two jq -e checks below with an EMPTY file. jq 1.6 (GitHub
	# Actions' own ubuntu-22.04 runners; see engines/rx/h-stats.sh's valid_summary()/valid_backends() for the
	# full writeup) exits 0 ("successful") for `-e` against empty input - both checks would incorrectly report
	# "found" on an empty file, setting BOTH has_rx and has_verus, which this function's own "both present ->
	# ambiguous, reject" rule then happens to catch anyway (an accidental save, not a deliberate one - fixed
	# properly here rather than relying on that coincidence surviving any future refactor of this function).
	[[ -n ${CUSTOM_CONFIG_FILENAME:-} && -r $CUSTOM_CONFIG_FILENAME && -s $CUSTOM_CONFIG_FILENAME ]] || return 1
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
#     new interface). ROUND 5b: this total is kept ONLY as a readiness signal (allocated==total) - see below for
#     why it is no longer the "need" value the predicted-total formula itself uses.
#
# ROUND 5b - the API's own total still undercounts "need" by exactly one allocation. Proven live on cask18,
# 2026-09-29 (package 2c89cc4c.../commit 12e9cfa): record prior=0/prelim=1200/free0=1200, the API reported
# `hugepages:[1200,1200]` (fully allocated, by its own accounting), yet live vm.nr_hugepages was really 1201 -
# Round 5's formula (`prelim + max(0, api_total - free0)` = 1200) called that an unexplained foreign conflict,
# a false positive. `/proc/<xmrig pid>/smaps_rollup` showed `Private_Hugetlb: 2459648 kB` = exactly 1201 x
# 2048 kB, matching the live value exactly (`Shared_Hugetlb: 0`). Root cause: HugePagesInfo (and so the API's
# total) only ever counts allocations that went through a `VirtualMemory::reserve()`-backed path
# (VirtualMemory_unix.cpp:233-236/259, one per dataset/scratchpad) - but RandomX's JIT code buffer is allocated
# by a SEPARATE path, `VirtualMemory::allocateExecutableMemory` (VirtualMemory_unix.cpp:142-176, called from
# crypto/randomx/jit_compiler_x86.cpp's `JitCompilerX86` via crypto/randomx/virtual_memory.cpp:36-37), which on
# Linux (VirtualMemory_unix.cpp:165-171) mmaps `MAP_HUGETLB` directly with NO `LinuxMemory::reserve()` call and
# NO `HugePagesInfo` bookkeeping at all - a real huge page the kernel actually committed, completely invisible
# to XMRig's own self-reported total. The fix: ask the KERNEL what this exact, ownership-verified xmrig process
# actually has mapped right now (`_hp_xmrig_need_pages`, via `/proc/<pid>/smaps_rollup`'s own
# `Private_Hugetlb`+`Shared_Hugetlb`, divided by `/proc/meminfo`'s own `Hugepagesize` - never hardcoded), not
# what XMRig's incomplete self-report claims. This cannot miss the JIT buffer, or any other future allocation
# path this package does not know about, the same way trusting the API's own accounting did.
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
# until readiness is proven - ownership of the API port confirmed (the same /proc/net/tcp -> inode -> pid ->
# exe check rx's own h-stats.sh already does), khs>0 (real hashing under way), and the API's own hugepages
# allocated==total (its allocator has stopped moving) - and only THEN reads the KERNEL's own truth of what that
# process actually has mapped (`_hp_xmrig_need_pages`, Round 5b - see above for why the API's own total is not
# used here). `live vm.nr_hugepages` is compared against the value XMRig's own rule predicts
# (`prelim + max(0, need - free0)`, the closed form derived above, with `need` now the kernel-measured value).
# An exact match writes `ours=<live>` and `final=1` - THIS is the value a later Verus start is entitled to
# restore over (restore_verus_hugepages, below, now also requires final=1 before it looks at prior/ours at
# all). A mismatch (something else changed
# nr_hugepages during the startup window - the one case the old code silently mis-attributed to this package)
# is never finalised: logged ONCE (final is set to "conflict", a terminal state this function never revisits,
# so it never spams the log every poll), record kept for a human/reboot to sort out. Backward compatibility: an
# OLD-format record (prior=/ours= only, written by a pre-Round-5 package, still on tmpfs after an in-place
# upgrade with no reboot) has no `final=` line at all - restore_verus_hugepages's `final=1` gate below simply
# never matches an empty/missing value, so such a record is left untouched (never wrongly trusted) until the
# next reboot clears it; no migration code is needed for that, per design.
# DOCUMENTED LIMITATION: if RandomX 1 GB-pages is in effect (engines/rx/h-config.sh's opt-in
# `"randomx":{"1gb-pages":true}`, gated behind its own >=3 GiB/NUMA-node free check), smaps_rollup's
# Private_Hugetlb/Shared_Hugetlb fields (Round 5b) sum 1 GB-page and 2 MB-page mappings into the SAME byte
# counters with no way to tell them apart (and the API's own total mixed units here too - HugePagesInfo.cpp:26-
# 30 vs :32-34, summed with no conversion), so neither corresponds 1:1 to `/proc/sys/vm/nr_hugepages`'s own 2 MB
# units, and the predicted-value formula above
# does not apply. finalize_rx_hugepages detects this from config.json itself (the same file h-config.sh wrote)
# and refuses to finalize for that session - logged once, record kept, exactly like any other unconfirmed case.
#
# ROUND 5c - equality with the predicted value is not, by itself, PROOF that XMRig raised it: with prelim==free0
# (no shortfall at all, e.g. cask18's own prior=0/prelim=1200/free0=1200), a FOREIGN write to vm.nr_hugepages
# landing at exactly the same moment XMRig would have raised it anyway could be silently adopted as "ours" -
# Codex's exact counterexample. There is no cheap way to make XMRig itself ATTRIBUTE its own write (it logs
# nothing about it - confirmed by re-reading xmrig-src's LinuxMemory.cpp/VirtualMemory_unix.cpp again for this
# round: no log line, no API field identifies the writer). Codex accepted an alternative: an EXPLICIT,
# documented EXCLUSIVE-STARTUP POLICY instead of an attribution proof. Policy (also in README.md's "Huge
# pages" section): from the moment this dispatcher runs `hugepages -rx` (note_rx_hugepages_start) until
# finalize_rx_hugepages either finalizes or gives up, THIS PACKAGE is the sole SUPPORTED writer of
# vm.nr_hugepages on the rig - HiveOS runs exactly one miner at a time, and the only other program that ever
# writes that counter on a Hive rig is Hive's own `hugepages` tool, which is the one THIS package itself
# invokes; anything else writing it during that window is explicitly unsupported and may be adopted. This is
# bounded, not an open licence: the window itself is time-limited (HUGEPAGES_STARTUP_WINDOW_S below,
# start_uptime in the record) - readiness reached outside it is never finalized regardless of whether the
# numbers would otherwise match, closing off indefinite exposure.
HUGEPAGES_FILE="$STATEDIR/.bloxminer-hugepages"

# HUGEPAGES_STARTUP_WINDOW_S - the exclusive-ownership window's own bound, in seconds since note_rx_hugepages_
# start's own `hugepages -rx` call (start_uptime in the record, from /proc/uptime - monotonic within a boot,
# immune to wall-clock/date changes, and already anchored to the SAME boot via the existing boot_id gate).
# 300 s: on cask18 (2026-09-29 live measurement) the RandomX dataset was ready ~2 s after start - even a much
# slower or resource-starved rig is expected to finish well under a minute; 300 s leaves a generous margin for
# a pathologically slow start while still tightly bounding how long a foreign write could ever be adopted under
# the policy above (never "forever", which was the actual concern - not the exact number of seconds).
# BLOX_HP_STARTUP_WINDOW_S overrides it for tests.
HUGEPAGES_STARTUP_WINDOW_S=${BLOX_HP_STARTUP_WINDOW_S:-300}

# _hp_kv_field <prefix (no trailing colon)> <file> - ROUND 5d: a tiny shared, builtin-only "key: value" line
# scanner for /proc's own colon-separated files (meminfo, smaps_rollup) - one `while read` loop, no fork at all
# (unlike the awk this replaces): matches a line starting with "<prefix>:", strips the prefix, any trailing
# "kB" unit, and all embedded spaces via pure parameter expansion, and prints the remaining digits. Prints
# nothing on no match/unreadable file - callers treat that exactly like any other missing precondition.
_hp_kv_field() {
	local prefix=$1 file=$2 line val
	[[ -r $file ]] || return 0
	while IFS= read -r line; do
		case $line in
			"$prefix":*)
				val=${line#"$prefix":}; val=${val%kB}; val=${val// /}
				printf '%s' "$val"; return 0 ;;
		esac
	done < "$file" 2>/dev/null
}

# _hp_uptime_seconds - integer seconds since boot from /proc/uptime's first field (BLOX_PROCFS_ROOT overridable
# for tests). Prints nothing on any read failure - callers treat that exactly like any other missing
# precondition (note_rx_hugepages_start never writes a record without it; finalize_rx_hugepages never finalizes
# without it). ROUND 5d: builtin `read` + parameter expansion, no fork (was `awk`).
_hp_uptime_seconds() {
	local first _rest
	read -r first _rest < "${BLOX_PROCFS_ROOT:-/proc}/uptime" 2>/dev/null || return 0
	printf '%s' "${first%%.*}"
}

# _hp_now_us - sets $REPLY = now, integer microseconds since epoch. PR #2 follow-up review (Codex): "Compare
# the deadline without launching another process" - bash-builtin EPOCHREALTIME (no fork), falling back to
# `date +%s.%N` only if unset (an older bash), is the EXACT same idiom (and 6-digit-padding fix) both engines'
# own h-stats.sh already use for every timing decision (see their own now_us()) - reused verbatim rather than
# a second, independently-written copy of this arithmetic that could subtly drift from it. EPOCHREALTIME's own
# fraction is always exactly 6 digits (real microseconds) already, but the `date +%s.%N` fallback's is 9
# (nanoseconds) - concatenating it raw would silently inflate the result by 1000x whenever that fallback path
# is ever taken. Pad with trailing zeros first, then keep only the first 6 digits - normalizes either source
# to exactly 6 real microsecond digits, no fork.
_hp_now_us() {
	local t=${EPOCHREALTIME:-} frac
	[[ -n $t ]] || t=$(date +%s.%N 2>/dev/null)
	frac="${t#*.}000000"
	REPLY="${t%%.*}${frac:0:6}"
}

# _hp_secs_to_us <seconds, possibly fractional e.g. "1.5"> - sets $REPLY = integer microseconds, no fork. Only
# needed for BLOX_HP_TOTAL_BUDGET_S (h-stats.sh's test-only override of the real 3.0 s poll budget) -
# _hp_now_us's own EPOCHREALTIME input never needs this (always exactly "S.ffffff", 6 digits already). Handles
# a bare integer ("3", no dot) too, defensively, even though the real default ("3.0") and every test override
# on file always have one. `10#` forces base-10 on both halves - a fractional part with a leading zero (e.g.
# "1.05" -> frac "050000") would otherwise be misread as octal by bash's own arithmetic evaluator.
_hp_secs_to_us() {
	local s=$1 whole frac
	if [[ $s == *.* ]]; then frac="${s#*.}000000"; frac=${frac:0:6}; else frac=000000; fi
	whole=${s%%.*}
	REPLY=$(( 10#$whole * 1000000 + 10#$frac ))
}

# _hp_field <name> - one field from the ownership record, or empty if absent/unreadable. A tiny shared reader
# so every gate below (note/finalize/restore) parses the same key=value file the same way. ROUND 5d: builtin
# `while read` (IFS='=' so "key=value" lines split cleanly, even if value itself is empty), no fork (was
# `sed`+`tail`) - the LAST matching line wins, same as the sed+tail it replaces, for a key ever written twice.
_hp_field() {
	local key=$1 k v val=""
	[[ -r $HUGEPAGES_FILE ]] || return 0
	while IFS='=' read -r k v; do
		[[ $k == "$key" ]] && val=$v
	done < "$HUGEPAGES_FILE" 2>/dev/null
	printf '%s' "$val"
}

# _hp_boot_id - current /proc/sys/kernel/random/boot_id (BLOX_PROCFS_ROOT overridable for tests), or empty if
# unreadable. Empty never matches a recorded boot (also possibly empty) unless a test deliberately makes both
# sides empty to exercise that path - see finalize_rx_hugepages's boot-id gate. ROUND 5d: builtin `read`, no
# fork (was `cat`).
_hp_boot_id() {
	local f="${BLOX_PROCFS_ROOT:-/proc}/sys/kernel/random/boot_id" val
	read -r val < "$f" 2>/dev/null || return 0
	printf '%s' "$val"
}

# _hp_sysfs_hugetlb_present - true if the kernel's hugetlb sysfs interface exists at all (at least one
# /sys/kernel/mm/hugepages/hugepages-<size> entry) - BLOX_SYSFS_ROOT overridable for tests, the SAME variable
# engines/rx/h-config.sh's own 1gb-pages NUMA check and bloxsense's own sysfs reads already use (never a second,
# differently-named override for the same concept). PR #2 follow-up review (Codex): "Verify sysfs before
# allowing an untracked start" - an absent /proc/sys/vm/nr_hugepages does NOT by itself prove no reservation is
# possible on this host: in a restricted container, the proc alias can be masked out while the REAL hugetlb
# sysfs controls underneath it (this path, and its per-NUMA-node mirrors under
# /sys/devices/system/node/node*/hugepages/) remain fully live - XMRig can and does write those directly when
# the proc path is unavailable (confirmed against this package's own pinned xmrig-src:
# LinuxMemory::write_nr_hugepages falls back to exactly the global sysfs node, never just /proc). A host like
# that genuinely CAN reserve - just not through the one path this package itself reads - so it must never take
# the untracked-but-safe fallback note_rx_hugepages_start's own absent-proc branch otherwise would; see that
# function's own call site for what happens instead. No fork: a glob expansion, no external command at all.
_hp_sysfs_hugetlb_present() {
	local d="${BLOX_SYSFS_ROOT:-/sys}/kernel/mm/hugepages" e
	[[ -d $d ]] || return 1
	for e in "$d"/hugepages-*; do
		[[ -e $e ]] && return 0
	done
	return 1
}

# _hp_free_hugepages - HugePages_Free from /proc/meminfo (BLOX_PROCFS_ROOT overridable for tests). Empty/absent
# on any read failure - callers treat that exactly like any other missing precondition (never finalize).
# ROUND 5d: via _hp_kv_field, no fork (was `awk`).
_hp_free_hugepages() { _hp_kv_field HugePages_Free "${BLOX_PROCFS_ROOT:-/proc}/meminfo"; }

# _hp_hugepage_size_kb - Hugepagesize (kB) from /proc/meminfo (BLOX_PROCFS_ROOT overridable for tests). Round
# 5b: this is what /proc/sys/vm/nr_hugepages AND /proc/<pid>/smaps_rollup's Hugetlb fields are both denominated
# in - never hardcoded to 2048, even though that is every observed rig's actual value, since nothing forces it.
# ROUND 5d: via _hp_kv_field, no fork (was `awk`).
_hp_hugepage_size_kb() { _hp_kv_field Hugepagesize "${BLOX_PROCFS_ROOT:-/proc}/meminfo"; }

# _hp_xmrig_need_pages <owner pid> - KERNEL TRUTH of how many huge pages that ownership-verified xmrig process
# actually has mapped right now (Private_Hugetlb + Shared_Hugetlb from ITS OWN /proc/<pid>/smaps_rollup, never
# any other process's), in units of _hp_hugepage_size_kb. Prints nothing - caller treats that as "unreadable or
# incomplete", fails safe, never finalizes - unless both Hugetlb fields are present, numeric, a valid
# Hugepagesize was read, and the byte total divides evenly into whole pages.
# ROUND 5b: replaces trusting the xmrig HTTP API's own "hugepages":[allocated,total] for this number. Proven
# wrong live on cask18, 2026-09-29 (2c89cc4c/commit 12e9cfa): record prior=0/prelim=1200/free0=1200, API
# reported [1200,1200] (fully allocated), but live vm.nr_hugepages was really 1201 and Round 5's formula (using
# the API's total) called that an unexplained foreign conflict - when smaps_rollup showed Private_Hugetlb=
# 2459648 kB = exactly 1201 x 2048 kB, matching live exactly. Root cause: the API's total is built from
# HugePagesInfo, which only ever counts allocations that went through xmrig::VirtualMemory::reserve()-backed
# paths (VirtualMemory_unix.cpp:233-236/259, one per dataset/scratchpad) - but RandomX's JIT code buffer is
# allocated by a SEPARATE path, xmrig::VirtualMemory::allocateExecutableMemory (VirtualMemory_unix.cpp:142-176,
# called from crypto/randomx/jit_compiler_x86.cpp's JitCompilerX86 via crypto/randomx/virtual_memory.cpp:36-37)
# which on Linux (VirtualMemory_unix.cpp:165-171) mmaps MAP_HUGETLB directly, with NO LinuxMemory::reserve()
# call and NO HugePagesInfo bookkeeping - so it consumes a real huge page the kernel actually committed, yet is
# completely invisible to XMRig's own self-reported total. Reading /proc/<pid>/smaps_rollup instead asks the
# kernel what is ACTUALLY mapped, not what XMRig's own (incomplete) accounting claims - it cannot miss this or
# any other future untracked allocation the same way. The xmrig HTTP API's hugepages field is kept ONLY as a
# readiness signal (allocated==total, in finalize_rx_hugepages) - never again as the source of the "need" value.
# ROUND 5d: via _hp_kv_field (builtin `read`, no EXTERNAL process forked - was two `awk` calls, each its own
# exec'd process). The `$(...)` around each call still forks a plain bash subshell to capture its output, but
# that subshell is never exec'd into anything else and always inherits THIS process's pgid - always reachable
# by finalize_rx_hugepages_bounded's group-kill, unlike a separately exec'd `awk` would be. The one place this
# reads a /proc file a test can make deliberately slow (a FIFO) now blocks on a builtin `read` inside that
# subshell, never inside a further, harder-to-reach exec'd grandchild.
_hp_xmrig_need_pages() {
	local f="${BLOX_PROCFS_ROOT:-/proc}/$1/smaps_rollup" priv shared hpkb
	[[ -r $f ]] || return 0
	priv=$(_hp_kv_field Private_Hugetlb "$f")
	shared=$(_hp_kv_field Shared_Hugetlb "$f")
	[[ $priv =~ ^[0-9]+$ && $shared =~ ^[0-9]+$ ]] || return 0
	hpkb=$(_hp_hugepage_size_kb)
	[[ $hpkb =~ ^[0-9]+$ && $hpkb -gt 0 ]] || return 0
	(( (priv + shared) % hpkb == 0 )) || return 0   # not a whole number of pages - inconsistent, never guess
	echo $(( (priv + shared) / hpkb ))
}

# _hp_xmrig_2mb_need_pages <owner pid> - PR #2 follow-up review (Codex): like _hp_xmrig_need_pages above, but
# ISOLATES the standard-size (2 MB on every observed rig, via _hp_hugepage_size_kb - never hardcoded) huge-page
# portion of what that ownership-verified xmrig process actually has mapped, from its FULL /proc/<pid>/smaps -
# never smaps_rollup, which sums Private_Hugetlb/Shared_Hugetlb across EVERY page size a process maps, with no
# way to separate them again (exactly the limitation finalize_rx_hugepages's own 1gb-pages handling used to
# give up entirely over). Each VMA entry in the full smaps file carries its OWN KernelPageSize (2048 for a
# 2 MB-hugetlb-backed VMA, 1048576 for a 1 GB-hugetlb-backed one, 4 for an ordinary page) - only VMAs whose
# KernelPageSize equals the pool `hugepages -rx`/nr_hugepages actually manages are summed, so a RandomX dataset
# mapped via 1 GB pages (a DIFFERENT, independently-managed pool this package never touches) is correctly
# excluded, leaving only whatever this package's own 2 MB reservation is actually responsible for - typically
# just RandomX's own JIT code buffer in 1gb-pages mode (see _hp_xmrig_need_pages's own header comment: that
# buffer is allocated by a SEPARATE path from the main dataset and is not necessarily steered by 1gb-pages at
# all). Prints nothing on any read failure (missing/unreadable smaps, no readable Hugepagesize, not a whole
# number of pages) - the caller treats that exactly like _hp_xmrig_need_pages's own failure mode. Legitimately
# prints 0 when nothing was mapped through the 2 MB pool at all (e.g. the JIT buffer itself also landed in the
# 1 GB pool) - callers must NOT treat 0 as a failure here the way _hp_xmrig_need_pages's own callers do.
# ONE awk pass (no per-VMA fork) - smaps has many more lines than smaps_rollup, but still only one process's
# own VMAs (a handful for xmrig), never a system-wide scan.
_hp_xmrig_2mb_need_pages() {
	local f="${BLOX_PROCFS_ROOT:-/proc}/$1/smaps" hpkb sum
	[[ -r $f ]] || return 0
	hpkb=$(_hp_hugepage_size_kb)
	[[ $hpkb =~ ^[0-9]+$ && $hpkb -gt 0 ]] || return 0
	sum=$(awk -v want="$hpkb" '
		/^KernelPageSize:/ { ksize = $2 + 0 }
		/^Private_Hugetlb:/ { if (ksize == want) sum += $2 + 0 }
		/^Shared_Hugetlb:/  { if (ksize == want) sum += $2 + 0 }
		END { print sum + 0 }
	' "$f" 2>/dev/null)
	[[ $sum =~ ^[0-9]+$ ]] || return 0
	(( sum % hpkb == 0 )) || return 0   # not a whole number of pages - inconsistent, never guess
	echo $(( sum / hpkb ))
}

# _hp_rewrite <final> [ours] - atomically rewrites the record, keeping prior/prelim/free0/boot/start_uptime as
# they already are and setting only `final` (and `ours`, when given - only ever passed on a successful finalisation).
# tmp+mv, same atomicity convention as every other write in this file.
_hp_rewrite() {
	local prior prelim free0 boot start_uptime tmp
	prior=$(_hp_field prior); prelim=$(_hp_field prelim); free0=$(_hp_field free0); boot=$(_hp_field boot)
	start_uptime=$(_hp_field start_uptime)
	tmp="$HUGEPAGES_FILE.tmp.$$"
	{
		printf 'prior=%s\nprelim=%s\nfree0=%s\nboot=%s\nstart_uptime=%s\nfinal=%s\n' \
			"$prior" "$prelim" "$free0" "$boot" "$start_uptime" "$1"
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

# _hp_invalidate - removes the ownership record and PROVES it is actually gone, never just trusting `rm -f`'s
# own exit status (the same belt-and-braces standard restore_verus_hugepages already applies to ITS OWN writes:
# reading vm.nr_hugepages back after sysctl, never trusting sysctl's own exit status alone). Returns 0 only
# when $HUGEPAGES_FILE provably does not exist any more (including "it never existed in the first place");
# returns 1 otherwise. A full filesystem does NOT by itself block an unlink (that needs write+execute
# permission on the CONTAINING directory, not free space) - this exists for the case that genuinely can: an
# unwritable/read-only STATEDIR, or any other reason rm silently fails. See note_rx_hugepages_start's own call
# for why a stale record that cannot be removed must never simply be left in place.
_hp_invalidate() {
	rm -f "$HUGEPAGES_FILE" 2>/dev/null
	[[ -e $HUGEPAGES_FILE ]] && return 1
	return 0
}

# _hp_rollback_reservation <prior> <reason> - PR #2 follow-up review (Codex): "Fail the RandomX start when
# tracking cannot be persisted". note_rx_hugepages_start's own `hugepages -rx` call can succeed (genuinely
# reserving pages) even when this package then fails to record that fact (prelim/free0/start_uptime unreadable,
# or the record's own temp-write+rename fails) - without this helper, that used to just log a note and return
# 0: XMRig would then start on top of a real reservation with NO record at all, and since nothing tracks it,
# nothing can ever finalize or restore it - the ~2.4 GiB stays pinned until a reboot, silently, forever, not
# just until the write problem is fixed. Best-effort undoes that SAME reservation (sysctl back to <prior>,
# verified by readback - never trusting sysctl's own exit status alone, the same standard restore_
# verus_hugepages already applies to its own restore) and logs exactly which of the two outcomes happened -
# rolled back cleanly, or (sysctl itself failing, or a readback mismatch) still possibly holding pages with no
# record to ever release them, spelled out loudly rather than silently accepted. Every caller of this helper
# returns 1 immediately afterward regardless of which outcome logged: even a CLEAN rollback here does not make
# it safe to let rx proceed - engines/rx/h-run.sh would just reserve again, unconditionally, moments later
# (see note_rx_hugepages_start's own header on why that call can never be prevented from here), recreating the
# exact same untracked-reservation risk this helper exists to close. Refusing the whole rx start (the caller's
# own return 1, checked by bloxminer/h-run.sh exactly like a failed cpu_ok()) is what actually prevents that
# second, redundant reservation from ever happening.
_hp_rollback_reservation() {
	local prior=$1 reason=$2 proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages" verify=""
	if command -v sysctl > /dev/null 2>&1 && sysctl -q -w vm.nr_hugepages="$prior" 2>/dev/null; then
		[[ -r $proc ]] && verify=$(<"$proc") 2>/dev/null
		if [[ $verify == "$prior" ]]; then
			log_hugepages_note "BloxMiner: $reason - rolled back vm.nr_hugepages to $prior (verified) and refusing to start rx this time, rather than leave an untracked reservation with no way to ever release it"
			return 0
		fi
	fi
	log_hugepages_note "BloxMiner: $reason - could not roll back vm.nr_hugepages to $prior (sysctl failed, or did not read back correctly: now=${verify:-<unreadable>}) - refusing to start rx this time; a reservation MAY remain pinned with no record to release it until a reboot or a manual \`sysctl vm.nr_hugepages=$prior\`"
	return 1
}

# _hp_read_baseline <proc file> - reads the PRE-RESERVATION vm.nr_hugepages baseline, before note_rx_hugepages_
# start ever calls `hugepages -rx`. PR #2 follow-up review (Codex): "Reject RandomX starts when the baseline is
# unreadable" - three outcomes, deliberately kept distinct rather than collapsed into one:
#   0, $REPLY=<N> - a valid baseline was read; proceed normally.
#   1             - the file does NOT EXIST AT ALL (`! -e`): no hugetlbfs support on this host, so NO ONE - not
#                   this package, not engines/rx/h-run.sh's own unconditional `hugepages -rx` moments later -
#                   can reserve anything here either. There is nothing to track because there is nothing to
#                   leak; the caller must let rx start anyway (untracked, but mining correctly, just without
#                   this package's extra reservation on top) rather than refuse a host that was never at risk
#                   in the first place - refusing here would be a real functional regression, not a safety
#                   improvement, on any host without hugetlbfs (some minimal/embedded kernels, some containers).
#   2             - the file EXISTS but is unreadable, or its content is not a plain non-negative integer:
#                   hugetlbfs IS present, so engines/rx/h-run.sh's own unconditional `hugepages -rx` call
#                   moments later WILL genuinely reserve real pages, with no baseline on record to ever restore
#                   to - the caller must refuse the whole rx start (nothing has been reserved yet at this point,
#                   so this needs no rollback, only _hp_rollback_reservation's own post-reservation checks do).
_hp_read_baseline() {
	local f=$1
	[[ -e $f ]] || return 1
	REPLY=""
	[[ -r $f ]] && REPLY=$(<"$f") 2>/dev/null
	[[ $REPLY =~ ^[0-9]+$ ]] || return 2
	return 0
}

# note_rx_hugepages_start - called just before exec'ing the rx engine. EVERY call means a genuinely NEW XMRig
# process is about to start: h-run.sh's own final action is always an unconditional `exec ./xmrig` (this file's
# own header), so Hive calling it again - a flight-sheet edit, a watchdog restart after a hang, the API being
# unreachable past the ownership window, anything - always means the PREVIOUS xmrig instance (if any) is gone
# and a fresh one is about to take its place. There is no scenario where "the same process is still running
# and this is a no-op call" - so the session-specific fields (prelim/free0/boot/start_uptime) are ALWAYS
# refreshed for whatever is about to start, on every call, regardless of what an existing record's own `final`
# says. The only real question a pre-existing record raises is what "prior" - the TRUE pre-rx baseline this
# whole mechanism exists to protect - should be for THIS new session.
#
# PR #2 follow-up review (Codex), four rounds:
#
# (round 1) An existing record that is still final=0 used to be left COMPLETELY untouched (a "still starting,
# never touch it" guard) - wrong: if the API never became reachable within HUGEPAGES_STARTUP_WINDOW_S (5 min)
# and Hive restarts the miner, the OLD record's own start_uptime is now stale by more than that window, so the
# NEW (perfectly healthy) instance's own finalize_rx_hugepages would immediately see the window as already
# exceeded and mark "conflict" - a terminal state - even though nothing is actually wrong. Fixed: final=0 no
# longer means "never touch it" - it means "the session fields need refreshing for the NEW process", exactly
# like final=1/conflict/corrupt below.
#
# (round 2) An existing record - whatever its `final` - used to always have its own "prior" blindly preserved,
# on the theory that it must be the TRUE original baseline. Not necessarily true: an operator (or another
# workload) could have changed vm.nr_hugepages since this package's own last write, or the record could be
# from a DIFFERENT boot entirely (STATEDIR need not be tmpfs) - in either case the OLD "prior" describes a
# baseline that may no longer be the right one to restore to, and blindly keeping it would have Verus restore
# OVER whatever that operator/other-boot value actually was. Fixed: the old record's own "prior" is only ever
# preserved when it is PROVABLY still this package's own, undisturbed reservation - the exact same proof
# standard restore_verus_hugepages already uses for ITS OWN restore, just checked one step earlier and against
# whichever value THIS record's own `final` state makes the right one to check: same boot_id AND (final=1:
# current live value == the record's own "ours"; final=0 (round 2): current live value == the record's own
# "prelim"). Anything else - a different boot, current not matching, or final is "conflict"/corrupt/legacy
# with nothing trustworthy to check - means the old record can no longer positively vouch for its own "prior":
# the CURRENT live value is taken as the new "prior" instead (the same as a genuinely first-ever note), which
# is the safer of the two options named in the review (silently keeping a stale baseline vs. rebasing to what
# is actually on the box right now) and is exactly what happens anyway when there was no record at all.
#
# (round 3) Round 2's final=0 check (current == prelim, exactly) was ITSELF too strict: XMRig's own huge-page
# allocation, on top of whatever `hugepages -rx` already reserved, normally raises vm.nr_hugepages further
# during its own startup, still well inside HUGEPAGES_STARTUP_WINDOW_S - i.e. this is documented, expected,
# in-policy behaviour for a session that is still exclusively ours, not tampering. A restart landing between
# that raise and the first finalize_rx_hugepages poll (current == prelim + XMRig's own delta, same boot) was
# being misread as "not provably owned" and rebasing "prior" to the already-raised value - the exact bug this
# whole mechanism exists to prevent, just one step earlier. Fixed: for a final=0 record, same boot AND
# `current >= prelim` counts as owned (current can only be >= prelim from this package's own reservation
# growing during startup; it is never expected to shrink on its own). The final=1 rule is unchanged (exact
# `current == ours`, since by then XMRig's own allocation is done and finalize_rx_hugepages has already
# recorded the settled value) - only rebase, for either state, when boot differs or current is LOWER than
# what this package itself is known to have reserved.
#
# (round 4) Round 3's `current >= prelim` relaxation for a final=0 record is only actually consistent with the
# policy that justifies it while the OLD record's own session is STILL inside its own exclusive-ownership
# startup window - finalize_rx_hugepages itself would already have marked an EXPIRED one "conflict" on its
# very next poll, had one ever happened (see HUGEPAGES_STARTUP_WINDOW_S above). Once expired, nothing this
# package still controls can explain a further raise: an operator could just as easily have raised
# vm.nr_hugepages in the meantime, and the relaxed `>=` would wrongly vouch for THAT as if it were XMRig's own
# startup, letting a later Verus restore land on a value from before the operator's own change. Fixed: the
# relaxation only applies when same boot AND `now_uptime - start_uptime <= HUGEPAGES_STARTUP_WINDOW_S` (the
# record's own session is still, provably, within the window it was ever granted); an expired final=0 record
# falls back to exact equality (current == prelim) - the same standard a settled final=1 record already uses.
#
# Either way: after "prior" is settled, this runs Hive's `hugepages -rx` if present (see the top comment for
# why), then reads vm.nr_hugepages ("prelim") and HugePages_Free ("free0") again, plus the current boot_id and
# (Round 5c) /proc/uptime ("start_uptime" - the exclusive-ownership window's own clock, see the top-of-section
# comment) - all freshly, for the process that is about to start.
# No record is written at all if "prior"/"prelim"/"free0"/"start_uptime" cannot each be read as a known-good
# number (the OLD record, if any, is simply left as it was, never partially overwritten) - finalize_rx_hugepages
# (h-stats.sh) needs every one of them to compute XMRig's own predicted total and to bound the window, and
# writing a record with any of them missing would let those checks never fire safely, so this function simply
# never produces that record in the first place. `final=0` marks it not yet finalized; `ours` is deliberately
# NOT written here any more (Round 5 - see the top-of-section comment for why "the value right after
# `hugepages -rx`" was wrong) - it is only ever written by finalize_rx_hugepages, once XMRig's own reported
# numbers confirm what it is.
note_rx_hugepages_start() {
	local proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages" prior prelim free0 boot start_uptime tmp rc

	# PR #2 follow-up review (Codex): "Handle absent huge-page support before requiring boot ID" - checked
	# FIRST, before the boot_id requirement just below (and before anything else): if vm.nr_hugepages does not
	# exist AT ALL, no one - not this package, not engines/rx/h-run.sh's own unconditional `hugepages -rx` call
	# moments later - can reserve or track anything on this host (a minimal kernel, or a restricted container,
	# with no hugetlbfs). boot_id's own validity is irrelevant to a host like this - there is nothing it would
	# ever need to be matched against - so requiring it here, before this check, wrongly refused rx on exactly
	# such a host whenever boot_id ALSO happened to be unreadable (both are plausible together on the same
	# minimal/restricted environment): a pure functional regression, never a safety improvement, on a host that
	# was never at risk in the first place. _hp_read_baseline's own OTHER two call sites, further down, already
	# make this exact distinction for the SAME file read at a different moment (after an existing record's own
	# ownership is decided) - this is the same policy, just also applied before boot_id, which did not exist as
	# a concept the first time that distinction was added.
	#
	# PR #2 follow-up review (Codex), next round: "Verify sysfs before allowing an untracked start" - an absent
	# $proc does NOT, by itself, prove "no one can reserve anything here" the way the paragraph above assumed:
	# in a restricted container, the /proc alias can be masked out while the REAL hugetlb sysfs controls
	# underneath it stay fully live, and XMRig writes those directly (see _hp_sysfs_hugetlb_present's own
	# header for the exact xmrig-src trace). A host like that is not "no hugetlbfs support" at all - it is
	# "hugetlbfs present, but unreachable through the one path this package reads" - so it must NOT take the
	# untracked-but-safe fallback: that would silently let a REAL reservation happen with nothing tracking it,
	# exactly the risk this whole mechanism exists to close. Only when the sysfs interface is ALSO absent is a
	# reservation genuinely impossible for anyone, anywhere on this host - the one case safe to let through.
	if [[ ! -e $proc ]]; then
		if _hp_sysfs_hugetlb_present; then
			log_hugepages_note "BloxMiner: $proc does not exist, but the kernel's hugetlb sysfs interface (${BLOX_SYSFS_ROOT:-/sys}/kernel/mm/hugepages) does - a reservation IS still possible here (XMRig can write that directly), just not through a path this package can track or restore; refusing to start rx rather than leave an untracked, unrestorable reservation"
			return 1
		fi
		log_hugepages_note "BloxMiner: $proc does not exist (no hugetlbfs support on this host - checked both /proc and the kernel's own sysfs interface) - huge-page tracking is not possible here; letting rx start anyway, without it"
		return 0
	fi

	# PR #2 follow-up review (Codex): "Require a boot ID before accepting the reservation" - read and validate
	# ONCE, before anything else (including the existing-record ownership check just below, which also needs
	# it): both finalize_rx_hugepages and restore_verus_hugepages require a non-empty, EXACT boot_id match
	# before they will ever act on a record - a record persisted with boot= (empty) would be permanently stuck
	# at final=0, its reservation pinned until reboot, with NOTHING in this file's own log to explain why (the
	# record WRITE itself never used to fail on this - a genuinely silent gap, worse than the prelim/free0/
	# start_uptime checks further down, which at least always log on failure). boot_id is a per-boot constant
	# (set once by the kernel at boot, from this exact file) - reading it once here and reusing the SAME value
	# throughout (the ownership check below, and the record write further down) is not just cheaper than the
	# two separate reads this used to be, it is what closes the gap: there is only one place left that could
	# ever disagree with itself. Checked here, before `hugepages -rx` ever runs, so a failure needs no rollback
	# at all - nothing has been reserved yet. By this point vm.nr_hugepages is already known to EXIST (checked
	# above), so a RandomX reservation really is possible on this host, and boot_id really is needed for it.
	boot=$(_hp_boot_id)
	if [[ -z $boot ]]; then
		log_hugepages_note "BloxMiner: could not read ${BLOX_PROCFS_ROOT:-/proc}/sys/kernel/random/boot_id (unreadable or empty) - refusing to start rx rather than persist a record that could never be finalized or restored"
		return 1
	fi

	if [[ -e $HUGEPAGES_FILE ]]; then
		local rec_final rec_boot rec_prior cur="" owned=0
		rec_final=$(_hp_field final); rec_boot=$(_hp_field boot); rec_prior=$(_hp_field prior)
		[[ -r $proc ]] && cur=$(<"$proc") 2>/dev/null
		if [[ -n $rec_boot && $rec_boot == "$boot" && $cur =~ ^[0-9]+$ ]]; then
			if [[ $rec_final == 1 ]]; then
				local rec_ours; rec_ours=$(_hp_field ours)
				[[ $rec_ours =~ ^[0-9]+$ && $cur == "$rec_ours" ]] && owned=1
			elif [[ $rec_final == 0 ]]; then
				local rec_prelim rec_start_uptime now_uptime in_window=0
				rec_prelim=$(_hp_field prelim); rec_start_uptime=$(_hp_field start_uptime)
				now_uptime=$(_hp_uptime_seconds)
				# Round 5g (Codex): a plain equality check here was too strict. XMRig's OWN huge-page
				# allocation, on top of whatever `hugepages -rx` already reserved, only ever RAISES
				# vm.nr_hugepages further during its own normal startup - never lowers it - and that startup
				# is still inside the documented exclusive-ownership window (HUGEPAGES_STARTUP_WINDOW_S) this
				# final=0 state represents in the first place. A restart between that raise and the first
				# finalize_rx_hugepages poll (current == prelim+delta, same boot) is therefore still THIS
				# package's own, undisturbed session - not evidence of tampering - so `current >= prelim` is
				# accepted as owned, consistent with the policy the window already grants. Only `current <
				# prelim` (something took pages away since - an operator, a different reservation, anything
				# that could not have come from XMRig's own startup raising the count) fails to vouch for it.
				#
				# Round 6 (Codex): that relaxation is only actually consistent with the policy while the OLD
				# record's own session is STILL inside its startup window - finalize_rx_hugepages itself would
				# already have marked an expired one "conflict" on its very next poll, had one happened (see
				# the window check above). Once expired, nothing this package still controls can explain a
				# further raise: an operator could just as easily have raised vm.nr_hugepages in the meantime,
				# and the relaxed `>=` would wrongly vouch for THAT as if it were XMRig's own startup, letting
				# Verus later restore a value from before the operator's own change. So the relaxation applies
				# only when same boot AND `now_uptime - start_uptime <= HUGEPAGES_STARTUP_WINDOW_S`; an expired
				# final=0 record falls back to exact equality (current == prelim), same standard as a settled
				# final=1 record.
				if [[ $rec_start_uptime =~ ^[0-9]+$ && $now_uptime =~ ^[0-9]+$ ]] \
					&& (( now_uptime - rec_start_uptime <= HUGEPAGES_STARTUP_WINDOW_S )); then
					in_window=1
				fi
				if [[ $rec_prelim =~ ^[0-9]+$ ]]; then
					if (( in_window )); then
						(( cur >= rec_prelim )) && owned=1
					else
						[[ $cur == "$rec_prelim" ]] && owned=1
					fi
				fi
			fi   # "conflict", or anything else unrecognised (corrupt/legacy, no final= at all): never provably
			     # owned - always rebase below, nothing here is trustworthy enough to check against
		fi
		if (( owned )) && [[ $rec_prior =~ ^[0-9]+$ ]]; then
			prior=$rec_prior   # still provably this package's own, undisturbed reservation - preserve the
				# TRUE original baseline rather than re-deriving it from the current (already-raised) value
		else
			# PR #2 follow-up review (Codex): "Invalidate stale ownership before attempting refresh" - the
			# record still on disk right now describes a session this package can no longer positively vouch
			# for (a different boot, an operator/foreign change, an expired window, or a corrupt/legacy
			# record) and is about to be superseded by a brand-new one below. Between now and that new write,
			# the OLD record must never be left sitting there for a LATER call to still trust: it is removed
			# FIRST, with removal PROVEN (never trusting `rm`'s own exit status alone - see _hp_invalidate),
			# closing exactly the gap Codex's counterexample used - a failed refresh write further down (a
			# full/unwritable STATEDIR) leaving the OLD, already-superseded record in place, still final=1
			# with some OLD prior/ours, for finalize_rx_hugepages to skip (final is not 0) and
			# restore_verus_hugepages to later wrongly trust IF this new session's own `hugepages -rx`
			# reservation happens to land on the exact value the old record's own "ours" recorded - plausible,
			# since that reservation is a near-deterministic function of NUMA/CPU topology, not a fresh random
			# number each time - restoring the OLD "prior" over whatever baseline (an operator's own change,
			# or simply "no session was ever attempted") is actually correct right now.
			#
			# If the stale record cannot be removed (STATEDIR unwritable - a full filesystem does not by
			# itself block an unlink, which needs directory write permission, not free space), this function
			# signals failure (return 1, checked by the caller - see below) instead of proceeding - the
			# simpler and safer of the two options Codex named. Proceeding anyway would NOT actually leave
			# vm.nr_hugepages untouched the way it might look from here alone: engines/rx/h-run.sh runs its
			# OWN, entirely unconditional `hugepages -rx` call right before exec'ing XMRig, regardless of
			# anything this function decides - so "abort before reserving" only means anything if the CALLER
			# (bloxminer/h-run.sh) also never reaches that exec at all once this returns failure, exactly like
			# it already refuses to reach it on a failed cpu_ok() check just above this call. That is the
			# actual mechanism that keeps vm.nr_hugepages untouched and the stale record's own numbers
			# (whatever they still say) describing a value that stays not-live - the same mismatch that
			# already makes restore_verus_hugepages refuse safely on its own next check, with nothing new to
			# get wrong. The cost is this rx session refusing to start at all until the write problem is fixed
			# (a real cost, but the alternative - proceeding while a stale, coincidence-prone record sits
			# there unneutralised - is exactly the bug this whole fix exists to close).
			_hp_invalidate || {
				log_hugepages_note "BloxMiner: existing huge-page ownership record is stale (not provably this package's own current session) but could not be removed ($HUGEPAGES_FILE unwritable?) - refusing to start rx this time rather than risk a later Verus restore trusting it; vm.nr_hugepages left untouched, record left as-is"
				return 1
			}
			# not provably ours any more - rebase to whatever is on the box right now, exactly like a genuinely
			# first-ever note (see the header comment for why this is the safer of the two options, not "decline
			# ownership") - see _hp_read_baseline's own header for the absent-vs-unreadable distinction below.
			_hp_read_baseline "$proc"; rc=$?
			if (( rc == 1 )); then
				log_hugepages_note "BloxMiner: $proc does not exist (no hugetlbfs support on this host?) - huge-page tracking is not possible here; letting rx start anyway, without it"
				return 0
			elif (( rc != 0 )); then
				log_hugepages_note "BloxMiner: $proc exists but could not be read as a plain number before reserving for rx - refusing to start rather than risk an untracked reservation"
				return 1
			fi
			prior=$REPLY
		fi
	else
		_hp_read_baseline "$proc"; rc=$?
		if (( rc == 1 )); then
			log_hugepages_note "BloxMiner: $proc does not exist (no hugetlbfs support on this host?) - huge-page tracking is not possible here; letting rx start anyway, without it"
			return 0
		elif (( rc != 0 )); then
			log_hugepages_note "BloxMiner: $proc exists but could not be read as a plain number before reserving for rx - refusing to start rather than risk an untracked reservation"
			return 1
		fi
		prior=$REPLY
	fi
	{ command -v hugepages > /dev/null 2>&1 && hugepages -rx; } > /dev/null 2>&1
	prelim=""
	[[ -r $proc ]] && prelim=$(<"$proc") 2>/dev/null
	if [[ ! $prelim =~ ^[0-9]+$ ]]; then
		# PR #2 follow-up review (Codex): "Fail the RandomX start when tracking cannot be persisted" - this
		# `hugepages -rx` call above may well have just reserved real pages; giving up here with a bare "no
		# record written" (as this used to) would let XMRig start on top of that reservation anyway, with
		# NOTHING left to ever finalize or restore it - see _hp_rollback_reservation's own header. Roll back
		# and refuse this rx start entirely instead.
		_hp_rollback_reservation "$prior" "could not read vm.nr_hugepages after reserving for rx ($proc unreadable/invalid)"
		return 1
	fi
	free0=$(_hp_free_hugepages)
	if [[ ! $free0 =~ ^[0-9]+$ ]]; then
		_hp_rollback_reservation "$prior" "could not read HugePages_Free after reserving for rx (/proc/meminfo unreadable/invalid)"
		return 1
	fi
	# ROUND 5c: start_uptime anchors the exclusive-ownership window's own bound (HUGEPAGES_STARTUP_WINDOW_S) -
	# same all-or-nothing treatment as prior/prelim/free0: no record at all if it cannot be read, rather than a
	# record finalize_rx_hugepages could never safely bound.
	start_uptime=$(_hp_uptime_seconds)
	if [[ ! $start_uptime =~ ^[0-9]+$ ]]; then
		_hp_rollback_reservation "$prior" "could not read /proc/uptime after reserving for rx"
		return 1
	fi
	# $boot was already read and validated once, at function entry, before this session's own reservation ever
	# happened - a per-boot constant, so the SAME value is still correct here; re-reading it a second time would
	# only reintroduce the exact two-separate-reads gap this round's review closed (see the top of this function).
	tmp="$HUGEPAGES_FILE.tmp.$$"
	if { printf 'prior=%s\nprelim=%s\nfree0=%s\nboot=%s\nstart_uptime=%s\nfinal=0\n' \
		"$prior" "$prelim" "$free0" "$boot" "$start_uptime" > "$tmp"; } 2>/dev/null \
		&& mv -f "$tmp" "$HUGEPAGES_FILE" 2>/dev/null
	then
		return 0
	fi
	# Same class as the three checks just above: the reservation already happened (prelim/free0/start_uptime
	# were all read successfully - only persisting the record itself failed, e.g. a full/unwritable STATEDIR)
	# - roll back and refuse, never let XMRig start on an untracked reservation.
	_hp_rollback_reservation "$prior" "reserved for rx (prelim=$prelim) but could not persist the ownership record ($HUGEPAGES_FILE unwritable?)"
	return 1
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
	# PR #2 follow-up review round 2 (Codex): `[[ -n $sum ]] &&` first - same rationale as engine_from_config()
	# above and engines/rx/h-stats.sh's valid_summary()/valid_backends() (jq 1.6's `-e` exits 0 on EMPTY input).
	# An empty $sum (API not ready yet, or the 0.5 s curl timeout hit) used to pass this check on jq 1.6 instead
	# of retrying next poll - the hp_allocated/hp_total regex checks just below happened to still catch it
	# safely (jq on empty input produces empty output either way, without -e), but only by accident.
	{ [[ -n $sum ]] && jq -e 'type == "object"' > /dev/null 2>&1 <<< "$sum"; } || return 0

	# ---- readiness ONLY (Round 5b: no longer the source of the "need" value used below - see
	# _hp_xmrig_need_pages's comment for why the API's own total undercounts by the RandomX JIT buffer).
	# allocated==total is still a useful proxy for "XMRig's own allocator has stopped moving" before trusting a
	# kernel snapshot of what it actually mapped.
	local hp_allocated hp_total
	hp_allocated=$(jq -r '(.hugepages[0]) // empty' <<< "$sum" 2>/dev/null)
	hp_total=$(jq -r '(.hugepages[1]) // empty' <<< "$sum" 2>/dev/null)
	[[ $hp_allocated =~ ^[0-9]+$ && $hp_total =~ ^[0-9]+$ && $hp_total -gt 0 ]] || return 0
	(( hp_allocated == hp_total )) || return 0   # dataset/scratchpads still being allocated - retry next poll

	# ---- PR #2 follow-up review (Codex): "Restore the 2 MB reservation in 1 GB mode" - 1gb-pages used to mean
	# giving up on this whole session outright (permanent "conflict", record kept forever, 2 MB pages pinned
	# until reboot). But the dispatcher's own `hugepages -rx` call ALWAYS reserves the 2 MB pool regardless of
	# this setting - Hive's helper does not know or care about XMRig's own, entirely separate 1 GB pool - so
	# that 2 MB reservation still deserves the exact same tracking/restore this package already gives the
	# non-1gb-pages case; only the MEASUREMENT needs to change, to isolate the 2 MB-only portion of what XMRig
	# actually mapped (see _hp_xmrig_2mb_need_pages's own header for how). 1 GB pages themselves stay entirely
	# user-managed, exactly as documented in README.md's "Huge pages" section - none of this package's own
	# arithmetic below ever concerns anything but the 2 MB pool `hugepages -rx`/nr_hugepages manages.
	local onegb=0
	[[ $(jq -r '(.randomx["1gb-pages"] // false)' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null) == true ]] && onegb=1

	local prior prelim free0 start_uptime
	prior=$(_hp_field prior); prelim=$(_hp_field prelim); free0=$(_hp_field free0); start_uptime=$(_hp_field start_uptime)
	[[ $prior =~ ^[0-9]+$ && $prelim =~ ^[0-9]+$ && $free0 =~ ^[0-9]+$ && $start_uptime =~ ^[0-9]+$ ]] || return 0
		# corrupt or legacy (pre-Round-5c, no start_uptime at all) record - never finalize, silent (same class of
		# problem as any other missing field, not the distinct "window exceeded" outcome checked next)

	# ---- Round 5c: the exclusive-ownership window's own bound (README.md's "Huge pages" section, Codex's
	# counterexample: prelim==free0 means a foreign write landing at the exact moment XMRig would have raised
	# nr_hugepages anyway is indistinguishable from XMRig's own write by value alone - this policy is what makes
	# adopting it supported, and only for a bounded time after the dispatcher's own `hugepages -rx` call).
	# Checked here (readiness otherwise fully proven) rather than earlier: "outside the window" is a distinct,
	# logged-once outcome, not a silent retry - proven readiness that arrives too late is meaningfully different
	# from "not ready yet".
	local now_uptime; now_uptime=$(_hp_uptime_seconds)
	if [[ ! $now_uptime =~ ^[0-9]+$ ]]; then return 0; fi   # can't measure the window right now - retry next poll
	if (( now_uptime - start_uptime > HUGEPAGES_STARTUP_WINDOW_S )); then
		log_hugepages_note "BloxMiner: rx's exclusive huge-page ownership window (${HUGEPAGES_STARTUP_WINDOW_S}s from the dispatcher's own \`hugepages -rx\` call) passed before readiness was confirmed - never finalizing this rx session, ownership record kept"
		# PR #2 follow-up review (Codex) audit: unlike note_rx_hugepages_start's own stale-record case (see
		# _hp_invalidate), a failed _hp_rewrite here leaves the record exactly as it already was - still
		# final=0, still describing THIS same session's own prior/prelim/free0/boot/start_uptime, none of
		# which change under a "conflict"/finalize write. restore_verus_hugepages requires final==1 exactly,
		# so this can never be wrongly trusted for a restore; the only cost of a persistently failing write
		# is this check simply repeating every poll (logged once already, above) rather than settling into
		# the terminal "conflict" state - logged here too, for operator visibility, never a behaviour change.
		_hp_rewrite conflict || log_hugepages_note "BloxMiner: could not persist the 'conflict' huge-page ownership record ($HUGEPAGES_FILE unwritable?) - stays final=0, this check will simply repeat next poll"
		return 0
	fi

	# ---- Round 5b: KERNEL TRUTH of what this exact, ownership-verified xmrig process actually has mapped -
	# never a foreign pid's smaps_rollup/smaps (owner_pid was already positively confirmed above), never the
	# API's own (incomplete) self-report. Missing/unreadable/incomplete -> fail safe, log once, never finalize.
	# In 1gb-pages mode, the 2 MB-only measurement legitimately CAN be 0 (e.g. the JIT buffer itself also
	# landed in the 1 GB pool) - only an outright read failure is an error there, unlike the normal case.
	local need_pages
	if (( onegb )); then
		need_pages=$(_hp_xmrig_2mb_need_pages "$owner_pid")
		if [[ ! $need_pages =~ ^[0-9]+$ ]]; then
			log_hugepages_note "BloxMiner: 1gb-pages is enabled and could not read a complete 2 MB-only huge-page mapping from /proc/$owner_pid/smaps (KernelPageSize/Private_Hugetlb/Shared_Hugetlb/Hugepagesize missing, unreadable, or not a whole number of pages) - never finalizing this rx session, record kept"
			_hp_rewrite conflict || log_hugepages_note "BloxMiner: could not persist the 'conflict' huge-page ownership record ($HUGEPAGES_FILE unwritable?) - stays final=0, this check will simply repeat next poll"
			return 0
		fi
	else
		need_pages=$(_hp_xmrig_need_pages "$owner_pid")
		if [[ ! $need_pages =~ ^[0-9]+$ || $need_pages -le 0 ]]; then
			log_hugepages_note "BloxMiner: could not read a complete huge-page mapping from /proc/$owner_pid/smaps_rollup (Private_Hugetlb/Shared_Hugetlb/Hugepagesize missing, unreadable, or not a whole number of pages) - never finalizing this rx session, record kept"
			_hp_rewrite conflict || log_hugepages_note "BloxMiner: could not persist the 'conflict' huge-page ownership record ($HUGEPAGES_FILE unwritable?) - stays final=0, this check will simply repeat next poll"
			return 0
		fi
	fi

	local proc="${BLOX_PROCFS_ROOT:-/proc}/sys/vm/nr_hugepages" cur
	cur=""; [[ -r $proc ]] && cur=$(<"$proc") 2>/dev/null
	[[ $cur =~ ^[0-9]+$ ]] || return 0

	local short=$(( need_pages - free0 )); (( short < 0 )) && short=0
	local predicted=$(( prelim + short ))

	if [[ $cur != "$predicted" ]]; then
		local need_src="/proc/$owner_pid/smaps_rollup"; (( onegb )) && need_src="/proc/$owner_pid/smaps, 2 MB-only"
		log_hugepages_note "BloxMiner: vm.nr_hugepages ($cur) does not match XMRig's own predicted reservation (prelim $prelim + max(0, need $need_pages - free0 $free0) = $predicted, need from $need_src) once the dataset finished allocating - something else changed it during the startup window; never finalizing this rx session, record kept"
		_hp_rewrite conflict || log_hugepages_note "BloxMiner: could not persist the 'conflict' huge-page ownership record ($HUGEPAGES_FILE unwritable?) - stays final=0, this check will simply repeat next poll"
		return 0
	fi

	# everything XMRig itself raised, positively confirmed via its own kernel-mapped huge pages, nothing
	# foreign involved. A failed write here (PR #2 follow-up review audit) leaves the record exactly as it
	# already was - still final=0, still this same session's own fields - never a stale record from some
	# OTHER session (that class of risk is note_rx_hugepages_start's own, closed by _hp_invalidate above);
	# the only cost is this session simply never finalizing (safe: restore_verus_hugepages requires final==1
	# exactly) and this check retrying every poll until it either succeeds or the startup window expires.
	_hp_rewrite 1 "$cur" || log_hugepages_note "BloxMiner: huge-page reservation confirmed (ours=$cur) but the finalized record could not be persisted ($HUGEPAGES_FILE unwritable?) - stays final=0, finalization will simply be re-attempted next poll"
}

# _hp_bounded_still_running <cpid> <verified pgid, or empty> - true if anything remains: the WHOLE verified
# group, or else just <cpid> alone when no group was ever confirmed. Shared by finalize_rx_hugepages_bounded's
# own timeout/escalation logic below. PR #2 follow-up review (Codex): must be FORK-FREE - this used to run
# `pgrep -g` on every poll-loop iteration below; under full CPU saturation, fork/exec latency for an external
# process is exactly what can go unscheduled past the poll's own absolute deadline (see both engines' own
# h-stats.sh, same review, same underlying bug - real load-test evidence there: 3.5-4.0 s iterations against a
# 2.4 s budget). `kill -0` against a negative pid (the whole process group) is bash's own BUILTIN kill - not
# the external /bin/kill - and answers the identical question with no fork at all.
_hp_bounded_still_running() { if [[ -n ${2:-} ]]; then kill -0 -- "-$2" 2>/dev/null; else kill -0 "$1" 2>/dev/null; fi; }

# _hp_bounded_escalate <signal> <cpid> <verified pgid, or empty> - signals the WHOLE verified group when one
# was confirmed (reaching every descendant: curl, find, and any subshell finalize_rx_hugepages forks - see
# finalize_rx_hugepages_bounded), else just <cpid> alone - NEVER a guessed/unconfirmed group, and never the
# caller's own group (finalize_rx_hugepages_bounded only ever passes a pgid that already failed unless it
# differs from the caller's own).
_hp_bounded_escalate() { if [[ -n ${3:-} ]]; then kill -"$1" -- "-$3" 2>/dev/null; else kill -"$1" "$2" 2>/dev/null; fi; }

# _hp_wait <fd> <seconds, may be fractional e.g. "0.05"> - blocks for approximately that long, WITHOUT forking
# (was `sleep`, an external process). PR #2 follow-up review (Codex): "Compare the deadline without launching
# another process" named this loop's own `sleep 0.05` alongside its awk-based deadline check - under full CPU
# saturation, the fork/exec latency of starting a NEW `sleep` process every single iteration is exactly the
# kind of scheduling delay that can let the loop overshoot its own absolute deadline (the same class of bug
# already fixed for every OTHER external process this file's own poll/escalation logic used to fork - see
# _hp_bounded_still_running/_hp_bounded_escalate's own history). `read -t` against a private fd the caller
# opened ONCE via `{ exec {fd}<> <(:); } 2>/dev/null` (a process substitution of `:`, which exits immediately - but held open
# read-WRITE on OUR end of that pipe, so the reader side never sees EOF) always times out after almost exactly
# <seconds>: a plain builtin `read`, no external process launched per call, and no data is ever actually
# transferred (nothing ever writes to it). <fd> < 0 (the one-time `{ exec {fd}<> <(:); } 2>/dev/null` itself failed - not
# expected in practice, but never assumed away) falls back to the external `sleep`, exactly the prior
# behaviour, rather than a tight busy-loop that would itself burn the CPU budget this exists to protect.
_hp_wait() {
	local fd=$1 secs=$2
	if (( fd >= 0 )); then
		read -r -t "$secs" -u "$fd" _ 2>/dev/null
	else
		sleep "$secs" 2>/dev/null
	fi
	true
}

# finalize_rx_hugepages_bounded <absolute deadline, integer microseconds since epoch - the SAME DEADLINE_US
# convention both engines' own h-stats.sh already use, never the "EPOCHREALTIME-style seconds.fraction" float
# this parameter used to be (PR #2 follow-up review, Codex - see ROUND 5f below)> - the ONLY way the
# top-level h-stats.sh ever calls finalize_rx_hugepages. ROUND 5c (Codex): finalize_rx_hugepages itself has no
# deadline of its own - it runs AFTER the rx engine's own h-stats.sh, which already spends up to its own
# ~2.4-2.7 s budget under load in the common case (already finalized, or no huge-page record at all), or
# ~1.95-2.25 s while a record exists and is still unfinalized - the dispatcher's own h-stats.sh deliberately
# gives rx a smaller share than verus's 2.4 s for exactly those first few polls, so this function is guaranteed
# a real slice to do its one-time verification work, without costing every later poll's per-core enrichment
# headroom once it succeeds (see there for the full rationale and this round's own repro). Either way, without
# a bound here finalize's own work (a /proc/net/tcp scan, a curl call, a /proc/<pid>/smaps_rollup read) could
# push the WHOLE poll past whatever deadline Hive's watchdog enforces.
# <deadline> is an ABSOLUTE point in time (h-stats.sh's own start time + its total poll budget, computed ONCE
# at h-stats.sh's own entry - see there) - ROUND 5e (Codex) changed this from a "seconds remaining" SNAPSHOT to
# an absolute deadline specifically because a snapshot goes stale the moment ANY time passes after it was
# computed (Round 5c's own bug, below); an absolute deadline never does - "how long is left" is always
# `deadline - now`, recomputed fresh at the moment it is actually needed, never reused from an earlier instant.
# ROUND 5d (Codex): Round 5c's own `kill -TERM "$cpid"` only ever signalled the TOP-LEVEL backgrounded job, not
# any of ITS OWN descendants (a subshell from a `$(...)` command substitution, curl, find, ...) - a genuinely
# hung step (proven live by this file's own FIFO test) left an ORPHANED grandchild behind every time, and
# repeated timeouts could accumulate them indefinitely. Fixed with a VERIFIED process group instead of a bare
# pid: `set -m` (monitor mode) makes bash itself put the VERY NEXT backgrounded job into its OWN NEW process
# group (pgid == that job's own pid) as part of the SAME fork() bash performs to launch it - synchronous with
# the fork, not something the child has to arrange for itself moments later (unlike `setsid`, which needs a
# fresh exec'd command and would lose every shell function/variable finalize_rx_hugepages needs, forcing an
# export -f/export of all of them - engines/rx/h-stats.sh's own collector uses `setsid bash -c '...'` for
# exactly that reason, since it never needs to call back into shell functions). Every later fork this job makes
# (a curl process, a find process, a subshell for a `$(...)` capturing _hp_xmrig_need_pages's own output)
# inherits that SAME pgid, so ONE signal to the group (`kill -- -$pgid`) reaches all of them, including a
# blocked-forever read/open on a hung /proc/<pid>/smaps_rollup (this file's own FIFO test proves the WHOLE group
# is gone afterward, not just the top-level job). The pgid is VERIFIED before ever being used to signal anything
# - it must equal the job's own pid (confirms `set -m` really isolated it) and differ from THIS shell's own pgid
# (never signal the caller's own group); anything else falls back to signalling the bare pid alone, exactly
# like Round 5c did, never a guessed group. `set -m` is restored to whatever it was before this call, never
# left on beyond it, and is toggled only around the exact statement that launches the job.
# On a timeout: this poll simply defers finalization to a later one - $khs/$stats were already set by the
# engine's own h-stats.sh BEFORE this ever runs, so they are completely unaffected either way, and a killed
# attempt writes nothing at all (_hp_rewrite's tmp+mv is all-or-nothing: there is no partial record to leave
# behind beyond a stray .tmp.$$ file, cleaned up best-effort on the NEXT call) - proven by this file's own test:
# the record is BYTE-IDENTICAL after a killed attempt even once the hung read is later unblocked.
# Backgrounding the FUNCTION CALL directly - never a `bash -c` re-exec into a fresh interpreter - is what keeps
# this both simple and correct: a backgrounded job is a plain fork of THIS shell, so it sees every variable
# ($khs, the engine's own exported PORT/PROC/PKG, HUGEPAGES_FILE, ...) and every function (_hp_xmrig_need_pages,
# _hp_rewrite, log_hugepages_note, ...) it needs with no export/re-sourcing required.
# ROUND 5d also minimises external children in finalize_rx_hugepages's own read path (_hp_field, _hp_boot_id,
# _hp_free_hugepages, _hp_hugepage_size_kb, _hp_uptime_seconds, _hp_xmrig_need_pages all now use bash's own
# builtin `read`/parameter expansion instead of forking sed/cat/awk per call) - less to ever leave orphaned in
# the first place, on top of the group-kill above, not instead of it. The owner-pid lookup's own `find` call is
# already the SAME O(1)-fork pattern engines/rx/h-stats.sh's own (load-tested) ownership scan uses, never a
# per-item loop - left as is (replacing it would reintroduce exactly the per-item-fork class of bug this
# codebase already fixed once); the group-kill above is what bounds it, and everything else, on top of that.
#
# ROUND 5e (Codex) - Round 5d's OWN escalation still overran the deadline: the alarm slept for the FULL
# "remaining" value it was handed, THEN, only once that already elapsed, sent TERM, waited another fixed 0.05 s
# grace, then possibly KILL and a reap - none of that follow-up time was ever subtracted from anything, so the
# true worst-case wall time was "remaining + 0.05 s + signal/reap overhead", not "remaining". Worse, by the
# time the alarm actually started (after backgrounding the job and deriving/verifying its pgid via `ps`, both
# real elapsed time), "remaining" itself was already stale - using it as-is for the alarm double-counts that
# setup time on top. Fixed by working against the ABSOLUTE deadline throughout, and by reserving cleanup time
# BEFORE ever computing an alarm duration, recomputed fresh (fresh `now`) at the LAST possible moment - right
# before the alarm actually starts, after all setup work is already done - rather than once, early, and reused:
# `alarm = deadline - now - RESERVE_S`, where RESERVE_S (0.15 s: the 0.05 s TERM grace plus signal-delivery/
# reap overhead) is subtracted from the budget the alarm itself sleeps for, not added on top of it afterward.
# If that leaves less than 0.05 s to even try, this defers to a later poll without doing any of the setup work
# at all (cheap - one arithmetic check, no fork, no backgrounding). `EPOCHREALTIME` (bash 5's own builtin
# high-resolution clock, no fork) is used for "now" wherever available, falling back to `date +%s.%N` only if
# it is unset (an older bash) - consistent with minimising external children, on top of bounding the deadline
# correctly.
#
# ROUND 5f (Codex, PR #2 follow-up review): "Compare the deadline without launching another process" - the
# arithmetic above was never actually fork-free the way this whole function's own history claims: every "now"
# and every deadline COMPARISON still forked an external `awk`, and the poll loop's own pacing forked an
# external `sleep` every single iteration - under full CPU saturation, exactly the fork/exec scheduling latency
# this function already eliminated everywhere else (the group-kill, the liveness probe, _hp_uptime_seconds, ...)
# could still delay THESE specific calls past the loop's own absolute deadline: a stale "now" gets compared,
# one more iteration + sleep runs anyway, and the advertised deadline is exceeded. Fixed by adopting integer
# microseconds throughout - the exact same DEADLINE_US convention both engines' own h-stats.sh already use for
# every other timing decision in this codebase (_hp_now_us reuses their now_us() idiom verbatim; the caller,
# h-stats.sh, now passes an integer-microseconds deadline computed the same fork-free way) - so every
# comparison here is plain `$(( ))` bash arithmetic, and the poll/escalation waits go through _hp_wait (a
# builtin `read -t` against a private fd opened ONCE, not a fork of `sleep` per call - see its own header).
finalize_rx_hugepages_bounded() {
	local abs_deadline_us=$1 reserve_us=150000   # RESERVE_US: 0.05 s TERM grace + signal-delivery/KILL/reap
		# overhead - reserved from the deadline BEFORE any alarm duration is ever computed, never added on after.
	local now_us alarm_us parent_pgid cpid pgid had_monitor=0 waitfd=-1

	_hp_now_us; now_us=$REPLY
	alarm_us=$(( abs_deadline_us - now_us - reserve_us )); (( alarm_us < 0 )) && alarm_us=0
	(( alarm_us > 50000 )) || return 0   # not enough of the budget left to even attempt this poll (< 0.05 s)

	rm -f "$HUGEPAGES_FILE".tmp.* 2>/dev/null   # best-effort: a leftover temp file from an earlier killed attempt

	case $- in *m*) had_monitor=1 ;; esac
	parent_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')

	set -m
	finalize_rx_hugepages > /dev/null 2>&1 &
	cpid=$!
	(( had_monitor )) || set +m

	pgid=$(ps -o pgid= -p "$cpid" 2>/dev/null | tr -d '[:space:]')
	[[ $pgid =~ ^[0-9]+$ && $pgid == "$cpid" && $pgid != "$parent_pgid" && $pgid -gt 1 ]] || pgid=""

	# Recompute the alarm duration ONE LAST TIME, right here, right before it actually starts: backgrounding
	# the job and deriving/verifying its pgid above (a real `ps` fork) already consumed some of the budget -
	# reusing the value computed at function entry would double-count that time on top of the reserve.
	_hp_now_us; now_us=$REPLY
	alarm_us=$(( abs_deadline_us - now_us - reserve_us )); (( alarm_us < 0 )) && alarm_us=0
	local poll_deadline_us=$(( now_us + alarm_us ))
	# Poll for the child's own exit (short interval, forkless `kill -0` - no fork wasted on a real result once
	# it's done) instead of `wait -n <cpid> <apid>`: `wait -n` given explicit pids that mix a job-control-tracked
	# child (backgrounded under `set -m`, its own process group) with a plain one (the alarm `sleep`, started
	# after `set +m`) was measured to BLOCK for the alarm's own full duration even when the FIRST child had
	# already exited in ~1 ms - reproducible, and specific to how the invoking shell itself was started
	# (`bash -c '...'` vs a script file) - not something this function can assume away. Polling has no such
	# invocation-context dependency.
	# One process-substitution fork here (never per iteration) for _hp_wait's own private fd - see its header.
	# PR #2 follow-up review (Codex): "exec {fd}... 2>/dev/null" with NO command after it is a bare redirection,
	# not a command invocation - bash applies it to the CURRENT SHELL PERMANENTLY (exactly like a plain `exec
	# 2>/dev/null` would), not just to this one statement; a function's own scope does not limit it either. That
	# silently redirected this whole process's stderr to /dev/null for the rest of its life the instant this ran
	# once. The `{ ...; } 2>/dev/null` group form keeps the SAME {fd} allocation (still visible after the group,
	# since `{ }` is not a subshell) while scoping the redirect to only the command inside it.
	{ exec {waitfd}<> <(:); } 2>/dev/null || waitfd=-1
	# PR #2 follow-up review (Codex): the deadline is checked BEFORE the liveness probe on every iteration, not
	# after (the old `while _hp_bounded_still_running ...; do now=...; awk ... done` checked liveness FIRST, as
	# the loop's own condition) - see both engines' own h-stats.sh (same review) for the full rationale.
	while :; do
		_hp_now_us; now_us=$REPLY
		(( now_us < poll_deadline_us )) || break
		_hp_bounded_still_running "$cpid" "$pgid" || break
		_hp_wait "$waitfd" 0.05
	done
	if _hp_bounded_still_running "$cpid" "$pgid"; then
		_hp_bounded_escalate TERM "$cpid" "$pgid"
		_hp_wait "$waitfd" 0.05
		_hp_bounded_still_running "$cpid" "$pgid" && _hp_bounded_escalate KILL "$cpid" "$pgid"
	fi
	(( waitfd >= 0 )) && { exec {waitfd}<&-; } 2>/dev/null
	wait "$cpid" 2>/dev/null
	true
}

# restore_verus_hugepages - called just before exec'ing the verus engine. ONLY if a record exists (a fresh
# install, or a Verus start never preceded by an rx start under this package's ownership, touches
# vm.nr_hugepages at all) AND that record has final=1 (finalize_rx_hugepages, above, positively confirmed
# "ours" from XMRig's own reported numbers - final=0/"conflict"/missing, including an OLD pre-Round-5 record
# that only ever had prior=/ours= and no final= line at all, is never trusted here; see the top-of-section
# comment on backward compatibility) AND was finalized within the CURRENT boot (Round 5c - re-checked here,
# independently of finalize_rx_hugepages's own boot_id check, since a reboot could happen between finalization
# and this call). Given final=1 and a matching boot_id, the restore fires ONLY when ALL THREE of "prior", "ours"
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

	# ---- Round 5c: a finalized record is only ever trusted within the SAME boot it was finalized in - a stale
	# final=1 record surviving into a DIFFERENT boot (an unusual non-tmpfs $STATEDIR, or a boot_id anomaly) must
	# never authorize a restore just because "prior"/"ours" happen to still look numerically plausible; those
	# numbers describe a hugepage reservation from a boot that no longer exists. finalize_rx_hugepages already
	# checks boot_id before EVER finalizing, but that was checked THEN - a reboot could still happen between
	# finalization and this restore attempt, so it is re-checked here, independently, before any write. Decision
	# (documented, not just enforced): KEEP the record on a mismatch, never drop it - consistent with every other
	# gate in this function (a permanently unusable record has nowhere better to go than tmpfs until an actual
	# reboot clears it, which is also precisely the case that makes this cross-boot scenario vanishingly rare in
	# practice; dropping it here would only remove the one place "prior" is recorded, for no gain).
	local rec_boot cur_boot
	rec_boot=$(_hp_field boot); cur_boot=$(_hp_boot_id)
	if [[ -z $rec_boot || $rec_boot != "$cur_boot" ]]; then
		log_hugepages_note "BloxMiner: finalized huge-page ownership record is from a different boot (record=${rec_boot:-<missing>}, current=${cur_boot:-<unreadable>}) - a finalized record is only ever trusted within the SAME boot it was written in; left vm.nr_hugepages untouched, record kept"
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
			# PR #2 follow-up review (Codex) audit: only consumed once the restore is verified, by readback,
			# to have succeeded. If removal itself fails (STATEDIR unwritable), the record lingers with
			# final=1/ours=$ours describing an rx session that is now OVER (nr_hugepages == prior, not ours
			# any more) - but this is never dangerous the way an un-invalidated STALE record was before
			# _hp_invalidate existed: the very next rx start's own note_rx_hugepages_start sees cur(==prior)
			# != rec_ours immediately (prior is essentially never equal to the ours it was reserved on top
			# of), correctly determines "not owned", and invalidates this exact leftover record itself before
			# reserving again - the same mechanism that closes the ORIGINAL bug also mops this one up. Logged
			# here purely for operator visibility, never a behaviour change.
			_hp_invalidate || log_hugepages_note "BloxMiner: restored vm.nr_hugepages to $prior but could not remove the now-consumed ownership record ($HUGEPAGES_FILE) - a later rx start's own invalidation will clear it before reserving again"
		else
			log_hugepages_note "BloxMiner: restore write to $prior did not read back correctly (now=${verify:-<unreadable>}) - record kept for a later attempt"
		fi
	else
		log_hugepages_note "BloxMiner: failed to restore vm.nr_hugepages to $prior - record kept for a later attempt"
	fi
	true
}
