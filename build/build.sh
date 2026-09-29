#!/usr/bin/env bash
# Reproducible build of the BloxMiner engine (patched ccminer) for the HiveOS package.
# Host: stock Ubuntu 22.04 x86_64 (chroot/container), NOT a HiveOS rig: Hive pins libssl-dev 1.1.1l-hiveos,
# which links OpenSSL 1.1 next to libcurl's OpenSSL 3 in one process. Usage: build/build.sh [-O2|-O3] [outdir]
# Writes <outdir>/bloxminer<TAG><OPT> and <outdir>/bloxminer<TAG><OPT>.provenance (inputs + toolchain versions).
set -euo pipefail
OPT=${1:--O3}
OUT=${2:-$PWD/out}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)   # absolute before any cd
UPSTREAM=${UPSTREAM:-https://github.com/monkins1010/ccminer.git}
COMMIT=${COMMIT:-e28e183}   # Verus2.2 "Show thread hashrate (#33)", 2025-03-08
ARCH=${ARCH:-"-march=x86-64-v3 -mtune=znver3 -maes -mpclmul -fno-strict-aliasing"}   # -mtune=znver3 closed a 2% gap vs Oink 3.8.3a on 5950X (see BENCHMARKS.md)
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=${PATCH:-$HERE/bloxminer.patch}
DEPS=(clang-14 libomp-14-dev libomp5-14 libstdc++-12-dev libc6-dev binutils autoconf automake autotools-dev make patchelf
      libcurl4-openssl-dev libssl-dev libjansson-dev zlib1g-dev git)

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${DEPS[@]}" build-essential >/dev/null
SSLDEV=$(dpkg-query -W -f='${Version}' libssl-dev)
[[ $SSLDEV == 3.* ]] || { echo "libssl-dev $SSLDEV is not OpenSSL 3 (HiveOS rig?) - build in a stock Ubuntu 22.04 chroot/container" >&2; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
git clone -q -b Verus2.2 "$UPSTREAM" "$W/src"; cd "$W/src"; git checkout -q "$COMMIT"
FULL=$(git rev-parse HEAD)
patch -p1 < "$PATCH"
./autogen.sh >/dev/null 2>&1
CC=clang-14 CXX=clang++-14 CFLAGS="" CXXFLAGS="" ./configure >/dev/null
make -j"$(nproc)" HIVE_ARCH_FLAGS="$ARCH" HIVE_OPT="$OPT" >/dev/null
# shellcheck disable=SC2016   # literal $ORIGIN: the dynamic loader expands it
patchelf --set-rpath '$ORIGIN' ccminer   # bundled libomp.so.5 is found next to the binary
BIN="$OUT/bloxminer${TAG:-}$OPT"
cp ccminer "$BIN"
cp -L /usr/lib/llvm-14/lib/libomp.so.5 "$OUT/libomp.so.5"   # the exact runtime the binary above was linked/rpathed against

GLIBC=$(objdump -T "$BIN" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
{
	echo "binary_sha256=$(sha256sum "$BIN" | cut -d' ' -f1)"
	echo "version=$(sed -n 's/^AC_INIT(\[[^]]*\], \[\([^]]*\)\].*/\1/p' configure.ac)"
	echo "upstream=$UPSTREAM"
	echo "upstream_commit=$FULL"
	echo "patch_sha256=$(sha256sum "$PATCH" | cut -d' ' -f1)"
	echo "arch_flags=$ARCH"
	echo "opt=$OPT"
	echo "compiler=$(clang-14 --version | head -1)"
	echo "glibc_min=$GLIBC"
	echo "libomp_sha256=$(sha256sum /usr/lib/llvm-14/lib/libomp.so.5 | cut -d' ' -f1)"   # the runtime the package must ship
	echo "os=$(. /etc/os-release && echo "$PRETTY_NAME")"
	for p in "${DEPS[@]}"; do echo "pkg.$p=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo missing)"; done
} > "$BIN.provenance"
echo "built $BIN  commit=$FULL  $(grep ^compiler= "$BIN.provenance")  flags=$ARCH $OPT  needs $GLIBC"
sha256sum "$BIN"
