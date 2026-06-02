# Phase 12 — hosted docs site, exposures, rowcount baseline

**Status:** shipped (2026-10-25)
**Depends on:** Phase 11 (manifest artifact publishing, PR delta
scaffolding), Phase 7 (semantic layer + metrics so the exposures can
reference them)

## Goal

Make the project **browsable + contract-driven**:

1. **Exposures** — declare the downstream consumers (dashboards, ML
   feeds, regulatory reports) as first-class dbt resources with owner
   contacts + maturity labels. A breaking change to a mart surfaces as
   "X exposures impacted" in the lineage graph.
2. **Hosted dbt docs site** — build + deploy to GitHub Pages on every
   push to main. The published URL is the lineage + column-level docs
   source of truth; a reviewer or new team member clicks straight into
   the DAG instead of running `dbt docs serve` locally.
3. **Rowcount baseline publishing** — fill the "n/a" gap in the Phase 11
   PR delta table. Every main-branch build now emits
   `rowcount-baseline.json` as an artifact; the PR workflow downloads
   it and the delta table shows signed Δ per model instead of
   placeholder "n/a".
4. **README polish + Pages badge** — the headline README now carries
   the Pages URL + a per-phase ✅ matrix.

## Shape added

```
dbt/
└── models/
    └── exposures.yml                  -- 5 exposures (dashboard, app, ml)

scripts/
├── rowcount-baseline.py               -- NEW: emits per-model counts JSON
└── pr-rowcount-delta.py               -- UPGRADED: consumes --baseline-counts

.github/workflows/
├── ci.yml                             -- publishes rowcount-baseline-main artifact
├── pr-lineage.yml                     -- downloads it, passes to delta script
└── docs.yml                           -- NEW: build + deploy to GitHub Pages
```

## The five exposures

| Name | Type | Maturity | Depends on |
|---|---|---|---|
| `finance_executive_dashboard` | dashboard | high | `agg_monthly_customer_revenue`, `dim_customer`, metrics `bank_revenue_usd` + `revenue_per_transaction_usd` |
| `marketing_cohort_builder` | application | medium | `vw_customer_marketing` (Phase 9 always-masked consumer view) |
| `regulatory_quarterly_reporting` | application | high | `fct_transactions`, `fct_card_events`, `dim_account_scd2`, `recon_transaction_amounts` |
| `data_quality_dashboard` | dashboard | high | `recon_transaction_amounts` (Phase 9 recon surface) |
| `ml_fraud_scoring` | ml | medium | `fct_card_events`, `fct_transactions`, `dim_customer_scd2` |

Each one carries:
- `owner.name` + `owner.email` — the person a breaking change pings
- `url` — where the consumer actually runs
- `description` — a 2-3 sentence operational summary (SLA, refresh
  cadence, pager behaviour)

A targeted rebuild for a single consumer:

```bash
dbt build --select +exposure:finance_executive_dashboard
# → builds every model the dashboard depends on, in topo order,
#   including Phase 7 metrics.
```

## The rowcount-baseline + PR-delta loop

```
on push to main:
    ci.yml → full dbt build → rowcount-baseline.py → upload
             rowcount-baseline-main.json (14-day retention)

on PR open/sync:
    pr-lineage.yml → download dbt-manifest-main + rowcount-baseline-main
                  → dbt build --defer --state state/ --select state:modified+
                  → pr-rowcount-delta.py --baseline-counts state/rowcount-baseline.json
                  → sticky PR comment with | model | main baseline | PR build | Δ |
```

The upgraded `pr-rowcount-delta.py` has three modes:

| Baseline available? | PR models match baseline? | Output |
|---|---|---|
| no | — | Full count table, baseline column `n/a`, footer explaining why |
| yes | all match | `> _No row-count change vs the main baseline._` (quiet mode — no table) |
| yes | some differ | Only differing rows, signed Δ column, baseline populated |

The quiet mode keeps the sticky PR comment unobtrusive on docs-only or
model-rename PRs that genuinely don't change counts.

## The docs site

`docs.yml` runs on push-to-main (and `workflow_dispatch`). It:

1. Builds the full DAG against the fixture (so docs include real
   pass/fail test annotations + rowcounts).
2. Runs `dbt docs generate` to produce `manifest.json`, `catalog.json`,
   and the dbt docs app's `index.html`.
3. **Inlines** `manifest.json` + `catalog.json` into `index.html` so
   the deployed site is a single-file static deployable. Standard dbt
   docs loads the JSONs via `fetch()` at runtime; GitHub Pages serves
   both, but the inline trick removes the need for CORS fiddling and
   makes the site survive a `fetch()` failure on strict CSP browsers.
4. Deploys to GitHub Pages via `actions/deploy-pages@v4`.

**One-time repo setup.** The UI path is
`Settings → Pages → Build and deployment → Source: GitHub Actions`, but
the REST API is the reviewable + reproducible path:

```bash
gh api --method POST repos/<owner>/<repo>/pages -f build_type=workflow
```

After that flip, the next push to main publishes to
`https://<owner>.github.io/<repo>/`. For this repo the one-liner was
run against `bapuji-dirisala/banking-cdc-warehouse`; the live site is
<https://bapuji-dirisala.github.io/banking-cdc-warehouse/>.

## Trade-offs documented

| Decision | Alternative | Why we chose this |
|---|---|---|
| Inline manifest+catalog into `index.html` | Serve JSONs alongside | Single-file deploy survives CSP + CORS edge cases; no bandwidth concern at this project's manifest size (~160 KB) |
| Exposures in a single `exposures.yml` | One file per exposure | At 5 exposures the single file is still scannable; split happens at ~15 |
| Rowcount baseline per model (not per table.column) | Per-column null counts, min/max | Phase 12 is scope-bound to the Phase 11 "fill n/a" gap; column-level drift is Phase 13 scope if the project pivots to a formal data-contract framework |
| `cancel-in-progress: false` on pages concurrency | `true` | A cancelled deploy mid-upload can leave Pages serving a half-published site; the extra few seconds of queueing is worth it |

## What this phase explicitly does NOT ship

- The GitHub Pages Settings flip (manual one-time; documented above)
- A nightly re-publish of the Snowflake-side docs (project is
  DuckDB-first for the hosted artifact; Snowflake-side would need a
  running account to produce the catalog JSON)
- A "data contract" tool like `dbt-contracts` or `recce` (Phase 13
  scope if the project adds formal change-impact reviews)
- Column-level null/distinct-count baselines (same)
- A Mermaid architecture diagram embedded in the Pages site (dbt's own
  lineage DAG is richer; the README-side Mermaid is the architecture
  overview, the Pages site is the detailed browser)

## Local verification

```bash
cd dbt
dbt build --profiles-dir . --target dev --fail-fast
dbt docs generate --profiles-dir . --target dev
# Preview locally (opens a browser on :8080):
dbt docs serve --profiles-dir . --target dev

# Generate the rowcount baseline:
python ../scripts/rowcount-baseline.py \
    --duckdb-path ../warehouse/banking.duckdb \
    --manifest    target/manifest.json \
    --output      ../rowcount-baseline.json

cat ../rowcount-baseline.json | head -30
```

## Next phase

**Phase 13** (optional) — Jenkins declarative pipeline + Airflow DAG
mirroring the GitHub Actions pipeline. Side-by-side orchestrator
comparison for the portfolio.
