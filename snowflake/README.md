# Snowflake artifacts (shipped as code, not deployed)

This directory holds the Snowflake-specific DDL and configuration that the
**production path** of this project would apply. Nothing in this directory
runs automatically — the project runs end-to-end against a local DuckDB
warehouse. See [`docs/phase-03-warehouse-foundation.md`](../docs/phase-03-warehouse-foundation.md)
for the full "code-only Snowflake" rationale.

A reader with a Snowflake account can apply these files in order to stand
up the production equivalent of the DuckDB environment.

## Order of application

```bash
# Each file is idempotent — safe to re-run.
snowsql -a <account> -u <user> -f snowflake/ddl/01-roles.sql
snowsql -a <account> -u <user> -f snowflake/ddl/02-warehouses.sql
snowsql -a <account> -u <user> -f snowflake/ddl/03-resource-monitors.sql
snowsql -a <account> -u <user> -f snowflake/ddl/04-databases.sql
snowsql -a <account> -u <user> -f snowflake/ddl/05-grants.sql
```

Then register the Snowflake Kafka Connector against the Phase 2 Connect
cluster (production path — replaces the Python DuckDB sink):

```bash
# After filling in snowflake.url.name + snowflake.private.key in the config:
banking-cdc kafka register   # the register command loads whichever config
                             # BANKING_CDC_CONNECTOR_CONFIG points at
```

## Contents

| File | Purpose |
|---|---|
| `ddl/01-roles.sql` | Role hierarchy — functional + access role pattern (Snowflake Field Engineering reference) |
| `ddl/02-warehouses.sql` | Three warehouses sized by purpose: `WH_INGEST_XS`, `WH_TRANSFORM_S`, `WH_REPORT_XS` |
| `ddl/03-resource-monitors.sql` | Per-warehouse monthly resource monitors + account-level cap |
| `ddl/04-databases.sql` | Three-env namespace (`BANKING_DEV` / `BANKING_CI` / `BANKING_PROD`) with 5 schemas each |
| `ddl/05-grants.sql` | Access-role grants onto objects + user-to-role grant templates |
| `streams-tasks/01-raw-streams.sql` | Phase 6 — CREATE STREAM on each raw.* table (CDC-on-CDC) |
| `streams-tasks/02-staging-refresh-task.sql` | Phase 6 — Task DAG + stored procedure that drains streams into the staging layer |
| `streams-tasks/03-admin.sql` | Phase 6 — RESUME/SUSPEND/SHOW/EXECUTE ops for the Task DAG |
| `governance/01-tags.sql` | Phase 8 — PII inventory tags (PII_LEVEL, DATA_DOMAIN, RETENTION_CLASS) |
| `governance/02-masking-policies.sql` | Phase 8 — 4 dynamic masking policies: email, phone, DOB, card_last4 |
| `governance/03-apply-masking.sql` | Phase 8 — attach policies + tags to every PII column in staging/marts/snapshots |
| `governance/04-row-access-policies.sql` | Phase 8 — row access policy on fct_transactions by account_type |
| `governance/05-admin.sql` | Phase 8 — SHOW/inventory queries + role-swap test harness |
| `governance/06-erasure-template.sql` | Phase 9 — GDPR Article 17 right-to-be-forgotten erasure template |
| `../compose/connect/connectors/snowflake-sink.json` | Snowflake Kafka Connector config (sibling of the committed `pg-source.json` Debezium config) |

## Why "as code" instead of "deployed in a trial"

The portfolio value of the Snowflake layer is in the **design**: role
hierarchy, warehouse sizing, resource monitors, sink topology. Shipping
those as reviewable SQL + JSON captures 100% of that value for $0 forever,
with no 30-day trial-expiry risk and no live credentials to maintain.

A reader (or a future-you with a fresh trial) applies the DDL in minutes
and the dbt `prod` target lights up against a real Snowflake account.
