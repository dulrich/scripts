# Runtime Cache Pruning

*Recommended model/effort — Claude implementation: Sonnet/medium (well-scoped shell implementation against a pinned spec; no novel architecture); Codex review: Terra/medium (destructive-operation review on a small, self-contained surface); plan audit: `gpt-5.6-sol`/medium (default tier)*

**Status: IMPLEMENTED 2026-08-31 (rev 2; WP-1 `a6b6266`, WP-2 `1477690`)**

## Context

`FEEDBACK.md` carries the todo: *"debian-maintenance : `uv cache prune` and check parallel commands for other runtimes on the system (node/bun/rust/others?)"*.

The machine is under real disk pressure — `/` is at **75%** (88 G free) and hosts Docker; `/home` is at 68% (297 G free). A live survey found ~102 GB of reclaimable, rebuildable cache spread across five ecosystems, plus a gap in the existing maintenance script.

Two findings reshape the naive reading of the todo:

1. **The todo's premise is structurally wrong.** `util/debian-maintenance.sh` opens with `require_root`. The user-owned language-runtime caches all live under the invoking user's account (Docker's build cache is the exception — root-owned, and reached through the daemon rather than the filesystem). Adding `uv cache prune` to that script means running it as root, which prunes *root's* empty cache and reports success — a silent no-op. Runtime cache pruning cannot live in the root-run script.
2. **The root script has a genuine, unrelated gap**: it never runs `apt-get autoclean`/`clean`, leaving 1.3 G of `.deb` archives in `/var/cache/apt/archives`. That work *does* belong in `debian-maintenance.sh`.

So the todo splits into a new user-level tool and a small fix to the existing root tool.

## Decisions locked

User-confirmed 2026-08-31, before drafting:

1. **Structure** — new user-level `util/cache-prune.sh` for runtime caches; separately add the missing apt archive cleanup to root-run `util/debian-maintenance.sh`. The root/user split is the core structural constraint.
2. **Aggression** — safe prunes run by default; ecosystems with no safe prune verb (pip, bun) are offered only behind explicit **per-runtime** confirm prompts, reusing the existing `confirm()` pattern.
3. **Docker** — user's constraint, verbatim: *"prune whatever is safe and unlikely to trigger large new downloads every time the context-control fleet is rebuilt."*

## Measurements (live, 2026-08-31 — do not re-derive)

Disk: `/` 366 G, 75% used, 88 G avail (Docker lives here). `/home` 974 G, 68% used, 297 G avail.

| Target | Size | Prune verb | Class |
|---|---|---|---|
| Docker build cache | 92.83 GB total, **71.66 GB last used weeks ago** | `docker builder prune --filter until=168h` | safe |
| `~/.cache/uv` | 22 GB | `uv cache prune` (true prune — unreachable objects only) | safe |
| `~/.npm` | 7.0 GB | `npm cache verify` (GCs unreferenced entries) | safe |
| `~/.cache/pip` | 6.3 GB | `pip cache purge` — **nuke-all only** | opt-in |
| `/var/cache/apt/archives` | 1.3 GB | `apt-get autoclean` (389 MB) / `clean` (all) | safe / opt-in |
| `~/.bun/install/cache` | 1.3 GB | `bun pm cache rm` — **nuke-all only** | opt-in |
| `~/.cargo/registry` | 485 MB | no builtin; `cargo-cache` **not installed** | report-only |
| `~/.cache/huggingface` | 26 GB | — | **excluded**: model weights, not rebuildable cache |

Docker build cache by last-used age: weeks-ago 1451 entries / **71.66 GB**; days-ago 597 / 18.75 GB; hours+minutes 29 / 2.40 GB. Docker daemon 29.7.2 reachable.

**Docker images are excluded, on evidence.** There are **zero dangling images**, so `docker image prune` reclaims literally nothing. The 69.44 GB that `docker system df` reports as reclaimable is entirely *tagged* images, headed by `vllm/vllm-openai-rocm` (42.4 GB) and `vllm/vllm-openai` (30.2 GB) — re-pulling those is exactly the "large new download" the user's constraint rules out. The 168 h build-cache window preserves every entry any build touched in the last week; the fleet is demonstrably active inside that window (a `crucible-llamacpp-vulkan` image built 17 minutes before the survey, `open-webui` 11 hours), so a rebuild re-runs nothing it would otherwise have cache-hit.

Installed: uv 0.11.3, npm 11.13.0 (nvm-managed), bun 1.3.11, cargo 1.95.0, rustup, docker, flatpak, pip. Absent: pipx, poetry, pnpm, yarn, deno, go, podman, nix, ccache, composer, gem, snap, dotnet, conda, cargo-cache.

Verified command surfaces: `npm config get cache` → `/home/dulrich/.npm`; `pip cache dir` → `/home/dulrich/.cache/pip`; `uv cache size` works but is **experimental** (warns without `--preview-features cache-size`); `bun pm cache` **fails outside a package directory** (`error: No package.json was found`); `apt-get -s autoclean` emits **`Del `** lines, *not* `Remv` — the script's existing `extract_removals`/`transaction_has_changes` parsers do not apply to it.

## Summary

Add `util/cache-prune.sh`, a user-level (explicitly **non-root**) subcommand that walks a registry of detected runtimes, reports reclaimable space per runtime, and applies prunes behind per-runtime confirmation. Safe prunes (uv, npm, docker build cache) are the default path; nuke-only ecosystems (pip, bun) require an explicit opt-in; cargo is report-only until `cargo-cache` exists. Separately, add an apt-archive cleanup stage to `util/debian-maintenance.sh` where root privilege actually applies. Both get hermetic tests in the established source-and-stub style and are wired into `tests/shell-gate.sh`.

## Key Changes

**WP-1 — `util/cache-prune.sh` + hermetic tests.**
*~0.45 kSLOC touched · ~90k tokens (Codex review est. ~30k raw) · ~10 min wall · mid (Claude Sonnet/medium; Codex Terra/medium review-only) · Claude: subagent (60% saving; 56k dispatched vs 90k direct)*
New user-level subcommand and its test suite. Files: `util/cache-prune.sh` (new), `util/tests/cache-prune.sh` (new), `tests/shell-gate.sh` (wire the new smoke), `AGENTS.md` (util section + gate list).

Required behaviour:

- **`require_not_root`** — the mirror of `debian-maintenance.sh`'s `require_root`, and the load-bearing guard of this whole design. Refuse to run under sudo/root with a message naming the reason (root's caches are not the user's). This encodes decision 1 in executable form.
- **Runtime registry**, one entry per ecosystem, each carrying: detect predicate, cache-dir resolver, size probe, prune command, and class (`safe` | `optin` | `report`). Adding an ecosystem is adding a registry entry, not editing control flow.
- **Detection is dynamic** (`command -v`), never hardcoded paths — the repo is public and must degrade cleanly on machines lacking a runtime. A missing runtime prints a one-line skip, not an error.
- **Cache dirs come from the tool**, never hardcoded: `npm config get cache` (nvm-managed npm is PATH-dependent — resolve at runtime), `pip cache dir`, `uv cache dir`, `${BUN_INSTALL:-$HOME/.bun}/install/cache`.
- **Size probe**: `du -sb` on the resolved cache dir is the uniform, stable probe. Deliberately **not** `uv cache size` — it is experimental and its flag surface may shift; a warning-suppression flag is not worth the coupling. Docker is the exception: `/var/lib/docker` is root-owned, so parse build-cache reclaimable from `docker system df` instead.
- **Docker preflight**: CLI present is not enough — `docker info` must succeed. A present CLI with a dead daemon must skip gracefully, not abort under `set -e`.
- **Docker prune**: `docker builder prune --filter until=<window> --force`, window default `168h`, overridable via flag. Never `docker image prune`, never `docker system prune`.
- **bun wrinkle**: `bun pm cache rm` fails outside a package directory (measured). Run it from a scratch dir holding a minimal `package.json`. If it still fails, report and skip — **never** fall back to a blind `rm -rf` of the cache path.
- **Mode matrix** — this is the full contract; no combination is left undefined:

  | Invocation | safe prunes (uv, npm, docker) | opt-in purges (pip, bun) |
  |---|---|---|
  | `--report` | report size only; no prompt, no mutation | report size only; no prompt, no mutation |
  | *(default, interactive)* | per-runtime confirm → act | per-runtime confirm (prompt defaults to **No**) → act only on explicit yes |
  | `--yes` | auto-confirmed → act | **skipped entirely**, without prompting |
  | `--yes --include-purge` | auto-confirmed → act | auto-confirmed → act |

  `--report` must work non-TTY (cron/monitoring-safe). `--include-purge` is meaningful **only** together with `--yes` — it is the non-interactive unlock, since interactive mode already offers purges via their own prompt; passing it interactively changes nothing. The load-bearing safety property: **`--yes` alone never purges pip or bun.**
- **Reporting**: print reclaimed total per runtime and a grand total.
- Style matches the sibling script: `set -euo pipefail`, `section()`/`die()`/`confirm()`/`require_tty()`, report-then-confirm, no destructive op without confirmation.
- **Testability contract**: keep the `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi` guard so tests can source the file, and invoke every external tool as a bare command so tests can stub it as a shell function — the exact pattern `util/tests/debian-maintenance.sh` already uses.

Tests must cover: root refusal; graceful skip on absent runtime; docker daemon-down skip; `--report` mutates nothing — assert an empty **mutation** log, while explicitly permitting detection, cache-dir resolution and size-probe calls (`npm config get cache`, `pip cache dir`, `uv cache dir`, `du`, `docker info`, `docker system df`), which reporting necessarily makes; safe prunes fire under `--yes`; **pip/bun purges do NOT fire under `--yes` alone, and are skipped without prompting** (the load-bearing safety assertion); purges fire under `--yes --include-purge`; interactive purge prompts default to No and a declined prompt executes nothing; docker prune carries the `until=` filter.

**WP-2 — apt archive cleanup in `debian-maintenance.sh`.** `after: wp-1`
*~0.12 kSLOC touched · ~60k tokens (Codex review est. ~20k raw) · ~5 min wall · mid (Claude Sonnet/medium; Codex Terra/medium review-only) · Claude: subagent (60% saving; 44k dispatched vs 60k direct)*
Add the missing apt cache stage to the root script. Files: `util/debian-maintenance.sh`, `util/tests/debian-maintenance.sh`, `AGENTS.md`.

- New `run_apt_cache_cleanup()`, called from `main()` after `run_autoremove`, before the closing `Done` section.
- Report current archive size, then `apt-get -s autoclean` to preview, confirm, and run `apt-get -y autoclean` (safe: drops only no-longer-downloadable `.deb`s — 389 MB here).
- Full `apt-get clean` offered behind a **second, separate** confirm (reclaims the remaining ~900 MB at the cost of re-downloading current packages). Matches the safe/opt-in split from decision 2.
- **Parser caveat, measured**: `apt-get -s autoclean` emits `Del ` lines, so `transaction_has_changes`/`extract_removals` (which match `^(Inst|Remv) `) must **not** be reused. Add a distinct `Del `-aware check. Reusing the existing helpers here is the most likely implementation bug and the reviewer should look for it specifically.
- Extend `util/tests/debian-maintenance.sh` with the established `apt-get` stub + `APT_LOG` assertions: no-changes path runs nothing, confirmed autoclean runs exactly once, declined confirm runs nothing, `clean` only after its own confirm.

## Public Interfaces

- New user command: `util cache-prune [--report] [--yes] [--include-purge] [--docker-until <window>]`. Auto-discovered by `util/dispatch.sh` and `util/completions.sh` (both enumerate `util/*.sh`) — no registry edit needed.
- `util/debian-maintenance.sh` gains one interactive stage; its CLI contract (`usage: $0`, no arguments) is unchanged.
- No new env vars beyond honouring existing `BUN_INSTALL`.

## Execution

Chain: `wp-1 → wp-2`. Both dispatch to Claude Agent workers on self-contained execution briefs.

The `after: wp-1` edge exists only because both WPs touch `AGENTS.md` and would otherwise conflict; they are functionally independent. `parallel-ok:` is deliberately **not** set.

No `hold-for-user:` markers — neither WP touches user-owned files. Note that **`FEEDBACK.md` is user-owned and must not be edited**: closing the todo line is the user's action, not the implementing session's.

## Test Plan / Verification

Full gate, re-run verbatim by the orchestrator before each commit:

```bash
bash tests/shell-gate.sh
```

Focused during iteration:

```bash
bash util/tests/cache-prune.sh
bash util/tests/debian-maintenance.sh
bash util/tests/util-router.sh
```

Observable outcomes beyond green gates:

- `util cache-prune --report` on this machine lists uv ≈22 G, npm ≈7.0 G, pip ≈6.3 G, bun ≈1.3 G, cargo ≈485 M (report-only), docker build cache ≈71.7 G reclaimable at the 168 h window — and mutates nothing.
- `sudo util cache-prune` refuses with the root-mismatch message.
- `util cache-prune --yes` prunes uv/npm/docker only; `pip cache dir` and the bun cache remain non-empty afterward.
- ShellCheck passes on both new/changed scripts (the gate enumerates via `git ls-files '*.sh'`, so the new files are covered automatically once tracked).

## Critical Files

- `util/cache-prune.sh` — new; the whole user-level surface.
- `util/debian-maintenance.sh` — root-run; `main()` ordering and the `Del `-vs-`Remv` parser distinction.
- `util/tests/cache-prune.sh`, `util/tests/debian-maintenance.sh` — hermetic source-and-stub suites.
- `tests/shell-gate.sh` — gate wiring; new smoke must be added.
- `util/dispatch.sh`, `util/completions.sh` — read-only here; they auto-discover, confirming no registry edit is needed.
- `AGENTS.md` — util section and gate command list.

## Assumptions

- Reclaim figures are point-in-time (2026-08-31) and will drift; they are targets for eyeballing the report, not assertions to encode in tests. **No test may assert a specific byte count from this machine** — that would be a machine-specific dependency in a public repo.
- 168 h is a judgement call fitting the observed weeks-vs-days cliff (71.66 GB vs 18.75 GB), not a measured optimum. Exposed as a flag precisely because it is a judgement call.
- `~/.cache/huggingface` (26 GB) is treated as data, not cache, and is out of scope. If the user wants it managed, that is a separate plan — `huggingface-cli delete-cache` is interactive and revision-aware.
- cargo stays report-only. If `cargo-cache` is later installed, the registry entry should detect it and offer `cargo cache --autoclean` as a safe prune; the entry should be shaped to allow that without restructuring.
- flatpak is installed but its store is 52 K — below the noise floor, omitted. `flatpak uninstall --unused` is a package operation, not a cache prune.
- Assumed the user runs this manually, not from cron. `--report` is built non-TTY-safe to keep the cron door open, but no scheduling is in scope.

## Audit record

**Cycle 1** — `codex-david` / `gpt-5.6-sol` / medium, read-only, at base commit `d652d7b`. Brief: `runs/dispatch/runtime-cache-pruning-plan-audit-brief.md`; report: `runs/dispatch/runtime-cache-pruning-plan-audit-report.md`. Verdict: **0 blocking — sound to execute / 3 material / 5 execution-level / 1 minor**.

Auditor constraint recorded: `FEEDBACK.md` could not be read (deny-enforced for Codex), so the quoted todo text was not independently verified. Expected and correct — that file is user-owned.

Every finding dispositioned:

| # | Class | Finding | Disposition |
|---|---|---|---|
| 1 | material | Purge-mode contract internally inconsistent — default-interactive handling of pip/bun undefined between Decisions locked and the Modes bullet | **valid-actionable** — verified against plan text; the Modes bullet genuinely never defined interactive purge behaviour. Fixed in rev 2 with a full four-row mode matrix; no combination now undefined. |
| 2 | material | `--report` test cannot assert an empty command log — reporting must invoke resolvers/probes | **valid-actionable** — verified; the assertion as written would have proven reporting never ran. Fixed: assertion is now an empty *mutation* log with probe calls explicitly permitted. |
| 3 | material | ~20k Codex-path total not recomputable from the document | **valid-actionable** — verified; the raw review inputs existed only in the drafting session. Fixed: per-WP raw review estimates added to both tag lines plus an explicit derivation under the totals. |
| 4 | execution-level | Docker report algorithm unpinned — needs verbose output and age-filtered derivation, not the `docker system df` summary | **valid-defer-to-execution** — true; pin the exact parse and fixture in WP-1's execution brief. Plan text unchanged. |
| 5 | execution-level | cargo entry lacks a cache-dir resolver; must honour `CARGO_HOME` | **valid-defer-to-execution** — true and correct; resolver list omitted cargo because it is report-only. Brief instructs `${CARGO_HOME:-$HOME/.cargo}`. Plan text unchanged. |
| 6 | execution-level | `require_tty()` placement could contradict the non-TTY `--report` invariant | **valid-defer-to-execution** — true; the invariant is already stated, and the resolution (call it after arg parsing, only for prompting modes) is within worker discretion. Carried to the brief. |
| 7 | execution-level | Partial-failure exit semantics unspecified | **valid-defer-to-execution** — true; brief defines the aggregate policy (per-runtime failure warns and continues, grand total still printed, aggregate nonzero exit if any runtime failed). Plan text unchanged. |
| 8 | execution-level | Final ShellCheck/`bash -n` coverage depends on the new scripts already being tracked (`git ls-files`) | **valid-defer-to-execution** — true, and an orchestrator-side commit-sequencing detail: stage the new scripts by explicit path *before* the final full-gate run. Carried into the WP-1 commit step. |
| 9 | minor | "Every runtime cache lives under `$HOME`" overbroad — the plan itself treats Docker's cache as root-owned | **valid-actionable** — verified; the sentence sits in the load-bearing Context section, so worth correcting despite being minor. Reworded in rev 2. |

**Convergence exit**: no cycle 2. No blocking finding invalidated a premise or forced an architecture change; no WP was rescoped or resized (all four corrections are bounded text fixes to a single bullet, one test assertion, two tag lines and one sentence); the user has not requested another cycle.

**Residual risk** (the unaudited fold of the final cycle's corrections, accepted by design): the rev-2 mode matrix, the revised report-test assertion, the estimate-derivation paragraph and the reworded Context sentence have not themselves been audited. The mode matrix is the one that carries real weight — it defines the safety property that `--yes` alone never purges, and it is new text. WP-1's test suite is specified to assert exactly that property, so an implementation error in it fails the gate rather than reaching disk.

### Execution-brief carry-ins

Findings 4–8 are not plan defects but must not be lost — each is an instruction to the execution brief that WP-1 (4, 5, 6, 7) and the WP-1 commit step (8) must carry.

**Total ≈ 0.57 kSLOC, ~150k raw tokens; ~100k Claude-path (implementation) Opus-equivalent tokens; ~20k Codex-path (review-estimate) Sol-equivalent tokens.**

Estimate inputs, so the totals are recomputable: Claude path — raw 90k + 60k, dispatched to Sonnet (weight 0.4) with ~20k orchestrator overhead each at Opus weight 1.0 → 56k + 44k = **100k**. Codex path — raw review 30k + 20k at Terra weight 0.4 → 12k + 8k = **20k**. Both verified with `model-cost.mjs`.
