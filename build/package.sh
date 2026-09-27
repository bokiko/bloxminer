#!/usr/bin/env bash
# Assemble the HiveOS custom-miner release archive: bloxminer-<version>.tar.gz
# Usage (Ubuntu 22.04 x86-64): build/package.sh <path-to-built-ccminer> [outdir]
set -euo pipefail
BIN=${1:?path to ccminer built by build/build.sh}; OUT=${2:-$PWD}
HERE=$(cd "$(dirname "$0")/.." && pwd)
VER=$(sed -n 's/^CUSTOM_VERSION=//p' "$HERE/bloxminer/h-manifest.conf")
LIBOMP=/usr/lib/llvm-14/lib/libomp.so.5   # from Ubuntu 22.04 package libomp5-14
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir "$W/bloxminer"
cp "$HERE"/bloxminer/h-config.sh "$HERE"/bloxminer/h-run.sh "$HERE"/bloxminer/h-stats.sh "$HERE"/bloxminer/h-manifest.conf "$W/bloxminer/"
cp "$BIN" "$W/bloxminer/ccminer"; cp -L "$LIBOMP" "$W/bloxminer/libomp.so.5"
# distribution notices: GPL for ccminer/BloxMiner, LLVM license for libomp, and where the exact source is
cp "$HERE/LICENSE" "$W/bloxminer/LICENSE"
cp /usr/share/doc/libomp5-14/copyright "$W/bloxminer/LICENSE.libomp"
COMMIT=$(sed -n 's/^COMMIT=\${COMMIT:-\([0-9a-f]*\)}.*/\1/p' "$HERE/build/build.sh")
cat > "$W/bloxminer/SOURCE.md" <<SRC
BloxMiner $VER — corresponding source (GPL-3.0)
ccminer: https://github.com/monkins1010/ccminer (branch Verus2.2) at commit $COMMIT
patch + build script: https://github.com/bokiko/bloxminer/tree/$VER/build (bloxminer.patch, build.sh)
compiler: $(clang-14 --version | head -1)
ccminer sha256: $(sha256sum "$BIN" | cut -d' ' -f1)
libomp.so.5: Ubuntu 22.04 package libomp5-14 $(dpkg-query -W -f='${Version}' libomp5-14 2>/dev/null) (Apache-2.0 WITH LLVM-exception, see LICENSE.libomp)
SRC
chmod 755 "$W/bloxminer" "$W/bloxminer"/*.sh "$W/bloxminer/ccminer"; chmod 644 "$W/bloxminer/h-manifest.conf" "$W/bloxminer/libomp.so.5" "$W/bloxminer/LICENSE" "$W/bloxminer/LICENSE.libomp" "$W/bloxminer/SOURCE.md"
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-09-27 00:00:00Z' -C "$W" -czf "$OUT/bloxminer-$VER.tar.gz" bloxminer
cd "$OUT"; sha256sum "bloxminer-$VER.tar.gz"; (cd "$W/bloxminer" && sha256sum ccminer libomp.so.5)
