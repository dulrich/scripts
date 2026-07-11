# scripts

A personal collection of bash aliases, dotfiles, and small utility scripts.
The entry point is `aliases.sh`, which is meant to be sourced from every shell.

## Install

```bash
git clone <this-repo> ~/scripts
~/scripts/link.sh
```

`link.sh` creates the standard symlinks:

- `~/.bash_aliases` → `aliases.sh` (sourced by `~/.bashrc` on most distros)
- `~/.Xresources` → `Xresources`

Or just add `source ~/scripts/aliases.sh` to your `~/.bashrc`.

## Alias chain

`aliases.sh` is the root. It defines the core aliases/functions and then
chain-loads:

- `git-aliases.sh` — git shorthands (`s`, `a`, `c`, `d`, `u`, `p`, `z`, …).
  Depends on helpers from `aliases.sh`, so it is always sourced after it.
- `debian-aliases.sh` **or** `gentoo-aliases.sh` — selected by OS detection.
- `config.sh` and `work-aliases.sh` — optional local files (see
  [Local overrides](#local-overrides)); sourced only if present.

`aliases.sh` resolves its own location via
`here=$( dirname $( realpath "${BASH_SOURCE[0]}" ) )`, so every sibling-script
reference works regardless of where the file is symlinked from.

## The `util` command

Custom scripts live under `util/` behind a small filesystem-router. Running
`util <command> [args]` execs `util/<command>[.sh]`:

```bash
util                       # list available commands
util youtube-id @handle    # -> util/youtube-id.sh
util vault-snapshot ./dir  # -> util/vault-snapshot.sh
util debian-maintenance    # -> util/debian-maintenance.sh
```

Adding a command is just dropping a new `util/<name>.sh` file — no central
registry. Bash completion for `util` (in `util/completions.sh`) generates its
subcommand list from `util/*.sh`, so new commands complete automatically.

## Key utilities

| Script | Purpose |
|---|---|
| `daylog.sh` | Time-tracking log. Appends to `logs/YYYY-MM-DD.daylog`. Aliases: `dl` (log entry), `dls` (show today), `wl` (last 7 days). |
| `lifi.sh` | Adds license/copyright headers to new source files, reading bodies from `licenses/`. Configured per-project via `config.lifi`. |
| `dotfiles.sh` | Manages dotfiles across machines via a `meta_repo`. Commands: `add`, `backup`, `restore`, `snapshot`, `list`. |
| `build_system/build.sh` | C build system (public domain, from yzziizzy). `mkproject` bootstraps new C projects. Aliases `x` = `./build.sh`, `xd` = `./debug.sh`. |

## Subdirectories

- `util/` — utility subcommands dispatched by the `util` command.
- `build_system/` — C build system + `mkproject`.
- `themegen/` — generates terminal/Xresources color themes from JSON palettes.
- `blamecount/` — Node.js tool summarizing `git blame` stats.
- `pkg-ioc/` — supply-chain-attack IOC scanner for npm/PyPI.
- `gpuedit/` — config (themes, keybindings, highlighters) for the gpuedit editor.
- `i3/` — i3 window manager config.
- `gentoo/` — Portage `make.conf`, `package.use`, and world files.
- `licenses/` — plain-text license bodies used by `lifi.sh`.

## Local overrides

Per-machine and private customization stays out of the repo:

- `config.sh` — machine-specific overrides for `aliases.sh` variables
  (display outputs, audio device, paths). Copy `config.example.sh` → `config.sh`
  and edit. Gitignored.
- `config.lifi` — local `lifi.sh` config. Copy `config.example.lifi`. Gitignored.
- `work-aliases.sh` and private `util/*` scripts — provided by a separate,
  private overlay repo and symlinked into place; both are gitignored so they
  never land in this public repo. The `util` router picks up any private
  subcommands symlinked into `util/` automatically.

## License

[CC0 1.0 Universal](./LICENSE) — dedicated to the public domain. Anything added
to this repo should be CC0 / public-domain compatible. Vendored subdirectories
keep their own (compatible) licenses: `build_system/` is public domain,
`pkg-ioc/` is CC0.
