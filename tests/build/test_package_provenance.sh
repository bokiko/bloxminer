#!/usr/bin/env bash
# Tests for build/package.sh's tamper detection: every sha256/version fact it is supposed to verify (both
# engine binaries, both RandomX patches, both engines' declared version) really is checked, and a mismatch on
# any one of them refuses to write a package - never a silent, mismatched artefact. BloxMiner 3.0.0 REBUILDS
# both engines, so package.sh's inputs are the two engines' own build/build.sh and build/build-rx.sh OUTDIRS
# (binary + its own fresh provenance), not previously released tarballs - this suite tampers copies of those
# outdirs the same way the old suite tampered tarball copies: never the frozen originals.
# Usage: tests/build/test_package_provenance.sh <verus-build-outdir> <rx-build-outdir>
#   (defaults to ~/c3work/verus-out and ~/c3work/rx-out - the frozen, gated build outputs - when run with no
#   arguments; SKIPs cleanly if they are not found, exactly like the old suite did for its frozen tarballs)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
FROZEN=$HOME/c3work
VERUS_OUT=${1:-$FROZEN/verus-out}
RX_OUT=${2:-$FROZEN/rx-out}
[[ -f $VERUS_OUT/bloxminer-O3 && -f $VERUS_OUT/bloxminer-O3.provenance && -f $VERUS_OUT/libomp.so.5 && -f $RX_OUT/xmrig && -f $RX_OUT/bloxsense && -f $RX_OUT/build.provenance ]] || {
	echo "SKIP: frozen build outdirs not found ($VERUS_OUT / $RX_OUT) - pass them as arguments"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
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
