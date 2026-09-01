# Spike record — cache reporting fidelity (2026-08-31)

Measurements taken after `util cache-prune` shipped and was run live (once interactive, twice `--yes`). These are load-bearing inputs for the reporting-fidelity plan; **do not re-derive.**

## Live run outcome

Safety property held exactly. Across two `--yes` runs, byte-identical before/after:
- pip `6737118576` → `6737118576`
- bun `1068204235` → `1068204235`

Reclaimed: npm ~2.9 GB, docker build cache 92.83 → 68.26 GB (~24.5 GB). uv byte-identical (`23061960377`).
Separately, `~/.cache/huggingface` fell 26 GB → 5.8 GB by some other means — **not** this tool, which has no huggingface entry. Do not attribute it to cache-prune.

## Finding A — docker: age cannot predict reclaim

Build cache is a **DAG**. `docker buildx du --verbose` emits explicit `Parents:` edges. BuildKit will not remove a record while any descendant survives, so an old parent with a recent child is retained regardless of its own age.

Both filter keys are valid and both were tested:
- `--filter until=<d>` — created-before
- `--filter unused-for=<d>` — last-used

Decisive probe: `docker builder prune --filter unused-for=1300h --force` → **`Total: 0B`**, despite 8 entries last used 8 weeks ago. Neither filter reaches them.

Surviving weeks-old cache after two prunes (42.27 GB total): 2wk 26.04, 3wk 1.38, 4wk 2.18, 5wk 11.55, 6wk 0.16, 7wk 0.57, 8wk 0.40 GB.

`docker buildx du`: Shared 9.099 GB / Private 59.16 GB / Reclaimable 68.26 GB / Total 68.26 GB. **`Reclaimable: true` means "not pinned by an active build", not "removable under your filter."**

Conclusion: the shipped age-sum probe reported 72.8 GB; the real prune yielded 24.5 GB. Age-summing has no predictive power. The reportable figure is an upper bound at best.

## Finding B — uv: hardlink sharing makes `du` overstate ~20x

The 22 GB is entirely `archive-v0`, uv's unpacked wheel store, which uv **hardlinks** into venvs.

Byte-weighted census of `~/.cache/uv/archive-v0`:
```
total:                 22.26 GB  (115,596 files)
cache-only (link=1):    1.08 GB   <- genuinely reclaimable
shared with venvs (>1):21.18 GB   <- freeing the cache frees ~0
```

95% is co-owned by live virtualenvs; deleting a cache entry only decrements a link count. `uv cache prune` returning zero is **correct**. Even a full `uv cache clean` returns ~1 GB, not 22.

Cross-runtime check (total | cache-only | shared, GB):
```
~/.npm                4.29 | 4.29 | 0.00
~/.cache/pip          6.74 | 6.74 | 0.00
~/.bun/install/cache  1.07 | 0.69 | 0.38
~/.cargo/registry     0.43 | 0.43 | 0.00
```
So hardlink sharing is overwhelmingly a uv phenomenon; bun is mildly affected; npm/pip/cargo are unaffected and `du` is accurate for them.

## Root cause, stated once

`du -sb` and age-sums measure **how much data is present**, not **how much would be returned**. Sharing (hardlinks) and structure (the build-cache DAG) both break that equivalence. The tool's *actions* are correct and safe; its *reporting* oversells.

## Corrected reclaim picture

Original survey claimed ~102 GB. Realistic: npm 4.29, pip 6.74 (opt-in), uv ~1.08, bun ~0.69 (opt-in), cargo 0.43 (report-only), plus an unpredictable docker slice.

## Method notes for the implementer

- Link-aware sizing: `find <dir> -type f -printf '%n %s\n'` then sum by `$1>1` vs `$1==1`. Completed over 115k files well inside a 300 s timeout, but it is materially slower than `du -sb` — a perf consideration for the probe.
- `docker buildx du` prints `Shared:`/`Private:`/`Reclaimable:`/`Total:` as trailing labelled lines — a far more stable parse than the `system df -v` table walk currently in the script.
