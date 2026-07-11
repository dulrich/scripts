---
title: Scripts Development Notes
created: 2026-04-16
modified: 2026-07-06
word-count: 62
tags: ""
initiative-visibility: hybrid
initiative-status: active
initiative-cadence: as-needed
pending-plans:
initiative-title: Scripts
initiative-slug: scripts
---

# Blocked on User

---
# Todos

- [ ] test mkproject.sh — emptiness check was broken (scalar/array confusion), verify `--force` behaviour and normal empty-dir case
- [ ] dotfiles.sh `proj_name_list()` — `find | ls` pipe is a no-op, ls ignores stdin and lists cwd instead; fix to use find output directly
- [ ] dotfiles.sh `dotfile_backup()` — `$filename` is never set in this scope (it belongs to `dotfile_add`), so every backup silently targets a malformed path
- [ ] pull updated build system from `extras_and_rejects/build_system`
