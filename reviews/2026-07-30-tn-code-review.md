---
review-date: 2026-07-30
review-commit: 311b804
review-type: tn-code-review
review-model: gpt-5.6-sol
review-harness: codex
review-effort: high
---
# Review — scripts repository maintainability audit

| Tier | Open | Resolved |
|---|---:|---:|
| structural-regressions | 2 | 0 |
| simplification-misses | 2 | 0 |
| spaghetti | 1 | 0 |
| boundary-type-contracts | 2 | 0 |
| file-size | 0 | 0 |
| modularity | 1 | 0 |
| legibility | 0 | 0 |

**Verdict: remediation required.** The shell gate is green at `311b804`, but it
does not exercise the canonical C build sources, performs no meaningful theme
generation, and does not cover the JavaScript utility. Those omissions are
already hiding source drift and broken public surfaces.

## Scope and method

This was a repository-wide review of the tracked tree and the recent change
history, with focused inspection of the highest-churn and highest-branch-density
paths. The review ran the prescribed `bash tests/shell-gate.sh` gate successfully
(55 root-utility assertions plus the component suites; final exit 0). The
user-owned `FEEDBACK.md` was neither read nor modified.

The only file over 1,000 lines is the generated
`build_system/_build.inc.c` (1,705 lines). Its size is not counted again as a
file-size finding: the more serious defect is the competing-source architecture
described in F1, and WP-R1 removes the generated file entirely. The largest
non-generated implementation files are 481 lines.

## Findings

### F1 — The build gate compiles a stale generated copy, not the canonical C sources

**Tier: structural-regressions. Severity: blocker.**

`build_system/_build.c:11` includes the tracked `_build.inc.c`, while
`build_system/parts/compile.sh:4-17` separately concatenates eleven
`parts/*.c` files into that artifact. The two sources have already diverged:
the generated copy and the concatenated parts differ around the `popen()` error
path. In `build_system/parts/pkgconfig.c:36-39`, `tmp` is freed before an error
message still uses it; the stale generated copy frees it afterward and therefore
masks that defect.

`tests/shell-gate.sh:41-45` only runs `build_system/build.sh`; it never regenerates
or compares the amalgamation and never exercises `mkproject.sh`. That means a
green gate can validate old code while changes to the apparent source are
uncompiled. `mkproject.sh` compounds the split by copying `_build.inc.c`
(`build_system/mkproject.sh:8,134-142`) rather than the parts.

The code-judo move is to delete the generated source layer. Include the ordered
`parts/*.c` sources directly (or compile them as ordinary translation units),
copy those canonical sources into generated projects, and test a generated
project end to end. This removes 1.7 kSLOC and makes stale-source success
impossible.

### F2 — `themegen` is an inert pipeline that the gate incorrectly calls generation

**Tier: structural-regressions. Severity: high.**

`themegen/gen.sh:12` always sources only `dark_pastel.sh`; every write at
`themegen/gen.sh:45,55,60` is commented out, so the script merely prints token
substitutions. `themegen/dark_saturated.sh` contains no palette data.
Unresolved `GEN_*` tokens remain in `themegen/Xresources`,
`themegen/dark_pastel.json`, and `themegen/options.json`, while
`themegen/dark_saturated.json` is already a static copy of the gpuedit theme.
Nevertheless, `tests/shell-gate.sh:47-51` treats `bash gen.sh` exiting zero as a
theme-generation check.

This is dead indirection, not a generator. The simplest behavior-preserving
structure is to keep the working root `Xresources` and `gpuedit/themes/*.json`
files as the canonical static assets, delete the dormant generator/templates,
and remove the false gate. A real generator can be reintroduced later only when
there is an actual multi-output requirement and an idempotence test.

### F3 — Package IOC policy has multiple hand-synchronized sources of truth

**Tier: simplification-misses. Severity: high.**

The npm leg defines the same hit policy as `PKG_PREFIXES`, `PKG_RE`, and
`prefix_hit_pkg()` (`pkg-ioc/lib/npm.sh:20-39,235-243`), and repeats watch policy
between `WATCH_RE` and `watch_pkg()` (`pkg-ioc/lib/npm.sh:126,245-252`). The PyPI
leg repeats the same pattern with `PYPI_HIT_NAMES` /
`PYPI_HIT_BOUND` and `PYPI_WATCH_NAMES` / `PYPI_WATCH_BOUND`
(`pkg-ioc/lib/pypi.sh:23-52`). Any advisory update therefore requires coordinated
edits to arrays, regexes, and classifiers.

The two ecosystems then carry near-parallel exact-version lookup and reporting
flows (`pkg-ioc/lib/npm.sh:195-281`,
`pkg-ioc/lib/pypi.sh:104-171`). Those helpers mutate per-ecosystem counters via
Bash dynamic scope, a hidden contract explicitly entrenched in
`pkg-ioc/AGENTS.md`.

Replace this with one canonical, declarative rule representation per ecosystem
and one shared classifier/reporter. Derived regexes or text-sweep matchers must
be generated from the canonical data, and classification results must be
explicit rather than depending on a caller-local variable name.

### F4 — The IOC scanner repeatedly walks the same tree from three monolithic flows

**Tier: spaghetti. Severity: high.**

`run_common_checks`, `run_npm_checks`, and `run_pypi_checks` are respectively
143, 160, and 153 lines with 24, 29, and 25 branch headers. Across them, the
scanner starts at least eighteen `find` traversals of the root/temp/config trees:
nine in `npm.sh`, six in `pypi.sh`, and three in `common.sh`. The same prune
expressions, marker-printing pipelines, and hit/review branches are scattered
through the large orchestration functions.

This structure makes every new IOC another special-case branch and another
potential full-tree pass. Build a bounded file inventory once per scan scope,
split each check into a small named function over that inventory, and dispatch
checks from an explicit ordered table. Preserve the single verdict and exact
false-positive/false-negative contracts, but remove dynamic incidental flow and
redundant traversal.

### F5 — The alias boundary reparses argv and uses runtime code generation for four paths

**Tier: simplification-misses. Severity: medium.**

`defarg()` is duplicated in `aliases.sh:134-152` and `util/lib.sh:12-30`. Its
contract takes a flattened string, uses `read -a` to split it again, and requires
callers such as `ga`, `gp`, `highfile`, `gigs`, and `gb` to pass `"$*"`.
Quoting and positional structure are discarded by design even though ordinary
`${1:-default}` / `${2:-default}` expansion already expresses every current
call site directly.

The same root file spends roughly 70 lines generating four directory functions
and their completions through `eval` (`aliases.sh:44-70,155-187`). The util
router also duplicates filesystem command discovery between
`util/dispatch.sh:24-41` and `util/completions.sh:15-40`.

Delete `defarg` and convert callers to normal positional parameters. Replace the
eval-generated directory helpers with direct wrappers plus one completion
function, and expose one canonical util command-list operation for both routing
and completion. This removes magic and restores a real argv boundary.

### F6 — `dotfiles.sh` conflates configuration, project identity, and mutation

**Tier: boundary-type-contracts. Severity: high.**

The script creates the metadata directory before it has parsed any command
(`dotfiles.sh:9-13`), so even help and invalid invocations mutate the filesystem.
Project identity is inferred only from a basename and, for `--all`, sibling
directories are guessed relative to the caller (`dotfiles.sh:35-69`). Two
different roots with the same basename cannot be represented, and registered
projects need not actually be siblings.

The `snapshot` operation stages the entire metadata repository with `git add .`,
commits, and then pushes every enabled remote sequentially
(`dotfiles.sh:157-174`). Unrelated metadata can be swept into the commit and a
later push failure leaves a partially published snapshot. Restore also reports
“Restored” when its no-clobber branch intentionally did nothing
(`dotfiles.sh:121-128`).

Introduce an explicit project record (`stable id -> absolute source root`),
resolve and validate configuration before mutation, scope staging to the managed
dotfiles path, and make snapshot phases/reporting explicit. Preserve the
no-clobber restore behavior and existing on-disk dotfile payload layout.

### F7 — The public/private boundary is contradicted by tracked runtime surfaces

**Tier: boundary-type-contracts. Severity: high.**

The repository contract says host-specific paths and private utilities do not
belong in the public tree, yet `/home/fractal` appears in
`dotfiles.sh:9`, `gpuedit/options.json:4-9`, and
`themegen/options.json:4-9`. More seriously, `lifi.sh`, `licenses/`, and
`config.example.lifi` were removed from the public tree in commit `14c5db0`, but
`aliases.sh:131`, `README.md`, and `AGENTS.md` still expose them as working public
features. A fresh public checkout therefore installs an alias to a nonexistent
script.

Remove the stale lifi surface (or restore a complete CC0-only implementation),
replace live host paths with machine-neutral examples/overrides, and delete the
tracked `gpuedit/commands.bak.json` backup. Add a cheap public-contract check so
missing advertised files, unresolved generator tokens, and literal personal
home paths cannot silently return.

### F8 — `blamecount` is advertised but has no reproducible runtime or failure contract

**Tier: modularity. Severity: medium.**

`blamecount/blamecount.js:7-10` requires lodash, async, and nodegit, but the
repository contains no `package.json` or lockfile. A fresh checkout cannot
install or run the advertised tool reproducibly. Its callback traversal keeps
global mutable totals and converts repository, directory, and blame errors into
logged success paths (`blamecount/blamecount.js:52-145`); no prescribed gate
executes it.

Rewrite the small utility around Node built-ins plus the Git CLI
(`git ls-files` and porcelain blame output), use a bounded worker pool, report
failures through a nonzero exit, and add a hermetic fixture test. This deletes
three undeclared dependencies and most callback plumbing rather than packaging
an obsolete dependency stack.

## Remediation plan

*Recommended model/effort — Claude: Opus/high for the cross-cutting scanner and
state-boundary work, with Sonnet/medium workers for settled packages; Codex:
gpt-5.6-sol/high for the scanner and state-boundary work, with
gpt-5.6-terra/medium workers for settled packages. The review artifact is plan
only; implementation belongs to a later orchestrator session.*

### Context

The repository is small enough to stay direct and boring, but several historical
layers now create competing sources of truth: generated C beside canonical C,
templates beside static themes, regexes beside indicator arrays, and public docs
beside private-only files. Remediation should delete those competing layers
before adding more local hardening.

### Decisions locked

- Preserve user-visible command names, scanner exit codes (`0` clean, `2` hit),
  IOC classifications, dotfile payload layout, and alias-chain load order unless
  a finding explicitly identifies the surface as broken.
- Delete the inactive theme-generation layer and retain the working static
  `Xresources` / gpuedit themes as canonical.
- Delete the generated C amalgamation and compile canonical `parts/*.c` sources.
- Remove the stale public lifi surface; do not restore the old multi-license
  implementation into this CC0-only repository.
- Keep remediation separate from this review session. Do not register this
  review artifact in `pending-plans`.
- Use the repository-standard review tripwires: 20 commits and 1,500 changed
  lines; either meter triggers a new review.

### Summary

First remove the two false source-generation layers. Next establish a canonical
IOC policy model, then decompose scanner orchestration around a shared inventory.
The alias, dotfiles, and blamecount packages can proceed independently once their
existing behavior is characterized. Finish by making the single root gate
exercise every retained public tool and structural invariant.

### Key Changes

**WP-R1 — Make the C parts the only build-system source.**
*~2.1 kSLOC touched, net-negative · ~150k tokens · ~12 min wall · mid (Claude
Sonnet/medium; Codex gpt-5.6-terra/medium) · Claude: subagent (98k normalized
with overhead vs 130k direct); Codex: subagent (85k vs 130k direct)*
Replace the tracked amalgamation with ordered canonical part includes/objects,
fix the `pkgconfig.c` lifetime defect, update `mkproject.sh` to copy the canonical
sources, and add an end-to-end generated-project build fixture. Files:
`build_system/_build.c`, `build_system/_build.inc.c`,
`build_system/parts/*.c`, `build_system/parts/compile.sh`,
`build_system/mkproject.sh`, build-system tests, `tests/shell-gate.sh`.

**WP-R2 — Collapse dormant theme and private-surface duplication.**
*~1.1 kSLOC touched, net-negative · ~180k tokens · ~14 min wall · mid (Claude
Sonnet/medium; Codex gpt-5.6-terra/medium) · Claude: subagent (116k normalized
with overhead vs 160k direct); Codex: subagent (100k vs 160k direct)*
Delete the inactive `themegen` layer and backup config, retain static canonical
themes, replace tracked host paths with public examples/overrides, and remove
the missing lifi alias and documentation. Add public-tree invariants to the
existing gate. Files: `themegen/**`, `Xresources`, `gpuedit/**`, `aliases.sh`,
`README.md`, `AGENTS.md`, `tests/shell-gate.sh`, focused fixture tests.

**WP-R3 — Introduce one declarative package-IOC policy core.**
*~0.8 kSLOC touched, net-negative · ~240k tokens · ~19 min wall · top (Claude
Opus/high; Codex gpt-5.6-sol/high) · Claude: subagent (same-tier dispatch adds
20k orchestration overhead but supplies independent detection-contract review);
Codex: subagent (same-tier dispatch adds 20k for the same review boundary)*
Make each ecosystem's indicator data canonical, derive secondary matchers,
unify exact-version/watch/hit reporting, and replace dynamic-scope counters with
explicit classification results. Extend positive and negative fixtures before
removing the old paths. Files: `pkg-ioc/lib/common.sh`,
`pkg-ioc/lib/npm.sh`, `pkg-ioc/lib/pypi.sh`,
`pkg-ioc/tests/smoke.sh`, `pkg-ioc/AGENTS.md`.

**WP-R4 — Replace repeated scanner walks with an explicit check pipeline.**
*~1.4 kSLOC touched, net-negative · ~320k tokens · ~25 min wall · top (Claude
Opus/high; Codex gpt-5.6-sol/high) · Claude: subagent (same-tier isolation costs
20k overhead and buys a second false-positive/evasion audit); Codex: subagent
(same-tier isolation with the same audit benefit)*
After WP-R3, build a bounded per-scope inventory, split the three large
`run_*_checks` functions into named checks, and dispatch them in an explicit
order without changing verdict semantics or unsafe-file handling. Measure and
assert traversal behavior in fixtures without scanning the real home directory.
Files: `pkg-ioc/scan.sh`, `pkg-ioc/lib/common.sh`,
`pkg-ioc/lib/npm.sh`, `pkg-ioc/lib/pypi.sh`,
`pkg-ioc/tests/smoke.sh`, `pkg-ioc/AGENTS.md`.

**WP-R5 — Restore direct argv and discovery boundaries in the alias chain.**
*~1.1 kSLOC touched, net-negative · ~200k tokens · ~16 min wall · mid (Claude
Sonnet/medium; Codex gpt-5.6-terra/medium) · Claude: subagent (128k normalized
with overhead vs 180k direct); Codex: subagent (110k vs 180k direct)*
Delete both `defarg` copies, convert callers to positional expansion, replace
eval-generated directory commands with direct wrappers and one completion
function, and make util listing/completion consume one discovery implementation.
Characterize spaced arguments and command shadowing first. Files:
`aliases.sh`, `git-aliases.sh`, `util/lib.sh`, `util/dispatch.sh`,
`util/completions.sh`, `tests/aliases-smoke.sh`,
`util/tests/util-router.sh`.

**WP-R6 — Give dotfiles explicit identity and transaction boundaries.**
*~0.8 kSLOC touched · ~240k tokens · ~19 min wall · top (Claude Opus/high;
Codex gpt-5.6-sol/high) · Claude: subagent (same-tier dispatch adds 20k for
independent state-transition review); Codex: subagent (same-tier dispatch adds
20k for the same boundary review)*
Separate configuration/validation from mutation, record stable project roots,
scope snapshot staging, preflight/report multi-remote publication, and make
restore outcomes truthful while preserving no-clobber semantics. Include a
backward-compatible migration from basename-only metadata. Files:
`dotfiles.sh`, `config.example.sh`, `tests/root-utils-smoke.sh`,
`README.md`, `AGENTS.md`.

**WP-R7 — Make blamecount self-contained and close the root gate.**
*~0.6 kSLOC touched · ~180k tokens · ~14 min wall · mid (Claude Sonnet/medium;
Codex gpt-5.6-terra/medium) · Claude: subagent (116k normalized with overhead
vs 160k direct); Codex: subagent (100k vs 160k direct)*
Replace undeclared Node dependencies and callback-global flow with built-in
Node/Git primitives, add bounded concurrency and explicit failure exits, add a
hermetic blame fixture, and have the prescribed root gate exercise every
retained public tool plus the new source/public-contract invariants. Files:
`blamecount/blamecount.js`, `blamecount/config.example.json`,
new blamecount tests, `tests/shell-gate.sh`, `README.md`, `AGENTS.md`.

### Public Interfaces

- `pkg-ioc/scan.sh` keeps its CLI, output classes, and exit codes.
- Existing alias names and `util <command> [args...]` remain available except
  the already-broken `lifi` alias.
- `dotfiles.sh` keeps `add`, `backup`, `restore`, `list`, `project`, `snapshot`,
  and `status`; project metadata gains an explicit source-root record and a
  compatibility migration.
- `blamecount` keeps config-file support and gains explicit CLI/error behavior.
- Generated C projects retain their build/debug/profiling/valgrind entry points.

### Execution

WP-R3 must land before WP-R4. WP-R1, WP-R2, WP-R3, WP-R5, WP-R6, and WP-R7 have
coherent file scopes and may otherwise be dispatched in parallel, subject to
the user's model/subagent choice at orchestration time. WP-R7's final root-gate
integration is rebased after the other packages. The orchestrator reviews every
worker diff, runs the package-focused gate, runs the full prescribed gate, and
commits each work package; workers never commit.

### Test Plan / Verification

Focused iteration uses the commands already prescribed by the nearest
`AGENTS.md`:

```bash
bash util/tests/util-router.sh
bash tests/aliases-smoke.sh
bash tests/root-utils-smoke.sh
bash pkg-ioc/tests/smoke.sh
(cd build_system && ./build.sh)
```

WP-R1 adds a hermetic `mkproject` fixture that builds from canonical parts.
WP-R2 adds assertions that the public tree has no missing advertised target,
unresolved `GEN_*` token, tracked backup, or literal personal home path. WP-R3
and WP-R4 retain every existing positive, negative, watch-only, and router
assertion while adding canonical-rule and traversal-count coverage. WP-R7 adds
a temporary Git repository with known authorship and a forced-error case.

Every package closes with the repository's prescribed complete gate:

```bash
bash tests/shell-gate.sh
```

Observable success is exit 0 with no working-tree changes produced by the gate.

### Critical Files

- `build_system/_build.c`, `build_system/mkproject.sh`,
  `build_system/parts/pkgconfig.c`
- `pkg-ioc/lib/common.sh`, `pkg-ioc/lib/npm.sh`,
  `pkg-ioc/lib/pypi.sh`, `pkg-ioc/AGENTS.md`
- `aliases.sh`, `util/dispatch.sh`, `util/completions.sh`
- `dotfiles.sh`
- `blamecount/blamecount.js`
- `tests/shell-gate.sh`

### Assumptions

- Static root/gpuedit themes are the behavior that matters; the currently inert
  generator has no external consumer requiring its placeholder templates.
- The old lifi implementation was intentionally moved out of the public tree in
  `14c5db0`; removing stale references is preferable to reintroducing
  multi-license assets into a CC0-only repository.
- Node and Git are acceptable runtime dependencies for the already-advertised
  blamecount tool; third-party npm dependencies are not needed.
- Multi-remote Git pushes cannot be made truly atomic, so dotfiles remediation
  preflights and reports partial publication rather than pretending atomicity.
- Token tags are all-in raw estimates (worker band plus 20k orchestration
  overhead). Normalized path totals use the canonical model-cost calculator.

**Total ≈ 7.9 kSLOC, ~1,510k raw tokens; ~1,258k Claude-path / ~1,195k
Codex-path Opus/Sol-equivalent tokens.**
