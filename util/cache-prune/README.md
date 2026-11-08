# util cache-prune

Reports, and optionally prunes, rebuildable language-runtime caches for the invoking user: uv, npm, docker (build cache), pip, bun and cargo, plus the home trash. It refuses to run as root, because every cache it handles lives under the calling account. `util cache-prune --help` is the authoritative reference; this page is a summary.

## Modes

- `--report` prints cache sizes only. It never prompts and never changes anything.
- Default (no flags) is interactive: each runtime gets its own confirm, defaulting to No.
- `--yes` auto-confirms the safe verb for uv (`cache prune`), npm (`cache verify`) and docker (`builder prune`). pip, bun and cargo have no safe verb and are skipped.
- `--yes --include-purge` also runs the purge tier. pip, bun and cargo are purged (cargo removes only the unpacked `registry/src` children), and uv, npm and docker run their purge verb instead of their safe verb.
- `--docker-until <window>` narrows docker's safe builder prune to records at least that old. It never affects the purge verb.

## Safe and purge tiers

The safe verbs are conservative and free little by design. The purge verbs clear a whole cache and force a re-download or cold rebuild, so interactive runs offer them only when `--include-purge` is given (pip and bun, whose only verb is a purge, are always offered it). Reclaimable space is reported per tier, never as one combined figure.

The trash is user-deleted data rather than a rebuildable cache, so it is purge tier and interactive-only: it is never emptied under `--yes`, even with `--include-purge`, and only after one confirm that names its size.

After the docker build-cache step, docker image, container and anonymous-volume residue is classified afresh and handled by its own confirmed step (never in `--report`, named volumes are never removed).

## Measuring

Outside `--report`, every action measures the affected cache immediately before and after and reports the observed footprint change. That is a measurement, not an exact attribution: a concurrent write can make the change negative, and a run that frees nothing reports 0B explicitly.

## Absent tools

A runtime whose tool is missing (or whose docker daemon is unreachable, or whose trash directory does not exist) prints a `skip:` line. A skip never fails the run or changes the exit code.

## Exit codes

- `0` success
- `1` a runtime verb failed, or the tool was run as root or without a terminal where one is required
- `2` a usage error, such as an unknown flag or `--docker-until` without a valid value

## Requirements and environment

Requires `perl`; the docker residue step also needs `JSON::PP` and is skipped with a reason line when it is missing. The environment overrides (for example `BUN_INSTALL`, `CARGO_HOME`, `CACHE_PRUNE_TRASH_DIR`) are listed in `--help`.

An optional private overlay can add runtimes by placing `*.pm` modules in `private/util/cache-prune/fleet/`; with that directory absent the tool runs unchanged.
