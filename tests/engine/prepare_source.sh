#!/usr/bin/env bash
# Clone upstream ccminer at the pinned commit and apply build/bloxminer.patch into <dir> (for tests and debug builds).
# Usage: tests/engine/prepare_source.sh <dir>
set -euo pipefail
DIR=${1:?target directory}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck disable=SC2016   # matches the literal ${COMMIT:-...} line in build.sh
COMMIT=$(sed -n 's/^COMMIT=\${COMMIT:-\([0-9a-f]*\)}.*/\1/p' "$HERE/build/build.sh")
git clone -q -b Verus2.2 https://github.com/monkins1010/ccminer.git "$DIR"
git -C "$DIR" checkout -q "$COMMIT"
patch -d "$DIR" -p1 -s < "$HERE/build/bloxminer.patch"
echo "patched source ready in $DIR (upstream $COMMIT)"
