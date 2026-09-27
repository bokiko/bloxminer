#!/usr/bin/env bash
# Reproducible build of the patched ccminer for the HiveOS package.
# Host: Ubuntu 22.04 x86_64 (HiveOS 22.04 base). Usage: build/build.sh [-O2|-O3] [outdir]
set -euo pipefail
OPT=${1:--O3}; OUT=${2:-$PWD/out}
UPSTREAM=${UPSTREAM:-https://github.com/monkins1010/ccminer.git}
COMMIT=${COMMIT:-e28e183}   # Verus2.2 "Show thread hashrate (#33)", 2025-03-08
ARCH=${ARCH:-"-march=x86-64-v3 -mtune=znver3 -maes -mpclmul -fno-strict-aliasing"}   # -mtune=znver3 closed a 2% gap vs Oink 3.8.3a on 5950X (see BENCHMARKS.md)
HERE=$(cd "$(dirname "$0")" && pwd)

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git build-essential automake autotools-dev \
  clang-14 libomp-14-dev libstdc++-12-dev patchelf libcurl4-openssl-dev libssl-dev libjansson-dev zlib1g-dev >/dev/null

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
git clone -q -b Verus2.2 "$UPSTREAM" "$W/src"; cd "$W/src"; git checkout -q "$COMMIT"
patch -p1 < "${PATCH:-$HERE/bloxminer.patch}"
./autogen.sh >/dev/null 2>&1
CC=clang-14 CXX=clang++-14 CFLAGS="" CXXFLAGS="" ./configure >/dev/null
make -j"$(nproc)" HIVE_ARCH_FLAGS="$ARCH" HIVE_OPT="$OPT" >/dev/null
patchelf --set-rpath '$ORIGIN' ccminer   # bundled libomp.so.5 is found next to the binary
mkdir -p "$OUT"; cp ccminer "$OUT/ccminer${TAG:-}$OPT"
echo "built $OUT/ccminer${TAG:-}$OPT  commit=$COMMIT  cc=$(clang-14 --version | head -1)  flags=$ARCH $OPT"
sha256sum "$OUT/ccminer${TAG:-}$OPT"
