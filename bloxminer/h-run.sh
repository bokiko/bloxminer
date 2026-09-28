#!/usr/bin/env bash
# Top-level dispatcher: starts whichever engine h-config.sh last selected (the state file; see h-common.sh for
# the missing/stale fallback). The engines never run at once - Hive stops the previous miner process before
# calling h-config/h-run again on an algo switch, and this package has only one screen/log for either engine.
BLOX_DIR=${BLOX_DIR:-/hive/miners/custom/bloxminer}
cd "$BLOX_DIR" || exit 1
. "$BLOX_DIR/h-manifest.conf" || exit 1
. "$BLOX_DIR/h-common.sh" || exit 1

engine=$(read_engine_state)

# Host hygiene: the RandomX engine reserves ~1200 x 2 MB huge pages on start (its own h-run.sh, via Hive's
# `hugepages -rx` helper when present) and nothing ever releases them on a switch - custom miners have no stop
# hook. The Verus engine never wants hugepages reserved (it uses a few hundred MB total), so release them here
# before it starts: unconditionally and best-effort, so this is also a correct no-op when nothing was ever
# reserved (e.g. a fresh install that starts on Verus). On an 8 GB rig, 1200 x 2 MB left pinned is ~30% of RAM
# held for nothing.
if [[ $engine == verus ]]; then
	{ command -v sysctl > /dev/null 2>&1 && sysctl -q -w vm.nr_hugepages=0; } 2>/dev/null
	true
fi

export BLOX_DIR
exec "$BLOX_DIR/engines/$engine/h-run.sh"
