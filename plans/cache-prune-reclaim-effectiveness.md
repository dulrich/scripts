# Cache prune reclaim effectiveness — make the tool actually free space, and prove it did

*Recommended model/effort — Claude implementation: Sonnet/high (registry restructuring + careful action-path changes in a script that deletes user data); Codex review: Terra/medium; plan audit: `gpt-5.6-sol`/medium*

**Status: PROVISIONAL 2026-08-31 (rev 1) — awaiting audit**

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

1. **Docker: drop the default age filter.** The safe tier runs `docker builder prune --force` unfiltered. `--docker-until` remains available as an opt-in narrowing and keeps its parse-time validation (`6aa7edc`), but is no longer applied by default. No new destructive verb — docker's own guarantee (never removes an ACTIVE record) is what makes this safe, and `--all` is explicitly **not** adopted.
2. **uv and npm join the opt-in purge tier** alongside pip and bun: `uv cache clean` and `npm cache clean --force`, behind the same explicit `--include-purge` confirm the existing purge runtimes already require. Their safe verbs stay exactly as they are for the safe tier.
3. **Stop predicting what can be measured.** Every action path measures the cache before and after and reports **bytes actually freed**. Prediction has now failed twice in this codebase (the age-sum, and this plan's parent). Actual-freed is ground truth and needs no premise.
4. **The estimate column is relabelled to what it measures**, and is stated per tier rather than as one conflated "reclaimable" figure — the safe verb and the purge verb free different amounts and must not share a number.
5. **`--all` is out of scope** (user-declined). The remaining ~9 GB gap between docker's `Reclaimable` and `Total` is the least valuable slice and is not worth the added blast radius.

## Measured premises

Taken live 2026-08-31. Load-bearing; do not re-derive by reasoning.

**(a) Docker's filter, not its safety tier, is what blocks reclaim.**
```
TYPE          TOTAL   ACTIVE   SIZE      RECLAIMABLE
Build Cache   1625    0        68.26GB   59.16GB
```
`ACTIVE 0` — nothing is pinned by a running build. `docker builder prune --help` confirms `-a, --all` means only "Include internal/frontend images", **not** "remove otherwise-retained cache". So the unfiltered default prune is already the correct safe verb; it is the `until=` filter that yields `Total: 0B`.

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
Measure each cache immediately before and after its action and print bytes actually freed, with a grand total of real reclaim at the end. Replace the single "reclaimable" column with a per-tier estimate labelled for the verb it corresponds to (safe vs purge), so no number is ever reported against a verb that will not free it. Docker's before/after comes from its own accounting rather than a directory census. Files: `util/cache-prune.sh`, `util/tests/cache-prune.sh`, `AGENTS.md`.

## Public Interfaces

- **`--docker-until`** — unchanged spelling and validation; changed default (was `168h`, now unset/no filter). This is a **behaviour change to a destructive action's scope** and is the single highest-risk item in this plan; it must be called out in `-h` and `AGENTS.md`.
- **`--include-purge`** — unchanged spelling and confirm semantics; now additionally covers uv and npm.
- **Probe contract** — the `"<total> <reclaimable>"` seam from the predecessor plan (`234637d`) still holds. WP-3 changes what the second value *means* per tier, not the wire format.
- **Registry** — new `RT_PURGE` associative array. `RT_PRUNE` keeps its current meaning (the safe verb).

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

**Acceptance (user-run, not orchestrator-run).** The plan is verified only by a live run showing real reclaim — expected on the order of ~59 GB from docker on the safe tier alone, and ~6 GB more from uv+npm under `--include-purge`. Reported actual-freed must agree with the observed change in `docker system df` / directory size. Until that run happens, this plan is implemented but **not** validated, and the `FEEDBACK.md` item stays open.

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
- Left for the audit: whether WP-3's actual-freed measurement should also cover the report-only path (measuring twice with no action between, to prove the measurement itself is stable), and whether docker's estimate should switch to `system df`'s RECLAIMABLE for *all* modes or only when unfiltered.

## Audit record

*(pending — cycle 1 dispatching to codex-david @ `gpt-5.6-sol`/medium)*

**Total ≈ 0.65 kSLOC, ~350k raw tokens; ~200k Claude-path (implementation) Opus-equivalent tokens; ~200k Codex-path (review-estimate) Sol-equivalent tokens.**
