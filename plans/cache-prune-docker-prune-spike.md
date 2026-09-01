# Spike record — unfiltered docker build-cache prune (2026-09-01)

User-authorised destructive measurement, run to settle the blocking finding of the `cache-prune-reclaim-effectiveness` plan audit (`runs/dispatch/cache-prune-reclaim-effectiveness-plan-audit-report.md`, codex-david / `gpt-5.6-sol` / medium).

**Unrepeatable.** The 59 GB it measured no longer exists. Do not attempt to re-derive these numbers; read them here.

Command, exactly as run — unfiltered, **no `--all`**, build cache only:

```
docker builder prune --force
```

## Measurements

| | before | after |
|---|---|---|
| `buildx du` Total | 68.26 GB | 9.099 GB |
| `buildx du` Private | 59.16 GB | **0B** |
| `buildx du` Shared | 9.099 GB | 9.099 GB |
| `buildx du` Reclaimable | 68.26 GB | 9.099 GB |
| `system df` Build Cache SIZE | 68.26 GB | 9.099 GB |
| `system df` Build Cache RECLAIMABLE | 59.16 GB | **0B** |
| record count | 1625 | 218 |
| disk avail on docker root | 117,213,601,792 | 175,811,203,072 |

Docker's own prune output reported `Total: 59.16GB` freed.

## Finding A — `system df`'s RECLAIMABLE is the exact predictor; `buildx du`'s is not

```
system df RECLAIMABLE  59.16 GB  ->  freed 59.16 GB   EXACT
buildx du Reclaimable  68.26 GB  ->  freed 59.16 GB   over by 9.10 GB
```

This settles the primary/fallback question the predecessor plan deliberately left open. For the **unfiltered prune verb**, `docker system df`'s Build Cache RECLAIMABLE column is the figure that corresponds; `buildx du`'s `Reclaimable:` overstates by exactly the Shared total. The predecessor's choice of buildx-as-primary was correct for *parse stability* but wrong for *predictive correspondence*.

## Finding B — the residual is Shared, and `--all` is a different dimension

After the prune, `Private: 0B` and `system df` RECLAIMABLE `0B`: docker itself now says **nothing further is reclaimable**. The surviving 9.099 GB is exactly the pre-existing `Shared` figure.

The audit was right to reject the plan's earlier claim that this ~9 GB is "the slice `--all` would add". `--all` means "include internal/frontend images" — a different axis from Shared entirely. Whether `--all` would remove any of the 9.099 GB remains **unmeasured**, and the plan does not claim otherwise.

## Finding C — the age filter was the whole obstacle, for the Private portion only

Measured contrast on the same cache state:

- `--filter until=168h` → `Total: 0B` (recorded in the predecessor spike)
- unfiltered → `Total: 59.16GB`

So dropping the default filter is worth the entire Private slice. Confirmed by execution, not inferred from the DAG argument.

## Finding D — reported freed ≠ disk freed, by ~1%

```
docker reported freed:  59.16 GB
disk actually freed:    58.60 GB  (58,597,601,280 bytes)
discrepancy:             0.56 GB  (1.0%)
```

Independent empirical support for the audit's material finding that a before/after delta is an **observed footprint delta**, not exact attributable bytes. Docker's accounting is quantised (it renders rounded human tokens like `68.26GB`, even under `--format json`) and does not reconcile exactly with filesystem reality. Any "bytes freed" reporting must be labelled as observed, never as exact.

## Consequence for the plan

The acceptance criterion changes: docker's cache is now 9.099 GB with 0B reclaimable, so a post-implementation live run **cannot** reclaim ~59 GB again. WP-1's value is that future accumulation stays reachable rather than being blocked by the filter; acceptance must be stated against a fresh accumulation, not against this one-time figure.
