# Debian Maintenance Safety Audit and Full ShellCheck Rollout

*Recommended model/effort — Claude: Opus/high for destructive package and shared-shell contracts; Codex: Sol/high for the same cross-cutting safety work.*

## Context

The current audit found:

- Kernel inventory includes `rc`/uninstalled package records; local evidence shows two installed images mixed with many residual records.
- When the newest kernel is running, cleanup can remove every fallback.
- Plain `apt-get upgrade` can hold upgrades requiring new dependencies; `--with-new-pkgs` permits those dependencies without allowing removals.
- `dpkg-query` patterns include packages in multiple states, so installed status must be filtered explicitly.
- Kernel package hooks already regenerate initramfs/GRUB state; the script must not add retrying `update-grub` repair loops.
- The repository currently has 31 tracked shell files and 319 ShellCheck findings: 14 errors, 140 warnings, and 165 notes.

## Decisions Locked

- Retain the newest two fully installed concrete kernel images plus the running kernel.
- Require root and an interactive TTY; add no automation mode.
- Run `upgrade --with-new-pkgs`, followed by a simulated, approval-gated `full-upgrade`.
- Perform explicit kernel cleanup, then validated and separately confirmed general autoremove.
- Use narrowly scoped, justified ShellCheck directives only for proven false positives; no global code exclusions.
- Stage ShellCheck green status through Debian maintenance, all `util`, leaf/vendored scripts, shared aliases, standalone root utilities, then the full repository.
- Use family-native subagents for isolated cleanup packages; keep destructive/shared contracts and integration direct.

## Key Changes

**WP-1 — Debian maintenance safety contract (~0.8 kSLOC touched, ~1200k tokens).** Persist this plan, then refactor the maintenance workflow and add hermetic regression coverage. Files: `plans/debian-maintenance-shellcheck-rollout.md`, `DEVELOPMENT.md`, `util/debian-maintenance.sh`, `util/tests/debian-maintenance.sh`. *Model: top (Claude Opus/high; Codex Sol/high). Execution: Claude direct (must-direct: destructive transaction safety contract); Codex direct (must-direct: destructive transaction safety contract).*

- Refactor into sourceable functions with a guarded `main`, strict error propagation, root validation, and TTY validation.
- Simulate and display each transaction before a script-level confirmation; use `-y` only after approval.
- Run update, `upgrade --with-new-pkgs`, dependency check, then simulated `full-upgrade`.
- Block `full-upgrade` when its removal set contains kernel images/modules, kernel meta-packages, GRUB, shim, or initramfs packages; do not retry or repair automatically.
- Inventory only fully installed signed or unsigned concrete kernel images. Preserve the newest two and the running image; abort all removal phases if the running package or protected boot artifacts cannot be verified.
- Purge only explicitly approved old image releases and their exact installed header/module companions.
- Simulate autoremove afterward. Reject it if it proposes any kernel image/module or boot-critical package; otherwise display and confirm it separately.
- Leave GRUB/initramfs regeneration to package hooks and stop immediately on hook failure.
- Test residual-package filtering, retention overlap, older running kernels, absent running packages, benign/blocked full-upgrades, declined approvals, autoremove validation, and hook failures without touching the host APT database.

**WP-2 — Remaining `util` ShellCheck cleanup (~0.3 kSLOC touched, ~220k tokens).** Make the router, completion, and helper layer green without changing public commands or argument splitting semantics. Files: remaining tracked `util/*.sh` and a focused router smoke test. *Model: mid (Claude Sonnet/medium; Codex Terra/medium). Execution: Claude subagent (clean scope, 40% normalized saving); Codex subagent (clean scope, 50% normalized saving).*

- Fix quoting, array construction, dynamic source annotations, and completion comparisons.
- Characterize filesystem routing, private-overlay precedence, command discovery, and completion output before changing them.
- Establish the complete `util` directory as the second green ShellCheck target.

**WP-3 — Leaf and vendored script cleanup (~0.5 kSLOC touched, ~260k tokens).** Resolve findings in `build_system/`, `themegen/`, and `pkg-ioc/` while preserving their existing licenses and behavior. Files: tracked shell files under those directories and existing smoke coverage. *Model: mid (Claude Sonnet/medium; Codex Terra/medium). Execution: Claude subagent (clean scope, 40% normalized saving); Codex subagent (clean scope, 50% normalized saving).*

- Correct build flag arrays and positional argument forwarding; add source directives where ShellCheck cannot resolve deliberate includes.
- Mark palette/source fragments with a Bash shell declaration and targeted unused-variable annotations where indirect expansion proves the variables are consumed.
- Keep `pkg-ioc` globals and dynamic sources intact, using targeted annotations backed by its existing smoke suite.
- Avoid global `.shellcheckrc` exclusions.

**WP-4 — Shared alias-chain remediation (~0.9 kSLOC touched, ~1400k tokens).** Make the interactive alias chain green while preserving reload behavior and every public alias/function contract. Files: root alias/config scripts and `tests/aliases-smoke.sh`. *Model: top (Claude Opus/high; Codex Sol/high). Execution: Claude direct (must-direct: evolving shared interactive-shell seam); Codex direct (must-direct: evolving shared interactive-shell seam).*

- Add characterization coverage for sourcing, reloading, generated directory helpers, Git shorthands, argument defaults, completion setup, and the Git-aware `cl`.
- Replace unsafe word splitting and array expansion only where tests lock the intended behavior; use arrays or explicit splitting when splitting is intentional.
- Preserve optional configuration/private-overlay loading and symlink-relative path resolution.

**WP-5 — Standalone root utility remediation (~0.8 kSLOC touched, ~320k tokens).** Clear findings in `dotfiles.sh`, `daylog.sh`, and the remaining tracked root utilities with temp-directory regression coverage for stateful operations. Files: standalone root scripts and `tests/root-utils-smoke.sh`. *Model: mid (Claude Sonnet/medium; Codex Terra/medium). Execution: Claude subagent (clean scope, 40% normalized saving); Codex subagent (clean scope, 50% normalized saving).*

- Characterize dotfile add/backup/restore/list behavior against disposable fixtures before quoting or array changes.
- Preserve daylog formats, database command argument boundaries, symlink installation, and user-management command construction.
- Do not touch real dotfiles, databases, users, logs, or host configuration during verification.

**WP-6 — Full-repository gate integration (~0.3 kSLOC touched, ~600k tokens).** Enroll every tracked `.sh` file in one prescribed green gate, run all smoke suites, document the workflow, and close the pending plan. Files: `AGENTS.md`, `README.md`, `tests/shell-gate.sh`, `DEVELOPMENT.md`. *Model: top (Claude Opus/high; Codex Sol/high). Execution: Claude direct (must-direct: final integration, gates, and commit); Codex direct (must-direct: final integration, gates, and commit).*

- Make the gate enumerate tracked shell files with `git ls-files`, so private/gitignored overlays remain excluded and future tracked scripts are automatically enrolled.
- Run ShellCheck and `bash -n` over the same file set, then the Debian, util, alias, root-utility, build-system, theme, and `pkg-ioc` smoke checks.
- Document exact commands in `AGENTS.md`; update README behavior for Debian maintenance.
- Remove the quoted pending-plan link after the final committed gate passes. Do not edit `FEEDBACK.md`.

## Public Interfaces

- `util debian-maintenance` remains a no-argument command but now requires root and a TTY.
- Declining an individual transaction skips it cleanly; safety-validation failures or package/hook failures return nonzero.
- No explicit boot repair, reboot, `update-grub`, or noninteractive mode is added.
- The repository gate becomes `bash tests/shell-gate.sh` plus the focused smoke scripts.

## Execution

- Execute WPs sequentially because each expands the green baseline.
- Dispatch WPs 2, 3, and 5 in fresh family-native workers using grounded briefs; workers never commit.
- Keep WPs 1, 4, and 6 orchestrator-direct. Review every diff, rerun its scoped gates, and commit each WP separately.
- Preserve the existing Git-aware `cl` behavior throughout.

## Test Plan / Verification

At each WP, run scoped `shellcheck`, `bash -n`, and its smoke test. The final sequential gates are:

```bash
git ls-files -z '*.sh' | xargs -0 shellcheck
git ls-files -z '*.sh' | xargs -0 bash -n
bash util/tests/debian-maintenance.sh
bash util/tests/util-router.sh
bash tests/aliases-smoke.sh
bash tests/root-utils-smoke.sh
bash pkg-ioc/tests/smoke.sh
(cd build_system && ./build.sh)
(cd themegen && bash gen.sh)
```

Acceptance requires zero ShellCheck diagnostics, clean Bash parsing, all hermetic tests passing, unchanged public alias/router behavior, and no automated test invoking real APT, kernel, bootloader, user, database, or dotfile mutations.

## Assumptions

- Supported hosts are Debian/Ubuntu-style systems with Bash, `apt-get`, `dpkg-query`, and standard kernel package hooks.
- “Newest” is determined from fully installed kernel package versions using Debian version comparison.
- The fixed retention count is two; it is not configurable.
- Tracked vendored/public-domain shell files are included in the full gate.
- Inline ShellCheck suppressions require a nearby rationale and must cover only the proven false-positive code.
- Live execution of the audited maintenance command is a later user-run acceptance check, not an automated implementation gate.

**Total ≈ 3.6 kSLOC, ~4000k raw tokens; ~3680k Claude-path / ~3600k Codex-path Opus/Sol-equivalent tokens.**
