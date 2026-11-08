# util debian-maintenance

Interactive APT maintenance for Debian-family systems. It must run as root on a terminal; run unprefixed as a normal user it re-executes itself under `sudo`. `util debian-maintenance --help` prints the short usage.

## Steps

Each destructive step is simulated first and then asks for its own explicit confirmation:

1. `apt-get update`, then upgrade and full-upgrade.
2. Old-kernel cleanup. The keep-set protects it: the newest two installed kernels and the running kernel are always kept. (The boot-critical package guard, which refuses any removal that would take out what the system needs to boot, covers full-upgrade and autoremove.)
3. Autoremove of packages no longer required.
4. A sweep of `rc`-state kernel packages (old `linux-image-*` and `linux-modules-*` that were removed but not purged), purged behind a confirm. Only exact `rc` status is considered, never the running kernel.
5. APT archive cleanup: a preview with `apt-get -s autoclean` and one confirm to run it, then a separate confirm for a full `apt-get clean`.
6. Journal: prints `journalctl --disk-usage` and, behind its own confirm, vacuums archived journal files down to 200M. Skipped when `journalctl` is absent or its usage cannot be read.

## `--report`

`util debian-maintenance --report` is the only non-interactive mode. It needs no root and no terminal, runs no `apt-get update` and changes nothing. It prints one JSON object on stdout and exits 0, with these top-level keys: `host`, `indexAgeSeconds` (age of the newest APT list file, or `-1`), `upgradable`, `securityUpgradable`, `autoremovable`, `rcKernels` and `rebootRequired`.

## Exit codes

- `0` success
- `1` not run as root, no interactive terminal, or a step failed (a failing command's own exit status is passed through)
- `2` a usage error (the only accepted argument is `--report`)

## Requirements

`perl` with `JSON::PP`, both part of a standard Debian install, plus `apt`, `apt-get` and `dpkg`.
