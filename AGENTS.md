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

`git-aliases.sh` depends on `defarg` and `grep_options` defined in `aliases.sh` — it must always be sourced after `aliases.sh`.

### The `util` router

`aliases.sh` aliases `util` to `util/dispatch.sh`, a filesystem-router: `util <command> [args]` execs `util/<command>[.sh]`. There is no central registry — adding a subcommand is just dropping a `util/<name>.sh` file. `util/lib.sh` holds shared helpers (e.g. `defarg`) that subcommands can source, since they run as separate processes and don't inherit `aliases.sh` functions. `util/completions.sh` generates the completion list from `util/*.sh` (excluding `dispatch`/`lib`/`completions`), so private subcommands symlinked into `util/` are picked up automatically. Pattern modeled on `asset-tools/cond/util/`.

### Key utilities

| Script | Purpose |
|---|---|
| `daylog.sh` | Time-tracking log. Appends entries to `logs/YYYY-MM-DD.daylog`. Aliases: `dl` (log entry), `dls` (show today), `wl` (show last 7 days) |
| `lifi.sh` | Adds license/copyright headers to new source files. Reads license texts from `licenses/`. Configured per-project via `config.lifi`. |
| `dotfiles.sh` | Manages dotfiles across machines via a `meta_repo`. Commands: `add`, `backup`, `restore`, `snapshot`, `list`. |
| `build_system/build.sh` | C build system (public domain, from yzziizzy). `mkproject` bootstraps new C projects. Aliases `x` = `./build.sh`, `xd` = `./debug.sh`. |
| `util/cache-prune.sh` (`util cache-prune`) | Reports and prunes rebuildable language-runtime caches (uv, npm, docker build cache, pip, bun, cargo) for the invoking user. Refuses to run as root — every cache here lives under the calling account. `--report` shows sizes only; safe prunes (uv/npm/docker) run interactively-confirmed or via `--yes`; opt-in purges (pip/bun) need `--yes --include-purge` or an explicit interactive confirm; cargo is report-only. See `-h` for the full mode matrix. |

### Subdirectories

- `util/` — utility subcommands dispatched by the `util` router (see above).
- `themegen/` — Generates terminal/Xresources color themes from JSON palette definitions. Run `gen.sh`.
- `blamecount/` — Node.js tool for summarizing `git blame` stats. Configure via `config.json` (see `config.example.json`).
- `pkg-ioc/` — Supply-chain-attack IOC scanner for npm/PyPI. Has its own tests (`tests/smoke.sh`).
- `gpuedit/` — Config files (themes, keybindings, highlighters) for gpuedit.
- `i3/` — i3 window manager config.
- `gentoo/` — Portage `make.conf`, `package.use`, world files for two machines (bluebox, tower).
- `licenses/` — Plain-text license bodies used by `lifi.sh` (agplv3, gplv2, gplv3, mit, apache2, bsd3, cc0, fdl).

### Config pattern

Scripts that need per-machine customization look for `config.sh` (or `config.lifi`) in the repo root and source it if present. The repo ships `config.example.sh` and `config.example.lifi` as templates — copy and edit locally, never commit the live versions (they are gitignored).

## Quality gates

Run the complete tracked-shell gate before reporting a change complete:

```bash
bash tests/shell-gate.sh
```

The gate enumerates public tracked scripts with `git ls-files -z '*.sh'`, then
runs ShellCheck and `bash -n` over that exact set. It also runs the Debian
maintenance, util router, cache-prune, alias-chain, root-utility, and `pkg-ioc`
smoke suites, followed by the build-system and theme-generation checks.
Gitignored private overlays are intentionally outside this public repository gate.

For focused iteration, the component smoke commands are:

```bash
bash util/tests/debian-maintenance.sh
bash util/tests/util-router.sh
bash util/tests/cache-prune.sh
bash tests/aliases-smoke.sh
bash tests/root-utils-smoke.sh
bash pkg-ioc/tests/smoke.sh
(cd build_system && ./build.sh)
(cd themegen && bash gen.sh)
```

## Public / private split

This is the **public** repo. Private and machine-specific content
(`work-aliases.sh`, private `util/*` scripts, kernel configs, secrets) lives in
a separate private overlay repo and is symlinked into place locally; all such
paths are gitignored here. When adding files, keep private/host-specific detail
(hostnames, credentials, tokens, personal paths) out — this repo is public.

## License

The repo is **CC0 1.0** (public domain); see `LICENSE`. Anything added must be
CC0 / public-domain compatible — do not introduce copyleft (e.g. GPL) or
otherwise restrictively-licensed code into the tracked tree. Vendored
subdirectories keep their own compatible licenses (`build_system/` public
domain, `pkg-ioc/` CC0). New source headers added by `lifi.sh` should use the
`cc0` license body.
