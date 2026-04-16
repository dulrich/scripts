# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal scripts and dotfiles collection. The primary entry point is `aliases.sh`, which is symlinked to `~/.bash_aliases` so it loads on every shell session.

## Setup / installation

Run `./link.sh` to create the standard symlinks:
- `~/.bash_aliases` → `aliases.sh`
- `~/.vimrc` → `vimrc`
- `~/.vim` → `vim/`
- `~/.irssi/scripts` → `irssi_scripts/`

Or manually: `ln -s ~/scripts/aliases.sh ~/.bash_aliases`

## Architecture

### Shell alias chain

`aliases.sh` is the root. It always chain-loads:
- `git-aliases.sh` — git shorthands (`s`, `a`, `c`, `d`, `u`, `p`, `z`, etc.)
- `debian-aliases.sh` or `gentoo-aliases.sh` — conditionally by OS detection

It optionally loads (not in repo):
- `config.sh` — local machine-specific overrides for variables like `EXTERNAL_OUTPUT`, `AUDIO_DEVICE`, `code_path`
- `work-aliases.sh` — work-specific aliases

`aliases.sh` uses `$here` (resolved via `realpath "${BASH_SOURCE[0]}"`) so all sibling-script references work correctly regardless of where it is symlinked from.

`git-aliases.sh` depends on `defarg` and `grep_options` defined in `aliases.sh` — it must always be sourced after `aliases.sh`.

### Key utilities

| Script | Purpose |
|---|---|
| `daylog.sh` | Time-tracking log. Appends entries to `logs/YYYY-MM-DD.daylog`. Aliases: `dl` (log entry), `dls` (show today), `wl` (show last 7 days) |
| `lifi.sh` | Adds license/copyright headers to new source files. Reads license texts from `licenses/`. Configured per-project via `config.lifi`. |
| `dotfiles.sh` | Manages dotfiles across machines via a `meta_repo`. Commands: `add`, `backup`, `restore`, `snapshot`, `list`. |
| `build_system/build.sh` | C build system (public domain, from yzziizzy). `mkproject` bootstraps new C projects. Aliases `x` = `./build.sh`, `xd` = `./debug.sh`. |

### Subdirectories

- `magic_8_ball/` — Same fortune-telling program in multiple languages (JS, Lua, Perl, Python, Ruby, Java, C#). Run with `./run <lang>`.
- `pystat/` — Python statistics REPL. Launch with `python -i startup.py` inside a virtualenv (`setup.sh` creates it). Uses numpy/scipy. Put data in `data_file.py` (see `data_file.example.py`).
- `themegen/` — Generates terminal/Xresources color themes from JSON palette definitions. Run `gen.sh`.
- `blamecount/` — Node.js tool for summarizing `git blame` stats. Configure via `config.json` (see `config.example.json`).
- `irssi_scripts/` — Perl scripts for the irssi IRC client. `autorun/` symlinks are loaded automatically by irssi.
- `gpuedit/` — Config files (themes, keybindings, highlighters) for gpuedit.
- `i3/` — i3 window manager config.
- `gentoo/` — Portage `make.conf`, `package.use`, world files for two machines (bluebox, tower).
- `licenses/` — Plain-text license bodies used by `lifi.sh` (agplv3, gplv2, gplv3, mit, apache2, bsd3, cc0, fdl).

### Config pattern

Scripts that need per-machine customization look for `config.sh` (or `config.lifi`) in the repo root and source it if present. The repo ships `config.example.sh` and `config.example.lifi` as templates — copy and edit locally, never commit the live versions (they are gitignored).
