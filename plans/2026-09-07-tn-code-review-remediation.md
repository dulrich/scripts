# Scripts — thermo-nuclear review remediation

*Recommended model/effort — Claude implementation: opus-5/high for scanner, dotfiles, and cache measurement boundaries; sonnet-5/medium for isolated build, public-surface, alias, and blamecount packages. Codex review-only: gpt-5.6-sol/high and gpt-5.6-terra/medium respectively. Separate adversarial plan audit: exempt for tn-code-review remediation; later Claude orchestrator verifies findings against source before approval.*

**Status: PROVISIONAL 2026-09-07 (rev 1) — awaiting executing-orchestrator source verification and user approval.**

## Context

The [current review](../reviews/2026-09-07-tn-code-review.md) revalidated all eight July findings and found a ninth regression: cache-prune transports measurement provenance through a temporary file, then computes a cross-source delta if that file cannot be created. The current shell gate passes, but the stale C amalgamation, inert theme generator, and untested JavaScript tool make that insufficient evidence of public-tool health. This plan supersedes the embedded proposal in the July review.

## Decisions locked

- This session produces review artifacts only. A later persistent Claude orchestrator implements approved packages; Codex remains review-only. Workers never commit.
- Land on local master without pushing or modifying remotes. Use mocked Git publication in tests; no real publication belongs to these packages.
- Preserve the user's scratchpad and the body of `INITIATIVE.md`. Registration changes only frontmatter; review thresholds remain untouched.
- Counts live in `reviews/2026-09-07-tn-code-review.md`. Historical July counts are historical, not a second remediation target. Preserve both records' immutable reviewed SHAs.
- Preserve scanner CLI/verdicts, the established false-positive/evasion rules, cache-prune confirmation and measurement contracts, alias-chain load order, and no-clobber dotfile payload behavior. Proposed removal of broken public surfaces and snapshot publication changes are explicit approval scope below.

## Summary

Delete competing source layers, make policy and measurement results explicit, and separate orchestration from adapters. Each substantive package owns complete findings and updates their counts in its landing commit. Execute the new measured cache defect first, then work through the remaining packages serially to avoid shared gate, docs, and review-record conflicts. Finish with a gated record closeout.

## Key Changes

**WP-R1 — Make canonical C parts the only source (~2.1 kSLOC touched, net-negative, ~170k tokens).** Remove the stale generated layer and validate generated projects.
Files: `build_system/_build.c`, `build_system/_build.inc.c`, `build_system/parts/*.c`, `build_system/parts/compile.sh`, `build_system/mkproject.sh`, new `build_system/tests/smoke.sh`, `tests/shell-gate.sh`, `build_system/README.md`. *Model: mid (Claude sonnet-5/medium; Codex review-estimate gpt-5.6-terra/medium). Execution: Claude subagent.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: F1 — structural-regressions.
- Record delta: structural-regressions Open -1 / Resolved +1.

*Sizing/execution: ~14 min wall; 150k worker + 20k orchestrator overhead; 80k normalized vs 150k direct, a 70k saving. Native-build estimate includes integration contingency.*

Preserve ordered inclusion in one translation unit unless source inspection requires otherwise; do not introduce a build framework. Correct the `pkgconfig.c` freed-command error path and delete the concatenation mechanism. Have `mkproject.sh` copy canonical parts into new projects while retaining existing build/debug/profiling/valgrind entry points. Before retiring the amalgamation, characterize generated output layout. The fixture must generate a project in a temporary directory, compile and run it, then change a canonical part or source and demonstrate the expected rebuild. Add the fixture to the root gate and verify no tracked generated output changes. Exercise the corrected command failure path with a controlled stub/harness.

**WP-R2 — Retire dormant themes and broken public surfaces (~1.1 kSLOC touched, net-negative, ~170k tokens).** Keep static assets canonical and make advertised runtime paths real and machine-neutral.
Files: `themegen/**`, `gpuedit/options.json`, `gpuedit/commands.bak.json`, `Xresources`, `gpuedit/themes/*.json`, `aliases.sh`, `dotfiles.sh` configuration preamble only, `config.example.sh`, `README.md`, `AGENTS.md`, new `tests/public-contract-smoke.sh`, `tests/shell-gate.sh`. *Model: mid (Claude sonnet-5/medium; Codex review-estimate gpt-5.6-terra/medium). Execution: Claude subagent.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: F2 — structural-regressions; F7 — boundary-type-contracts.
- Record delta: structural-regressions Open -1 / Resolved +1; boundary-type-contracts Open -1 / Resolved +1.

*Sizing/execution: ~14 min wall; 150k worker + 20k overhead; 80k normalized vs 150k direct, a 70k saving.*

Retain static theme contents and installation paths; delete the inert `themegen` pipeline/templates and misleading generation gate. Remove the nonexistent lifi alias and documentation rather than restoring the old multi-license tree. Remove the tracked backup and literal personal-home defaults in active public config. Preserve `DOTFILES_META_REPO` overrides and choose a documented machine-neutral default. Public checks target active scripts/config and declared public entry points, exempt historical prose, and never inspect private overlays. Gate static JSON parsing and retained asset existence. Plan approval accepts these removals; if a live generator/lifi consumer is identified before approval, revise this package instead of assuming the historical proposal approved deletion.

**WP-R3 — Establish one IOC policy representation (~0.8 kSLOC touched, net-negative, ~260k tokens).** Derive secondary matchers and remove caller-local counter coupling.
Files: `pkg-ioc/lib/common.sh`, `pkg-ioc/lib/npm.sh`, `pkg-ioc/lib/pypi.sh`, proposed `pkg-ioc/lib/policy.sh`, `pkg-ioc/scan.sh` source wiring, `pkg-ioc/tests/smoke.sh`, `pkg-ioc/AGENTS.md`. *Model: top (Claude opus-5/high; Codex review-estimate gpt-5.6-sol/high). Execution: Claude subagent.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: F3 — simplification-misses.
- Record delta: simplification-misses Open -1 / Resolved +1.

*Sizing/execution: ~20 min wall; 240k worker + 20k overhead. Same-tier dispatch costs 20k extra and provides an isolated policy-contract review boundary.*

Read all of `pkg-ioc/AGENTS.md` before editing. Characterize every current rule class and negative boundary, then define canonical family/watch/exact-version data per ecosystem. Derive text-sweep regexes from that data with explicit escaping and ecosystem normalization. Share classification/report mechanics while keeping parser-specific matching separate. Replace dynamic-scope package counters with an explicit classification result consumed by the check owner; preserve the single router verdict. Do not refresh advisory data or broaden detection during this structural package. Existing and expanded fixtures must retain clean=0, hit=2, and review-only=0, including exact-version lockfile attribution and near-match negatives.

**WP-R4 — Inventory scan scopes and simplify check orchestration (~1.4 kSLOC touched, net-negative, ~300k tokens).** Remove redundant traversal without changing scan reach.
Files: `pkg-ioc/scan.sh`, `pkg-ioc/lib/common.sh`, `pkg-ioc/lib/npm.sh`, `pkg-ioc/lib/pypi.sh`, proposed `pkg-ioc/lib/inventory.sh`, `pkg-ioc/tests/smoke.sh`, `pkg-ioc/AGENTS.md`. *Model: top (Claude opus-5/high; Codex review-estimate gpt-5.6-sol/high). Execution: Claude subagent.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: F4 — spaghetti.
- Record delta: spaghetti Open -1 / Resolved +1.

*Sizing/execution: ~24 min wall; 280k worker + 20k overhead. Same-tier isolation adds 20k for independent evasion/scan-scope review.*

After WP-R3, inventory current root/temp/config walks and their exact depth, prune, dedupe, and symlink policies before proposing shared inventories. Build one bounded inventory per genuinely shared policy, not one global inventory that silently alters reach. Use NUL-safe paths and explicit ordered named checks; retain legitimate distinct host/process checks. Remove repeated marker-display and traversal plumbing where the contract is identical. Instrument traversal in hermetic fixtures and show fewer redundant walks than the current eighteen call-site design; compare verdicts and classifications on deep/shallow, temp-root, config-symlink, whitespace-path, and every existing evasion fixture. No scan of the real home directory is required.

**WP-R5 — Restore direct argv and shared util discovery (~1.1 kSLOC touched, net-negative, ~200k tokens).** Delete flattened-string defaults and eval-generated directory helpers.
Files: `aliases.sh`, `git-aliases.sh`, `util/lib.sh`, `util/dispatch.sh`, `util/completions.sh`, `tests/aliases-smoke.sh`, `util/tests/util-router.sh`, `AGENTS.md`. *Model: mid (Claude sonnet-5/medium; Codex review-estimate gpt-5.6-terra/medium). Execution: Claude subagent.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: F5 — simplification-misses.
- Record delta: simplification-misses Open -1 / Resolved +1.

*Sizing/execution: ~16 min wall; 180k worker + 20k overhead; 92k normalized vs 180k direct, an 88k saving.*

Characterize omitted, empty, spaced, and multiple arguments at each tracked `defarg` caller; express intended defaults with positional parameters and preserve argument boundaries. Replace the four generated directory commands with ordinary wrappers and a shared completion function. Make router listing and completion use the same discovery operation, retaining overlay precedence, infrastructure exclusions, and `.sh` resolution. Keep private overlays outside the inspection scope; document removal of the public helper in the handoff so an external consumer can be migrated explicitly rather than preserving dead compatibility by default. No other alias semantics change. Gate both root and symlinked sourcing and spaced directory completion.

**WP-R6 — Give dotfiles explicit identity and mutation phases (~0.8 kSLOC touched, ~260k tokens).** Stop inferring project roots and stop mutating on read-only commands.
Files: `dotfiles.sh`, `config.example.sh`, `tests/root-utils-smoke.sh`, `README.md`, `AGENTS.md`. *Model: top (Claude opus-5/high; Codex review-estimate gpt-5.6-sol/high). Execution: Claude subagent.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: F6 — boundary-type-contracts.
- Record delta: boundary-type-contracts Open -1 / Resolved +1.

*Sizing/execution: ~20 min wall; 240k worker + 20k overhead. Same-tier dispatch adds 20k for isolated state-transition review.*

Parse CLI/config and validate before creating metadata. Add a stable project record mapping identity to absolute source root while preserving stored dotfile payload paths. Provide an explicit legacy registration/migration path; refuse ambiguous basename matches rather than guessing. Limit snapshot staging and commits to managed paths and reject unrelated pre-staged content instead of sweeping it into a snapshot. Snapshot creates a local commit and reports publication as a separate user action; remove automatic remote pushes to match the current local-only Git contract. Report restore as restored/skipped/failed truthfully and preserve no-clobber semantics. Tests cover help and invalid input with no writes, duplicate basenames, nonsibling registered roots, legacy ambiguity, symlink payloads, unrelated staged content, and forced copy/Git failures. All repositories used in tests are temporary; no real remotes are contacted.

**WP-R7 — Make blamecount self-contained and gate it (~0.6 kSLOC touched, ~170k tokens).** Replace undeclared dependencies and callback-global traversal.
Files: `blamecount/blamecount.js`, `blamecount/config.example.json`, new `blamecount/tests/smoke.sh`, `tests/shell-gate.sh`, `README.md`, `AGENTS.md`. *Model: mid (Claude sonnet-5/medium; Codex review-estimate gpt-5.6-terra/medium). Execution: Claude subagent.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: F8 — modularity.
- Record delta: modularity Open -1 / Resolved +1.

*Sizing/execution: ~14 min wall; 150k worker + 20k overhead; 80k normalized vs 150k direct, a 70k saving.*

Use Node built-ins and Git CLI with NUL-delimited tracked-file discovery and porcelain blame. Bound subprocess concurrency and accumulate explicit results rather than mutate globals through nested callbacks. Preserve author/language totals, stop directories, and minified-file exclusions; specify deterministic handling of empty repos and uncommitted lines. Missing config, invalid repositories, and blame failures exit nonzero with useful diagnostics. A hermetic fixture with multiple authors, excluded paths, whitespace filenames, and a forced Git failure runs from the root gate with no npm install. Document Node/Git runtime prerequisites.

**WP-R8 — Return complete cache measurements and shrink orchestration (~1.6 kSLOC touched, net-negative, ~260k tokens).** Eliminate the Docker source side channel and separate adapter, measurement, and action responsibilities.
Files: `util/cache-prune.sh`, proposed `util/cache-prune/{adapters,measurement,actions}.sh`, `util/tests/cache-prune.sh`, proposed `util/tests/cache-prune/*.sh`, `util/tests/util-router.sh`, `AGENTS.md`. *Model: top (Claude opus-5/high; Codex review-estimate gpt-5.6-sol/high). Execution: Claude subagent.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: F9 — structural-regressions.
- Record delta: structural-regressions Open -1 / Resolved +1.

*Sizing/execution: ~20 min wall; 240k worker + 20k overhead. Same-tier dispatch adds 20k for isolated measurement/action-boundary review.*

Start with a hermetic failing-source-transport regression: before `system-df` reports `1000 900`, after `buildx-du` reports `400 300`, and `mktemp` fails; assert unavailable delta and no contribution to the delta total. The current code incorrectly reports 600 bytes. Mock every action; never prune a live cache to validate this refactor.

Define one probe result with explicit available/unavailable state, total/reclaimable bytes, and a nonempty source identity for available measurements. Use the same validated boundary for local census and Docker. Return the complete result through one transport rather than splitting counts and provenance across stdout and a scratch file. Delete `DOCKER_SIZE_SOURCE_FILE`, `docker_record_source`, and the corresponding RETURN trap. Missing, malformed, failed, or changed provenance must never yield a numeric delta. A single comparison helper owns eligibility and signed subtraction.

Make `process_runtime` a short lifecycle: detect/resolve, measure/report, elect/run in existing order, measure/report outcome. Keep estimate tier rendering and adapter details out of action election. Preserve `--yes` purge substitution, interactive safe-then-purge confirmations, purge-only prompting without `--include-purge`, failed-safe short-circuit, post-failure measurement, report-only behavior, and signed/zero/unavailable deltas. Retain Docker's unfiltered default and optional age narrowing. Split adapters and focused tests along these responsibilities; the existing smoke entry point remains canonical. Keep helpers under subdirectories so filesystem routing cannot expose them as util commands. Acceptance requires the giant runner and source side channel to disappear, not simply move, with implementation files below 1,000 lines unless the reviewer records a compelling structural reason.

**WP-R9 — Gate and close the remediation record (~0.1 kSLOC touched, ~40k tokens).** Confirm all packages and write the final baseline and plan lifecycle transition.
Files: `reviews/2026-09-07-tn-code-review.md`, this plan, `INITIATIVE.md` frontmatter. *Model: top (Claude opus-5/high; Codex review-estimate gpt-5.6-sol/high). Execution: Claude direct.*

- Review record: `reviews/2026-09-07-tn-code-review.md`.
- Findings: none; closeout only, all F1–F9 must already be Resolved.
- Record delta: all seven tiers Open -0 / Resolved +0. Required final counts: structural-regressions 0/3, simplification-misses 0/2, spaghetti 0/1, boundary-type-contracts 0/2, file-size 0/0, modularity 0/1, legibility 0/0.

*Sizing/execution: 5 min wall; 40k direct. Must-direct: final integration, source verification, gates, record update, and commit responsibility.*

Verify every finding's acceptance evidence and rerun the full gate. Only once all Open counts are zero and closeout gates pass, set `remediation-commit` to the SHA of the last substantive WP commit that brought every Open count to zero. Never use this separate closeout commit's own SHA. Name that substantive commit in the closeout body. Preserve `review-commit`, mark this plan IMPLEMENTED with the landing commit references, and remove its pending-plans entry in the same closeout commit. Partial remediation only applies the declared finding deltas and adds no baseline.

## Public Interfaces

Scanner and cache-prune CLIs/verdicts remain stable; adapter internals gain explicit result boundaries. Util discovery becomes canonical and continues to support symlinked private commands. Generated C projects carry canonical parts. The broken lifi alias and inert theme generator are removed on plan approval; static themes remain. Dotfiles gains explicit project-root registration, read-only help/validation, honest outcomes, and a local-only snapshot operation. Blamecount retains config-driven author/language counting with documented Node/Git dependencies and meaningful nonzero failures.

## Execution

Use a later persistent Claude orchestrator. This review session does not execute any package. Before approval, that orchestrator verifies the nine findings against its source tip and records dispositions here; no separate adversarial plan-audit dispatch is required. Approval must cover the explicitly described public-surface changes and model/execution posture.

Serial execution deliberately avoids overlapping edits to the root gate, public docs, and single review record. `WP-R8 → WP-R1 → WP-R2 → WP-R3 → WP-R4 → WP-R5 → WP-R6 → WP-R7 → WP-R9`.

| WP | after: | parallel-ok: | hold-for-user: |
|---|---|---|---|
| WP-R8 | approved plan | none | plan approval |
| WP-R1 | WP-R8 | none | none |
| WP-R2 | WP-R1 | none | none; removals included in plan approval |
| WP-R3 | WP-R2 | none | none |
| WP-R4 | WP-R3 | none | none |
| WP-R5 | WP-R4 | none | none |
| WP-R6 | WP-R5 | none | none; identity and snapshot contract included in plan approval |
| WP-R7 | WP-R6 | none | none |
| WP-R9 | WP-R7 and every Open count zero | none | none |

Each worker gets a self-contained source-grounded brief and current acceptance fixtures. The orchestrator verifies the diff, reruns the prescribed gate, applies the finding status/count delta, stages by explicit paths, and commits using the commit skill. Each substantive WP edits its finding's status to Resolved with evidence as well as updating the table. Do not advance the baseline during partial completion.

## Test Plan / Verification

Before each implementation commit, use the nearest `AGENTS.md` commands. The repository-wide gate remains:

```bash
bash tests/shell-gate.sh
```

Focused existing commands:

```bash
bash util/tests/cache-prune.sh
bash util/tests/util-router.sh
bash tests/aliases-smoke.sh
bash tests/root-utils-smoke.sh
bash pkg-ioc/tests/smoke.sh
(cd build_system && ./build.sh)
```

WP-R1, WP-R2, and WP-R7 add their specified fixtures to the root gate in their own commits. WP-R2 removes the false theme-generation command and adds real static-asset checks. New tracked shell helpers must be staged by path before running the final tracked-shell gate so `git ls-files` includes them. The gate must exit 0, exercise every retained public tool, and leave tracked implementation unchanged. Verify the public-contract checks exclude historical reviews and private files. No test contacts real remotes, invokes a live destructive cache action, or reads the user scratchpad.

## Critical Files

`build_system/_build.c`, `build_system/parts/pkgconfig.c`, and `mkproject.sh` own the source-of-truth change. `pkg-ioc/AGENTS.md` owns detection invariants. `util/cache-prune.sh` owns measured action semantics. `aliases.sh` and the util router own interactive boundaries. `dotfiles.sh` owns identity and mutation. `tests/shell-gate.sh` owns integrated validation. The current review record alone owns current finding counts.

## Assumptions

Static themes are the intended retained output; no working external generator consumer has been established. Removal approval is therefore explicit, not inferred from the July proposal. Node and Git are acceptable dependencies for an already advertised JavaScript Git utility. Dotfiles payload layout is retained, but identity metadata requires an explicit migration contract. Private overlay consumers of removed public helpers may require a separately authorized migration. Scanner rules are frozen for this refactor; no advisory refresh is implied.

Estimates use grounded-worker budgets plus 20k orchestration overhead for each of eight workers; closeout is direct. Native-build work includes risk allowance. Reserve an additional, unallocated ~100k raw tokens if a distinct integration follow-up is needed; it is not authorization for unrelated work. Planned kSLOC sums per-WP touch estimates, including overlapping test/docs edits, rather than unique repository size.

## Audit record

2026-09-07: review producer `gpt-6-astra/high`, harness `codex`, reviewed SHA `ade9ded4c2fb06f2b19f33ef110b376c0dfbeca4`; mandatory mechanical comment preflight `gpt-5.6-terra/low`, no candidates. Nine implementation findings (one blocker, six high, two medium), all Open and assigned once. Root gate passed and the F9 source-transport failure was reproduced with mocks. This is review evidence, not an adversarial plan-audit approval. Scoped remediation exception applies; executing-orchestrator source verification and user approval remain pending.

Canonical model-cost calculator inputs were `150000,150000,240000,280000,180000,240000,150000,240000,40000`, with Claude workers `sonnet,sonnet,opus,opus,sonnet,opus,sonnet,opus,opus` and corresponding Codex review-estimate tiers `terra,terra,sol,sol,terra,sol,terra,sol,sol`. Calculator worker-path total is 1,292k normalized; add 160k orchestration for the eight dispatched WPs, with no dispatch overhead for direct closeout. Both independently calculated paths have the same normalized estimate under the current registry. Codex accounting is review-estimate only, not an implementation dispatch choice.

**Total ≈ 9.6 kSLOC, ~1,830k raw tokens; ~1,452k Claude-path (implementation) Opus-equivalent tokens; ~1,452k Codex-path (review-estimate) Sol-equivalent tokens.**
