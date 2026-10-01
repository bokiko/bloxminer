#!/usr/bin/env bash
# Assemble the HiveOS custom-miner release archive bloxminer-<version>.tar.gz (deterministic tar) + SHA256SUMS.
# Usage (Ubuntu 22.04 x86-64): build/package.sh <binary built by build/build.sh> [outdir]
# The binary must have its <binary>.provenance next to it; the package's SOURCE.md is generated from it.
set -euo pipefail
BIN=${1:?path to the binary built by build/build.sh}
OUT=${2:-$PWD}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROV="$BIN.provenance"
[[ -f $PROV ]] || { echo "missing $PROV (build with build/build.sh)"; exit 1; }
p() { sed -n "s/^$1=//p" "$PROV"; }
[[ $(p binary_sha256) == $(sha256sum "$BIN" | cut -d' ' -f1) ]] || { echo "$PROV does not describe $BIN (sha256 differs)"; exit 1; }
[[ $(p patch_sha256) == $(sha256sum "$HERE/build/bloxminer.patch" | cut -d' ' -f1) ]] || { echo "binary was built from a different bloxminer.patch"; exit 1; }
VER=$(sed -n 's/^CUSTOM_VERSION=//p' "$HERE/bloxminer/h-manifest.conf")
ENGINE_VER=$(p version)
# A scripts-only hotfix (this file's own caller may package an unchanged, already-gated binary under a NEW
# package version - see bloxminer/h-stats.sh's own header: it shows $CUSTOM_VERSION, never the engine's raw API
# VER, for exactly this reason) legitimately has ENGINE_VER != VER. That must stay an explicit, opt-in decision
# (BLOX_PACKAGE_ALLOW_VERSION_MISMATCH=1), never a silent default - this check exists to catch an accidentally
# stale/wrong binary being shipped under the wrong version number, and only the caller packaging a deliberate
# hotfix knows the mismatch here is expected rather than a mistake.
if [[ $ENGINE_VER != "$VER" ]]; then
	# Exact-match the opt-in to the literal string "1" - anything else (unset, empty, "0", "false", "yes", a
	# typo) must leave the gate closed. `[[ -n ... ]]` treated ANY non-empty value as "yes", so an operator
	# setting BLOX_PACKAGE_ALLOW_VERSION_MISMATCH=0 to mean "no" (a common shell convention elsewhere) would
	# have silently been let through by this gate - the one place this check exists to prevent an accidental
	# mismatched ship, defeated by the most natural-looking way to write "false".
	[[ ${BLOX_PACKAGE_ALLOW_VERSION_MISMATCH:-} == 1 ]] || {
		echo "binary version $ENGINE_VER != h-manifest.conf CUSTOM_VERSION $VER (scripts-only hotfix? set BLOX_PACKAGE_ALLOW_VERSION_MISMATCH=1, exactly \"1\", to package this already-verified binary under the new package version - any other value, including 0/false/yes, is treated as not set)"
		exit 1
	}
	echo "binary version $ENGINE_VER != h-manifest.conf CUSTOM_VERSION $VER - BLOX_PACKAGE_ALLOW_VERSION_MISMATCH=1 is set, packaging the existing binary under the new package version"
fi
LIBOMP=/usr/lib/llvm-14/lib/libomp.so.5   # from Ubuntu 22.04 package libomp5-14
[[ $(p libomp_sha256) == $(sha256sum "$LIBOMP" | cut -d' ' -f1) ]] || { echo "this host's libomp.so.5 differs from the one the binary was built with"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D="$W/bloxminer"; mkdir "$D"
cp "$HERE"/bloxminer/h-config.sh "$HERE"/bloxminer/h-run.sh "$HERE"/bloxminer/h-stats.sh "$HERE"/bloxminer/h-manifest.conf "$D/"
cp "$BIN" "$D/bloxminer"; cp -L "$LIBOMP" "$D/libomp.so.5"
# distribution notices: GPL-3.0 for BloxMiner/ccminer; libomp's copyright file plus the full Apache-2.0 text it refers to
cp "$HERE/LICENSE" "$D/LICENSE"
cp /usr/share/doc/libomp5-14/copyright "$D/LICENSE.libomp"
cp /usr/share/common-licenses/Apache-2.0 "$D/LICENSE.Apache-2.0"
ENGINE_NOTE=""
[[ $ENGINE_VER != "$VER" ]] && ENGINE_NOTE="
This is a scripts-only release: the engine binary is unchanged from the $ENGINE_VER package (same build,
same sha256 below) - only bloxminer/*.sh changed. See CHANGES.md."
cat > "$D/SOURCE.md" <<SRC
BloxMiner $VER - corresponding source (GPL-3.0)
$ENGINE_NOTE
The bloxminer binary is monkins1010/ccminer (branch Verus2.2) at commit $(p upstream_commit)
with build/bloxminer.patch applied, built by build/build.sh:
  https://github.com/bokiko/bloxminer/tree/$VER/build

bloxminer sha256        $(p binary_sha256)
bloxminer.patch sha256  $(p patch_sha256)
compiler                $(p compiler)
flags                   $(p arch_flags) $(p opt)
build OS                $(p os)
needs                   $(p glibc_min) or newer (Ubuntu 22.04+)

Build packages (a rebuild with these versions reproduces the binary bit for bit):
$(sed -n 's/^pkg\.\([^=]*\)=/  \1 /p' "$PROV")

libomp.so.5: Ubuntu 22.04 package libomp5-14 $(p pkg.libomp5-14), Apache-2.0 WITH LLVM-exception
(see LICENSE.libomp and LICENSE.Apache-2.0).
SRC
chmod 755 "$D" "$D"/*.sh "$D/bloxminer"
chmod 644 "$D/h-manifest.conf" "$D/libomp.so.5" "$D/LICENSE" "$D/LICENSE.libomp" "$D/LICENSE.Apache-2.0" "$D/SOURCE.md"
TGZ="bloxminer-$VER.tar.gz"
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-09-27 00:00:00Z' -C "$W" -cf - bloxminer | gzip -n -9 > "$OUT/$TGZ"
cd "$OUT"
{ sha256sum "$TGZ"; (cd "$D" && sha256sum bloxminer libomp.so.5 | sed 's#  #  bloxminer/#'); } > SHA256SUMS
cat SHA256SUMS
