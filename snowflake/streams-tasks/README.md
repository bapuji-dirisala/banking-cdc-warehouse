# Snowflake Streams + Tasks — the native CDC-on-CDC layer

Everything in this directory is **code-only** — reviewable but not
deployed by this repo. In production this layer runs between the
Snowflake Kafka Connector (which lands raw rows in `BANKING_PROD.RAW.*`)
and the dbt-managed staging + marts layer.

## Why Streams at all when we already have Debezium CDC?

Debezium CDC gets Postgres row changes into Snowflake raw tables. That's
one hop. The question "which raw rows are *new since dbt last ran*?" is
a different, downstream question — answered by Snowflake **Streams**:

- Debezium / Kafka Connector → `RAW.CUSTOMERS` (append-only change log)
- Snowflake Stream `STRM_RAW_CUSTOMERS` → tracks which rows in
  `RAW.CUSTOMERS` are new since the last consumer

Streams give the mart layer a cheap "give me only what changed" query
instead of re-scanning full raw history every refresh. This is the
primary cost + latency win for incremental dbt materializations.

## Files

| File | Purpose |
|---|---|
| `01-raw-streams.sql`         | `CREATE STREAM` on each raw table |
| `02-staging-refresh-task.sql` | Root Task + child Tasks that call a stored proc to MERGE stream deltas into the staging layer |
| `03-admin.sql`                | `RESUME` / `SUSPEND` / observability commands |

## Apply order

```bash
snowsql -c banking_admin -f 01-raw-streams.sql
snowsql -c banking_admin -f 02-staging-refresh-task.sql
# then one-time: resume the root task
snowsql -c banking_admin -f 03-admin.sql
```

## Design notes

- **Streams are append-only=false** so updates + deletes also surface
  (not just inserts). Change rows carry `METADATA$ACTION`
  (INSERT/DELETE), `METADATA$ISUPDATE`, `METADATA$ROW_ID`.
- **Root task + child tasks** instead of one monolithic task — gives
  independent retry semantics per table and matches the dbt per-model
  granularity when you later swap the stored proc for a `dbt run
  --select +stg_banking__{table}` trigger.
- **Scheduled vs event-driven** — the root task uses a 5-minute
  schedule (`SCHEDULE = '5 MINUTE'`). For near-real-time, drop to
  `SCHEDULE = '1 MINUTE'`; for batch, go to `USING CRON`.
- **Serverless vs warehouse-attached** — the tasks here use
  `WH_INGEST_XS` for predictable cost (every task run shows up on the
  resource monitor). Switch to serverless (`USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE`)
  if latency matters more than cost accounting.

## Equivalent in dev (DuckDB)

The DuckDB dev path has no Streams primitive — the equivalent is
scheduled `dbt build` runs. For Phase 6 dev the recommendation is:

```bash
# One-off local scheduling (replace with Airflow / cron in prod):
while true; do
    cd dbt && dbt build --profiles-dir . --target dev
    sleep 300
done
```

See `docs/phase-06-snapshots-streams.md` for the full dev-vs-prod
mapping and the "what runs where" matrix.
