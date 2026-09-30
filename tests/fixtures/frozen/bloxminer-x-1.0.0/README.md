# bloxminer-x-1.0.0 (frozen test fixture)

PR #2 follow-up review (Codex): `tests/hive/test_config_diff.sh` proves BloxMiner 3.0.0's dispatcher produces
byte-identical `config.json` output to the ORIGINAL gated releases it carries speed evidence over from - the
reviewers' own condition for licensing that carry-over. BloxMiner-X 1.0.0 was never published (unlike Verus
2.1.0, which has a public GitHub release this same test now downloads and sha256-verifies instead), so the CI
"scripts" job had no way to run this half of the comparison at all and silently SKIPped it.

These are exactly the four **gated scripts** from bokiko's own local BloxMiner-X 1.0.0 build - text, GPL-3.0,
no binaries - copied verbatim from the frozen release tarball at `~/c3work/frozen/bloxminer-x-1.0.0.tar.gz`
(bokiko's own machine, not part of this repo). Only what `test_config_diff.sh` actually needs to run
`h-config.sh` and read `h-manifest.conf`'s `CUSTOM_VERSION`/`CUSTOM_NAME`; `h-run.sh`/`h-stats.sh` are included
too for completeness (the same gated set 2.1.0's own public release ships) even though this particular test
only exercises `h-config.sh`.

`SHA256SUMS` records each file's own hash at the time it was copied in - a mismatch there means this directory
was edited after the fact, not that BloxMiner-X 1.0.0 itself somehow changed (a released, frozen artefact
never does).

Used by `tests/hive/test_config_diff.sh` as a fallback ONLY when the real frozen tarballs
(`~/c3work/frozen/{bloxminer-2.1.0.tar.gz,bloxminer-x-1.0.0.tar.gz}`) are not present - e.g. every CI run,
which has neither bokiko's machine nor its `~c3work` state. Passing real tarball paths (or running on a host
that has `~/c3work/frozen`) always takes priority over this fixture.
