#!/usr/bin/env bash
# Tests for build/package.sh's own version-mismatch opt-in gate (BLOX_PACKAGE_ALLOW_VERSION_MISMATCH).
# Needs a real Ubuntu 22.04 host/container with the libomp5-14 package installed (same requirement
# build/package.sh itself has) - SKIPs cleanly elsewhere, the same convention tests/engine/* uses.
# Usage: tests/build/test_package.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
LIBOMP=/usr/lib/llvm-14/lib/libomp.so.5
if [[ ! -f $LIBOMP ]] || [[ ! -f /usr/share/doc/libomp5-14/copyright ]] || [[ ! -f /usr/share/common-licenses/Apache-2.0 ]]; then
	echo "SKIP: needs Ubuntu 22.04 + libomp5-14 (same host requirement as build/package.sh itself)"
	exit 0
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }

VER=$(sed -n 's/^CUSTOM_VERSION=//p' "$REPO/bloxminer/h-manifest.conf")
PATCH_SHA=$(sha256sum "$REPO/build/bloxminer.patch" | cut -d' ' -f1)
LIBOMP_SHA=$(sha256sum "$LIBOMP" | cut -d' ' -f1)

# A fake binary - content is irrelevant, package.sh never runs it, only hashes it and copies it. Every OTHER
# provenance field (binary_sha256/patch_sha256/libomp_sha256) is made to match this real host/repo exactly, so
# the ONLY thing varied across cases below is `version` vs. $VER and the opt-in env var - an isolated test of
# the gate itself, not of build/build.sh's own output.
BIN="$T/bloxminer-O3"
printf 'not a real binary, only its sha256 matters to package.sh' > "$BIN"
BIN_SHA=$(sha256sum "$BIN" | cut -d' ' -f1)

make_prov() {  # $1 = version field value
	cat > "$BIN.provenance" <<EOF
binary_sha256=$BIN_SHA
version=$1
upstream=https://github.com/monkins1010/ccminer.git
upstream_commit=0000000000000000000000000000000000000000
patch_sha256=$PATCH_SHA
arch_flags=-march=x86-64-v3 -mtune=znver3 -maes -mpclmul -fno-strict-aliasing
opt=-O3
compiler=test
glibc_min=GLIBC_2.34
libomp_sha256=$LIBOMP_SHA
os=test
EOF
}

run_pkg() {  # $1 = BLOX_PACKAGE_ALLOW_VERSION_MISMATCH value, or "unset" -> sets $out $rc
	local outdir; outdir=$(mktemp -d)
	if [[ $1 == unset ]]; then
		out=$(cd "$REPO" && bash build/package.sh "$BIN" "$outdir" 2>&1); rc=$?
	else
		out=$(cd "$REPO" && BLOX_PACKAGE_ALLOW_VERSION_MISMATCH=$1 bash build/package.sh "$BIN" "$outdir" 2>&1); rc=$?
	fi
	rm -rf "$outdir"
}

# ---- matching version: no gate involved at all, must always succeed regardless of the opt-in var
make_prov "$VER"
run_pkg unset
if [[ $rc == 0 ]]; then ok "version matches manifest: packages with no opt-in needed"; else bad "version matches manifest: packages with no opt-in needed" "rc=$rc out=$out"; fi

# ---- mismatched version: gate must refuse unless the opt-in is EXACTLY "1"
make_prov "1.9.9"
for v in unset 0 false yes " 1" "1 " "true" ""; do
	run_pkg "$v"
	if [[ $rc != 0 ]] && grep -qF "BLOX_PACKAGE_ALLOW_VERSION_MISMATCH" <<< "$out"; then
		ok "mismatched version, opt-in='$v': refused"
	else
		bad "mismatched version, opt-in='$v': refused" "rc=$rc out=$out"
	fi
done
run_pkg 1
if [[ $rc == 0 ]] && grep -qF "packaging the existing binary under the new package version" <<< "$out"; then
	ok "mismatched version, opt-in=1 (exact): allowed"
else
	bad "mismatched version, opt-in=1 (exact): allowed" "rc=$rc out=$out"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
