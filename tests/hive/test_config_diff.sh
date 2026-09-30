#!/usr/bin/env bash
# The config-diff gate the reviewers required to license carrying G10 (Verus speed)/X6 (rx speed) evidence
# over from the gated 2.1.0/X 1.0.0 releases: for identical flight-sheet inputs, the config.json this
# package's dispatcher produces (via engines/verus or engines/rx) must be byte-equal to what the ORIGINAL
# gated h-config.sh of that release produced - only CUSTOM_CONFIG_FILENAME/CUSTOM_LOG_BASENAME (test-harness
# paths, never shipped as literal values) may differ, and even those are normalised out below before compare.
# Usage: tests/hive/test_config_diff.sh
#   (uses the frozen release tarballs at ~/c3work/frozen/{bloxminer-2.1.0.tar.gz,bloxminer-x-1.0.0.tar.gz} by
#   default - pass different paths as $1/$2 to override)
#
# PR #2 follow-up review (Codex): with neither the frozen tarballs NOR $1/$2 present, this used to
# unconditionally SKIP - meaning CI never ran this gate at all (bokiko's own ~/c3work/frozen exists only on
# his machine, never on a GitHub Actions runner). Fixed, per source:
#   - Verus (2.1.0): PUBLICLY released (github.com/bokiko/bloxminer/releases/tag/2.1.0) - downloaded and
#     sha256-verified against the known-good hash below (itself cross-checked against that release's own
#     published SHA256SUMS asset, not just typed in once and trusted) instead of needing a local copy at all.
#   - RandomX (X 1.0.0): NEVER publicly released, so nothing to download - instead falls back to
#     tests/fixtures/frozen/bloxminer-x-1.0.0/, the exact gated h-config.sh/h-manifest.conf (GPL-3.0, text
#     only, no binaries) committed to THIS repo for exactly this purpose (see that directory's own README.md).
# Either fallback only ever engages when the real frozen tarball is absent - a real ~/c3work/frozen (or an
# explicit $1/$2 override) always takes priority, unchanged from before. With BLOX_CI set, a SKIP becomes a
# hard FAIL instead (this gate must never silently stop running in CI) - a bare local dev run without BLOX_CI
# still SKIPs on a genuine failure (e.g. no network at all), same as before this fix existed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
FROZEN=$HOME/c3work/frozen
FIXTURE_RX="$HERE/../fixtures/frozen/bloxminer-x-1.0.0"
VERUS_TGZ=${1:-$FROZEN/bloxminer-2.1.0.tar.gz}
RX_TGZ=${2:-$FROZEN/bloxminer-x-1.0.0.tar.gz}
VERUS_2_1_0_URL="https://github.com/bokiko/bloxminer/releases/download/2.1.0/bloxminer-2.1.0.tar.gz"
VERUS_2_1_0_SHA256="731e508b352c495750bd588b965cd5c82e2a3d2d92dc7b68585daf0076058d1f"

skip_or_fail() {   # $1 = reason - SKIP normally, FAIL under BLOX_CI (see the header comment above)
	if [[ -n ${BLOX_CI:-} ]]; then
		echo "FAIL: $1 (BLOX_CI is set - a SKIP here would silently stop this gate from ever running in CI)"
		exit 1
	fi
	echo "SKIP: $1"
	exit 0
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }

mkdir -p "$T/gated-verus" "$T/gated-rx"

# ---- Verus side: real tarball first, else download + verify the public 2.1.0 release
if [[ -f $VERUS_TGZ ]]; then
	tar xzf "$VERUS_TGZ" -C "$T/gated-verus"
else
	DL_TGZ="$T/bloxminer-2.1.0.tar.gz"
	if curl -fsSL -o "$DL_TGZ" "$VERUS_2_1_0_URL" 2>"$T/verus-dl.err"; then
		GOT_SHA=$(sha256sum "$DL_TGZ" 2>/dev/null | cut -d' ' -f1)
		if [[ $GOT_SHA == "$VERUS_2_1_0_SHA256" ]]; then
			tar xzf "$DL_TGZ" -C "$T/gated-verus"
		else
			skip_or_fail "downloaded $VERUS_2_1_0_URL but its sha256 ($GOT_SHA) does not match the known-good $VERUS_2_1_0_SHA256 - refusing to use it"
		fi
	else
		skip_or_fail "no frozen tarball at $VERUS_TGZ and downloading $VERUS_2_1_0_URL failed: $(cat "$T/verus-dl.err" 2>/dev/null)"
	fi
fi
[[ -f $T/gated-verus/bloxminer/h-config.sh && -f $T/gated-verus/bloxminer/h-manifest.conf ]] || \
	skip_or_fail "gated verus h-config.sh/h-manifest.conf not found after extraction ($T/gated-verus)"

# ---- RandomX side: real tarball first, else the committed fixture (X 1.0.0 was never publicly released)
if [[ -f $RX_TGZ ]]; then
	tar xzf "$RX_TGZ" -C "$T/gated-rx"
else
	[[ -d $FIXTURE_RX ]] || skip_or_fail "no frozen tarball at $RX_TGZ and no fixture at $FIXTURE_RX"
	( cd "$FIXTURE_RX" && sha256sum -c SHA256SUMS ) > "$T/fixture-check.log" 2>&1 || \
		skip_or_fail "tests/fixtures/frozen/bloxminer-x-1.0.0 failed its own SHA256SUMS check - refusing to use it: $(cat "$T/fixture-check.log")"
	mkdir -p "$T/gated-rx/bloxminer-x"
	cp "$FIXTURE_RX"/h-config.sh "$FIXTURE_RX"/h-run.sh "$FIXTURE_RX"/h-stats.sh "$FIXTURE_RX"/h-manifest.conf "$T/gated-rx/bloxminer-x/"
fi
[[ -f $T/gated-rx/bloxminer-x/h-config.sh && -f $T/gated-rx/bloxminer-x/h-manifest.conf ]] || \
	skip_or_fail "gated rx h-config.sh/h-manifest.conf not found after extraction ($T/gated-rx)"

# ---------------------------------------------------------------- Verus: gated 2.1.0 vs dispatcher (v3)
# Round 5 (Codex test-gap review): both runners below now SOURCE their h-config.sh with CUSTOM_* as plain,
# NON-exported variables of the calling shell - Hive's real invocation shape (hive-ref/miner:
# `. $MINER_DIR/$CUSTOM_MINER/h-config.sh`; see tests/hive/test_dispatcher.sh's hconfig() for the identical
# pattern and why an exported child-process call is exactly the shape that hid the cask18 sourcing bug from
# every earlier round's tests). This changes nothing about what diff_configs actually compares - config.json's
# CONTENT never depended on export vs. source (a child process still receives an exported var); it only makes
# this suite exercise the same call shape as test_dispatcher.sh instead of a shape no real Hive invocation uses.
run_gated_verus() {   # $1 url $2 template $3 pass $4 extra -> writes $T/gated.json
	local d="$T/rv"; rm -rf "$d"; mkdir -p "$d" "$T/logrv"
	cp "$T/gated-verus/bloxminer/h-config.sh" "$T/gated-verus/bloxminer/h-manifest.conf" "$d/"
	sed -i.bak -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/gated.json#" \
	           -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/logrv/bloxminer#" "$d/h-manifest.conf"
	rm -f "$T/gated.json"
	BLOX_DIR=$d bash -c '
		set +a
		CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4
		. "$BLOX_DIR/h-config.sh"
	' _ "$1" "$2" "$3" "$4" > /dev/null 2>&1
}
run_v3_verus() {   # $1 url $2 template $3 pass $4 extra $5 algo -> writes $T/v3.json
	local d="$T/nv"; rm -rf "$d"; mkdir -p "$d" "$T/lognv"
	cp -r "$ROOT"/bloxminer/* "$d/"
	chmod +x "$d"/*.sh "$d"/engines/*/*.sh
	sed -i.bak -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/v3.json#" \
	           -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/lognv/bloxminer#" "$d/h-manifest.conf"
	rm -f "$T/v3.json"
	BLOX_DIR=$d bash -c '
		set +a
		message() { :; }
		CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 CUSTOM_ALGO=$5
		. "$BLOX_DIR/h-config.sh"
	' _ "$1" "$2" "$3" "$4" "$5" > /dev/null 2>&1
}
diff_configs() {   # compares $T/gated.json to $T/v3.json, both jq-canonicalised, with "log-file" stripped:
	# that value is CUSTOM_LOG_BASENAME.log, a per-package PATH (never a literal shipped in either release) -
	# this test harness deliberately points the gated and v3 fixtures at different temp log directories, so
	# the path differs by test construction even though both sides compute it the exact same way from their
	# own CUSTOM_LOG_BASENAME. Every other key - including the two engines' actual mining-relevant settings -
	# is compared byte-for-byte, unnormalised.
	jq -S 'del(."log-file")' "$T/gated.json" > "$T/gated.sorted.json" 2>/dev/null
	jq -S 'del(."log-file")' "$T/v3.json" > "$T/v3.sorted.json" 2>/dev/null
	diff -u "$T/gated.sorted.json" "$T/v3.sorted.json"
}

for case_desc_url_tpl_pass_extra in \
	"host:port, all CPUs|pool.example.com:9999|W.rig|4|" \
	"stratum+ssl url, extra threads|stratum+ssl://p:443|W.rig2|16|\"threads\": 12" \
	"text pass, dashboard on|p:1|Worker.Name|s3cret|\"dashboard\": true"
do
	desc=${case_desc_url_tpl_pass_extra%%|*}; rest=${case_desc_url_tpl_pass_extra#*|}
	url=${rest%%|*}; rest=${rest#*|}
	tpl=${rest%%|*}; rest=${rest#*|}
	mpass=${rest%%|*}; extra=${rest#*|}
	run_gated_verus "$url" "$tpl" "$mpass" "$extra"
	run_v3_verus "$url" "$tpl" "$mpass" "$extra" ""
	d=$(diff_configs)
	if [[ -z $d ]]; then ok "verus config-diff: $desc"; else bad "verus config-diff: $desc" "$d"; fi
done

# ---------------------------------------------------------------- RandomX: gated X 1.0.0 vs dispatcher (v3)
run_gated_rx() {   # $1 url $2 template $3 pass $4 extra $5 algo -> writes $T/gated.json
	local d="$T/rx1"; rm -rf "$d"; mkdir -p "$d" "$T/logrx1"
	cp "$T/gated-rx/bloxminer-x/h-config.sh" "$T/gated-rx/bloxminer-x/h-manifest.conf" "$d/"
	sed -i.bak -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/gated.json#" \
	           -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/logrx1/bloxminer-x#" "$d/h-manifest.conf"
	rm -f "$T/gated.json"
	BLOX_DIR=$d bash -c '
		set +a
		CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 CUSTOM_ALGO=$5
		. "$BLOX_DIR/h-config.sh"
	' _ "$1" "$2" "$3" "$4" "$5" > /dev/null 2>&1
}
for case_desc_url_tpl_pass_extra_algo in \
	"host:port, default algo|pool.example.com:9999|W.rig|x|" \
	"stratum+ssl, tls, 1gb-pages declined (no NUMA info)|stratum+ssl://p:443|W.rig2|poolpass|\"tls\": true|rx/0" \
	"rx/wow, extra cpu opts|p:1|Worker.Name|mypass|\"cpu\": {\"max-threads-hint\": 50}|rx/wow"
do
	desc=${case_desc_url_tpl_pass_extra_algo%%|*}; rest=${case_desc_url_tpl_pass_extra_algo#*|}
	url=${rest%%|*}; rest=${rest#*|}
	tpl=${rest%%|*}; rest=${rest#*|}
	mpass=${rest%%|*}; rest=${rest#*|}
	extra=${rest%%|*}; algo=${rest#*|}
	run_gated_rx "$url" "$tpl" "$mpass" "$extra" "$algo"
	run_v3_verus "$url" "$tpl" "$mpass" "$extra" "${algo:-rx/0}"   # reuses the v3 runner (algo picks the rx engine)
	d=$(diff_configs)
	if [[ -z $d ]]; then ok "rx config-diff: $desc"; else bad "rx config-diff: $desc" "$d"; fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
