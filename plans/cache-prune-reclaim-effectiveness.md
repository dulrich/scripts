# Cache prune reclaim effectiveness — make the tool actually free space, and prove it did

*Recommended model/effort — Claude implementation: Sonnet/high (registry restructuring + careful action-path changes in a script that deletes user data); Codex review: Terra/medium; plan audit: `gpt-5.6-sol`/medium*

**Status: AUDITED 2026-09-01 (rev 2; cycle-1 codex-david/`gpt-5.6-sol`/medium, 1 blocking / 4 material / 1 execution-level, dispositioned)**

## Context

The predecessor plan (`plans/cache-reporting-fidelity.md`, IMPLEMENTED) fixed the *size census*: reported bytes now exclude what is hardlinked outside the cache. It did not fix the thing the user actually cares about. A live `--yes` run reclaims **nothing** while the tool reports 76.8 GB "reclaimable":

```
uv     21.5GB total, 1.8GB reclaimable   -> uv cache prune   -> "No unused entries found"
npm     4.1GB total, 4.1GB reclaimable   -> npm cache verify -> verifies, frees nothing
docker 63.6GB total, 63.6GB reclaimable  -> builder prune --filter until=168h -> "Total: 0B"
```

The census number is not wrong — it correctly measures bytes not held from outside the cache, which is what a **full clean** would free. The error is that the tool reports that quantity and then runs a *different* verb that frees approximately none of it. This is the same "measured one thing, promised another" defect the predecessor plan existed to eliminate, displaced one level up from sizing into actions.

Root cause per runtime, measured (see "Measured premises"):

- **docker** — the `until=168h` filter is the whole problem. Docker's own accounting says `ACTIVE 0, RECLAIMABLE 59.16GB`; an unfiltered prune removes unused cache and never touches an in-use record. The filter blocks ~59 GB for no safety benefit, because the build-cache DAG retains an old parent with a recent child regardless of age.
- **uv / npm** — their safe verbs (`uv cache prune`, `npm cache verify`) are conservative by design and free ~0 on a healthy cache. The space is only reachable via `uv cache clean` / `npm cache clean --force`, which are genuinely destructive and belong behind the existing opt-in purge tier.

## Decisions locked

1. **Docker: drop the default age filter.** The safe tier runs `docker builder prune --force` unfiltered. `--docker-until` remains available as an opt-in narrowing and keeps its parse-time validation (`6aa7edc`), but is no longer applied by default. No new destructive verb — docker's own guarantee (never removes an ACTIVE record) is what makes this safe, and `--all` is explicitly **not** adopted. Measured basis: premise (a), not the DAG argument alone.
2. **uv and npm join the opt-in purge tier** alongside pip and bun: `uv cache clean` and `npm cache clean --force`, behind the same explicit `--include-purge` confirm the existing purge runtimes already require. Their safe verbs stay exactly as they are for the safe tier.
3. **Stop predicting what can be measured.** Every action path measures the cache before and after and reports the **observed footprint delta** — deliberately not called "bytes actually freed": premise (a) measured docker's own reported 59.16 GB against 58.60 GB of real disk, a ~1% gap, and a concurrent cache write can even make a delta negative. The value is an observation, labelled as one, never an exact attribution. Prediction has now failed twice in this codebase (the age-sum, and this plan's parent). Actual-freed is ground truth and needs no premise.
4. **The estimate column is relabelled to what it measures**, and is stated per tier rather than as one conflated "reclaimable" figure — the safe verb and the purge verb free different amounts and must not share a number.
5. **`--all` is out of scope** (user-declined). Rev 1 justified this by claiming the residual ~9 GB *is* the `--all` slice; premise (a) shows that is false — the residual is `Shared`, and `--all` concerns internal/frontend images, a different axis. `--all` stays out of scope on blast-radius grounds alone, with **no claim** about what it would free.

6. **`RT_PRUNE` becomes safe-only, and pip/bun migrate into `RT_PURGE`.** Today `RT_PRUNE` holds uv/npm/docker safe verbs *and* pip/bun destructive purges (`util/cache-prune.sh:461-467`); safety is carried separately by `RT_CLASS`. Adding `RT_PURGE` for uv/npm alone would leave two competing representations of a purge and force runtime-specific branches in `process_runtime`. So pip and bun move out of `RT_PRUNE` entirely, ending with a `RT_PURGE` entry and **no** `RT_PRUNE` entry, and `RT_PRUNE` means "the safe verb" only after that migration.
7. **Dual-verb mode matrix, pinned** (a runtime may now hold both a safe and a purge verb):

| mode | safe-only (docker) | dual-verb (uv, npm) | purge-only (pip, bun) | report-only (cargo) |
|---|---|---|---|---|
| `--report` | no action | no action | no action | no action |
| `--yes` | safe verb | **safe verb only** | nothing | no action |
| `--yes --include-purge` | safe verb | **purge verb only, not both** | purge verb | no action |
| interactive | confirm safe | confirm safe; then a **separate** purge confirm, offered only when `--include-purge` was passed | confirm purge | no action |

The purge verb supersedes the safe verb for a dual-verb runtime rather than running after it — the safe verb's work is a strict subset, so running both wastes time and muddies the freed-bytes accounting.

## Measured premises

Taken live 2026-08-31. Load-bearing; do not re-derive by reasoning.

**(a) MEASURED — the unfiltered prune frees the Private slice exactly, and `system df` is its exact predictor.** Full record: `plans/cache-prune-docker-prune-spike.md` (user-authorised, destructive, **unrepeatable**).

```
before: Total 68.26GB  Private 59.16GB  Shared 9.099GB   system df RECLAIMABLE 59.16GB
  $ docker builder prune --force          # unfiltered, no --all
after:  Total 9.099GB  Private 0B        Shared 9.099GB   system df RECLAIMABLE 0B
docker reported freed 59.16GB; disk avail rose 58.60GB
```

Three consequences, all replacing claims rev 1 asserted without measurement:

- **`system df`'s Build Cache RECLAIMABLE predicted the outcome exactly** (59.16 GB → 59.16 GB freed). `buildx du`'s `Reclaimable:` overstated by 9.10 GB. The estimate for this verb must come from `system df`, and this is now measured rather than argued.
- **The residual 9.099 GB is exactly `Shared`, and is NOT "the `--all` slice"** — rev 1 conflated two different dimensions of docker's accounting, which the audit caught. After the prune docker reports `Reclaimable: 0B`: it considers nothing further reclaimable. Whether `--all` touches any of that 9.099 GB is **unmeasured and unclaimed**.
- **Reported freed (59.16 GB) ≠ disk freed (58.60 GB), a ~1% gap.** Docker's accounting is quantised — it renders rounded tokens like `68.26GB` even under `--format json` — and does not reconcile exactly with the filesystem.

**(b) No prune verb offers a dry run.** Neither `uv cache prune` nor `docker builder prune` has `--dry-run`. There is therefore **no way to predict** what the safe verbs would free short of running them. This is the direct justification for decision 3: measure the delta, do not model it.

**(c) The safe verbs are near-no-ops by design, not by defect.** `uv cache prune` is documented as "Prune all *unreachable* objects from the cache" — a cache entry hardlinked only inside the cache is still *reachable* from uv's index, so it is correctly retained. `npm cache verify` verifies and compacts; it garbage-collects unreferenced content and is not a size-reducing verb on an already-compacted cache (it freed ~2.9 GB on its first-ever run in the earlier spike, then nothing on subsequent runs). Neither is broken. Both are simply the wrong verb to report a full-clean figure against.

**(d) The two docker sources still disagree, and this plan deliberately does not settle it.** `buildx du` reports `Reclaimable: 68.26GB`; `system df` reports `59.16GB`. Under decision 3 the disagreement stops mattering: the estimate is labelled an estimate and the *reported outcome* is the measured delta. Do not spend a WP reconciling them.

## Summary

Three sequential work packages. First unblock docker's safe tier by dropping the default filter. Then extend the registry so a runtime can carry both a safe verb and a purge verb, and enrol uv and npm in the purge tier. Finally, replace the single conflated "reclaimable" figure with a per-tier estimate plus a measured, reported actual-freed delta on every action — which is what makes the tool self-validating and closes this class of defect permanently.

## Key Changes

**WP-1 — docker: unfiltered safe prune, filter becomes opt-in.**
*~0.15 kSLOC touched · ~90k tokens · ~7 min wall · mid (Claude Sonnet/high; Codex Terra/medium review-only) · Claude: subagent (60% saving, 56k vs 90k normalized)*
Default `DOCKER_UNTIL` to empty. `rt_docker_prune` applies `--filter until=…` only when a window was explicitly supplied, otherwise runs `docker builder prune --force` bare. Parse-time validation from `6aa7edc` is unchanged and still rejects a malformed explicit window. Align docker's reported estimate with the verb that will now actually run (`system df`'s `RECLAIMABLE`, which is the figure corresponding to an unfiltered prune) while keeping the upper-bound labelling. Update `-h` and the `AGENTS.md` row. Files: `util/cache-prune.sh`, `util/tests/cache-prune.sh`, `AGENTS.md`.

**WP-2 — purge tier for uv and npm (registry gains a second verb per runtime).**
*~0.25 kSLOC touched · ~130k tokens · ~10 min wall · mid (Claude Sonnet/high; Codex Terra/medium review-only) · Claude: subagent (60% saving, 72k vs 130k normalized)*
Today `RT_CLASS` is single-valued and each runtime has exactly one `RT_PRUNE` verb, so a runtime is either safe or opt-in but never both. Add an `RT_PURGE` registry so a runtime can carry a conservative safe verb *and* a destructive purge verb; `process_runtime` selects by mode. Enrol `uv cache clean` and `npm cache clean --force` as purge verbs while their safe verbs stay unchanged. pip and bun keep their current behaviour exactly — they have no safe verb and must not acquire one. Every destructive step keeps its own explicit confirm; `--include-purge` semantics are unchanged. Files: `util/cache-prune.sh`, `util/tests/cache-prune.sh`, `AGENTS.md`.

**WP-3 — measured actual-freed reporting; retire the conflated estimate.**
*~0.25 kSLOC touched · ~130k tokens · ~10 min wall · mid (Claude Sonnet/high; Codex Terra/medium review-only) · Claude: subagent (60% saving, 72k vs 130k normalized)*
Measure each cache immediately before and after its action and print the observed footprint delta (labelled as such per decision 3, never as exact attributed bytes), with a grand total at the end. Define behaviour for a non-decrease and for a negative delta rather than assuming reclaim. Replace the single "reclaimable" column with a per-tier estimate labelled for the verb it corresponds to (safe vs purge), so no number is ever reported against a verb that will not free it. Docker's before/after comes from its own accounting rather than a directory census. Files: `util/cache-prune.sh`, `util/tests/cache-prune.sh`, `AGENTS.md`.

## Public Interfaces

- **`--docker-until`** — unchanged spelling and validation; changed default (was `168h`, now unset/no filter). This is a **behaviour change to a destructive action's scope** and is the single highest-risk item in this plan; it must be called out in `-h` and `AGENTS.md`.
- **`--include-purge`** — unchanged spelling and confirm semantics; now additionally covers uv and npm.
- **Probe contract** — the `"<total> <reclaimable>"` seam from the predecessor plan (`234637d`) still holds. WP-3 changes what the second value *means* per tier, not the wire format.
- **Registry** — new `RT_PURGE` associative array; `RT_PRUNE` is **narrowed** to safe-only, with pip/bun migrating out of it (decision 6). This is a change to `RT_PRUNE`'s current meaning, not a preservation of it.

## Execution

Sequential: **WP-2 `after: WP-1`**, **WP-3 `after: WP-2`**. WP-1 and WP-2 both touch the action path and the registry; WP-3's before/after measurement must wrap whichever verbs the first two settle on. No `parallel-ok` pairs — every WP owns `util/cache-prune.sh`.

`hold-for-user:` on **WP-3's acceptance step only** — the plan is not complete until a live `--yes` run demonstrates real reclaim, and that run destroys the user's caches. The orchestrator does not run it; the user does, and the result closes the `FEEDBACK.md` item (which is user-owned and remains theirs to edit).

All three dispatch to Claude Agent workers. No must-direct reason applies. Briefs pin the deferred audit findings per fleet convention.

## Test Plan / Verification

Gate, verbatim, before every commit:

```bash
bash tests/shell-gate.sh
```
Focused: `bash util/tests/cache-prune.sh` — baseline **88 passed, 0 failed** (`6aa7edc`). Must grow, never shrink.

Hermetic coverage required:

- **WP-1** — unfiltered prune is the default (assert the command log contains no `--filter`); an explicitly supplied `--docker-until` still produces `until=<window>`; an invalid window still exits 2 (the `6aa7edc` regression assertions must survive unchanged).
- **WP-2** — safe mode runs the safe verb and never the purge verb for uv/npm; `--include-purge` runs the purge verb; a declined confirm executes neither; pip/bun behaviour is byte-identical to today. The existing "byte-identical before/after under `--yes` without `--include-purge`" safety property for pip/bun is the load-bearing regression here.
- **WP-3** — actual-freed is computed from real before/after values against a fixture whose size changes between the two probes; a runtime whose action frees nothing reports `0B freed` rather than the estimate; an `unavailable` probe never fabricates a delta.

**Acceptance (user-run, not orchestrator-run).** Revised after premise (a): docker's cache is now 9.099 GB with `RECLAIMABLE 0B`, so **a live run cannot reclaim ~59 GB again** and must not be judged against that figure. Acceptance is instead:

1. On a *freshly accumulated* docker build cache, a `--yes` run reclaims what `system df` reported as RECLAIMABLE, within the ~1% quantisation gap premise (a) measured.
2. `--yes --include-purge` reclaims uv's and npm's cache-only bytes (~1.8 GB and ~4.1 GB at last census).
3. Every reported delta is labelled an observation, and no runtime reports a figure against a verb that will not free it.

Until such a run happens the plan is implemented but **not** validated, and the `FEEDBACK.md` item stays open — it is user-owned and closes on the user's judgement, not the orchestrator's.

**Public/CC0:** fixtures stay synthetic; no personal paths, hostnames, or real machine byte counts in code or assertions.

## Critical Files

- `util/cache-prune.sh` — `rt_docker_prune`, `rt_uv_prune`, `rt_npm_prune`, the `RT_CLASS`/`RT_PRUNE` registry, `should_act`, `process_runtime`, `main`'s arg parsing and `Total` section.
- `util/tests/cache-prune.sh` — 88 assertions; the pip/bun byte-identical safety property and the `6aa7edc` validation assertions are the two regression anchors.
- `plans/cache-reporting-fidelity.md` — the predecessor; its census is correct and is **not** revisited here.
- `AGENTS.md` — the `cache-prune` row, which now understates the tool's destructive reach.

## Assumptions

- Docker's "never prunes an ACTIVE record" guarantee is trusted. It is the sole safety basis for dropping the filter; if it were false, WP-1 would be unsafe.
- `ACTIVE 0` is a snapshot. A prune run concurrently with a live build will simply free less — safe, not dangerous.
- uv/npm purge verbs force re-download on next use. That is the accepted cost of an opt-in tier the user must explicitly request.
- Build cache is rebuildable by definition; the cost of pruning it is slower subsequent builds, never lost data.
- ~~Left for the audit~~ — both closed. Docker's estimate uses `system df`'s RECLAIMABLE, now measured as the exact predictor (premise (a)). The report-only stability check is folded into WP-3's coverage.
- **Residual risk accepted at this exit** (the unaudited fold of cycle 1's revision): premise (a) is a single measurement on one host at one cache state. It establishes correspondence for `system df` RECLAIMABLE against the unfiltered verb; it does not prove that correspondence holds at every cache state, and in particular it says nothing about a cache with `ACTIVE > 0`.

## Audit record

**cycle 1 — codex-david, `gpt-5.6-sol`, medium.** Verdict: **1 blocking / 4 material / 1 execution-level / 0 minor**. Report: `runs/dispatch/cache-prune-reclaim-effectiveness-plan-audit-report.md`. Every finding was verified against source by the orchestrator before disposition.

| # | class | finding | disposition |
|---|---|---|---|
| 1 | blocking | The 59 GB expectation, the `system df`→verb correspondence, and the "~9 GB is the `--all` slice" claim were all unmeasured; Shared and internal/frontend are different dimensions | **valid-actionable.** Verified: `68.26 − 59.16 = 9.10` is exactly `Shared`, so the `--all` attribution was false. Routed to a measurement spike per the empirical-premise rule rather than another prose cycle. Spike run under user authorisation; premise (a) rewritten from measurement, `--all` claim deleted. |
| 2 | material | Dropping the default filter silently widens an existing `--yes` run's blast radius; `should_act` returns 0 for `yes:safe` with no prompt | **valid-trade-off, rejected by user.** Verified accurate against `util/cache-prune.sh:486-489`. User's call, quoted: *"'existing scripts' is completely hypothetical, the feature hasn't even left development testing yet"* — the tool shipped one day earlier and has a single user. Default stays unfiltered; no compensating confirm added. |
| 3 | material | `RT_PRUNE` does not currently mean "the safe verb" — it holds pip/bun purges too, so an `RT_PURGE` added only for uv/npm leaves two competing representations | **valid-actionable.** Verified at `util/cache-prune.sh:461-467`. Decision 6 added: pip/bun migrate out of `RT_PRUNE` into `RT_PURGE`; `RT_PRUNE` becomes safe-only. Public Interfaces corrected — this is a change to its meaning, not a preservation. |
| 4 | material | A before/after delta is an observed, quantised accounting delta, not "bytes actually freed"; docker parses rounded human tokens and concurrent writes can make it negative | **valid-actionable, and independently confirmed by the spike**: docker reported 59.16 GB freed against 58.60 GB of real disk, a 1.0% gap. Decision 3 and WP-3 relabelled to "observed footprint delta"; non-decrease and negative-delta behaviour now explicitly in scope. |
| 5 | material | The dual-verb action matrix is undefined — whether `--yes --include-purge` runs safe-then-purge or purge-only, and how interactive exposes the new uv/npm purges | **valid-actionable.** Decision 7 added as an explicit mode × runtime-kind matrix. Pinned: purge **supersedes** safe for dual-verb runtimes rather than running after it, since the safe verb's work is a strict subset. |
| 6 | execution-level | Post-action probe failure and failed-action-with-changed-probe are unpinned | **valid-defer-to-execution.** Carried into WP-3's execution brief as a required decision rather than left to worker discretion, per fleet convention. |

**Convergence exit.** No cycle 2. The blocking finding invalidated a premise, but the revision **pinned measured values rather than restructuring** — WP boundaries, ordering, and sizing are unchanged, and no WP moved by >30%. Exit condition (a) is therefore not met, and the plan proceeds to approval carrying these dispositions and the residual-risk note in Assumptions.

**Total ≈ 0.65 kSLOC, ~350k raw tokens; ~200k Claude-path (implementation) Opus-equivalent tokens; ~200k Codex-path (review-estimate) Sol-equivalent tokens.**
