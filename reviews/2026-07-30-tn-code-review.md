---
review-date: 2026-07-30
review-commit: 311b804
review-type: tn-code-review
review-model: gpt-5.6-sol
review-harness: codex
review-effort: high
remediation-commit: ebcee627a05be206f11b5eac4ac83a88308086be
---
# Review — scripts repository maintainability audit

| Tier | Open | Resolved |
|---|---:|---:|
| structural-regressions | 0 | 2 |
| simplification-misses | 0 | 2 |
| spaghetti | 0 | 1 |
| boundary-type-contracts | 0 | 2 |
| file-size | 0 | 0 |
| modularity | 0 | 1 |
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

## Revalidation — 2026-09-07

All eight findings F1–F8 remain Open at `ade9ded4c2fb06f2b19f33ef110b376c0dfbeca4`. The affected implementation paths are byte-identical to `311b804`; the current review rechecked their source and the expanded root gate. No finding was remediated by this documentation update. Historical provenance and counts above are preserved.

The current assessment is [the 2026-09-07 review](2026-09-07-tn-code-review.md), which carries F1–F8 forward and adds F9 for cache-prune measurement provenance and orchestration growth. The old claim that only generated code exceeds 1,000 lines is historical: the current cache implementation and test file now exceed that threshold. The old scope paragraph also misattributes the 55 assertions to root utilities: today's root-utility suite reports 44/44; the IOC suite reports 55/55.

The embedded remediation proposal has been superseded by [the standalone remediation plan](../plans/2026-09-07-tn-code-review-remediation.md), registered in `INITIATIVE.md` under `pending-plans`. Its previous instructions to leave the plan unregistered, route implementation to Codex, and impose separate review thresholds are withdrawn. Actual initiative thresholds remain unchanged. Proposed design choices in that historical proposal were not evidence of user approval.

Future remediation updates the current review record only; this historical record remains an account of the July review. Neither record receives a remediation baseline from this revalidation.

## Closed — 2026-09-07

F1–F8 were remediated by the [standalone remediation plan](../plans/2026-09-07-tn-code-review-remediation.md) (WP-R8, R1–R7, landing SHAs in the plan's Status line); the last substantive commit, `ebcee62` (WP-R7), brought every Open count to zero and is this record's `remediation-commit`, matching the [2026-09-07 record](2026-09-07-tn-code-review.md). The table above now reads 0 Open / 8 Resolved. The 2026-09-07 revalidation's instruction to preserve this record's Open counts is withdrawn: the Initiative Tracker sums Open counts across every record in `reviews/`, so carried findings left Open here were double-counted against the current record and, after closeout, showed as eight phantom open findings. The original finding prose and `review-commit` remain the historical account.
