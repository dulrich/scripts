# AGENTS.md

Guidance for anyone (human or agent) working in this repo. This is the primary
doc; `CLAUDE.md` just points here.

## What this repo is

A personal scripts and dotfiles collection. The entry point is `aliases.sh`,
symlinked to `~/.bash_aliases` so it loads on every shell session.

## Setup / installation

Run `./link.sh` to create the standard symlinks:
- `~/.bash_aliases` → `aliases.sh`
- `~/.Xresources` → `Xresources`
- `~/.config/ghostty/config` → `ghostty/config`
- `~/.config/zellij/config.kdl` → `zellij/config.kdl`

Or manually: `ln -s ~/scripts/aliases.sh ~/.bash_aliases`

## Architecture

### Shell alias chain

`aliases.sh` is the root. It always chain-loads:
- `git-aliases.sh` — git shorthands (`s`, `a`, `c`, `d`, `u`, `p`, `z`, etc.)
- `debian-aliases.sh` or `gentoo-aliases.sh` — conditionally by OS detection

It optionally loads (not in repo, gitignored):
- `config.sh` — local machine-specific overrides for variables like `EXTERNAL_OUTPUT`, `AUDIO_DEVICE`, `code_path` (template: `config.example.sh`)
- `work-aliases.sh` — private aliases, provided by the separate private overlay repo

`aliases.sh` uses `$here` (resolved via `realpath "${BASH_SOURCE[0]}"`) so all sibling-script references work correctly regardless of where it is symlinked from.

`git-aliases.sh` depends on `grep_options` defined in `aliases.sh` — it must always be sourced after `aliases.sh`.

### The `util` router

`aliases.sh` aliases `util` to `util/dispatch.sh`, a filesystem-router: `util <command> [args]` execs `util/<command>[.sh]`. There is no central registry — adding a subcommand is just dropping a `util/<name>.sh` file. `util/lib.sh` holds `_util_commands`, the one discovery function that both `dispatch.sh`'s listing and `completions.sh`'s completion source and call, so overlay precedence, infrastructure exclusion, and `.sh` resolution can't drift apart between them. `util/completions.sh` generates the completion list from `util/*.sh` (excluding `dispatch`/`lib`/`completions`), so private subcommands symlinked into `util/` are picked up automatically. Pattern modeled on `asset-tools/cond/util/`.

### Key utilities

| Script | Purpose |
|---|---|
| `daylog.sh` | Time-tracking log. Appends entries to `logs/YYYY-MM-DD.daylog`. Aliases: `dl` (log entry), `dls` (show today), `wl` (show last 7 days) |
| `dotfiles.sh` | Manages dotfiles across machines via a `meta_repo`. Commands: `add`, `backup`, `list`, `migrate`, `project`, `restore`, `snapshot`, `status`. Every project is identified by a record at `<meta_repo>/<meta_dotfiles>/.projects/<name>` holding its absolute source root, so a root is never guessed from a sibling directory; `project` registers `$PWD` and refuses a duplicate basename, `migrate` adopts an unambiguous pre-record payload directory and refuses ambiguous names. Parsing and validation write nothing — only `project` and `migrate` create metadata. `restore` reports restored, skipped or failed truthfully and keeps no-clobber. `snapshot` stages only the managed paths, refuses unrelated pre-staged content, commits locally, and prints the publish command instead of running it. |
| `build_system/build.sh` | C build system (public domain, from yzziizzy). `mkproject` bootstraps new C projects. Aliases `x` = `./build.sh`, `xd` = `./debug.sh`. |
| `util/cache-prune.sh` (`util cache-prune`) | Reports and prunes rebuildable language-runtime caches (uv, npm, docker build cache, pip, bun, cargo) for the invoking user. Refuses to run as root — every cache here lives under the calling account. Reports total footprint alongside a per-tier reclaimable estimate, never one conflated figure: docker's safe-tier estimate is `system df`'s RECLAIMABLE (`buildx du` as fallback source), labelled an explicit upper bound; uv/npm/pip/bun's purge-tier estimate is the hardlink-aware census (a cache entry also linked outside the tree counts toward total but not reclaimable), printed only against the verb that actually frees it — uv/npm's safe verb gets no number, since no dry run exists to predict it; cargo's purge-tier estimate is `registry/src` alone. Every action outside `--report` measures the cache before and after and reports the observed footprint change as its own line — a measurement, not an exact attribution, reported signed and explicitly even at zero, and unavailable rather than guessed when the post-action probe fails or docker's before/after come from different sources. docker is dual-verb like uv/npm: the safe verb `docker builder prune --force` runs unfiltered by default (what docker reports as reclaimable, with `--docker-until` as an opt-in age-window narrowing of the safe verb only), and the purge verb `docker builder prune -a --force` clears the whole unused build cache (cold rebuilds after), is never filtered, and runs only under `--yes --include-purge` or an interactive confirm offered when `--include-purge` is passed; the report keeps docker's system-df figure on the safe line and names the purge verb's scope without a purge figure. `--report` shows sizes only, no action, no delta line; the safe verb (uv/npm/docker) runs interactively-confirmed or via `--yes`; `--yes --include-purge` purges pip/bun (their only verb) and cargo's `registry/src` children only (`registry/cache`, `index`, `git/` kept; re-extraction is offline; skipped with a warning, exit unchanged, when `registry`/`src` is symlinked or either `.package-cache`/`.package-cache-mutate` lock is held; lock files never removed) and, for uv/npm/docker, purges instead of running their safe verb — `uv cache clean`/`npm cache clean --force`/`docker builder prune -a` are destructive and force a re-download, unlike their conservative safe verbs; interactively each destructive purge gets its own confirm, unconditional for pip/bun and gated on `--include-purge` for uv/npm/docker. The script itself holds only the CLI, the runtime registry and the per-runtime lifecycle; `util/cache-prune/{measurement,adapters,actions}.sh` hold the probe-record type and delta comparison, the shared size probes, and the election rules plus verb execution; each core runtime (its adapters, verbs and help text) is a self-registering module in `util/cache-prune/runtimes/<name>.sh`. They sit in a subdirectory because the router lists `util/*.sh` as commands — helper modules must never be routable, and `util/tests/util-router.sh` asserts they are not. Tests mirror that split: `util/tests/cache-prune.sh` stays the canonical entry point and sources focused suites from `util/tests/cache-prune/`. Optional unpublished modules under `util/cache-prune/fleet/` register extra runtimes (see its `AGENTS.md`); with that directory absent the tool and its suite run unchanged. Docker image/container residue (`util/cache-prune/docker-residue.sh`) is classified from a fresh capture after the build-cache prune and removed by its own step (never in `--report`, never `-f`, never a prune, named volumes never removed): superseded tags are safe tier (`--yes`, or one interactive confirm), stale containers purge tier (`--include-purge`), anonymous volumes (label key `com.docker.volume.anonymous`) already dangling before the run's removals purge tier too, removed per name with `docker volume rm`, unreferenced images only via a per-image interactive confirm under `--include-purge`; per-item failures are warnings, and the step prints its own images/containers/volumes footprint change. The `codex` runtime reports leaked Codex CLI marketplace staging copies (`<home>/.tmp/marketplaces/.staging/marketplace-upgrade-*`, direct children only, for homes `$HOME/.codex` and `$HOME/.codex-*`, root overridable via `CACHE_PRUNE_CODEX_HOME_ROOT`) with a per-profile breakdown, counting every entry toward total but only those older than 24 h as reclaimable, removed purge-tier only (`--yes --include-purge`, or one interactive confirm) with each deletion refusing symlinked entries, symlinked home/`.tmp`/`marketplaces`/`.staging` components and any realpath outside `.staging`. The `trash` runtime sizes the home trash (`files/`+`info/`+`expunged/` under `CACHE_PRUNE_TRASH_DIR`, default `${XDG_DATA_HOME:-$HOME/.local/share}/Trash`; detected only when `gio`, overridable via `CACHE_PRUNE_GIO`, resolves) as purge tier but is interactive-only (`RT_INTERACTIVE_ONLY`): user-deleted data is never emptied under `--yes`, even with `--include-purge`, only after one interactive confirm naming its size, via `gio trash --empty`, never `rm`. A runtime whose detect fails reports `skip: <name>: <reason>` from `RT_ABSENT`: a missing executable is `no <tool> on host` (uv, npm, docker, pip, bun, cargo, gio), a dead docker daemon is `docker daemon not reachable`, an absent trash dir its own line; docker's residue step (its JSON work in the sibling `docker-residue.pl`, perl + JSON::PP) reports `no perl on host` or `no JSON::PP on host`; none of these ever fails the run or changes the exit code. See `-h` for the full mode matrix. |
| `util/debian-maintenance.sh` | Root-run, interactive APT maintenance (a non-root interactive run re-execs itself by absolute path under `sudo`, so `util debian-maintenance` works unprefixed; `aliases.sh`'s `alias sudo='sudo '` makes `sudo util debian-maintenance` alias-expand too): update, upgrade, full-upgrade, old-kernel cleanup, autoremove, then an apt archive cleanup stage — root-owned, unlike the user-level caches `cache-prune.sh` handles. The archive stage previews with `apt-get -s autoclean` (matched via a `Del `-line-aware check, distinct from the `Inst`/`Remv` parser used elsewhere in the file) and runs it behind one confirm; a full `apt-get clean` is offered behind its own separate confirm. A final journal stage prints `journalctl --disk-usage` and, behind its own confirm, runs `journalctl --vacuum-size=200M` (`JOURNAL_VACUUM_SIZE`; archived files only), skipping when `journalctl` is absent or its usage is unreadable. Every destructive step in the script requires its own explicit confirmation. `--report` is the one accepted argument and the only non-interactive mode: no root, no TTY, no `apt-get update`, no mutation — it prints a single JSON object (`host`, `indexAgeSeconds` from the newest `/var/lib/apt/lists` mtime or `-1`, `upgradable`, `securityUpgradable`, `autoremovable`, `rebootRequired`) on stdout and exits 0, for the fleet host-posture scanner. |
| `util/battery.sh` (`util battery`) | Read-only battery report from sysfs alone (`BATTERY_SYSFS`, default `/sys/class/power_supply`; no upower/acpi): per battery charge %, status, energy now/full (`energy_*` Wh, else `charge_*` Ah), health (full vs design), draw and time to full/empty, plus a total line and the AC state; `--brief` prints only the total. Peripheral batteries (`scope=Device`) are skipped; the total's time-to-full counts only charging batteries. Exit 1 when no battery is found. Remote check without installing: `ssh <host> bash -s -- --brief < util/battery.sh`. Tests: `util/tests/battery.sh` (fixture trees). |
| `util/push-all.sh` (`util push-all`) | Applies `cl`'s push semantics to every git repo directly under the code root (`code_path`, or `--root`) that has a root `INITIATIVE.md` or legacy `DEVELOPMENT.md`. Bare = read-only status (origin ahead count of `master`, projection lag, unpushed projection; no fetch, never projects), listing only repos with pending work plus a summary count; `--verbose` lists every repo, in-sync and skipped included. `--push` output is filtered the same way (pushed and failed repos always shown). `--push` pushes `master` to its upstream whatever is checked out and mirrors the `github` remote, rebuilding the scanned projection only when `publish.mjs status` reports lag; it is refused (exit 2, nothing pushed) when `CLAUDECODE` or any `CODEX_*` variable is set. The projection and its scan run before any push, here and in `cl`: a failed scan pushes to neither remote, so flagged commits stay local and can be amended without a force push. A repo without a `master` upstream is reported and skipped; one repo's failure never stops the sweep and makes the exit non-zero. Per-repo logic lives in `util/lib/push.sh`, sourced by both this and `cl` in `aliases.sh`. Tests: `util/tests/push-all.sh`. |

### Subdirectories

- `util/` — utility subcommands dispatched by the `util` router (see above). A subcommand's own helper modules live in a subdirectory named after it (e.g. `util/cache-prune/`), which the router's `util/*.sh` glob deliberately cannot reach.
- `blamecount/` — bun-run (Node built-ins only) tool summarizing `git blame` stats per author/language via the `git` CLI, with bounded blame concurrency. Configure via `config.json` (see `config.example.json`, which also sets `concurrency`); accepts `--config <path>`. Missing/invalid config, a non-repo `basepath`, or any failed `git` invocation exits nonzero naming the offending path. Has its own tests (`blamecount/tests/smoke.sh`).
- `pkg-ioc/` — Supply-chain-attack IOC scanner for npm/PyPI. Has its own tests (`tests/smoke.sh`).
- `gpuedit/` — Config files (themes, keybindings, highlighters) for gpuedit.
- `i3/` — i3 window manager config.

### Config pattern

Scripts that need per-machine customization look for `config.sh` in the repo root and source it if present. The repo ships `config.example.sh` as a template — copy and edit locally, never commit the live version (it is gitignored).

## Quality gates

Run the complete tracked-shell gate before reporting a change complete:

```bash
bash tests/shell-gate.sh
```

The `--help` contract gate (every entrypoint prints usage on a bare `--help` with no side effect; manifest `.help-gate.json`):

```bash
bun /home/_shared_code/context-control/scripts/help-gate.mjs .
```

The gate enumerates public tracked scripts with `git ls-files -z '*.sh'`, then
runs ShellCheck and `bash -n` over that exact set. It also runs the Debian
maintenance, util router, cache-prune, alias-chain, root-utility, and `pkg-ioc`
smoke suites, followed by the build-system, public-contract, and blamecount
checks. Gitignored private overlays are intentionally outside this public
repository gate.

For focused iteration, the component smoke commands are:

```bash
bash util/tests/debian-maintenance.sh
bash util/tests/util-router.sh
bash util/tests/push-all.sh
bash util/tests/cache-prune.sh
bash tests/aliases-smoke.sh
bash tests/root-utils-smoke.sh
bash pkg-ioc/tests/smoke.sh
(cd build_system && ./build.sh)
bash tests/public-contract-smoke.sh
bash blamecount/tests/smoke.sh
```

## Public / private split

This is the **public** repo. Private and machine-specific content
(`work-aliases.sh`, private `util/*` scripts, kernel configs, secrets) lives in
a separate private overlay repo and is symlinked into place locally; all such
paths are gitignored here. When adding files, keep private/host-specific detail
(hostnames, credentials, tokens, personal paths) out — this repo is public.

- The control plane (`plans/`, `reviews/`, `references/`, `INITIATIVE.md`) lives in this repo on `master` and is stripped from the GitHub `public` branch by the fleet `publish.mjs` projection. Agents never push; the user publishes.

## License

The repo is **CC0 1.0** (public domain); see `LICENSE`. Anything added must be
CC0 / public-domain compatible — do not introduce copyleft (e.g. GPL) or
otherwise restrictively-licensed code into the tracked tree. Vendored
subdirectories keep their own compatible licenses (`build_system/` public
domain, `pkg-ioc/` CC0). Any new source-file headers should carry a CC0
notice.
