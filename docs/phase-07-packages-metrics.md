# Phase 7 — package patterns + incremental + semantic layer + orchestration

**Status:** shipped (2026-10-25)
**Depends on:** Phase 5 (marts), Phase 6 (snapshots)

## Goal

Four things that take the dbt layer from "working project" to
"production-ready package":

1. **Incremental** `fct_transactions` using `_cdc_lsn` as the watermark —
   the dbt-native equivalent to Phase 6's Snowflake Streams + Tasks path.
2. **Reusable macros** under the `banking_cdc.*` namespace — organised
   so this folder is one `mv` away from being a standalone
   `dbt-packages/dbt_banking` installable package.
3. **Semantic layer** definitions (`semantic_models` + `metrics`) so
   downstream BI tools consume curated metrics instead of re-implementing
   `SUM(amount) WHERE status = 'posted'` in every dashboard.
4. **Airflow DAG example** showing how `dbt build` is scheduled in a
   non-dbt-Cloud, non-Snowflake-Tasks world.

## Shape added

```
dbt/
├── macros/
│   ├── initcap.sql           -- Phase 5 (dispatch example)
│   ├── safe_divide.sql       -- Phase 7 — portable divide-by-zero
│   └── audit_columns.sql     -- Phase 7 — standard audit column block
└── models/
    └── marts/
        ├── core/
        │   └── fct_transactions.sql    -- Phase 7 — converted to incremental
        └── finance/
            └── _finance__metrics.yml   -- Phase 7 — semantic models + metrics

orchestration/airflow/
├── README.md
└── dags/
    └── banking_cdc_dbt.py              -- example DAG for scheduled dbt build
```

## Incremental `fct_transactions`

The model is now:

```sql
{{ config(
    materialized='incremental',
    unique_key='transaction_sk',
    incremental_strategy='delete+insert',
) }}

...
{% if is_incremental() %}
    where _cdc_lsn > (select coalesce(max(source_lsn), 0) from {{ this }})
{% endif %}
...
```

Behavior:

| Run | Behavior |
|---|---|
| First (`--full-refresh` or empty target) | `is_incremental()` is false → scans all source rows → full build |
| Steady-state | `is_incremental()` is true → scans only rows with `_cdc_lsn > max(materialised source_lsn)` |

Portability — `delete+insert` is the DuckDB default and Snowflake
supports it natively; both adapters emit the same semantics (delete rows
whose `unique_key` matches the incoming batch, then insert the batch).
Snowflake-only clusters that want to leverage `MERGE INTO` can switch
to `incremental_strategy='merge'` without touching the SQL body.

### Streams + Tasks vs. incremental dbt — side by side

Both patterns are now in the repo. Choose by cadence + ownership:

| Pattern | Latency floor | Ownership | Right choice when… |
|---|---|---|---|
| **Snowflake Streams + Tasks** (Phase 6) | ~1 min | SQL + Snowflake Admin | sub-minute SLA; raw layer is append-only; prefer SQL-native change detection |
| **Incremental dbt** (this phase) | scheduler floor (~5 min) | dbt + Airflow | batch-friendly SLA; want portable logic across adapters; prefer git-reviewable transforms |

Both can coexist — streams for latency-critical paths, incremental dbt
for everything else.

## The `banking_cdc.*` macro namespace

Three macros, each solving a legitimate dual-adapter problem:

| Macro | Purpose | Snowflake impl | DuckDB impl |
|---|---|---|---|
| `banking_cdc.initcap(col)` | Title-case a single word | native `INITCAP(col)` | `upper(substr(x,1,1)) \|\| lower(substr(x,2))` |
| `banking_cdc.safe_divide(num, denom)` | Divide-by-zero returns NULL | native `DIV0NULL(num, denom)` | explicit `CASE WHEN denom = 0 THEN NULL …` |
| `banking_cdc.audit_columns(...)` | Emit standard audit columns block | shared | shared |

All three use the `adapter.dispatch` pattern. Promoted to this phase so
the macros folder has enough content to make the "extract to installable
dbt package" conversation real — the extraction itself is a mechanical
move + a `packages.yml` entry, left for Phase 10+ if a second project
needs the same macros.

### How to actually extract this to a reusable package later

```bash
# From the repo root, when the time comes:
git mv dbt/macros ../dbt-packages/dbt_banking/macros
cd ../dbt-packages/dbt_banking
# Add a minimal dbt_project.yml at the root naming the package.
# Push to a git repo, then reference it from this project's packages.yml:
#
#   packages:
#     - git: "https://github.com/bapuji-dirisala/dbt-banking.git"
#       revision: "v0.1.0"
```

The current `banking_cdc.*` namespace in every call site makes this a
no-op for consumers.

## Semantic layer / metrics

`dbt/models/marts/finance/_finance__metrics.yml` defines:

- One `semantic_model` (`transactions`) over `fct_transactions` with
  the primary entity (`transaction`), two foreign entities (`customer`,
  `account`), four categorical/time dimensions, and four measures.
- Five `metrics` composed from those measures:
  - `posted_transaction_count` — count of posted txns
  - `posted_transaction_volume_usd` — sum of posted amounts
  - `net_balance_change_usd` — sum of signed amounts
  - `bank_revenue_usd` — the headline Finance metric
  - `revenue_per_transaction_usd` — ratio metric built from the two above

Why this matters: downstream consumers (Hex, Tableau Cloud, dbt Cloud
Semantic Layer, Lightdash) all understand the same semantic layer
protocol. A dashboard that asks for `bank_revenue_usd grouped by
customer, month` gets the exact same SQL that a Python notebook does
when it asks for the same metric with the same group-by — no
re-implementation drift.

### Why these don't run in CI

Metric execution needs `dbt-metricflow` (not in this project's extras).
The committed yml *is* the deliverable — any MetricFlow-aware consumer
reads it directly. If a Phase 10 budget comes in, adding
`dbt-metricflow` to the `dbt` extra and a `mf validate-configs` step
to the CI job is a 10-line change.

## Airflow DAG example

`orchestration/airflow/dags/banking_cdc_dbt.py` — a self-contained,
Airflow-2.x-compatible DAG that:

```
source_freshness → deps → build_staging → ┬─ build_marts  ─┐
                                           ├─ snapshot     ├─→ done
                                           └─ docs_generate┘
```

Highlights worth reviewing:

- `BashOperator` wrapping `dbt build` so the DAG runs anywhere Airflow
  runs — swap for `KubernetesPodOperator` without touching DAG shape
- `catchup=False` + `max_active_runs=1` so backlogged schedules don't
  stampede the warehouse
- Snapshots and docs run **parallel to** marts, not after — their
  failure doesn't block the mart publish

Not deployed by this repo. Verify the file syntax-parses with:

```bash
python -c "import ast; ast.parse(open('orchestration/airflow/dags/banking_cdc_dbt.py').read()); print('ok')"
```

## What this phase explicitly does NOT ship

- Actual package extraction (the macros folder could be a package;
  mechanical move only — left for when a second project uses it)
- Metrics execution in CI (needs `dbt-metricflow` added to extras)
- Airflow runtime (the DAG is example code; deploy to any Airflow 2.x
  `dags/` folder to adopt)
- dbt Cloud API hook (orthogonal to Airflow; `dbt_cloud_run_job`
  operator is a 20-line swap for `BashOperator` if you move to dbt Cloud)
- PII masking (Phase 8)
- Reconciliation + GE suite (Phase 9)
- Cost/perf runbook (Phase 10)

## Next phase

**Phase 8** — Snowflake PII governance as code. Dynamic data masking
policies on `email` / `phone` / `date_of_birth` scoped per role,
tagging + `OBJECT_TAG` grants, row-access policies on `fct_transactions`
by account_type. Dev-side equivalent: documented masking contract that
the dbt layer honours regardless of adapter.
