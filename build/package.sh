#!/usr/bin/env bash
# Assemble the combined HiveOS custom-miner release bloxminer-<version>.tar.gz (deterministic tar) + SHA256SUMS,
# plus the GPL "Corresponding Source" bundle bloxminer-<version>-src.tar.gz. BloxMiner 3.0.0 REBUILDS both
# engines (Verus: AC_INIT version bump only; RandomX: a second, display-only patch on top of donate0.patch) -
# this script consumes their freshly built outdirs directly and checks every binary's sha256 against that
# build's OWN recorded provenance (see README/SOURCE.md and C6-BRANDING.md for the hashing/object-identity
# proofs that neither engine's actual mining code changed).
# Usage: build/package.sh <verus-build-outdir> <rx-build-outdir> [outdir]
#   <verus-build-outdir>  output of build/build.sh   (bloxminer-O3, bloxminer-O3.provenance, libomp.so.5)
#   <rx-build-outdir>     output of build/build-rx.sh (xmrig, bloxsense, build.provenance)
# Needs: git, patch, tar, gzip, sha256sum, network access to github.com (only for the -src bundle: it re-clones
# both upstream engines to prove the two patches are the entire, exact difference - see the tag/commit checks below).
set -euo pipefail
VERUS_OUT=${1:?path to build/build.sh outdir (bloxminer-O3, bloxminer-O3.provenance, libomp.so.5)}
RX_OUT=${2:?path to build/build-rx.sh outdir (xmrig, bloxsense, build.provenance)}
OUT=${3:-$PWD}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
VER=$(sed -n 's/^CUSTOM_VERSION=//p' "$ROOT/bloxminer/h-manifest.conf")
[[ -d $VERUS_OUT && -d $RX_OUT ]] || { echo "usage: build/package.sh <verus-build-outdir> <rx-build-outdir> [outdir]"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# ---------------------------------------------------------------- verify: Verus (VerusHash) engine, freshly built
VBIN="$VERUS_OUT/bloxminer-O3"; VLIBOMP="$VERUS_OUT/libomp.so.5"; VERUS_PROV="$VERUS_OUT/bloxminer-O3.provenance"
[[ -f $VBIN && -f $VLIBOMP && -f $VERUS_PROV ]] || { echo "$VERUS_OUT: missing bloxminer-O3{,.provenance}/libomp.so.5 - run build/build.sh first"; exit 1; }
p_verus() { sed -n "s|^$1=||p" "$VERUS_PROV"; }
[[ $(p_verus binary_sha256) == "$(sha256sum "$VBIN" | cut -d' ' -f1)" ]] || { echo "verus binary sha256 does not match $VERUS_PROV"; exit 1; }
[[ $(p_verus libomp_sha256) == "$(sha256sum "$VLIBOMP" | cut -d' ' -f1)" ]] || { echo "libomp.so.5 sha256 does not match $VERUS_PROV"; exit 1; }
[[ $(p_verus patch_sha256) == "$(sha256sum "$ROOT/build/bloxminer.patch" | cut -d' ' -f1)" ]] || { echo "verus provenance patch_sha256 does not match this repo's build/bloxminer.patch"; exit 1; }
[[ $(p_verus version) == "$VER" ]] || { echo "verus provenance version ($(p_verus version)) does not match package version $VER"; exit 1; }

# ---------------------------------------------------------------- verify: RandomX engine, freshly built (donate0
# + branding patches both applied by build/build-rx.sh; its own build.provenance travels with the outdir)
XBIN="$RX_OUT/xmrig"; XSENSE="$RX_OUT/bloxsense"; RXPROV="$RX_OUT/build.provenance"
[[ -f $XBIN && -f $XSENSE && -f $RXPROV ]] || { echo "$RX_OUT: missing xmrig/bloxsense/build.provenance - run build/build-rx.sh first"; exit 1; }
p_rx() { sed -n "s|^$1=||p" "$RXPROV"; }
[[ $(p_rx xmrig_sha256) == "$(sha256sum "$XBIN" | cut -d' ' -f1)" ]] || { echo "xmrig sha256 does not match $RXPROV"; exit 1; }
[[ $(p_rx bloxsense_sha256) == "$(sha256sum "$XSENSE" | cut -d' ' -f1)" ]] || { echo "bloxsense sha256 does not match $RXPROV"; exit 1; }
[[ $(p_rx patch_sha256) == "$(sha256sum "$ROOT/build/donate0.patch" | cut -d' ' -f1)" ]] || { echo "rx provenance patch_sha256 does not match this repo's build/donate0.patch"; exit 1; }
[[ $(p_rx branding_patch_sha256) == "$(sha256sum "$ROOT/build/branding.patch" | cut -d' ' -f1)" ]] || { echo "rx provenance branding_patch_sha256 does not match this repo's build/branding.patch"; exit 1; }
[[ $(p_rx blox_display_version) == "$VER" ]] || { echo "rx provenance blox_display_version ($(p_rx blox_display_version)) does not match package version $VER"; exit 1; }

# bloxsense is compiled from these three sources (build/build-rx.sh's own HELPERS list, recorded at build
# time as helper.bloxsense/<file>.sha256); the binary above is only verified against the bytes it actually
# WAS built from - it says nothing about the sources THIS repo is about to ship next to it. Refuse to package
# if any of the three has changed since that build, exactly as if the binary itself had changed.
for BS in blox.h blox_sys.cpp bloxsense.cpp; do
	[[ $(p_rx "helper.bloxsense/$BS.sha256") == "$(sha256sum "$ROOT/bloxsense/$BS" | cut -d' ' -f1)" ]] ||
		{ echo "bloxsense/$BS does not match its recorded source hash in $RXPROV - refusing to package"; exit 1; }
done

REPO_COMMIT=${BLOXMINER_REPO_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}

# combined provenance: the two engines' own freshly recorded build provenance kept verbatim (namespaced
# verus./rx.), plus this integration's own facts - never mutates either original provenance file.
AUGPROV="$W/build.provenance"
{
	echo "package=bloxminer"
	echo "package_version=$VER"
	echo "repo_commit=$REPO_COMMIT"
	sed 's/^/verus./' "$VERUS_PROV"
	sed 's/^/rx./' "$RXPROV"
	# dispatcher.*: this integration's own new scripts (neither engine's own gated release ever shipped or
	# recorded these - they exist only from this repo commit forward), recorded here so a later package can be
	# checked against this one the same way the two engines' own binaries already are.
	for D in h-common.sh h-config.sh h-run.sh h-stats.sh; do
		echo "dispatcher.$D.sha256=$(sha256sum "$ROOT/bloxminer/$D" | cut -d' ' -f1)"
	done
} > "$AUGPROV"

gen_source_md() {   # $1 = "binary" or "src"
	cat <<SRC
BloxMiner $VER - corresponding source (GPL-3.0)

BloxMiner $VER mines both VerusHash (Verus engine) and RandomX (RandomX engine); the flight-sheet algorithm
picks which one runs (see README.md). BOTH engines are rebuilt for this release, from their own previously
gated sources (2.1.0 / X 1.0.0) plus one small, precisely scoped change each - not "byte-identical" claims but
verified, narrower ones: the Verus engine's own AC_INIT release number moves 2.1.0 -> 3.0.0 (every hashing
function - verus/haraka/clhash/scanhash - is instruction-identical to the 2.1.0 binary; only the version string
differs; libomp.so.5 is untouched); the RandomX engine gets one extra display-only patch, build/branding.patch,
on top of build/donate0.patch (two cosmetic log lines only - XMRig's own APP_VERSION/user-agent/API version stay
"6.26.0" for pool/API compatibility; every object outside the touched source files is byte-identical). Full
proof output (hashing-identity tool, per-object binary diff, xmrig --bench=1M) is in this release's own
C6-BRANDING.md, kept with the repo. Both binaries are verified against their own recorded provenance below
before packaging.

Verus engine (bloxminer binary): monkins1010/ccminer at commit $(p_verus upstream_commit)
with build/bloxminer.patch applied (version bump 2.1.0 -> 3.0.0 only vs the 2.1.0 patch; see git history):
  bloxminer sha256        $(p_verus binary_sha256)
  libomp.so.5 sha256      $(p_verus libomp_sha256)
  bloxminer.patch sha256  $(p_verus patch_sha256)
  compiler                $(p_verus compiler)
  flags                   $(p_verus arch_flags) $(p_verus opt)
  build OS                $(p_verus os)
  libomp.so.5: Ubuntu 22.04 package libomp5-14, Apache-2.0 WITH LLVM-exception (LICENSE.libomp, LICENSE.Apache-2.0)

RandomX engine (xmrig binary): xmrig/xmrig at tag $(p_rx upstream_tag), commit $(p_rx upstream_commit),
with build/donate0.patch (src/donate.h, 1% -> 0% donation) AND build/branding.patch (display-only BloxMiner
version strings; src/version_blox.h, src/base/kernel/config/BaseConfig.cpp, src/core/Miner.cpp) both applied:
  xmrig sha256               $(p_rx xmrig_sha256)
  bloxsense sha256           $(p_rx bloxsense_sha256)
  donate0.patch sha256       $(p_rx patch_sha256)
  branding.patch sha256      $(p_rx branding_patch_sha256)
  BLOX_DISPLAY_VERSION       $(p_rx blox_display_version)
  compiler (xmrig)           $(p_rx compiler.gcc)
  compiler (bloxsense)       $(p_rx compiler.gxx)
  build OS                   $(p_rx os)
  Static deps: libuv $(p_rx dep.libuv.version) (MIT), hwloc $(p_rx dep.hwloc.version) (BSD-3-Clause),
               OpenSSL $(p_rx dep.openssl.version) (Apache-2.0) - see LICENSES/.

bloxsense/bloxsense.cpp is BloxMiner-X's own code; bloxsense/blox.h and bloxsense/blox_sys.cpp are shared,
unchanged source, compiled identically for both engines' packaging (see that file's header comment).

bloxminer repo commit (this integration) $REPO_COMMIT
SRC
	if [[ $1 == src ]]; then
		cat <<'SRC2'

This is the SOURCE bundle: ccminer/ and xmrig/ already contain each upstream tree at the commit above with its
patch(es) already applied (build/bloxminer.patch; build/donate0.patch + build/branding.patch) - no network
access or upstream checkout is needed to inspect or rebuild either engine from this bundle alone. bloxminer/
here holds the HiveOS integration scripts (dispatcher + both engines' gated scripts) this bundle's own
build/package.sh needs to reassemble a full binary package; they are the exact files shipped in the companion
binary package. To rebuild the engine binaries: run build/build.sh (Verus engine, Ubuntu 22.04) and
build/build-rx.sh (RandomX engine, Ubuntu 22.04) as root in a stock container/chroot; each clones its own
upstream at the pinned tag/commit, verifies it, applies its patch(es), and builds exactly as described above.
bloxsense is built the same way: plain -O2, static.
SRC2
	else
		cat <<'SRC3'

Licenses: ccminer/BloxMiner and XMRig/bloxsense are GPL-3.0 (LICENSE). Statically linked XMRig dependencies:
libuv (MIT), hwloc (BSD-3-Clause), OpenSSL 3 (Apache-2.0) - see LICENSES/. libomp.so.5 is Apache-2.0 WITH
LLVM-exception - see LICENSE.libomp and LICENSE.Apache-2.0. The full GPL "Corresponding Source" for both
engines (each upstream tree with its patch(es) already applied, plus every build/integration script) is
published alongside this package as bloxminer-VERSION-src.tar.gz.
SRC3
	fi
}

# ---------------------------------------------------------------- binary package
D="$W/bloxminer"; mkdir -p "$D/engines/verus" "$D/engines/rx" "$D/LICENSES"
cp "$ROOT"/bloxminer/h-manifest.conf "$ROOT"/bloxminer/h-common.sh "$ROOT"/bloxminer/h-config.sh "$ROOT"/bloxminer/h-run.sh "$ROOT"/bloxminer/h-stats.sh "$D/"
cp "$ROOT"/bloxminer/engines/verus/h-config.sh "$ROOT"/bloxminer/engines/verus/h-run.sh "$ROOT"/bloxminer/engines/verus/h-stats.sh "$D/engines/verus/"
cp "$ROOT"/bloxminer/engines/rx/h-config.sh "$ROOT"/bloxminer/engines/rx/h-run.sh "$ROOT"/bloxminer/engines/rx/h-stats.sh "$D/engines/rx/"
cp "$VBIN" "$D/bloxminer"; cp -L "$VLIBOMP" "$D/libomp.so.5"
cp "$XBIN" "$D/xmrig"; cp "$XSENSE" "$D/bloxsense"
cp "$ROOT/LICENSE" "$D/LICENSE"
cp "$ROOT"/LICENSES/LICENSE.libuv "$ROOT"/LICENSES/LICENSE.hwloc "$ROOT"/LICENSES/LICENSE.openssl "$D/LICENSES/"
cp "$ROOT/LICENSES/LICENSE.libomp" "$D/LICENSE.libomp"
cp "$ROOT/LICENSES/LICENSE.Apache-2.0" "$D/LICENSE.Apache-2.0"
cp "$AUGPROV" "$D/build.provenance"
gen_source_md binary > "$D/SOURCE.md"
chmod 755 "$D" "$D"/*.sh "$D"/engines "$D"/engines/*/  "$D"/engines/*/*.sh "$D/bloxminer" "$D/xmrig" "$D/bloxsense"
chmod 644 "$D/h-manifest.conf" "$D/libomp.so.5" "$D/LICENSE" "$D/LICENSES"/* "$D/LICENSE.libomp" "$D/LICENSE.Apache-2.0" "$D/SOURCE.md" "$D/build.provenance"
TGZ="bloxminer-$VER.tar.gz"
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-09-28 00:00:00Z' -C "$W" -cf - bloxminer | gzip -n -9 > "$OUT/$TGZ"

# ---------------------------------------------------------------- source package: re-clone + re-verify + re-patch BOTH engines
CV="$W/ccminer-src"
git clone -q "$(p_verus upstream)" "$CV"
git -C "$CV" checkout -q "$(p_verus upstream_commit)"
FULLV=$(git -C "$CV" rev-parse HEAD)
[[ $FULLV == "$(p_verus upstream_commit)" ]] || { echo "ccminer resolved to $FULLV, expected $(p_verus upstream_commit) - refusing to package"; exit 1; }
(cd "$CV" && patch -p1 < "$ROOT/build/bloxminer.patch" > /dev/null)
rm -rf "$CV/.git"

CX="$W/xmrig-src"
git clone -q --branch "$(p_rx upstream_tag)" "$(p_rx upstream)" "$CX"
FULLX=$(git -C "$CX" rev-parse HEAD)
[[ $FULLX == "$(p_rx upstream_commit)" ]] || { echo "xmrig $(p_rx upstream_tag) resolved to $FULLX, expected $(p_rx upstream_commit) - refusing to package"; exit 1; }
(cd "$CX" && patch -p1 < "$ROOT/build/donate0.patch" > /dev/null && patch -p1 < "$ROOT/build/branding.patch" > /dev/null)
git -C "$CX" add -A -N .
XDIFF=$(git -C "$CX" diff --name-only)
XALLOWED=(src/donate.h src/version_blox.h src/base/kernel/config/BaseConfig.cpp src/core/Miner.cpp)
while IFS= read -r f; do
	[[ -n $f ]] || continue
	xfound=0
	for a in "${XALLOWED[@]}"; do [[ $f == "$a" ]] && { xfound=1; break; }; done
	(( xfound )) || { echo "donate0.patch/branding.patch touched a file outside the allowlist: $f"; exit 1; }
done <<< "$XDIFF"
rm -rf "$CX/.git"

SDNAME="bloxminer-$VER-src"; SD="$W/$SDNAME"
mkdir -p "$SD/build" "$SD/bloxsense" "$SD/bloxminer/engines/verus" "$SD/bloxminer/engines/rx" "$SD/LICENSES"
mv "$CV" "$SD/ccminer"
mv "$CX" "$SD/xmrig"
cp "$ROOT"/build/bloxminer.patch "$ROOT"/build/donate0.patch "$ROOT"/build/branding.patch "$ROOT"/build/build.sh "$ROOT"/build/build-rx.sh "$ROOT"/build/package.sh "$SD/build/"
cp "$ROOT"/bloxsense/blox.h "$ROOT"/bloxsense/blox_sys.cpp "$ROOT"/bloxsense/bloxsense.cpp "$SD/bloxsense/"
cp "$ROOT"/bloxminer/h-manifest.conf "$ROOT"/bloxminer/h-common.sh "$ROOT"/bloxminer/h-config.sh "$ROOT"/bloxminer/h-run.sh "$ROOT"/bloxminer/h-stats.sh "$SD/bloxminer/"
cp "$ROOT"/bloxminer/engines/verus/h-config.sh "$ROOT"/bloxminer/engines/verus/h-run.sh "$ROOT"/bloxminer/engines/verus/h-stats.sh "$SD/bloxminer/engines/verus/"
cp "$ROOT"/bloxminer/engines/rx/h-config.sh "$ROOT"/bloxminer/engines/rx/h-run.sh "$ROOT"/bloxminer/engines/rx/h-stats.sh "$SD/bloxminer/engines/rx/"
cp "$ROOT/LICENSE" "$SD/LICENSE"
cp "$ROOT"/LICENSES/LICENSE.libuv "$ROOT"/LICENSES/LICENSE.hwloc "$ROOT"/LICENSES/LICENSE.openssl "$SD/LICENSES/"
cp "$ROOT/LICENSES/LICENSE.libomp" "$ROOT/LICENSES/LICENSE.Apache-2.0" "$SD/LICENSES/"
cp "$AUGPROV" "$SD/build.provenance"
gen_source_md src > "$SD/SOURCE.md"
chmod -R u+rwX,go+rX,go-w "$SD"
SRCTGZ="$SDNAME.tar.gz"
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-09-28 00:00:00Z' -C "$W" -cf - "$SDNAME" | gzip -n -9 > "$OUT/$SRCTGZ"

cd "$OUT"
{
	sha256sum "$TGZ" "$SRCTGZ"
	(cd "$W" && find bloxminer -type f | sort | xargs sha256sum)
} > SHA256SUMS
cat SHA256SUMS
