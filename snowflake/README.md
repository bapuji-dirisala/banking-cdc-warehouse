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
| `../compose/connect/connectors/snowflake-sink.json` | Snowflake Kafka Connector config (sibling of the committed `pg-source.json` Debezium config) |

## Why "as code" instead of "deployed in a trial"

The portfolio value of the Snowflake layer is in the **design**: role
hierarchy, warehouse sizing, resource monitors, sink topology. Shipping
those as reviewable SQL + JSON captures 100% of that value for $0 forever,
with no 30-day trial-expiry risk and no live credentials to maintain.

A reader (or a future-you with a fresh trial) applies the DDL in minutes
and the dbt `prod` target lights up against a real Snowflake account.
