#!/usr/bin/env bash
# Tests for build/package.sh's tamper detection: every sha256 it is supposed to verify (both engine binaries,
# both patches) really is checked, and a mismatch on any one of them refuses to write a package - never a
# silent, mismatched artefact. Adapted from BloxMiner-X 1.0.0's gated provenance-tamper suite (same shape: one
# baseline success + one refusal per protected fact) to this package's extract-and-verify design (v3 never
# rebuilds either engine, so there is no "helper source changed since the build" case here - only "the shipped
# binary/patch no longer matches what its own provenance says" is meaningful, and is exactly what package.sh
# is asked to prove for every artefact it uses).
# Usage: tests/build/test_package_provenance.sh <verus-release-tarball> <verus-provenance> <rx-release-tarball>
#   (defaults to ~/c3work/frozen/{bloxminer-2.1.0.tar.gz,bloxminer-O3.provenance,bloxminer-x-1.0.0.tar.gz} -
#   the frozen, gated release artefacts - when run with no arguments)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
FROZEN=$HOME/c3work/frozen
VERUS_TGZ=${1:-$FROZEN/bloxminer-2.1.0.tar.gz}
VERUS_PROV=${2:-$FROZEN/bloxminer-O3.provenance}
RX_TGZ=${3:-$FROZEN/bloxminer-x-1.0.0.tar.gz}
[[ -f $VERUS_TGZ && -f $VERUS_PROV && -f $RX_TGZ ]] || { echo "SKIP: frozen release artefacts not found ($VERUS_TGZ / $VERUS_PROV / $RX_TGZ) - pass them as arguments"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-60s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-60s FAIL: %s\n' "$1" "$2"; }

# flip one byte of $2 well inside $1 (a tar.gz), rewritten as a NEW standalone file at $3 - never mutates the
# frozen original. Corrupting the compressed bytes directly is enough: package.sh must reject a tarball it
# cannot even decompress/verify cleanly exactly as readily as one whose sha256 merely differs.
tamper_tarball_bytes() {   # $1 = source tar.gz, $2 = dest tar.gz
	cp "$1" "$2"
	python3 - "$2" <<'PY'
import sys
p = sys.argv[1]
with open(p, "r+b") as f:
	f.seek(-200, 2)
	b = f.read(1)
	f.seek(-200, 2)
	f.write(bytes([b[0] ^ 0xFF]))
PY
}

run_pkg() {   # $1 verus_tgz $2 verus_prov $3 rx_tgz $4 outdir -> sets $rc $out
	local o=$4; mkdir -p "$o"
	out=$(bash "$ROOT/build/package.sh" "$1" "$2" "$3" "$o" 2>&1); rc=$?
}

# ---- 1: baseline, untampered - succeeds, both artefacts produced, sha256 in SHA256SUMS matches the frozen binaries
O="$T/ok"; run_pkg "$VERUS_TGZ" "$VERUS_PROV" "$RX_TGZ" "$O"
if [[ $rc == 0 && -f $O/bloxminer-3.0.0.tar.gz && -f $O/bloxminer-3.0.0-src.tar.gz && -f $O/SHA256SUMS ]] \
	&& grep -q "^3fd67be21d82c3fb62249fd612c1bbaea6743c21146340a489294d567acf0a88  bloxminer/bloxminer$" "$O/SHA256SUMS" \
	&& grep -q "^721aa3fc9a7a23f956e56e86208e2c8adc5cfb0b12df474fdc66063709e356ac  bloxminer/xmrig$" "$O/SHA256SUMS"
then
	ok "baseline: untampered inputs -> package.sh succeeds, both artefacts produced"
else
	bad "baseline: untampered inputs -> package.sh succeeds, both artefacts produced" "rc=$rc out=$out"
fi

# ---- 2: tampered Verus binary (inside a corrupted copy of the release tarball) -> refuses, no package written
BAD_VERUS="$T/bloxminer-2.1.0-bad.tar.gz"; tamper_tarball_bytes "$VERUS_TGZ" "$BAD_VERUS"
O="$T/bad-verus-bin"; run_pkg "$BAD_VERUS" "$VERUS_PROV" "$RX_TGZ" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]]; then ok "tampered verus release tarball -> package.sh refuses"; else bad "tampered verus release tarball -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 3: verus provenance's binary_sha256 doesn't match the (untampered) binary -> refuses
BAD_VPROV="$T/bloxminer-O3-badbin.provenance"; sed 's/^binary_sha256=.*/binary_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$VERUS_PROV" > "$BAD_VPROV"
O="$T/bad-verus-prov"; run_pkg "$VERUS_TGZ" "$BAD_VPROV" "$RX_TGZ" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "sha256" <<< "$out"; then ok "tampered verus provenance binary_sha256 -> package.sh refuses"; else bad "tampered verus provenance binary_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 4: verus provenance's libomp_sha256 doesn't match -> refuses
BAD_VPROV2="$T/bloxminer-O3-badlibomp.provenance"; sed 's/^libomp_sha256=.*/libomp_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$VERUS_PROV" > "$BAD_VPROV2"
O="$T/bad-libomp"; run_pkg "$VERUS_TGZ" "$BAD_VPROV2" "$RX_TGZ" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]]; then ok "tampered verus provenance libomp_sha256 -> package.sh refuses"; else bad "tampered verus provenance libomp_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 5: verus provenance's patch_sha256 no longer matches this repo's build/bloxminer.patch -> refuses
BAD_VPROV3="$T/bloxminer-O3-badpatch.provenance"; sed 's/^patch_sha256=.*/patch_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$VERUS_PROV" > "$BAD_VPROV3"
O="$T/bad-verus-patch"; run_pkg "$VERUS_TGZ" "$BAD_VPROV3" "$RX_TGZ" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "bloxminer.patch" <<< "$out"; then ok "tampered verus provenance patch_sha256 -> package.sh refuses"; else bad "tampered verus provenance patch_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 6: tampered RandomX release tarball (xmrig/bloxsense bytes corrupted) -> refuses
BAD_RX="$T/bloxminer-x-1.0.0-bad.tar.gz"; tamper_tarball_bytes "$RX_TGZ" "$BAD_RX"
O="$T/bad-rx"; run_pkg "$VERUS_TGZ" "$VERUS_PROV" "$BAD_RX" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]]; then ok "tampered rx release tarball -> package.sh refuses"; else bad "tampered rx release tarball -> package.sh refuses" "rc=$rc out=$out"; fi

# ---- 7: RandomX release tarball with a doctored build.provenance inside it (patch_sha256 no longer matches
#      this repo's build/donate0.patch) -> refuses. Rebuilds the tarball with only build.provenance edited, so
#      the binaries themselves stay byte-identical - this isolates the patch_sha256 check specifically.
RX_EDIT="$T/rx-edit"; mkdir -p "$RX_EDIT"; tar xzf "$RX_TGZ" -C "$RX_EDIT"
sed -i.bak 's/^patch_sha256=.*/patch_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$RX_EDIT/bloxminer-x/build.provenance"
BAD_RX2="$T/bloxminer-x-1.0.0-badprov.tar.gz"
tar --owner=0 --group=0 --numeric-owner -C "$RX_EDIT" -czf "$BAD_RX2" bloxminer-x
O="$T/bad-rx-patch"; run_pkg "$VERUS_TGZ" "$VERUS_PROV" "$BAD_RX2" "$O"
if [[ $rc != 0 && ! -f $O/bloxminer-3.0.0.tar.gz ]] && grep -qF "donate0.patch" <<< "$out"; then ok "tampered rx provenance patch_sha256 -> package.sh refuses"; else bad "tampered rx provenance patch_sha256 -> package.sh refuses" "rc=$rc out=$out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
