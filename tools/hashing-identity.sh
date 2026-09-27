#!/usr/bin/env bash
# Compare the hashing code of two builds instruction by instruction.
# Every function whose name matches verus|haraka|clhash|scanhash|GenNewCLKey is disassembled from both binaries
# and compared after normalising ONLY what depends on where the linker placed things: RIP-relative displacements
# and absolute branch/call addresses. Immediates, stack/struct offsets, and call targets by name (+offset) are
# kept, so a changed constant or a changed callee is reported. tests/tools/test_hashing_identity.sh has negative controls.
# Usage: tools/hashing-identity.sh <binary A> <binary B>      (Linux, binutils objdump + nm)
set -euo pipefail
A=${1:?binary A}; B=${2:?binary B}
PAT='verus|haraka|clhash|scanhash|GenNewCLKey'
# Exact symbols that match PAT by name but are not hashing code. Exact names only, never patterns.
#   _Z18blox_algo_is_verusv  bool blox_algo_is_verus(): stratum notify routing (opt_algo == ALGO_EQUIHASH), BloxMiner 2.1.0
NOT_HASHING='^(_Z18blox_algo_is_verusv)$'

syms() { nm --defined-only "$1" | awk '$2 ~ /^[tTwW]$/ {print $3}' | grep -E "$PAT" | grep -vE "$NOT_HASHING" | sort -u; }
body() {  # binary symbol -> normalised instructions
	objdump -d --no-show-raw-insn --disassemble="$2" "$1" |
		sed -n '/^[0-9a-f]* <.*>:$/,$p' | tail -n +2 |
		sed -E 's/^ *[0-9a-f]+:\t//; s/[[:space:]]*#.*$//; s/-?0x[0-9a-f]+\(%rip\)/REL(%rip)/g; s/\b[0-9a-f]+ (<[^>]*>)/\1/g; s/[[:space:]]+$//' |
		grep -v '^$'
}

diff <(syms "$A") <(syms "$B") > /dev/null || { echo "different hashing function sets:"; diff <(syms "$A") <(syms "$B"); exit 1; }
[[ -n $(syms "$A") ]] || { echo "no hashing functions found in $A"; exit 1; }
n=0; same=0
while read -r s; do
	n=$((n+1))
	a=$(body "$A" "$s"); b=$(body "$B" "$s")
	[[ -n $a && -n $b ]] || { echo "EMPTY disassembly: $s"; continue; }
	if [[ $a == "$b" ]]; then same=$((same+1)); else echo "DIFFERS: $s"; fi
done < <(syms "$A")
echo "$same/$n hashing functions instruction-identical"
[ "$same" -eq "$n" ] && [ "$n" -gt 0 ]
