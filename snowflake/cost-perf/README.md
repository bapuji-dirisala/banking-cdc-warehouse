# snowflake/cost-perf/ — Phase 10 runbook (code-only)

Snowflake cost + performance tuning on top of the Phase 3 baseline
(`../ddl/02-warehouses.sql`, `../ddl/03-resource-monitors.sql`). Every
file is reviewable SQL — nothing in this directory is executed by the
local DuckDB build. The companion dbt macro at
[`../../dbt/macros/query_tag.sql`](../../dbt/macros/query_tag.sql) is
the one piece that runs cross-adapter (no-op on DuckDB, full JSON tag
on Snowflake).

## Apply order

| Step | File | Role | Purpose |
|---|---|---|---|
| 1 | `01-resource-monitor-tuning.sql` | `ACCOUNTADMIN` | Tune Phase 3 RMs — add 90% warning + email notification integration + dev-tier RM |
| 2 | `02-warehouse-tuning.sql` | `SYSADMIN` | Add `STATEMENT_TIMEOUT`, `STATEMENT_QUEUED_TIMEOUT`, scaling-policy choice, dev-tier warehouse |
| 3 | `03-query-tags.sql` | `SYSADMIN` | Session + statement-level tag patterns; cost-per-model / cost-per-invocation reports |
| 4 | `04-clustering.sql` | `SYSADMIN` | `ALTER TABLE … CLUSTER BY` on `fct_transactions`; clustering-health queries |
| 5 | `05-performance-queries.sql` | `ACCOUNTADMIN` | 4-section `ACCOUNT_USAGE` investigation set |
| 6 | `06-admin.sql` | `SYSADMIN` / `ACCOUNTADMIN` | SHOW inventory + verification queries |

Steps 1–4 are DDL; apply once. Step 5 is read-only investigation,
re-runnable. Step 6 is the "did it land?" verifier.

## Why Snowflake-only (no DuckDB equivalent)?

Resource monitors, auto-suspend, clustering keys, `WAREHOUSE_LOAD_HISTORY`,
`AUTOMATIC_CLUSTERING_HISTORY` — none of these exist in DuckDB.
DuckDB's "cost model" is "the file lives on your laptop and compute is
your CPU". The portable guidance for the DuckDB side is in
[`../../docs/phase-10-cost-performance.md`](../../docs/phase-10-cost-performance.md)
under the **DuckDB-side profiling** section (`.timer on`,
`EXPLAIN ANALYZE`, `pragma_database_size()`).

## The one cross-adapter artifact — `banking_cdc.query_tag_json()`

Lives at [`../../dbt/macros/query_tag.sql`](../../dbt/macros/query_tag.sql).
Wired project-wide in [`../../dbt/dbt_project.yml`](../../dbt/dbt_project.yml)
via `+query_tag: "{{ banking_cdc.query_tag_json() }}"`.

| Adapter | Output | Effect |
|---|---|---|
| Snowflake | `{"project":"banking_cdc_warehouse","model":"fct_transactions","materialization":"incremental","dbt_target":"prod","invocation_id":"…","resource_type":"model"}` | dbt-snowflake emits `ALTER SESSION SET QUERY_TAG = '<json>'` around each model build; `ACCOUNT_USAGE.QUERY_HISTORY` carries the attribution |
| DuckDB (any other) | `""` | dbt-duckdb ignores `+query_tag` entirely — the empty string documents intent |

The payoff queries live in `03-query-tags.sql` (§4 cost-per-model /
cost-per-invocation) and `05-performance-queries.sql` (§1 credits by model).

## Related

- [`../ddl/02-warehouses.sql`](../ddl/02-warehouses.sql) — baseline
  warehouse DDL (Phase 3)
- [`../ddl/03-resource-monitors.sql`](../ddl/03-resource-monitors.sql) —
  baseline RM DDL (Phase 3)
- [`../streams-tasks/`](../streams-tasks/) — Phase 6 Streams + Tasks
  (also code-only)
- [`../governance/`](../governance/) — Phase 8 masking + Phase 9
  erasure template
