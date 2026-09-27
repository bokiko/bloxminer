#!/usr/bin/env bash
# Negative and positive controls for tools/hashing-identity.sh (Linux, cc + binutils).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOOL="$HERE/../../tools/hashing-identity.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
src() {  # $1 file, $2 constant, $3 callee, $4 extra padding function (shifts the layout)
	cat > "$1" <<C
#include <stdint.h>
__attribute__((noinline)) uint32_t helper_a(uint32_t x) { return x * 3u; }
__attribute__((noinline)) uint32_t helper_b(uint32_t x) { return x * 5u; }
static const uint32_t table[4] = { 1, 2, 3, 4 };
$4
__attribute__((noinline)) uint32_t verus_ctl_const(uint32_t x) { return (x ^ $2u) + table[x & 3]; }
__attribute__((noinline)) uint32_t verus_ctl_call(uint32_t x) { return $3(x) + 7u; }
int main(int c, char **v) { (void) v; return (int) (verus_ctl_const((uint32_t) c) + verus_ctl_call((uint32_t) c)); }
C
}
build() { src "$T/$1.c" "$2" "$3" "$4"; cc -O2 -o "$T/$1" "$T/$1.c"; }
expect() {  # name, tool must succeed (0) or fail (1), and output must contain text
	local out rc; out=$("$TOOL" "$T/$2" "$T/$3" 2>&1); rc=$?
	if [[ $rc == "$4" ]] && grep -qF -- "$5" <<< "$out"; then pass=$((pass+1)); printf '%-44s ok\n' "$1"
	else fail=$((fail+1)); printf '%-44s FAIL rc=%s\n%s\n' "$1" "$rc" "$out"; fi
}
PAD='__attribute__((noinline)) uint32_t padding(uint32_t x) { uint32_t s = 0; for (uint32_t i = 0; i < x; i++) s += i * i * 11u; return s; }'
build base      0x1234 helper_a ""
build same      0x1234 helper_a ""
build layout    0x1234 helper_a "$PAD"
build const     0x1235 helper_a ""
build callee    0x1234 helper_b ""
build notHash   0x1234 helper_a 'unsigned char nh(void) __asm__("_Z18blox_algo_is_verusv"); __attribute__((used,noinline)) unsigned char nh(void) { return 1; }'
build newVerus  0x1234 helper_a '__attribute__((used,noinline)) uint32_t verus_extra(uint32_t x) { return x + 1u; }'
expect "identical builds"              base same   0 "2/2 hashing functions instruction-identical"
expect "layout shift only"             base layout 0 "2/2 hashing functions instruction-identical"
expect "changed constant is detected"  base const  1 "DIFFERS: verus_ctl_const"
expect "changed callee is detected"    base callee 1 "DIFFERS: verus_ctl_call"
expect "listed non-hashing symbol ignored" base notHash 0 "2/2 hashing functions instruction-identical"
expect "unlisted new verus symbol fails" base newVerus 1 "different hashing function sets"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
