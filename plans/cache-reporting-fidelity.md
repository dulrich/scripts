# Cache reporting fidelity — report reclaimable bytes, not bytes present

*Recommended model/effort — Claude implementation: Sonnet/high (careful bash + awk accounting against a pinned brief; no novel architecture); Codex review: Terra/medium (well-scoped single-script change); plan audit: `gpt-5.6-sol`/medium*

**Status: APPROVED 2026-08-31 (rev 1; adversarial audit skipped by user). Execution in progress.**

## Context

`util cache-prune` ships correct and safe *actions* but oversells its *reporting*. Its original survey claimed ~102 GB of reclaimable cache; a live run returned ~27 GB. The spike record at `plans/cache-reporting-fidelity-spike.md` isolates two independent root causes, both instances of one error — `du -sb` and age-sums measure **how much data is present**, not **how much would be returned**:

- **uv / hardlink sharing.** `~/.cache/uv` is 23.06 GB, but ~92% of those bytes are hardlinked into live virtualenvs. Deleting the cache entry only decrements a link count. `uv cache prune` returning zero is *correct*; `du` overstates by ~12–20x.
- **docker / DAG structure.** BuildKit's build cache is a DAG with explicit `Parents:` edges, and will not remove a record while any descendant survives. The decisive probe — `docker builder prune --filter unused-for=1300h --force` → `Total: 0B` despite 8 entries unused for 8 weeks — shows age has **no predictive power** over reclaim. The shipped age-sum probe reported 72.8 GB where the real prune yielded 24.5 GB.

The fix is to make the probes report two distinct figures — total footprint and estimated reclaimable — rather than one number that silently means the wrong thing.

## Decisions locked

1. **Full fix, both probes** (user-approved). Not a docs-only caveat, not a single-probe patch.
2. **Target output shape**: uv reads `22.3GB total, 1.9GB reclaimable`, not a single figure.
3. **Docker reports its own `Reclaimable` figure, explicitly labelled an upper bound**, replacing the age-sum entirely. Age filters remain available for the *prune action* (`--docker-until`); they are simply never used for *reporting*.
4. **Actions are unchanged.** This plan touches the reporting path only. The safety classes (safe / optin / report), confirm gates, `require_not_root`, and every prune verb stay exactly as they are.
5. **Reclaimability rule — inode-complete, not naive link-count-1.** See "Measured premises" below; this supersedes the spike's `link==1` heuristic.
6. **One legend line in the `Total` section**, not per-runtime prose: the per-runtime lines print bare figures, and the `Total` section carries a single sentence explaining that total counts bytes present while reclaimable counts bytes a prune would actually return, with docker's figure an upper bound. Keeps six runtime lines terse and states the distinction once.

## Measured premises

Taken live on 2026-08-31 *after* the spike, and load-bearing for WP-1's design. Both **overturn** an assumption the spike left standing — recorded here so no audit cycle relitigates them by reasoning.

**(a) The link census is faster than `du -sb`, not slower.** The spike warned the `find` pass was "materially slower … a perf consideration". Measured, warm, same tree:

| tree | `du -sb` | link-census `find` |
|---|---|---|
| `~/.cache/uv` (115k files) | 2160 ms | **260 ms** |
| `~/.npm` | 863 ms | **19 ms** |
| `~/.cache/pip` | 243 ms | **10 ms** |

The census is ~8x *faster*. **Consequence: no opt-out flag, no `--fast` mode, no second `du` pass.** One `find` pass replaces `du -sb` outright and yields both figures from one traversal, which also makes total and reclaimable internally consistent by construction. Any WP that reintroduces a perf escape hatch is over-built.

**(b) The naive `link==1` rule undercounts.** Counting only link-count-1 files gives uv 1.08 GB. The inode-complete rule — track how many links to each inode are *seen inside the cache tree*, and count the inode as reclaimable when `seen == st_nlink` — gives **1.88 GB**. The 0.8 GB delta is files hardlinked several times *within* the cache itself, which are fully reclaimable but which `link==1` discards. The rule is also correct in the other direction: `du` counts a multiply-linked inode once, so a naive per-file size sum would double-count it; keying the total by inode fixes both at once. Reference implementation, validated against the table above:

```sh
find "$dir" -type f -printf '%n %i %s\n' |
  awk '{n[$2]=$1; s[$2]=$3; c[$2]++}
       END {for (i in s) {t += s[i]; if (c[i] == n[i]) r += s[i]}
            printf "%d %d\n", t, r}'
```

**(c) Both docker sources are live on this machine and disagree — deliberately.** `docker buildx du` trailing lines give `Shared: 9.099GB / Private: 59.16GB / Reclaimable: 68.26GB / Total: 68.26GB`. Plain `docker system df`'s Build Cache row gives `SIZE 68.26GB / RECLAIMABLE 59.16GB`. buildx's `Reclaimable` counts shared records (nothing is pinned by an active build); `system df`'s excludes them. Both are upper bounds over the ~24.5 GB a real prune returned. Take buildx as primary (trailing `Label:\tvalue` lines are a far more stable parse than any table walk) and `system df` as fallback.

## Summary

Replace the single-value size-probe contract with a two-value one — `<total_bytes> <reclaimable_bytes>` — across all six runtimes. `rt_generic_size` becomes a single-pass inode-complete link census; `rt_docker_size` parses `docker buildx du`'s trailing labelled lines for Total and Reclaimable and drops age-summing entirely. `process_runtime` prints both figures, and the grand-total section reports a footprint total and a reclaimable total, with docker's contribution flagged as an upper bound. Two sequential work packages, both dispatched.

## Key Changes

**WP-1 — two-value size contract and the inode-complete link census.**
*~0.25 kSLOC touched · ~120k tokens · ~10 min wall · mid (Claude Sonnet/high; Codex Terra/medium review-only) · Claude: subagent (60% saving, 68k vs 120k normalized)*
Change the `RT_SIZE` probe contract from one number to `"<total> <reclaimable>"` on one line; reimplement `rt_generic_size` as the single `find`-pass census from premise (b), dropping `du -sb`; update `process_runtime` to parse the pair, print both, and accumulate two running totals; update the `## Total` section to report both. `rt_docker_size` is brought onto the new contract mechanically in this WP by emitting `"<n> <n>"` from its existing age-sum, so the tree stays green — WP-2 replaces its body. Preserve the existing `unavailable` sentinel and every early-return path in `process_runtime` verbatim. Files: `util/cache-prune.sh`, `util/tests/cache-prune.sh`.

**WP-2 — docker probe: labelled `buildx du` parse, upper-bound reporting.**
*~0.18 kSLOC touched, net-negative · ~100k tokens · ~8 min wall · mid (Claude Sonnet/high; Codex Terra/medium review-only) · Claude: subagent (60% saving, 60k vs 100k normalized)*
Replace `rt_docker_size`'s body: parse `docker buildx du`'s trailing `Total:` and `Reclaimable:` lines; on failure fall back to plain `docker system df`'s Build Cache row (SIZE, RECLAIMABLE); on both failing, return `unavailable` as today. Delete `docker_build_cache_bytes` (the `system df -v` table walk) and its tests. Keep `docker_window_seconds` — `--docker-until` still validates and still drives the *prune* filter, it just no longer feeds reporting. Label docker's reclaimable figure an upper bound at the point of print and in `-h`. Files: `util/cache-prune.sh`, `util/tests/cache-prune.sh`, and the `cache-prune` row in `AGENTS.md`.

## Public Interfaces

- **Probe contract (internal, load-bearing).** Every `RT_SIZE` function returns either the literal `unavailable` or `"<total_bytes> <reclaimable_bytes>"` — two decimal integers, one space, one line. This is the seam both WPs are written against.
- **User-visible output.** Per-runtime line gains a reclaimable figure; the `Total` section gains a reclaimable total. No flag is added, removed, or renamed. `--report`, `--yes`, `--include-purge`, `--docker-until` keep their current meanings.

## Execution

Sequential: **WP-2 `after: WP-1`** — WP-2 rewrites a function whose contract WP-1 defines, so dispatching them in parallel would race on the same seam. No `hold-for-user:` markers; no `parallel-ok:` pairs.

Both WPs dispatch to Claude Agent workers on self-contained execution briefs. No must-direct reason applies to either: the file scope is clean and the seam is fully pinnable in prose (it is stated verbatim under Public Interfaces). The orchestrator's own duties — diff review, verbatim gate re-run, one commit per WP — remain direct as always.

Per the fleet contract, the briefs pin the deferred decisions rather than leaving them to worker discretion. Specifically pinned: the exact awk census from premise (b); no perf escape hatch (premise (a)); buildx-primary / `system df`-fallback ordering (premise (c)); and the exact probe contract string format.

## Test Plan / Verification

Full gate, verbatim, before each commit:

```bash
bash tests/shell-gate.sh
```

Focused iteration: `bash util/tests/cache-prune.sh` (currently 45 assertions; expect growth in both WPs).

New coverage required:

- **WP-1** — a hermetic fixture tree built under `mktemp -d` with real `ln` hardlinks, asserting: a file linked once counts as reclaimable; a file linked twice *within* the tree counts reclaimable exactly once (not twice, not zero); a file with an extra link *outside* the tree counts toward total but not reclaimable; an empty and a nonexistent directory both yield `0 0`. Plus a `process_runtime` assertion that both figures print, and that the two grand totals accumulate independently.
- **WP-2** — fixture strings for `buildx du` trailing lines (including the `2.052GB*` shared-marker row, which must not corrupt the parse), for the `system df` Build Cache fallback row, and for an unparseable response asserting `unavailable`. A regression assertion that `--docker-until` still reaches the prune filter (the existing `until=24h` test must survive unchanged).

**Public/CC0 discipline:** fixtures carry synthetic byte counts only — no personal paths, hostnames, or this machine's real cache sizes in code or assertions.

Manual confirmation after both land: `util cache-prune --report` shows uv as roughly `22–23GB total, ~1.9GB reclaimable` and docker's reclaimable figure explicitly marked an upper bound.

## Critical Files

- `util/cache-prune.sh` — `rt_generic_size` (L115), `docker_build_cache_bytes` (L219), `rt_docker_size` (L265), the `RT_SIZE` registry (L387), `process_runtime` (L444), and `main`'s `Total` section (L578-579).
- `util/tests/cache-prune.sh` — sources the script directly and overrides probes; the `DOCKER_DF_FIXTURE` / `DOCKER_DF_EXPECTED_BYTES` pair is WP-2's to retire.
- `plans/cache-reporting-fidelity-spike.md` — the measurement record; premises (a) and (b) above **supersede** its perf note and its `link==1` rule respectively.
- `AGENTS.md` — the `util/cache-prune.sh` table row describes the reporting behaviour and must track it.

## Assumptions

- `docker buildx` is present on this machine (verified live). The `system df` fallback exists precisely because that is not guaranteed on every host the repo lands on.
- `find -printf` is GNU find. Already assumed repo-wide; the gate runs on Debian and Gentoo.
- Reported reclaimable figures are *estimates* by nature. For docker it is an upper bound and is labelled as such. For hardlink-shared trees it is exact at census time but can drift if a venv is deleted between report and prune — acceptable, and not worth a locking scheme.
- The cargo probe stays report-only; nothing here changes its class.
- ~~Left open for the audit: whether the `Total` section should print a one-line explanation of why total ≠ reclaimable.~~ **Closed as decision 6 below** (no auditor was dispatched, so this is pinned here rather than deferred to a worker).

## Audit record

**cycle 1 — disposition: skipped by user (2026-08-31).** The user declined an adversarial pre-approval review at auditor-selection time. Recorded so this plan stays distinguishable from one that was never offered an audit.

Residual risk accepted by that skip, stated plainly so execution carries it knowingly:

- The probe contract under Public Interfaces is unreviewed by a second party. It is the seam both WPs are written against, and WP-2 depends on WP-1 having implemented it exactly — the orchestrator's WP-1 diff review is now the only check on it before WP-2 dispatches.
- The docker fallback ordering (buildx primary, `system df` secondary) rests on premise (c), measured on one host. A host where buildx is absent exercises a path proven only by fixture, not live.
- Premises (a) and (b) are live measurements taken by this session and are the strongest evidence in the plan; they are the parts least in need of an audit, which is part of why the skip is a reasonable trade here.

**Total ≈ 0.43 kSLOC, ~220k raw tokens; ~128k Claude-path (implementation) Opus-equivalent tokens; ~128k Codex-path (review-estimate) Sol-equivalent tokens.**
