---
review-date: 2026-09-07
review-commit: ade9ded4c2fb06f2b19f33ef110b376c0dfbeca4
review-type: tn-code-review
review-model: gpt-6-astra
review-harness: codex
review-effort: high
---
# Review — scripts maintainability revalidation

| Tier | Open | Resolved |
|---|---:|---:|
| structural-regressions | 3 | 0 |
| simplification-misses | 2 | 0 |
| spaghetti | 1 | 0 |
| boundary-type-contracts | 2 | 0 |
| file-size | 0 | 0 |
| modularity | 1 | 0 |
| legibility | 0 | 0 |

**Verdict: remediation required — nine Open findings.** All eight findings from [July's review](2026-07-30-tn-code-review.md) still apply. F9 is a new structural regression in cache-prune. No implementation was changed during this review.

## Scope and evidence

Repository-wide tracked public implementation, starting from July's reviewed SHA `311b804`, with focused inspection of the new cache-prune implementation, APT archive cleanup, and their gate integrations. The implementation paths underlying F1–F8 have no diff from that SHA to this review's HEAD. Their evidence was rechecked against current source; repeated concerns retain their original IDs and owning tiers. Private overlays and the user scratchpad were excluded.

The mandatory read-only comment preflight ran on `gpt-5.6-terra/low` and returned no high-confidence stale-comment candidates. The semantic pass independently checked boundaries, competing sources of truth, growing orchestration, and meaningful decomposition opportunities. This is an implementation review, not a refresh of external IOC advisories.

`bash tests/shell-gate.sh` passed at the reviewed HEAD: ShellCheck and Bash syntax, Debian maintenance 30/30, util router 35/35, cache-prune 173/173, alias chain 26/26, root utilities 44/44, IOC 55/55, and the existing build/theme commands. Passing those commands does not resolve F1, F2, or F8's coverage defects. The reviewed code remained unchanged after the gate.

## Findings

### F1 — Competing C sources let the gate validate stale code

**Open · structural-regressions · blocker · WP-R1.** `build_system/_build.c:11` includes the tracked 1,705-line `_build.inc.c`; `build_system/parts/compile.sh:6` separately concatenates eleven canonical parts. An in-memory concatenation still differs from the tracked amalgamation. `parts/pkgconfig.c:36` frees `tmp` before the failure message uses it at line 39; the compiled copy retains different ordering. `mkproject.sh:134` copies the generated layer, and `tests/shell-gate.sh:45` only runs the existing build script.

Delete the competing generated source, compile ordered canonical parts, and make generated projects carry those parts. Exercise a freshly generated project and the corrected failure path. This deletes an entire drift mechanism rather than adding a synchronization check. The generated file's size belongs to this finding, not a second file-size count.

### F2 — The theme pipeline still generates nothing

**Open · structural-regressions · high · WP-R2.** `themegen/gen.sh:12` sources only the pastel palette, and the writes at lines 45, 55, and 60 remain commented out. Templates contain unresolved `GEN_*` tokens; `tests/shell-gate.sh:51` still labels a successful token-printing command as theme generation.

Retain root `Xresources` and `gpuedit/themes/*.json` as canonical static assets and retire the inert templates/generator plus its false gate. This is a proposed removal to approve with the plan, not a claim that external consumers have been ruled out. A real generator would require a concrete output contract and assertions on produced assets.

### F9 — Cache-prune leaks measurement provenance through a temporary file into a growing generic runner

**Open · structural-regressions · high · WP-R8.** `util/cache-prune.sh:431` records Docker's probe source through `DOCKER_SIZE_SOURCE_FILE`, while the probe returns only two byte counts. `process_runtime():705–939` consequently owns Docker scratch-file creation, a RETURN trap, source reads, pair validation, estimate rendering, action election, failure handling, post-action measurement, and totals. Docker-specific branches appear at lines 753, 766, 813, 891, and 901. This defeats the existing runtime registry's separation of orchestration from adapters.

This is a measured correctness problem as well as unnecessary machinery. At line 754 a failed `mktemp` silently becomes an empty filename. Both source labels then remain empty; the inequality guard at line 901 accepts them as matching. A hermetic probe overrode `mktemp` to fail, mocked the before probe as `system-df: 1000 900`, and the after probe as `buildx-du: 400 300`; the action was a shell mock. `process_runtime docker` exited 0 and printed `observed footprint change: 600.0B (600 bytes)`, with `FAILED=0 DELTA_BYTES=600`. No Docker command or cache deletion ran. The required outcome is an unavailable delta when provenance cannot establish comparable measurements.

Commit `c1af930` grew the implementation from 819 to 1,023 lines and its smoke suite from 859 to 1,224. Decompose this before adding further modes. Return one validated measurement containing status, total bytes, reclaimable bytes, and source identity from every adapter; compare nonempty compatible identities in one place. Delete the scratch file, dynamically scoped source channel, and trap. Separate measurement/reporting from the small action lifecycle, and move adapters and focused tests into cohesive modules under non-command subdirectories. Preserve the existing prompt order, failure short-circuit, and one before/after measurement around all elected verbs. Merely splitting the current 235-line runner across files is insufficient. Size and boundary symptoms are counted here only.

### F3 — IOC policy is still maintained in parallel representations

**Open · simplification-misses · high · WP-R3.** `pkg-ioc/lib/npm.sh:20–39` duplicates package families in `PKG_PREFIXES` and `PKG_RE`; `WATCH_RE:126` and `watch_pkg():245` duplicate watch policy. `pkg-ioc/lib/pypi.sh:23–52` repeats arrays and independently maintained boundary regexes. Both report helpers mutate caller-local counters through dynamic scope (`npm.sh:254`, `pypi.sh:140`).

Keep canonical ecosystem rule data and derive secondary matchers, retaining ecosystem-specific boundary and normalization semantics. Share explicit classification/reporting mechanics instead of maintaining near-parallel known-version/watch flows and caller-local counter contracts. Characterization must distinguish exact hits, family hits, broad-scope reviews, and clean near-matches before replacement.

### F5 — Alias helpers flatten argv and generate runtime code unnecessarily

**Open · simplification-misses · medium · WP-R5.** `aliases.sh:134` and `util/lib.sh:12` still duplicate `defarg`, which reparses a flattened string via `read -a`; git and path helpers pass `"$*"`. `aliases.sh:44` and `:155` build directory functions/completions through `eval`. `util/dispatch.sh:24` and `util/completions.sh:15` each implement filesystem discovery.

Use direct positional arguments, four ordinary directory wrappers with shared completion, and one canonical discovery operation. Preserve `.sh` precedence, infrastructure exclusions, private overlay support, and symlink behavior. Spaced arguments must reach the final command unchanged. Remove the helper only after converting every tracked caller; do not inspect private overlays to accomplish that audit.

### F4 — IOC orchestration repeats tree walks and large branch-heavy flows

**Open · spaghetti · high · WP-R4.** `run_common_checks` (`common.sh:61`), `run_npm_checks` (`npm.sh:322`), and `run_pypi_checks` (`pypi.sh:208`) remain the same 143-, 160-, and 153-line flows. The original eighteen `find` call sites remain across those three modules, with repeated pruning, content display, and hit/review plumbing.

Use a shared inventory per distinct scan scope/policy and small named checks invoked in explicit order. Do not collapse genuinely different depth, prune, symlink, temp-root, and config-file policies into one indiscriminate walk. The reduction must remove redundant traversal and orchestration concepts while preserving every existing detection contract and single verdict.

### F6 — Dotfiles lacks explicit project identity and mutation boundaries

**Open · boundary-type-contracts · high · WP-R6.** `dotfiles.sh:9–13` initializes metadata before CLI parsing, including help. Project lookup at line 35 uses basenames; `project_path_for_name():61` guesses sibling roots. `snapshot_all():157` stages the whole metadata repo and pushes enabled remotes; restore at line 121 reports success even when no-clobber skipped the copy.

Parse and validate before mutation, register stable identities with explicit source roots, scope snapshot staging to managed paths, and report restored/skipped/failed outcomes honestly. Preserve payload layout and no-clobber behavior. Separate publication from snapshot creation under the current local-only Git contract; this review authorizes no real publication. Legacy ambiguous project mappings must require explicit resolution rather than silently picking a sibling.

### F7 — Public runtime surfaces still contradict the repository contract

**Open · boundary-type-contracts · high · WP-R2.** `aliases.sh:131` exposes missing `lifi.sh`; `README.md` and `AGENTS.md` still advertise that script and absent license assets. `dotfiles.sh:9`, `gpuedit/options.json:4–9`, and `themegen/options.json:4–9` retain personal home paths. `gpuedit/commands.bak.json` is still tracked.

Remove the broken lifi surface, keep local configuration external, replace active personal-path defaults with machine-neutral configuration, and retire the backup. Add narrowly scoped public runtime/documentation checks; do not scan historical review prose for literal-path examples or read private files. The dotfiles configuration change belongs to WP-R2; its identity/mutation redesign belongs to WP-R6.

### F8 — Blamecount has no reproducible runtime or meaningful error result

**Open · modularity · medium · WP-R7.** `blamecount/blamecount.js:7–10` still imports undeclared lodash, async, and nodegit; there is no tracked package manifest or lockfile. The traversal keeps mutable global totals, launches unbounded callback work, and converts errors to log-and-success paths (`:82`, `:99`, `:121`, `:143`). The root gate does not execute it.

Use Node built-ins and Git CLI discovery/blame, bounded concurrency, explicit results, and nonzero errors. Preserve author/language aggregation and configured exclusions. Verify a hermetic Git fixture, filenames with whitespace, and failure behavior through the root gate.

## Disposition and handoff

The [registered remediation plan](../plans/2026-09-07-tn-code-review-remediation.md) owns executable packages, dependencies, per-tier count deltas, and final closeout. It is provisional pending the later Claude orchestrator's source verification and user approval; implementation does not belong to this review session. F1–F8 are carried forward, not resolved and reopened. The historical record retains its historical counts; subsequent remediation updates this current record. There is no `remediation-commit` while any finding remains Open.
