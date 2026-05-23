# Phase 6 — snapshots + Snowflake Streams/Tasks as code

**Status:** shipped (2026-10-25)
**Depends on:** Phase 4 staging, Phase 5 marts

## Goal

Add two things that elevate the warehouse from "current state only" to
"full-fidelity regulatory asset":

1. **SCD2 history** for `customers` + `accounts` via dbt snapshots over
   the staging layer. Point-in-time joins become trivial, "what did we
   know on `posted_date`?" becomes answerable.
2. **Snowflake Streams + Tasks** committed as code — the native CDC-on-CDC
   layer that sits between Kafka Connector raw-landed rows and the
   staging layer in prod. Reviewable and documented; runs in prod, not
   in CI.

## Shape added

```
dbt/snapshots/
├── snap_banking__customers.sql          -- SCD2 history, timestamp strategy on updated_at
└── snap_banking__accounts.sql

dbt/models/marts/core/
├── dim_customer_scd2.sql                -- thin view that renames dbt_* columns
└── dim_account_scd2.sql

snowflake/streams-tasks/
├── README.md                            -- design, apply order, dev-vs-prod mapping
├── 01-raw-streams.sql                   -- CREATE STREAM on all 4 raw tables
├── 02-staging-refresh-task.sql          -- Task DAG + stored proc (customers templated;
│                                           other 3 follow identical pattern)
└── 03-admin.sql                         -- RESUME/SUSPEND/SHOW/EXECUTE ops
```

## SCD2 — the pattern

Snapshots read from `stg_banking__{customers, accounts}` (already
deduped to current state), use the `timestamp` strategy on `updated_at`,
and have `invalidate_hard_deletes: true`:

- Every change to `updated_at` opens a new SCD2 row (dbt sets
  `dbt_valid_from = source.updated_at`, closes the previous row's
  `dbt_valid_to`).
- Rows that disappear from source (deleted by the OLTP) have their
  current snapshot row closed (`dbt_valid_to = CURRENT_TIMESTAMP`).
- Rows that never change stay as one open row forever.

The snapshot table itself IS the SCD2 — dbt adds `dbt_valid_from`,
`dbt_valid_to`, `dbt_scd_id`, `dbt_updated_at`. The `dim_*_scd2` views
rename these to `valid_from` / `valid_to` / `is_current` so business
users don't need to know dbt lives underneath.

### Point-in-time join

The canonical SCD2 join against a fact:

```sql
select
    f.transaction_id_pk,
    f.posted_at,
    f.amount,
    d.full_name                              as customer_name_at_posting,
    d.kyc_status_label                       as kyc_status_at_posting
from {{ ref('fct_transactions') }}  f
join {{ ref('dim_customer_scd2') }} d
    on f.customer_id = d.customer_id
    and f.posted_at >= d.valid_from
    and (f.posted_at < d.valid_to or d.valid_to is null)
```

This answers "what was the customer's KYC status at the moment the
transaction posted?" — not "what is it today". For regulatory and
dispute workflows, the second answer is wrong.

## SCD2 doesn't run meaningfully in CI

`dbt build` in CI runs `dbt snapshot` exactly once per build:

- First run → creates the snapshot table, inserts all current staging rows.
- No second run → `dbt_valid_to` stays null for every row.

So CI proves the **plumbing works** (snapshots compile, SCD2 views
materialize, tests pass) but doesn't prove history is captured over
time. That proof happens one of two ways:

1. **Locally** — modify fixture, re-run the pipeline, inspect snapshot:
   ```bash
   # Run 1 — initial state
   python scripts/seed-duckdb-fixture.py
   cd dbt && dbt build --profiles-dir . --target dev --select +snap_banking__customers

   # Change customer 1's phone number in sql/duckdb/raw_fixture.sql, bump
   # updated_at by a day, then:
   python scripts/seed-duckdb-fixture.py
   dbt build --profiles-dir . --target dev --select +snap_banking__customers

   # Now there are 2 rows in snap_banking__customers for customer_id = 1
   duckdb ../warehouse/banking.duckdb -c "
       SELECT customer_id, phone, dbt_valid_from, dbt_valid_to
       FROM snapshots.snap_banking__customers
       WHERE customer_id = 1
       ORDER BY dbt_valid_from
   "
   ```

2. **In Snowflake prod** — snapshots run on schedule (dbt Cloud / Airflow)
   and every real customer attribute change captures a new row.

## Streams + Tasks — what they are, why they matter

`BANKING_PROD.RAW.*` is append-only (Snowflake Kafka Connector lands
every change event as a new row). The question "which rows arrived
since dbt last ran?" needs **change detection on top of change data**
— that's a Snowflake Stream's job.

| primitive | role |
|---|---|
| **Stream** | Virtual table over a base table that surfaces rows new/updated/deleted since last consumption. Here: one per raw table. |
| **Task**   | Scheduled or event-triggered SQL. Here: root task on 5-minute schedule, child task per table that drains its stream. |
| **Stored procedure** | Encapsulates the MERGE from stream → staging target. One per table. |

### Why not just use incremental dbt models and skip Streams?

Both work. The trade-off:

| Approach | Pro | Con |
|---|---|---|
| Incremental dbt models + `is_incremental()` | lives in dbt, one tool to learn | needs a watermark column + full-table scan to find new rows |
| Streams + Tasks (this phase) | O(delta) change detection, no watermark needed, exactly-once consumption via COMMIT | Snowflake-native, no DuckDB equivalent |

In prod, both exist side-by-side in most mature setups. This phase
demos the Streams/Tasks primitives so the pattern is in the portfolio;
Phase 7 demonstrates the incremental dbt path.

### Dev-vs-prod mapping

| Concern | DuckDB dev | Snowflake prod |
|---|---|---|
| Raw layer shape | current-state (sink does DELETE-INSERT) | append-only (Kafka Connector appends) |
| Change detection | not needed (sink already current-state) | Streams on raw.* |
| Incremental refresh | scheduled `dbt build` | Task DAG consuming streams |
| Reconciliation | `banking-cdc sink status` | Phase 10 cost + perf runbook |

Both run the same dbt staging/mart SQL — Phase 4 QUALIFY works on both
shapes transparently. Only the "what triggers a refresh" differs.

## What this phase explicitly does NOT ship

- Snapshot `check` strategy (we use `timestamp`; both are valid, `timestamp`
  is a cleaner contract with the OLTP's `updated_at` guarantee)
- Incremental dbt models (Phase 7)
- Stored procedures for the other three tables beyond customers (same
  pattern, templatise — kept short in `02-staging-refresh-task.sql` for
  review brevity)
- Streams on view-materialized objects (requires `CREATE SECURE VIEW
  SHOW_INITIAL_ROWS=TRUE` dance — not relevant here)
- Serverless tasks (we use `WH_INGEST_XS` for cost accounting; swap
  trivially in `02-...sql`)
- Airflow / dbt Cloud scheduling (Phase 7 or docs/examples)

## Next phase

**Phase 7** — the `dbt_banking` package. Extract the macros + the
dimensional conventions used by the marts into a reusable installable
dbt package. Add a `metrics_revenue` semantic layer definition, an
incremental model for `fct_transactions`, and the Airflow DAG example
that wires `dbt build` to a scheduler.
