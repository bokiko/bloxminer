#!/usr/bin/env bash
# Tests for build/package.sh's tamper detection: every sha256/version fact it is supposed to verify (both
# engine binaries, both RandomX patches, both engines' declared version) really is checked, and a mismatch on
# any one of them refuses to write a package - never a silent, mismatched artefact. BloxMiner 3.0.0 REBUILDS
# both engines, so package.sh's inputs are the two engines' own build/build.sh and build/build-rx.sh OUTDIRS
# (binary + its own fresh provenance), not previously released tarballs - this suite tampers copies of those
# outdirs the same way the old suite tampered tarball copies: never the originals.
# Usage: tests/build/test_package_provenance.sh <verus-build-outdir> <rx-build-outdir>
#   (or set BLOX_VERUS_OUT/BLOX_RX_OUT). Outdirs are otherwise REQUIRED - there is deliberately NO default/
#   fallback location: a previous version of this test defaulted to a shared, mutable ~/c3work/{verus-out,
#   rx-out} and kept passing its "baseline"/"control" cases against binaries built from an OLDER commit while
#   the tree under test had already moved on (a real, observed failure - a stale rx-out made those two cases
#   fail with a confusing "does not match its recorded source hash" instead of a clean skip). Real outdirs are
#   proven to actually match $ROOT (the tree this test script itself lives in) before anything else runs - see
#   the hermetic check below; never silently tested against a mismatching pair.
#
# PR #2 follow-up review (Codex): with no outdirs given, this used to unconditionally SKIP - meaning
# package.sh's entire tamper-detection logic (this file's ~20 cases) never ran in CI at all, since the
# "scripts" CI job never compiles either engine (that is the separate, much slower "engine" job, and even it
# only builds the Verus side). Fixed: with BLOX_CI set and no outdirs given, this generates SYNTHETIC-BUT-
# FAITHFUL outdirs instead of skipping - fake binary bytes (their content is never what package.sh actually
# checks; only their sha256, matched to a correspondingly fake provenance entry, is), but a GENUINELY correct
# provenance file in every field package.sh's own [[ ... ]] checks actually verify: this repo's real
# bloxminer.patch/donate0.patch/branding.patch hashes, the real current package version, and - for
# build/package.sh's own source-bundle step, which does a REAL `git clone` + commit-match against upstream,
# never fakeable - the real upstream repo/commit ccminer and xmrig are actually pinned to (resolved the same
# way build/build.sh and build/build-rx.sh themselves do, not hand-duplicated). This exercises the real
# tamper-detection logic end-to-end (every case below still copies+tampers this SAME baseline and asserts
# package.sh still refuses), without ever compiling either engine. Local/release runs are unaffected: passing
# real outdirs (or BLOX_VERUS_OUT/BLOX_RX_OUT) always wins, and with neither BLOX_CI nor real outdirs, this
# still cleanly SKIPs (a bare local dev run, no network, no CI) rather than surprising a laptop with 40 clones.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
VERUS_OUT=${1:-${BLOX_VERUS_OUT:-}}
RX_OUT=${2:-${BLOX_RX_OUT:-}}
SYNTH_DIR=""
gen_synthetic_outdirs() {   # $1 = verus outdir, $2 = rx outdir - see the header comment above for the full
	# rationale. Fails loudly (never silently) on any network/tooling problem: under BLOX_CI, that must FAIL
	# the whole suite (the point of this function existing), never fall through to a SKIP that looks the same
	# as "nothing to test here".
	local vout=$1 xout=$2
	mkdir -p "$vout" "$xout"
	local ver; ver=$(sed -n 's/^CUSTOM_VERSION=//p' "$ROOT/bloxminer/h-manifest.conf")
	[[ -n $ver ]] || { echo "gen_synthetic_outdirs: could not read CUSTOM_VERSION from bloxminer/h-manifest.conf" >&2; return 1; }
	# gen_fake_binary <path> <label> - a "binary" whose CONTENT is never what package.sh actually checks (only
	# its sha256, matched into a correspondingly fake provenance entry below, is) - but MUST be large enough
	# for this file's own flip_byte() (tests 2/7 below: `f.seek(-200, 2)` then flips that byte) to have
	# anywhere to seek to; a too-small synthetic binary makes flip_byte's own seek raise (caught nowhere,
	# since it runs as an uncaught exception in the disposable python heredoc), silently leaving the "tampered"
	# copy byte-identical to the original - the tamper case then wrongly asserts a refusal that never had
	# anything to refuse. 4 KiB of /dev/urandom is comfortably larger than that 200-byte tail, cheap, and
	# unique per generation (no risk of colliding with anything real).
	gen_fake_binary() { { printf '%s\n' "$2"; head -c 4096 /dev/urandom; } > "$1"; }

	# ---- verus (ccminer) side - upstream/short-commit read from build/build.sh itself (never hand-duplicated
	# here), resolved to the FULL 40-char commit build/package.sh's own -src bundle step requires (its own
	# `git rev-parse HEAD` after checkout, compared against this exact string) the SAME way build/build.sh
	# itself resolves it - a real, live git operation, proving the pin is still resolvable, not a hardcoded
	# guess that could go stale if the upstream branch ever moved.
	local v_upstream="https://github.com/monkins1010/ccminer.git"
	local v_short
	# shellcheck disable=SC2016   # single quotes on purpose: this is a literal sed pattern, not a shell expansion
	v_short=$(sed -n 's/^COMMIT=\${COMMIT:-\([^}]*\)}.*/\1/p' "$ROOT/build/build.sh")
	[[ -n $v_short ]] || { echo "gen_synthetic_outdirs: could not read COMMIT from build/build.sh" >&2; return 1; }
	local vclone; vclone=$(mktemp -d)
	git clone -q -b Verus2.2 "$v_upstream" "$vclone" || { rm -rf "$vclone"; echo "gen_synthetic_outdirs: git clone $v_upstream failed" >&2; return 1; }
	( cd "$vclone" && git checkout -q "$v_short" ) || { rm -rf "$vclone"; echo "gen_synthetic_outdirs: git checkout $v_short failed" >&2; return 1; }
	local v_full; v_full=$(git -C "$vclone" rev-parse HEAD); rm -rf "$vclone"
	[[ $v_full =~ ^[0-9a-f]{40}$ ]] || { echo "gen_synthetic_outdirs: resolved verus commit '$v_full' is not a full sha" >&2; return 1; }

	gen_fake_binary "$vout/bloxminer-O3" "synthetic bloxminer-O3 binary for CI provenance testing"
	gen_fake_binary "$vout/libomp.so.5" "synthetic libomp.so.5 for CI provenance testing"
	{
		echo "binary_sha256=$(sha256sum "$vout/bloxminer-O3" | cut -d' ' -f1)"
		echo "version=$ver"
		echo "upstream=$v_upstream"
		echo "upstream_commit=$v_full"
		echo "patch_sha256=$(sha256sum "$ROOT/build/bloxminer.patch" | cut -d' ' -f1)"
		echo "arch_flags=synthetic (CI provenance test - never a real build)"
		echo "opt=-O3"
		echo "compiler=synthetic"
		echo "glibc_min=synthetic"
		echo "libomp_sha256=$(sha256sum "$vout/libomp.so.5" | cut -d' ' -f1)"
		echo "os=synthetic"
	} > "$vout/bloxminer-O3.provenance"

	# ---- rx (xmrig) side - upstream/tag/commit read from build/build-rx.sh itself (already the FULL 40-char
	# hash there, no resolution needed - just extracted, not hand-duplicated).
	local x_upstream x_tag x_commit
	x_upstream=$(sed -n 's/^UPSTREAM=//p' "$ROOT/build/build-rx.sh")
	x_tag=$(sed -n 's/^TAG=//p' "$ROOT/build/build-rx.sh")
	x_commit=$(sed -n 's/^COMMIT=\([^[:space:]#]*\).*/\1/p' "$ROOT/build/build-rx.sh")
	[[ -n $x_upstream && -n $x_tag && $x_commit =~ ^[0-9a-f]{40}$ ]] || { echo "gen_synthetic_outdirs: could not read UPSTREAM/TAG/COMMIT from build/build-rx.sh" >&2; return 1; }

	gen_fake_binary "$xout/xmrig" "synthetic xmrig binary for CI provenance testing"
	gen_fake_binary "$xout/bloxsense" "synthetic bloxsense binary for CI provenance testing"
	{
		echo "upstream=$x_upstream"
		echo "upstream_tag=$x_tag"
		echo "upstream_commit=$x_commit"
		echo "patch_sha256=$(sha256sum "$ROOT/build/donate0.patch" | cut -d' ' -f1)"
		echo "branding_patch_sha256=$(sha256sum "$ROOT/build/branding.patch" | cut -d' ' -f1)"
		echo "blox_display_version=$ver"
		echo "xmrig_sha256=$(sha256sum "$xout/xmrig" | cut -d' ' -f1)"
		echo "bloxsense_sha256=$(sha256sum "$xout/bloxsense" | cut -d' ' -f1)"
		# HELPERS: parsed straight out of build/build-rx.sh's own array (same extraction test 12 below already
		# uses to prove every entry resolves to a real file) - never a second, hand-maintained copy that could
		# drift out of sync with what build/package.sh will actually walk.
		while IFS= read -r h; do
			[[ -n $h ]] || continue
			echo "helper.$h.sha256=$(sha256sum "$ROOT/$h" | cut -d' ' -f1)"
		done < <(sed -n "/^HELPERS=(/,/)/p" "$ROOT/build/build-rx.sh" | tr -d '()' | sed 's/^HELPERS=//' | tr -s ' \t\n' '\n' | grep -v '^$')
	} > "$xout/build.provenance"
}
if [[ -z $VERUS_OUT || -z $RX_OUT ]]; then
	if [[ -n ${BLOX_CI:-} ]]; then
		SYNTH_DIR=$(mktemp -d)
		VERUS_OUT="$SYNTH_DIR/verus-out"; RX_OUT="$SYNTH_DIR/rx-out"
		if ! gen_synthetic_outdirs "$VERUS_OUT" "$RX_OUT"; then
			echo "FAIL: BLOX_CI is set but synthetic outdir generation failed (see above) - this must not silently SKIP under CI" >&2
			rm -rf "$SYNTH_DIR"
			exit 1
		fi
	else
		echo "SKIP: no build outdirs given - pass <verus-out> <rx-out> as arguments, or set BLOX_VERUS_OUT/BLOX_RX_OUT (or BLOX_CI=1 to generate synthetic ones - see this file's own header comment). This test needs build/build.sh and build/build-rx.sh output for the EXACT commit/tree under test; it never falls back to a shared or previously-built default location."
		exit 0
	fi
fi
trap '[[ -n $SYNTH_DIR ]] && rm -rf "$SYNTH_DIR"' EXIT
[[ -f $VERUS_OUT/bloxminer-O3 && -f $VERUS_OUT/bloxminer-O3.provenance && -f $VERUS_OUT/libomp.so.5 && -f $RX_OUT/xmrig && -f $RX_OUT/bloxsense && -f $RX_OUT/build.provenance ]] || {
	echo "SKIP: build outdirs not found or incomplete ($VERUS_OUT / $RX_OUT)"; exit 0; }

# Hermetic check: prove these outdirs actually match $ROOT (the tree under test) BEFORE using them as the
# "known good" baseline for every tamper case below. The cheapest, always-in-sync way to prove this is to
# literally run build/package.sh once here - its own first act is exactly this verification (every helper
# hash, both binaries, against $ROOT's current bytes), refusing on any mismatch - reusing it, rather than
# re-implementing the same comparison a second time, means this check can never drift out of sync with what
# package.sh actually enforces. A refusal here SKIPs the whole suite with package.sh's own exact reason,
# instead of every tamper case below silently running against a provenance that describes different bytes
# than what is actually in $ROOT right now.
HERMCHECK_DIR=$(mktemp -d)
if ! HERMCHECK_OUT=$(bash "$ROOT/build/package.sh" "$VERUS_OUT" "$RX_OUT" "$HERMCHECK_DIR" 2>&1); then
	rm -rf "$HERMCHECK_DIR"
	echo "SKIP: $VERUS_OUT / $RX_OUT do not match the tree under test ($ROOT) - build/package.sh refused:"
	echo "$HERMCHECK_OUT"
	exit 0
fi
rm -rf "$HERMCHECK_DIR"

T=$(mktemp -d); trap '[[ -n $SYNTH_DIR ]] && rm -rf "$SYNTH_DIR"; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-60s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-60s FAIL: %s\n' "$1" "$2"; }

# copy an outdir so a tamper never touches the frozen original
copy_outdir() { rm -rf "$2"; mkdir -p "$2"; cp -a "$1"/. "$2"/; }

flip_byte() {   # $1 = file, flips one byte 200 bytes from the end (binaries) - never touches the frozen original
	python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
with open(p, "r+b") as f:
	f.seek(-200, 2)
	b = f.read(1)
	f.seek(-200, 2)
	f.write(bytes([b[0] ^ 0xFF]))
PY
}

run_pkg() {   # $1 verus_outdir $2 rx_outdir $3 outdir -> sets $rc $out
	local o=$3; mkdir -p "$o"
	out=$(bash "$ROOT/build/package.sh" "$1" "$2" "$o" 2>&1); rc=$?
}

# ---- 1: baseline, untampered - succeeds, both artefacts produced, sha256 in SHA256SUMS matches the built binaries
O="$T/ok"; run_pkg "$VERUS_OUT" "$RX_OUT" "$O"
VBIN_SHA=$(sha256sum "$VERUS_OUT/bloxminer-O3" | cut -d' ' -f1)
XBIN_SHA=$(sha256sum "$RX_OUT/xmrig" | cut -d' ' -f1)
if [[ $rc == 0 && -f $O/bloxminer-3.0.0.tar.gz && -f $O/bloxminer-3.0.0-src.tar.gz && -f $O/SHA256SUMS ]] \
	&& grep -q "^$VBIN_SHA  bloxminer/bloxminer$" "$O/SHA256SUMS" \
	&& grep -q "^$XBIN_SHA  bloxminer/xmrig$" "$O/SHA256SUMS"
then
	ok "baseline: untampered inputs -> package.sh succeeds, both artefacts produced"
else
	bad "baseline: untampered inputs -> package.sh succeeds, both artefacts produced" "rc=$rc out=$out"
fi

# ---- 2: tampered Verus binary bytes -> refuses, no package written
V2="$T/verus-bad-bin"; copy_outdir "$VERUS_OUT" "$V2"; flip_byte "$V2/bloxminer-O3"
O="$T/bad-verus-bin"; run_pkg "$V2" "$RX_OUT" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]]; then ok "tampered verus binary bytes -> package.sh refuses"; else bad "tampered verus binary bytes -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 3: verus provenance's binary_sha256 doesn't match the (untampered) binary -> refuses
V3="$T/verus-bad-prov"; copy_outdir "$VERUS_OUT" "$V3"
sed -i.bak 's/^binary_sha256=.*/binary_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$V3/bloxminer-O3.provenance"
O="$T/bad-verus-prov"; run_pkg "$V3" "$RX_OUT" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "sha256" <<< "$out"; then ok "tampered verus provenance binary_sha256 -> package.sh refuses"; else bad "tampered verus provenance binary_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 4: verus provenance's libomp_sha256 doesn't match -> refuses
V4="$T/verus-bad-libomp"; copy_outdir "$VERUS_OUT" "$V4"
sed -i.bak 's/^libomp_sha256=.*/libomp_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$V4/bloxminer-O3.provenance"
O="$T/bad-libomp"; run_pkg "$V4" "$RX_OUT" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]]; then ok "tampered verus provenance libomp_sha256 -> package.sh refuses"; else bad "tampered verus provenance libomp_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 5: verus provenance's patch_sha256 no longer matches this repo's build/bloxminer.patch -> refuses
V5="$T/verus-bad-patch"; copy_outdir "$VERUS_OUT" "$V5"
sed -i.bak 's/^patch_sha256=.*/patch_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$V5/bloxminer-O3.provenance"
O="$T/bad-verus-patch"; run_pkg "$V5" "$RX_OUT" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "bloxminer.patch" <<< "$out"; then ok "tampered verus provenance patch_sha256 -> package.sh refuses"; else bad "tampered verus provenance patch_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 6: verus provenance's own recorded AC_INIT version no longer matches the package version -> refuses
V6="$T/verus-bad-ver"; copy_outdir "$VERUS_OUT" "$V6"
sed -i.bak 's/^version=.*/version=2.1.0/' "$V6/bloxminer-O3.provenance"
O="$T/bad-verus-ver"; run_pkg "$V6" "$RX_OUT" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "version" <<< "$out"; then ok "tampered verus provenance version -> package.sh refuses"; else bad "tampered verus provenance version -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 7: tampered RandomX binary bytes -> refuses
X7="$T/rx-bad-bin"; copy_outdir "$RX_OUT" "$X7"; flip_byte "$X7/xmrig"
O="$T/bad-rx"; run_pkg "$VERUS_OUT" "$X7" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]]; then ok "tampered rx binary bytes -> package.sh refuses"; else bad "tampered rx binary bytes -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 8: rx provenance's donate0.patch patch_sha256 no longer matches this repo's build/donate0.patch -> refuses
X8="$T/rx-bad-donate"; copy_outdir "$RX_OUT" "$X8"
sed -i.bak 's/^patch_sha256=.*/patch_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$X8/build.provenance"
O="$T/bad-rx-patch"; run_pkg "$VERUS_OUT" "$X8" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "donate0.patch" <<< "$out"; then ok "tampered rx provenance patch_sha256 -> package.sh refuses"; else bad "tampered rx provenance patch_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 9: rx provenance's branding_patch_sha256 no longer matches this repo's build/branding.patch -> refuses
X9="$T/rx-bad-branding"; copy_outdir "$RX_OUT" "$X9"
sed -i.bak 's/^branding_patch_sha256=.*/branding_patch_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$X9/build.provenance"
O="$T/bad-rx-branding"; run_pkg "$VERUS_OUT" "$X9" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "branding.patch" <<< "$out"; then ok "tampered rx provenance branding_patch_sha256 -> package.sh refuses"; else bad "tampered rx provenance branding_patch_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 10: rx provenance's blox_display_version no longer matches the package version -> refuses
X10="$T/rx-bad-dispver"; copy_outdir "$RX_OUT" "$X10"
sed -i.bak 's/^blox_display_version=.*/blox_display_version=1.2.3/' "$X10/build.provenance"
O="$T/bad-rx-dispver"; run_pkg "$VERUS_OUT" "$X10" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "blox_display_version" <<< "$out"; then ok "tampered rx provenance blox_display_version -> package.sh refuses"; else bad "tampered rx provenance blox_display_version -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 11: bundled bloxsense SOURCE tampered by one byte (the binary and its own build.provenance are both
#      untouched - only the source this repo is about to ship next to that binary changed) -> refuses. package.sh
#      is run from a throwaway full copy of this repo (never the real checkout) so the tamper never touches
#      the working tree; only bloxsense.cpp is touched, one byte, well inside the file.
REPO_COPY="$T/repo-tamper"; rm -rf "$REPO_COPY"; mkdir -p "$REPO_COPY"
tar -C "$ROOT" --exclude=.git --exclude=.backups -cf - . | tar -C "$REPO_COPY" -xf -
python3 - "$REPO_COPY/bloxsense/bloxsense.cpp" <<'PY'
import sys
p = sys.argv[1]
with open(p, "r+b") as f:
	f.seek(200)
	b = f.read(1)
	f.seek(200)
	f.write(bytes([b[0] ^ 0xFF]))
PY
O="$T/bad-bloxsense-src"; out=$(bash "$REPO_COPY/build/package.sh" "$VERUS_OUT" "$RX_OUT" "$O" 2>&1); rc=$?
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "bloxsense/bloxsense.cpp" <<< "$out"; then
	ok "tampered bloxsense.cpp source (1 byte) -> package.sh refuses"
else
	bad "tampered bloxsense.cpp source (1 byte) -> package.sh refuses" "rc=$rc out=$out"
fi
# control: the SAME kind of throwaway copy, untouched, still packages successfully - proves the refusal above
# is really about the tamper and not some artefact of running out of a copy
REPO_COPY_CONTROL="$T/repo-tamper-control"; rm -rf "$REPO_COPY_CONTROL"; mkdir -p "$REPO_COPY_CONTROL"
tar -C "$ROOT" --exclude=.git --exclude=.backups -cf - . | tar -C "$REPO_COPY_CONTROL" -xf -
O="$T/ok-repo-copy"; out=$(bash "$REPO_COPY_CONTROL/build/package.sh" "$VERUS_OUT" "$RX_OUT" "$O" 2>&1); rc=$?
if [[ $rc == 0 && -f $O/bloxminer-3.0.0.tar.gz ]]; then ok "control: untampered repo copy -> package.sh still succeeds"; else bad "control: untampered repo copy -> package.sh still succeeds" "rc=$rc out=$out"; fi

# ---- 11b: every OTHER build/build-rx.sh HELPERS entry - not just the 3 bloxsense sources checked in test 11.
#      package.sh used to hardcode exactly those 3 and silently skip the rest (the rx engine's own gated
#      scripts, the shared manifest, build-rx.sh/package.sh themselves); it now walks every helper.*.sha256
#      line recorded in $RXPROV, so a one-byte edit to ANY of them must independently refuse to package.
#      Text-append (never flip_byte's binary XOR) so each shell/conf file stays syntactically valid - the
#      refusal must come from the sha256 mismatch, not from a broken script failing for an unrelated reason.
tamper_append() { printf '\n# tamper (test_package_provenance.sh)\n' >> "$1"; }
for HP in bloxminer/engines/rx/h-config.sh bloxminer/engines/rx/h-run.sh bloxminer/engines/rx/h-stats.sh \
          bloxminer/h-manifest.conf build/build-rx.sh build/package.sh; do
	RC="$T/repo-tamper-$(tr '/' '_' <<< "$HP")"; rm -rf "$RC"; mkdir -p "$RC"
	tar -C "$ROOT" --exclude=.git --exclude=.backups -cf - . | tar -C "$RC" -xf -
	tamper_append "$RC/$HP"
	O="$T/bad-$(tr '/' '_' <<< "$HP")"; out=$(bash "$RC/build/package.sh" "$VERUS_OUT" "$RX_OUT" "$O" 2>&1); rc=$?
	if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "$HP" <<< "$out"; then
		ok "tampered $HP (HELPERS, 1 line appended) -> package.sh refuses"
	else
		bad "tampered $HP (HELPERS, 1 line appended) -> package.sh refuses" "rc=$rc out=$out"
	fi
done

# ---- 11c: a HELPERS file recorded in provenance but since DELETED from the repo -> refuses with a clear
#      "missing", not an unrelated sha256sum error swallowed by set -e's bare exit.
RC="$T/repo-tamper-missing"; rm -rf "$RC"; mkdir -p "$RC"
tar -C "$ROOT" --exclude=.git --exclude=.backups -cf - . | tar -C "$RC" -xf -
rm -f "$RC/bloxminer/engines/rx/h-run.sh"
O="$T/bad-missing-helper"; out=$(bash "$RC/build/package.sh" "$VERUS_OUT" "$RX_OUT" "$O" 2>&1); rc=$?
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "missing from this repo" <<< "$out"; then
	ok "HELPERS file deleted from repo -> package.sh refuses with a clear message"
else
	bad "HELPERS file deleted from repo -> package.sh refuses with a clear message" "rc=$rc out=$out"
fi

# ---- 11d: rx provenance with its ENTIRE helper.*.sha256 section stripped (an old-format/corrupt
#      build.provenance) -> refuses outright rather than silently treating "zero helpers" as "nothing to check"
X11D="$T/rx-no-helpers"; copy_outdir "$RX_OUT" "$X11D"
sed -i.bak '/^helper\./d' "$X11D/build.provenance"
O="$T/bad-rx-no-helpers"; run_pkg "$VERUS_OUT" "$X11D" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "no helper" <<< "$out"; then
	ok "rx provenance with no helper.*.sha256 entries -> package.sh refuses"
else
	bad "rx provenance with no helper.*.sha256 entries -> package.sh refuses" "rc=$rc out=$out"
fi

# ---- 11e: PR #2 follow-up review (Codex): "Require every expected helper provenance entry" - the gate used
#      to only require rx_helpers_checked > 0 (at least ONE helper.*.sha256 line present and matching), never
#      "every CURRENTLY expected one is present" - deleting exactly ONE line from an otherwise-valid
#      build.provenance (leaving every other helper.*.sha256 line, and the binary/patch checks above, all
#      genuinely matching) used to still pass: that one file's own bytes were simply never re-checked at all.
#      Deletes ONLY h-run.sh's own line - every other helper (including the other rx engine scripts) stays
#      correctly recorded - and asserts package.sh now refuses, naming the specific missing helper.
X11E="$T/rx-missing-one-helper"; copy_outdir "$RX_OUT" "$X11E"
sed -i.bak '/^helper\.bloxminer\/engines\/rx\/h-run\.sh\.sha256=/d' "$X11E/build.provenance"
O="$T/bad-rx-missing-one-helper"; run_pkg "$VERUS_OUT" "$X11E" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "bloxminer/engines/rx/h-run.sh" <<< "$out" && grep -qF "missing from" <<< "$out"; then
	ok "rx provenance with exactly ONE helper.*.sha256 line deleted (others still valid) -> package.sh refuses"
else
	bad "rx provenance with exactly ONE helper.*.sha256 line deleted (others still valid) -> package.sh refuses" "rc=$rc out=$out"
fi

# ---- 11f: an EXTRA/unknown helper.*.sha256 entry - one that does not correspond to anything build/
#      build-rx.sh's own HELPERS array currently lists (e.g. a stale leftover from a renamed/removed file, or
#      a hand-edited addition) - must also refuse, not silently hash-check it and report "fine". The extra
#      entry's own hash is deliberately CORRECT (sha256 of a real file in this repo) - the refusal must come
#      from it not being an expected helper at all, never from a coincidental hash mismatch.
X11F="$T/rx-extra-helper"; copy_outdir "$RX_OUT" "$X11F"
printf 'helper.README.md.sha256=%s\n' "$(sha256sum "$ROOT/README.md" | cut -d' ' -f1)" >> "$X11F/build.provenance"
O="$T/bad-rx-extra-helper"; run_pkg "$VERUS_OUT" "$X11F" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "README.md" <<< "$out" && grep -qF "not in build/build-rx.sh's own current HELPERS array" <<< "$out"; then
	ok "rx provenance with an EXTRA/unknown helper.*.sha256 entry -> package.sh refuses"
else
	bad "rx provenance with an EXTRA/unknown helper.*.sha256 entry -> package.sh refuses" "rc=$rc out=$out"
fi

# ---- 12: build/build-rx.sh's own HELPERS list - every path it records a source hash for must resolve to a
#      real file in THIS repo layout, and its own self-reference must be build/build-rx.sh, never build/build.sh
#      (the unrelated Verus/ccminer builder) - otherwise a real build/build-rx.sh run (root, Ubuntu 22.04,
#      network; not exercised by this suite) would abort mid-provenance on a missing file, per its own
#      `set -euo pipefail`, and never produce a complete build.provenance at all. Also covers build/branding.patch
#      now being part of HELPERS.
missing=""
while IFS= read -r h; do
	[[ -f "$ROOT/$h" ]] || missing+="${missing:+, }$h"
done < <(sed -n "/^HELPERS=(/,/)/p" "$ROOT/build/build-rx.sh" | tr -d '()' | sed 's/^HELPERS=//' | tr -s ' \t\n' '\n' | grep -v '^$')
if [[ -z $missing ]]; then ok "build-rx.sh HELPERS: every referenced source path exists in this repo layout"; else bad "build-rx.sh HELPERS: every referenced source path exists in this repo layout" "missing: $missing"; fi
if grep -q 'build/build-rx\.sh' "$ROOT/build/build-rx.sh" && ! grep -qE '^\s*build/build\.sh\b' "$ROOT/build/build-rx.sh"; then
	ok "build-rx.sh HELPERS: self-referenced as build/build-rx.sh, not build/build.sh"
else
	bad "build-rx.sh HELPERS: self-referenced as build/build-rx.sh, not build/build.sh" "$(grep -n 'build/build' "$ROOT/build/build-rx.sh")"
fi
if grep -qF "build/branding.patch" "$ROOT/build/build-rx.sh"; then ok "build-rx.sh HELPERS: includes build/branding.patch"; else bad "build-rx.sh HELPERS: includes build/branding.patch" "not found"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
