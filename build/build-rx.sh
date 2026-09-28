#!/usr/bin/env bash
# Reproducible-inputs build of BloxMiner-X: XMRig 6.26.0 (0% donate patch) + bloxsense, both static, for the
# HiveOS package. Host: stock Ubuntu 22.04 x86_64 (container/chroot), run as root.
# Usage: build/build.sh [outdir]
# Writes <outdir>/xmrig, <outdir>/bloxsense, <outdir>/build.provenance (including the sha256 of every helper
# source file at build time - see HELPERS below - which build/package.sh later re-verifies before packaging).
set -euo pipefail

OUT=${1:-$PWD/out}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)   # absolute before any cd
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PATCH="$HERE/donate0.patch"

UPSTREAM=https://github.com/xmrig/xmrig
TAG=v6.26.0
COMMIT=b2ca72480c58d197e18c885d9fc1a0c8d517e60a   # pinned tag commit; build fails if the clone disagrees

# "helper" source files (everything BloxMiner-X adds on top of XMRig): their sha256, AS THEY EXIST RIGHT NOW
# at build time, is recorded in build.provenance below. build/package.sh recomputes these same hashes from the
# files it is about to ship and refuses to package if any of them changed since this build - so a package can
# never ship helper sources that do not match the binary they are shipped next to.
HELPERS=(bloxsense/blox.h bloxsense/blox_sys.cpp bloxsense/bloxsense.cpp
         bloxminer-x/h-config.sh bloxminer-x/h-run.sh bloxminer-x/h-stats.sh bloxminer-x/h-manifest.conf
         build/build.sh build/package.sh build/donate0.patch)

# Dependency tarballs xmrig's own scripts/build.uv.sh, build.hwloc.sh, build.openssl3.sh fetch for this tag,
# pinned by sha256 computed by hand from these exact URLs (upstream ships no checksums for them).
UV_VER=1.51.0
UV_URL="https://dist.libuv.org/dist/v${UV_VER}/libuv-v${UV_VER}.tar.gz"
UV_SHA256=5f0557b90b1106de71951a3c3931de5e0430d78da1d9a10287ebc7a3f78ef8eb

HWLOC_VER=2.12.1
HWLOC_URL="https://download.open-mpi.org/release/hwloc/v2.12/hwloc-${HWLOC_VER}.tar.gz"
HWLOC_SHA256=ffa02c3a308275a9339fbe92add054fac8e9a00cb8fe8c53340094012cb7c633

SSL_VER=3.0.16
SSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${SSL_VER}/openssl-${SSL_VER}.tar.gz"
SSL_SHA256=57e03c50feab5d31b152af2b764f10379aecd8ee92f16c985983ce4a99f7ef86

id -u >/dev/null 2>&1   # sanity: a shell exists
[[ $(id -u) == 0 ]] || { echo "build/build.sh must run as root in a stock Ubuntu 22.04 container/chroot" >&2; exit 1; }
[[ -f /etc/os-release ]] && grep -q '^VERSION_ID="22.04"' /etc/os-release || echo "warning: not detected as Ubuntu 22.04; proceeding anyway" >&2

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
DEPS=(build-essential cmake git wget ca-certificates pkg-config autoconf automake libtool perl python3 file binutils)
apt-get install -y -qq "${DEPS[@]}" >/dev/null

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
DL="$W/dl"; DEPSDIR="$W/deps"; mkdir -p "$DL" "$DEPSDIR/include" "$DEPSDIR/lib"

fetch_verify() {   # url sha256 outfile
	wget -q -O "$3" "$1"
	local got; got=$(sha256sum "$3" | cut -d' ' -f1)
	[[ $got == "$2" ]] || { echo "checksum mismatch for $3: got $got, want $2" >&2; exit 1; }
}

# ---------------------------------------------------------------- xmrig source, pinned to the exact commit
git clone -q --branch "$TAG" "$UPSTREAM" "$W/src"
cd "$W/src"
FULL=$(git rev-parse HEAD)
[[ $FULL == "$COMMIT" ]] || { echo "xmrig $TAG resolved to $FULL, expected $COMMIT - refusing to build" >&2; exit 1; }
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
export SOURCE_DATE_EPOCH
patch -p1 < "$PATCH"
# the only source change vs upstream must be donate.h
DIFF_FILES=$(git diff --name-only)
[[ $DIFF_FILES == "src/donate.h" ]] || { echo "patch touched more than src/donate.h: $DIFF_FILES" >&2; exit 1; }

PREFIX_MAP="-ffile-prefix-map=$W=."   # strip the build tree's absolute path out of both binaries
export CFLAGS="-O2 $PREFIX_MAP"
export CXXFLAGS="-O2 $PREFIX_MAP"

# ---------------------------------------------------------------- static libuv (xmrig scripts/build.uv.sh)
fetch_verify "$UV_URL" "$UV_SHA256" "$DL/libuv-v${UV_VER}.tar.gz"
tar -xzf "$DL/libuv-v${UV_VER}.tar.gz" -C "$W"
( cd "$W/libuv-v${UV_VER}" && sh autogen.sh && ./configure --disable-shared >/dev/null && make -j"$(nproc)" >/dev/null
  cp -r include "$DEPSDIR/" && cp .libs/libuv.a "$DEPSDIR/lib/" )

# ---------------------------------------------------------------- static hwloc (xmrig scripts/build.hwloc.sh)
fetch_verify "$HWLOC_URL" "$HWLOC_SHA256" "$DL/hwloc-${HWLOC_VER}.tar.gz"
tar -xzf "$DL/hwloc-${HWLOC_VER}.tar.gz" -C "$W"
( cd "$W/hwloc-${HWLOC_VER}" && ./configure --disable-shared --enable-static --disable-io --disable-libudev --disable-libxml2 >/dev/null
  make -j"$(nproc)" >/dev/null
  cp -r include "$DEPSDIR/" && cp hwloc/.libs/libhwloc.a "$DEPSDIR/lib/" )

# ---------------------------------------------------------------- static OpenSSL 3 (xmrig scripts/build.openssl3.sh)
fetch_verify "$SSL_URL" "$SSL_SHA256" "$DL/openssl-${SSL_VER}.tar.gz"
tar -xzf "$DL/openssl-${SSL_VER}.tar.gz" -C "$W"
( cd "$W/openssl-${SSL_VER}" && ./config -no-shared -no-asm -no-zlib -no-comp -no-dgram -no-filenames -no-cms >/dev/null
  make -j"$(nproc)" >/dev/null
  cp -r include "$DEPSDIR/" && cp libcrypto.a libssl.a "$DEPSDIR/lib/" )

# ---------------------------------------------------------------- xmrig itself: static, no OpenCL/CUDA
cmake -S "$W/src" -B "$W/build" -DCMAKE_BUILD_TYPE=Release \
	-DXMRIG_DEPS="$DEPSDIR" -DWITH_OPENCL=OFF -DWITH_CUDA=OFF -DBUILD_STATIC=ON \
	-DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" >/dev/null
cmake --build "$W/build" -j"$(nproc)" >/dev/null
cp "$W/build/xmrig" "$OUT/xmrig"

# ---------------------------------------------------------------- bloxsense: plain -O2, static, no xmrig deps
g++ -std=c++17 -O2 -Wall -Wextra -static -static-libgcc -static-libstdc++ "$PREFIX_MAP" \
	-I"$ROOT/bloxsense" "$ROOT/bloxsense/bloxsense.cpp" "$ROOT/bloxsense/blox_sys.cpp" -o "$OUT/bloxsense"

# ---------------------------------------------------------------- provenance
GCCV=$(gcc --version | head -1)
GXXV=$(g++ --version | head -1)
CMAKEV=$(cmake --version | head -1)
{
	echo "upstream=$UPSTREAM"
	echo "upstream_tag=$TAG"
	echo "upstream_commit=$FULL"
	echo "patch_sha256=$(sha256sum "$PATCH" | cut -d' ' -f1)"
	echo "dep.libuv.version=$UV_VER"
	echo "dep.libuv.url=$UV_URL"
	echo "dep.libuv.sha256=$UV_SHA256"
	echo "dep.hwloc.version=$HWLOC_VER"
	echo "dep.hwloc.url=$HWLOC_URL"
	echo "dep.hwloc.sha256=$HWLOC_SHA256"
	echo "dep.openssl.version=$SSL_VER"
	echo "dep.openssl.url=$SSL_URL"
	echo "dep.openssl.sha256=$SSL_SHA256"
	echo "source_date_epoch=$SOURCE_DATE_EPOCH"
	echo "cflags=$CFLAGS"
	echo "cxxflags=$CXXFLAGS"
	echo "compiler.gcc=$GCCV"
	echo "compiler.gxx=$GXXV"
	echo "compiler.cmake=$CMAKEV"
	echo "os=$(. /etc/os-release && echo "$PRETTY_NAME")"
	echo "xmrig_sha256=$(sha256sum "$OUT/xmrig" | cut -d' ' -f1)"
	echo "bloxsense_sha256=$(sha256sum "$OUT/bloxsense" | cut -d' ' -f1)"
	for h in "${HELPERS[@]}"; do
		echo "helper.$h.sha256=$(sha256sum "$ROOT/$h" | cut -d' ' -f1)"
	done
} > "$OUT/build.provenance"

echo "built $OUT/xmrig and $OUT/bloxsense"
cat "$OUT/build.provenance"
echo "--- readelf -d (expect no NEEDED: both binaries are static) ---"
for b in xmrig bloxsense; do
	echo "== $b =="
	readelf -d "$OUT/$b" || true
done
