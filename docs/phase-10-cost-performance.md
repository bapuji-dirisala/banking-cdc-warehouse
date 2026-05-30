# Phase 10 — Snowflake cost + performance runbook

**Status:** shipped (2026-10-25) — code-only
**Depends on:** Phase 3 (baseline warehouses + RMs), Phase 7
(incremental fct_transactions)

## Goal

Turn the Phase 3 baseline ("three warehouses, three monitors, done")
into a reviewable **runbook** — the actual tuning patterns a senior
data engineer applies after a month of real billing + QUERY_HISTORY
data:

1. **Resource-monitor + warehouse tuning** patterns including
   dev-vs-prod tiering, `STATEMENT_TIMEOUT` + queue timeouts, and the
   `STANDARD` vs `ECONOMY` scaling-policy decision.
2. **Clustering** — when to attach a cluster key (and when not to),
   including the `(posted_date, account_id)` key on `fct_transactions`
   plus the `SYSTEM$CLUSTERING_INFORMATION`-based maintenance queries.
3. **Query tags for cost attribution** — a cross-adapter dbt macro
   (`banking_cdc.query_tag_json()`) that emits a JSON tag on Snowflake
   and no-ops on DuckDB; FinOps queries slice `QUERY_HISTORY` by model /
   invocation / materialization.
4. **The `ACCOUNT_USAGE` investigation set** — the four groups of
   queries (top cost, slow queries, warehouse health, hidden costs)
   that any Snowflake FinOps review runs weekly.
5. **The "when to go incremental" decision table** — makes the
   Streams-vs-incremental-vs-materialized-view call reviewable.
6. **DuckDB-side profiling notes** — because the whole project is
   dual-adapter, Phase 10 wouldn't be honest if it only covered one
   side.

## Shape added

```
snowflake/cost-perf/
├── 01-resource-monitor-tuning.sql    -- ACCOUNTADMIN, extends Phase 3 RMs
├── 02-warehouse-tuning.sql           -- SYSADMIN, extends Phase 3 WHs + dev-tier
├── 03-query-tags.sql                 -- session/statement tag patterns + FinOps queries
├── 04-clustering.sql                 -- CLUSTER BY + SYSTEM$CLUSTERING_INFORMATION
├── 05-performance-queries.sql        -- ACCOUNT_USAGE investigation set (4 sections)
├── 06-admin.sql                      -- SHOW + verification queries
└── README.md

dbt/
├── macros/query_tag.sql              -- adapter-dispatched JSON tag emitter
└── dbt_project.yml                    -- wires +query_tag project-wide
```

## The `banking_cdc.query_tag_json()` macro

Adapter dispatch:

| Adapter | Output | Downstream |
|---|---|---|
| `snowflake` | `{"project":"banking_cdc_warehouse","model":"fct_transactions","materialization":"incremental","dbt_target":"prod","invocation_id":"abc-123…","resource_type":"model"}` | `ALTER SESSION SET QUERY_TAG = '<json>'` → `ACCOUNT_USAGE.QUERY_HISTORY.QUERY_TAG` |
| `duckdb` / default | `""` (empty string) | Silently ignored by `dbt-duckdb` — zero runtime cost |

Why JSON over a flat string: `PARSE_JSON(QUERY_TAG):model::STRING = 'fct_transactions'`
is cheap at query time. A flat string would require ILIKE or regex,
which is both slower and brittle.

The payoff queries (`03-query-tags.sql` §4, `05-performance-queries.sql`
§1) answer:
- **cost-per-model** — which model is burning the most warehouse hours?
- **cost-per-invocation** — did last night's dbt build blow the budget?
- **cost-per-materialization** — are the incremental configs actually
  saving credits vs the full-refresh baseline?

## The "when to go incremental" decision table

The question Phase 6 (Streams), Phase 7 (incremental), and this phase
(dynamic tables / materialized views) all answer differently:

| Workload shape | Right answer | Why |
|---|---|---|
| Append-only, high volume, fresh-within-5-min OK | **dbt incremental** (`delete+insert` or `merge`) | Portable DuckDB↔Snowflake; cheapest; no in-warehouse scheduler coupling |
| Append-only, fresh-within-seconds required | **Snowflake Streams + Tasks** | Single-engine latency floor; moves logic out of dbt |
| Mostly-overwrite UPSERT with occasional deletes | **dbt incremental `merge`** on Snowflake, `delete+insert` on DuckDB | Portability pattern; `merge` is more expensive but handles the overwrite shape |
| Mostly-overwrite, simple predicate, ≤ 1 TB | **Snowflake Dynamic Table** | Snowflake rebuilds on a target-lag schedule; zero orchestration code |
| Pure aggregation over 1 table, hot read path | **Snowflake Materialized View** | Snowflake auto-maintains; no dbt coupling at all |
| Low-cardinality dim with slow-changing attributes | **dbt snapshot** (SCD2) | What Phase 6 built; preserves history |
| Reference data < 10 MB, rare writes | **dbt seed** | No incremental complexity needed |

The project ships patterns from the first row (fct_transactions —
`delete+insert`, Phase 7), the second row (Streams/Tasks SQL as code,
Phase 6), and the sixth row (snapshots, Phase 6). Dynamic Tables + MVs
are listed as options; neither is justified at this project's data
volume but both are the next-step upgrade path a reader should
recognise.

## The 60-30-10 rule for warehouse sizing

From [`02-warehouse-tuning.sql`](../snowflake/cost-perf/02-warehouse-tuning.sql):

> - If a warehouse spends **60%+** of its runtime at `MAX_CLUSTER_COUNT`
>   AND the slowest queries are still slow → size **UP** (XS→S→M)
> - If a warehouse spends **30%+** of its runtime QUEUEING
>   (`QUERY_HISTORY.QUEUED_PROVISIONING_TIME > 0`) → raise `MAX_CLUSTER_COUNT`
> - If a warehouse spends **10%+** of its runtime SPILLING TO REMOTE
>   (`BYTES_SPILLED_TO_REMOTE_STORAGE > 0`) → size **UP** first
>   (bigger WH = more memory per query, often removes the spill)

Each of these percentages is a direct output of a query in
`05-performance-queries.sql` §3 (health) or §2 (slow queries). The
rule turns "the warehouse feels slow" into a one-SQL-query decision.

## Clustering decision tree

```
Is the table > 1 TB and growing?
├── NO  → skip clustering. Micro-partition natural ordering is enough.
└── YES → Is query predicate dominated by 1-3 columns?
         ├── NO  → skip. Clustering only pays off for selective predicates.
         └── YES → Are those columns high-cardinality?
                  ├── NO  → skip. 5-value enum keys thrash reclustering.
                  └── YES → Is the table append-mostly?
                           ├── NO  → skip. Churn fights auto-clustering.
                           └── YES → ALTER TABLE CLUSTER BY (col1, col2[, col3])
                                      Monitor avg_depth weekly.
                                      Alert if avg_depth > 5.
```

In this project only `fct_transactions` satisfies all four — hence the
`CLUSTER BY (posted_date, account_id)` in
[`04-clustering.sql`](../snowflake/cost-perf/04-clustering.sql).

## DuckDB-side profiling

DuckDB has no warehouse / credits concept, but the same workflow —
"figure out what's slow, make it faster" — applies:

```sql
-- Enable per-query timing in the REPL.
.timer on

-- Explain-with-stats; shows plan + per-operator actuals.
EXPLAIN ANALYZE
SELECT * FROM marts.fct_transactions
WHERE posted_date BETWEEN '2025-01-01' AND '2025-03-31';

-- Database file size (closest DuckDB analogue to ACCOUNT_USAGE.STORAGE_USAGE).
SELECT * FROM pragma_database_size();

-- Table-level storage.
SELECT table_name, estimated_size, column_count
FROM duckdb_tables()
ORDER BY estimated_size DESC;
```

DuckDB's query plan already uses zone maps (its native equivalent of
Snowflake's micro-partition pruning). If a DuckDB query is slow the
usual suspects are:
1. Missing projection — select only needed columns
2. Hash join larger side on the inner — DuckDB will reorder, but check `EXPLAIN`
3. Scanning too much — use `WHERE` on sorted columns (DuckDB is
   zone-map-friendly on `TIMESTAMP` and sequential `BIGINT` columns)

## What this phase explicitly does NOT ship

- A Snowflake trial account that actually runs any of this SQL
  (project-wide convention; the artifacts are code-reviewable, not
  deployed)
- A Streamlit cost-dashboard on top of the FinOps queries — Phase 11
  if BI deliverable is added
- Dynamic Tables (listed in the decision table; not justified at this
  data volume)
- A FinOps IAM role separate from `ACCOUNTADMIN` for
  `ACCOUNT_USAGE` reads — standard pattern (`GRANT IMPORTED PRIVILEGES
  ON DATABASE SNOWFLAKE TO ROLE FINOPS_READER`) left for the operator
- Change to the dbt profile — the `+query_tag` is a project-level
  config that activates automatically when `target == snowflake`;
  no profile change needed

## Local verification

The Phase 10 DuckDB side is a one-line test — the macro renders to an
empty string:

```bash
cd dbt
dbt build --profiles-dir . --target dev --fail-fast
# → still 158/158 PASS. The +query_tag config is a no-op on DuckDB.

# Compile a model and inspect the pre-/post-hook rendering:
dbt compile --profiles-dir . --target dev --select fct_transactions
# target/compiled/.../fct_transactions.sql should NOT contain any
# "ALTER SESSION" (DuckDB adapter strips it); the Snowflake target
# WOULD show it.
```

## Next phase

**Phase 11** — blue/green CI with Snowflake zero-copy clones +
`--defer --state:modified+` PR lineage. The dev-tier warehouse +
dev-tier RM shipped here are the operator-side preconditions for that
workflow.
