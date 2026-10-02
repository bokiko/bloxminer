# Changes

## 2.1.1 (hotfix)

Scripts-only hotfix: the engine binary is unchanged from 2.1.0 (same build, same sha256 below) — only
`bloxminer/*.sh` changed. No hashing, mining, or API-protocol changes.

### HiveOS stats collector (`h-stats.sh`)

Ported from the BloxMiner 3.0.0 development line, which found and fixed this class of bug through
multiple rounds of review of its own (structurally identical) Verus stats collector:

- **Fork-free field parsing and timing.** `field()` (one parse per API field and per `cores` row) used to run
  `tr`/`grep`/`cut` — three forks per call. On a rig with many physical cores, under full CPU load, that cost
  alone could push the whole script multiple seconds past its ~3 s Hive stats budget with nothing to show for
  it (reproduced with `taskset -c 0` under full load: 8+ s runs, no result). `field()` is now pure bash
  parameter expansion (no fork); all budget/deadline arithmetic is pure integer math off `EPOCHREALTIME`
  (no `date`/`awk` fork per check); the poll's own pacing uses a builtin `read -t` against a private fd opened
  once, not an external `sleep` per iteration.
- **One absolute deadline, a killable child.** The whole collection (both API calls, all parsing) now runs
  inside a single `setsid`-started, process-group-killable child bound to one absolute deadline computed at
  entry — not the previous uncapped per-field-call model.
- **Phase A / Phase B split, never a mixed or empty result.** Each poll first writes an honest answer from the
  cheap `summary` call alone (Phase A), then only *overwrites* it with a `cores` breakdown (Phase B) if that
  validates in time **and** is consistent with Phase A's own total (within 10%) — a structurally-valid but
  zero or near-zero `cores` reply can no longer silently replace a healthy Phase A rate, and a kill during
  Phase B can never lose Phase A's already-written answer.
- **jq 1.6 empty-input gap.** `jq -e '<filter>' <<< ""` (empty input) exits 0 ("vacuously successful") on jq
  1.6 — the Ubuntu 22.04 `apt` package, i.e. HiveOS's own base — but exits 4 on jq 1.7+. Every place that used
  to rely on `jq -e` alone to detect an empty/invalid API reply now checks emptiness with a plain bash pattern
  match first, so the behavior no longer depends on which jq happens to be installed.
- **Atomic, guarded writes.** The collector's result is written to a temp file and renamed into place; a
  failed composition (a transient jq fork/exec failure under resource pressure) is detected before the write,
  so it can never replace an already-good prior result with an empty or invalid one.
- **`ver` always shows the package version** (`h-manifest.conf`), never the engine binary's raw API `VER`
  field — needed precisely because this is a scripts-only hotfix: the binary still reports `2.1.0`.

### Packaging

- `build/package.sh` can package an existing, already-verified binary under a new package version
  (`BLOX_PACKAGE_ALLOW_VERSION_MISMATCH=1`, explicit opt-in) — needed for a scripts-only hotfix where the
  engine binary is intentionally not rebuilt.

### Tests

- `tests/hive/test_hive_scripts.sh`: added cases for the version-display fix (engine `VER` differing from, or
  absent vs., the package version), the Phase A/B 10%-consistency guard (all-zero and near-zero `cores`
  replies), `write_result`'s own write guard, a forced Phase A composition failure, the `now_us()` fallback
  timestamp normalization, a same-shell two-poll case (a stale positive rate never survives a later poll's
  failure), and that the poll loop's own private-fd handling never redirects the shell's stderr afterward.
- `tests/hive/test_under_load.sh` (new): sustained polling under full CPU load (unconstrained, and
  `taskset` 1/2/3 CPUs against many competing busy loops, plus a 90+ s sustained 2-CPU run) — asserts zero
  false zeros always, and a hard 3.0 s budget (with a 4.0 s hard cap) from 3 CPUs up.

## 2.1.0

See the [2.1.0 release](https://github.com/bokiko/bloxminer/releases/tag/2.1.0) notes.
