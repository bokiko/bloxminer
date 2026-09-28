#!/usr/bin/env bash
# The config-diff gate the reviewers required to license carrying G10 (Verus speed)/X6 (rx speed) evidence
# over from the gated 2.1.0/X 1.0.0 releases: for identical flight-sheet inputs, the config.json this
# package's dispatcher produces (via engines/verus or engines/rx) must be byte-equal to what the ORIGINAL
# gated h-config.sh of that release produced - only CUSTOM_CONFIG_FILENAME/CUSTOM_LOG_BASENAME (test-harness
# paths, never shipped as literal values) may differ, and even those are normalised out below before compare.
# Usage: tests/hive/test_config_diff.sh
#   (uses the frozen release tarballs at ~/c3work/frozen/{bloxminer-2.1.0.tar.gz,bloxminer-x-1.0.0.tar.gz} by
#   default - pass different paths as $1/$2 to override)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
FROZEN=$HOME/c3work/frozen
VERUS_TGZ=${1:-$FROZEN/bloxminer-2.1.0.tar.gz}
RX_TGZ=${2:-$FROZEN/bloxminer-x-1.0.0.tar.gz}
[[ -f $VERUS_TGZ && -f $RX_TGZ ]] || { echo "SKIP: frozen release tarballs not found ($VERUS_TGZ / $RX_TGZ)"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }

mkdir -p "$T/gated-verus" "$T/gated-rx"
tar xzf "$VERUS_TGZ" -C "$T/gated-verus"
tar xzf "$RX_TGZ" -C "$T/gated-rx"

# ---------------------------------------------------------------- Verus: gated 2.1.0 vs dispatcher (v3)
run_gated_verus() {   # $1 url $2 template $3 pass $4 extra -> writes $T/gated.json
	local d="$T/rv"; rm -rf "$d"; mkdir -p "$d" "$T/logrv"
	cp "$T/gated-verus/bloxminer/h-config.sh" "$T/gated-verus/bloxminer/h-manifest.conf" "$d/"
	sed -i.bak -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/gated.json#" \
	           -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/logrv/bloxminer#" "$d/h-manifest.conf"
	rm -f "$T/gated.json"
	BLOX_DIR=$d CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 bash "$d/h-config.sh" > /dev/null 2>&1
}
run_v3_verus() {   # $1 url $2 template $3 pass $4 extra -> writes $T/v3.json
	local d="$T/nv"; rm -rf "$d"; mkdir -p "$d" "$T/lognv"
	cp -r "$ROOT"/bloxminer/* "$d/"
	chmod +x "$d"/*.sh "$d"/engines/*/*.sh
	sed -i.bak -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/v3.json#" \
	           -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/lognv/bloxminer#" "$d/h-manifest.conf"
	rm -f "$T/v3.json"
	message() { :; }; export -f message
	BLOX_DIR=$d CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 CUSTOM_ALGO=$5 bash "$d/h-config.sh" > /dev/null 2>&1
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
	BLOX_DIR=$d CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_USER_CONFIG=$4 CUSTOM_ALGO=$5 bash "$d/h-config.sh" > /dev/null 2>&1
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
