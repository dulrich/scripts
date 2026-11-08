# scripts

A personal bash alias chain, dotfiles and small Linux utilities, published as-is under CC0 for anyone to read or borrow. The alias chain detects Debian-family and Gentoo systems and loads the matching package-manager aliases.

## Install

```sh
git clone <this repository> ~/scripts && ~/scripts/link.sh
```

`link.sh` creates these symlinks (existing links are replaced):

- `~/.bash_aliases` -> `aliases.sh`
- `~/.Xresources` -> `dotfiles/Xresources`
- `~/.config/foot/foot.ini` -> `dotfiles/foot/foot.ini`
- `~/.vim/plugin/osc52.vim` -> `dotfiles/vim/osc52.vim` (OSC 52 yank helper)

To skip the symlinks, add `source ~/scripts/aliases.sh` to `~/.bashrc` instead.

## Layout

```
aliases.sh            alias chain root (loaded via ~/.bash_aliases)
git-aliases.sh        git shorthands
debian-aliases.sh     Debian-family package aliases
gentoo-aliases.sh     Gentoo package aliases
config.example.sh     template for per-machine overrides
link.sh               creates the symlinks above
dotfiles/             Xresources, gdb/, foot/, vim/, gpuedit/
util/                 the `util` router and its subcommands
tools/                self-contained tools: build_system/, blamecount/
tests/                the shell gate and the repo-level smoke suites
```

## Alias chain

`aliases.sh` is the root. It always sources `git-aliases.sh`, then `debian-aliases.sh` or `gentoo-aliases.sh` depending on the OS it detects. It also sources two optional files when they exist: `config.sh` (per-machine overrides) and `private/aliases.sh` (see Local overrides). `git-aliases.sh` relies on helpers defined in `aliases.sh`, so it must be sourced after it.

## The `util` router

`aliases.sh` aliases `util` to `util/dispatch.sh`: `util <command> [args]` runs `util/<command>.sh`. There is no registry; adding a subcommand means adding a file. Helper code lives in a directory named after its command (for example `util/cache-prune/`), one level down where the router's `util/*.sh` glob cannot reach it, so helpers are never routable. Shell completion comes from the same discovery function (`util/lib.sh`) as the command listing that `util` prints with no arguments, so the two cannot drift. Subcommands from an optional private overlay (`private/util/*.sh`) are listed and completed too.

## Tools

- `util cache-prune` - report and prune rebuildable language-runtime caches (uv, npm, docker, pip, bun, cargo) and the home trash: [util/cache-prune/README.md](util/cache-prune/README.md)
- `util debian-maintenance` - root-run interactive APT maintenance, plus a read-only JSON `--report`: [util/debian-maintenance/README.md](util/debian-maintenance/README.md)
- `util battery` - read-only sysfs battery report: charge, health, draw and time to full or empty; `--brief` prints one line
- `util ip` - the machine's real IP addresses, hiding loopback and container interfaces; `--public` adds the public address
- `util dotfiles` - dotfile management across machines through a meta repository (add, backup, list, restore, snapshot, status)
- `util youtube-id` - print a YouTube channel id from a channel URL or handle

Details for these five are in [util/AGENTS.md](util/AGENTS.md), and each answers `--help`.

- [tools/build_system/](tools/build_system/README.md) - a public-domain C build system with a `mkproject` bootstrapper
- `tools/blamecount/` - a bun-run tool that summarizes `git blame` statistics per author and language; see [tools/AGENTS.md](tools/AGENTS.md)

## Versioning

`master` is rolling; there are no releases or semantic versions. Every entrypoint answers `--help`, and `--build` (or `--version`) prints its build id: the 40-hex hash of the last commit that touched that tool, with `-dirty` appended when the tool has uncommitted changes.

```sh
util cache-prune --version
```

## Local overrides and the private overlay

Copy `config.example.sh` to `config.sh` to set per-machine values such as paths and display outputs; `config.sh` is gitignored and `aliases.sh` sources it when present.

An optional private overlay may be checked out at `private/` (also gitignored). It can hold `private/aliases.sh` (sourced at the end of the chain), `private/util/*.sh` subcommands, and cache-prune runtime modules in `private/util/cache-prune/fleet/*.pm`. With `private/` absent everything works unchanged.

## Checks

```sh
bash tests/shell-gate.sh
```

This is the full public gate: ShellCheck and `bash -n` over every tracked `.sh` file, the hermetic suites for the utilities, the alias chain and the public contract, the build-system compile and smoke, and the blamecount smoke. It needs `shellcheck`, `perl` (with JSON::PP), a C compiler (`gcc`) for the build-system step, and `bun` for blamecount.

Two maintainer-only checks, the `--help` contract gate and the shell-disposition gate, run from tooling that is not published. Their manifests are not part of the public tree, and the shell gate skips the disposition step with a message when its manifest is absent.

## License

CC0 1.0 (see `LICENSE`). `tools/build_system/` is public domain and keeps its own license. Contributions must be CC0-compatible.
