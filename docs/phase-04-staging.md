# Phase 4 — dbt staging (dual-adapter)

**Status:** shipped (2026-10-25)
**Depends on:** Phase 3 (raw DuckDB tables populated by the sink; equivalent
Snowflake raw schema wired up by the Snowflake Kafka Connector in prod)

## Goal

Land the first dbt layer — four staging views that turn the Debezium raw
CDC log into a clean, deduplicated, type-cast surface the Phase 5 marts
can build on. The whole layer runs on both DuckDB (`dev`) and Snowflake
(`prod`) from the same SQL.

## Shape

```
dbt/
├── dbt_project.yml                 — project config, +schema per layer
├── profiles.yml                    — dev=duckdb, prod=snowflake (env_var only)
├── packages.yml                    — dbt_utils pinned
├── macros/
│   └── generate_schema_name.sql    — overrides default to drop <env>_ prefix
└── models/
    └── staging/
        ├── _banking__sources.yml   — 4 sources + descriptions
        ├── _banking__models.yml    — tests on every model
        ├── stg_banking__customers.sql
        ├── stg_banking__accounts.sql
        ├── stg_banking__transactions.sql
        └── stg_banking__card_events.sql
```

Plus one supporting artifact for the dev + CI loop:

- `sql/duckdb/raw_fixture.sql` — tiny deterministic rows that exercise
  every enum value, every FK relationship, and the dedup window.
- `scripts/seed-duckdb-fixture.py` — one-shot `raw_schema.sql` +
  `raw_fixture.sql` applier used by CI and cold-start dev.

## The dedup pattern

Both DuckDB and Snowflake support `QUALIFY`, so every staging model uses
the same window:

```sql
qualify row_number() over (
    partition by id
    order by __lsn desc, __source_ts_ms desc
) = 1
```

This handles **both** raw-layer shapes transparently:

| raw layer shape        | source                            | window behaviour                 |
|------------------------|-----------------------------------|----------------------------------|
| current-state per PK   | DuckDB sink (DELETE-then-INSERT)  | at most one row — no-op pass     |
| append-only change log | Snowflake Kafka Connector         | picks latest `__lsn` per PK      |

The models are therefore **adapter-agnostic**: no `{{ adapter.type() }}`
branching, no dispatch macros. If the two adapters later diverge on a
specific function (e.g. date-truncation syntax), the fix pattern is:

```sql
{{ banking_cdc.date_trunc('day', posted_at) }}
```

…backed by a `date_trunc` macro that dispatches on adapter type. Phase 4
doesn't need this yet — kept here as a design note so Phase 5 reviewers
know the escape hatch exists.

## Delete semantics

Delete tombstones (`__op = 'd'`) are **kept** in staging, flagged with
`_is_deleted = true`. Rationale:

- Regulatory banking workloads need the full audit trail; downstream
  marts can filter deletes out when they want a "live customers" view,
  but the raw-adjacent layer should preserve what happened.
- Dropping deletes at staging silently hides integrity bugs where a
  downstream model's PK uniqueness depends on a delete having happened.

Asymmetry to document: in the DuckDB dev path, deletes manifest as
**row absent** (because the sink does DELETE-and-no-INSERT); in the
Snowflake prod path, deletes manifest as a `_is_deleted=true` row. The
Phase 6 streams-and-tasks layer closes this gap by materialising a full
change log in dev too.

## Why not use dbt sources' `loaded_at_field` for freshness

Freshness is only meaningful when the sink is actively running. In CI
and in cold-start dev the fixture-driven raw tables are static, so
`dbt source freshness` would always fail. Phase 4 declares sources
without `loaded_at_field`; Phase 10 (cost + perf runbook) adds freshness
checks against a hosted Snowflake with real traffic.

## Tests shipped

Every staging model gets:

- `unique` + `not_null` on the business PK
- `relationships` where a FK is semantically present
- `accepted_values` on every enum column (synced to the OLTP enum)
- `accepted_values` on `_cdc_op` so a surprise envelope op would fail CI

Snapshot of the test matrix:

| model                        | PK unique+not_null | FK relationships | enum accepted_values |
|------------------------------|:------------------:|:----------------:|:--------------------:|
| `stg_banking__customers`     | ✓                  |                  | kyc_status, _cdc_op  |
| `stg_banking__accounts`      | ✓                  | → customers      | account_type, status, _cdc_op |
| `stg_banking__transactions`  | ✓ (PK + UUID)      | → accounts       | direction, type, status, _cdc_op |
| `stg_banking__card_events`   | ✓ (PK + UUID)      | → accounts       | event_type, _cdc_op  |

## CI

A new `dbt build (duckdb)` job runs in parallel with `pytest`:

1. install `[dev,warehouse,dbt]`
2. apply raw schema + fixture to a fresh `warehouse/banking.duckdb`
3. `dbt deps --profiles-dir .`
4. `dbt build --profiles-dir . --target dev --fail-fast`

This gives us compile-time + test-time coverage of every staging model
on every push, without needing the Postgres/Kafka service containers.

## Interview-safe answer to "did you run this on Snowflake?"

> The project ships the full Snowflake footprint as reviewable code —
> roles, warehouses, resource monitors, grants, dbt profile, Kafka
> Connector config — and runs end-to-end on DuckDB for the live demo
> because a personal Snowflake trial would conflict with my employer's
> data governance policy. The dbt staging layer is identical SQL on
> both adapters; the Snowflake path is one env-var export and a
> `dbt build --target prod` away from running.

## Local dev loop

```bash
# first time only
pip install -e ".[dev,postgres,kafka,warehouse,dbt]"
python scripts/seed-duckdb-fixture.py

# every iteration
cd dbt
dbt build --profiles-dir . --target dev --fail-fast

# inspect a specific model
dbt show --profiles-dir . --target dev --inline "
    select customer_id, first_name, kyc_status, _is_deleted, _cdc_lsn
    from {{ ref('stg_banking__customers') }}
    order by customer_id
"
```

## What this phase explicitly does NOT ship

- Intermediate models (Phase 5)
- Marts / dim + fact (Phase 5)
- Snapshots / SCD2 (Phase 6)
- Macros beyond `generate_schema_name` (Phase 5+)
- Snowflake adapter installed by default (prod deployer adds
  `dbt-snowflake~=1.8` on top of the `dbt` extra)
- `dbt docs` generation + hosting (Phase 12)

## Next phase

**Phase 5** — intermediate + marts. Build a `dim_customer` + `dim_account`
+ `fct_transactions` grain, with surrogate keys from `dbt_utils`, enum
decoding to display labels, and a first cut of the revenue + risk marts
the interview narrative hinges on.
