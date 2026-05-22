# Phase 3 — Warehouse foundation (DuckDB sink + Snowflake-as-code)

## Goal

Land the Phase 2 Debezium change events into a working warehouse so Phase 4
has a `raw.*` schema to point dbt at, **without signing up for Snowflake**.
Simultaneously ship every Snowflake-specific artifact (DDL, Kafka Connector
config, role model, resource monitors) as reviewable code under
`snowflake/` so the production path is a one-command apply for any reader
who adopts the project on a real Snowflake account.

Two warehouses, one codebase. The `dev` path runs anywhere for free; the
`prod` path is shipped as code and documented.

## Why this shape

The portfolio value of Phase 3 is **demonstrating the warehouse layer** —
role hierarchy, resource monitors, sink topology, bronze/raw schema design.
That value is in the *artifact*, not in a running Snowflake account.
Shipping the artifact as code (SQL files + connector JSON + runbook) gets
every bit of that value for $0 forever, with no trial expiry risk and no
cross-corp-boundary concerns at Nike.

The DuckDB side exists because a running CDC pipeline is a strong demo:
clone the repo, `make demo`, watch Postgres → Debezium → Kafka → DuckDB →
dbt build → dbt docs open in a browser. That's harder to fake and easier
to review than a Snowflake-only project with no runnable warehouse.

## What this phase delivers

### DuckDB sink (runnable)

- **`warehouse/duckdb/raw_schema.sql`** — DDL for four `raw.*` tables
  mirroring the Postgres OLTP shape, with Debezium envelope metadata
  columns (`__op`, `__source_ts_ms`, `__lsn`, `__ingested_at`)
- **`src/banking_cdc/sink/duckdb_sink.py`** — a long-running Python
  consumer that subscribes to all four Debezium topics (`banking.public.*`),
  parses the envelope JSON, and applies change semantics into DuckDB:
  - `op=c` (create) and `op=r` (snapshot read) → `INSERT`
  - `op=u` (update) → `UPDATE ... WHERE pk = before.pk SET ... = after.*`
  - `op=d` (delete) → `DELETE WHERE pk = before.pk`
  - Kafka consumer offsets committed every N records or every T seconds
  - Graceful shutdown on SIGINT with final offset commit
- **`src/banking_cdc/sink/envelope.py`** — pure-function Debezium envelope
  parser with unit tests (no Kafka or DuckDB dependency; parses sample
  payloads from `tests/fixtures/`)
- **`banking-cdc sink run`** — CLI entry point; `--duckdb-path`,
  `--kafka-bootstrap`, `--group-id`, `--batch-size`, `--commit-interval`
  flags
- **`banking-cdc sink status`** — prints row counts per `raw.*` table and
  the Kafka consumer group's current lag
- **Unit tests** for the envelope parser (deterministic, no infra)
- **CDC-marker smoke test** that runs the sink against a live stack and
  asserts the four `raw.*` tables reach the expected row counts

### Snowflake as code (reviewable, not deployed)

- **`snowflake/README.md`** — explains the "Snowflake-as-code" pattern,
  how to apply these files to a trial or paid account, what the dbt `prod`
  target expects, and what each DDL file does
- **`snowflake/ddl/01-roles.sql`** — role hierarchy following the
  functional + access role separation pattern:
  - System roles: `SYSADMIN`, `SECURITYADMIN`, `USERADMIN`
  - Functional roles: `BANKING_ENGINEER`, `BANKING_ANALYST`, `BANKING_READER`
  - Access roles per schema × privilege (e.g. `AR_RAW_READ`, `AR_RAW_WRITE`,
    `AR_MART_READ`, `AR_MART_WRITE`); functional roles are composed from
    access roles via grants
- **`snowflake/ddl/02-warehouses.sql`** — three warehouses sized for role:
  - `WH_INGEST_XS` — auto-suspend 60s, auto-resume on, max_cluster_count=1
    (used by the Snowflake Kafka Connector sink)
  - `WH_TRANSFORM_S` — auto-suspend 300s, used by dbt builds
  - `WH_REPORT_XS` — auto-suspend 60s, used by BI consumers
- **`snowflake/ddl/03-resource-monitors.sql`** — a monthly resource
  monitor on each warehouse with notify-at-50%, notify-at-80%,
  suspend-at-100% actions; a project-level monitor caps total monthly
  credits
- **`snowflake/ddl/04-databases.sql`** — three-level namespace:
  `BANKING_DEV`, `BANKING_CI`, `BANKING_PROD`; each with
  `RAW`, `STAGING`, `INTERMEDIATE`, `MARTS`, `SNAPSHOTS` schemas; `COMMENT`
  attributes describe owner + purpose
- **`snowflake/ddl/05-grants.sql`** — grants of access roles onto
  databases/schemas, grants of access roles into functional roles, grants
  of functional roles to users (the user-grant lines are templated — a
  reader fills in their own user names)
- **`compose/connect/connectors/snowflake-sink.json`** — the production
  Snowflake Kafka Connector config, using the official `com.snowflake.
  kafka.connector.SnowflakeSinkConnector`; targets `BANKING_PROD.RAW`;
  authenticates via key-pair auth (placeholder keys with inline comments
  pointing at Snowflake's key-pair setup docs); documented as "committed
  for the production path — not deployed in this repo's Compose stack"

### Shared

- **`pyproject.toml`** — new `warehouse` extra: `duckdb>=0.10` +
  `kafka-python>=2.0` (lightweight pure-Python Kafka client; a production
  reader would swap to `confluent-kafka` for performance — noted in doc)
- **Updated `README.md`** — Phase 3 quickstart (run the sink end-to-end
  against the Compose stack from Phase 2)
- **This doc** — the authoritative design reference for Phase 3

## Design decisions

- **DuckDB, not Postgres, as the local warehouse.** DuckDB is file-based
  (no server, no port, no init), free, has first-class dbt adapter
  support (`dbt-duckdb`), and matches the "columnar OLAP warehouse"
  mental model that Snowflake users carry. A reader clones the repo,
  runs the sink, and `duckdb warehouse/banking.duckdb` opens a REPL on
  real data — the shortest-possible-feedback-loop for warehouse-side
  development. Postgres would blur the lesson ("row-store vs columnar").

- **Snowflake-as-code, not Snowflake-at-runtime.** The portfolio value of
  the Snowflake layer is in the *design*: role hierarchy, warehouse
  sizing, resource monitors, sink topology. Shipping those as reviewable
  SQL + JSON captures 100% of that value for $0 forever. A reader (or a
  future-you with a fresh trial) applies the DDL in minutes and the
  dbt `prod` target lights up. The alternative — maintain a live trial,
  burn credits, hit the 30-day expiry — adds operational toil without
  adding portfolio signal.

- **DuckDB sink in Python, not via Kafka Connect.** Three alternatives
  were considered:
  - *Kafka Connect JDBC Sink → Postgres (as a shadow)*. Loses the
    columnar warehouse story; feels like a cop-out.
  - *Kafka Connect S3 Sink → MinIO → DuckDB external parquet*. Adds a
    whole lakehouse pattern (MinIO container, S3 sink connector,
    parquet partitioning) — scope creep for Phase 3.
  - *Python consumer*. Simple, minimal, and demonstrates understanding
    of the Debezium envelope semantics in reviewable code. A production
    reader points the committed Snowflake Kafka Connector config at
    their account instead.

  The Python consumer wins on simplicity, review-ability, and the fact
  that it exercises the one thing worth demonstrating in Phase 3 (CDC
  envelope semantics applied correctly). Production uses the Snowflake
  Kafka Connector; the code commentary makes that explicit.

- **`kafka-python`, not `confluent-kafka`.** `confluent-kafka` is the
  production-grade choice (C-backed, higher throughput, exactly-once
  support via transactions). For a portfolio sink processing hundreds of
  messages per second from a synthetic generator, `kafka-python` is pure
  Python, wheels available everywhere, and the API is roughly equivalent.
  A note in the sink module docstring points at `confluent-kafka` for a
  production reader.

- **Debezium envelope semantics applied, not just insert-all.** The sink
  reads the Debezium envelope and dispatches on `op`:
  - `c` + `r` → INSERT after.*
  - `u` → DELETE WHERE pk = before.pk; INSERT after.*  (DuckDB has no
    `MERGE` — DELETE+INSERT is the idiomatic alternative and preserves
    row ordering guarantees for a single transaction)
  - `d` → DELETE WHERE pk = before.pk
  - Each batch wraps in a DuckDB transaction so a partial failure
    rolls back without inconsistent state

- **Envelope metadata columns, not just the business payload.** Each
  `raw.*` table carries four extra columns: `__op`, `__source_ts_ms`,
  `__lsn`, `__ingested_at`. Phase 4's staging layer can rebuild the
  "latest-row-per-pk" view by taking the row with max LSN. Dropping the
  metadata would mean losing the audit lineage story that justifies
  CDC in the first place.

- **Three Snowflake warehouses by role, not one shared.** `WH_INGEST_XS`
  for the Kafka sink (short, bursty, auto-suspend 60s); `WH_TRANSFORM_S`
  for dbt (longer-running, higher cost per hour, auto-suspend 300s);
  `WH_REPORT_XS` for BI (small, auto-suspend 60s). This maps directly
  to the resource-monitor + cost-attribution story in Phase 10 — one
  warehouse per cost center is the right primitive.

- **Access-role / functional-role separation (Snowflake best practice).**
  Access roles encapsulate "what you can touch" (e.g. `AR_RAW_READ`,
  `AR_MART_WRITE`). Functional roles encapsulate "who you are"
  (`BANKING_ENGINEER`, `BANKING_ANALYST`). Functional roles are composed
  from access roles via `GRANT`. This is the pattern Snowflake Field
  Engineering publishes as the production reference and lets you add a
  schema or privilege without touching functional-role grants.

- **Resource monitors with multi-threshold actions.** `NOTIFY` at 50% and
  80%, `SUSPEND` at 100%. Not `SUSPEND_IMMEDIATE` — the extra few queries
  that finish in-flight at 100% are worth the smoother operator experience.
  Monthly windows aligned to the first of each month so the resource
  monitor matches Snowflake's billing cycle.

- **Snowflake Kafka Connector config committed with key-pair auth
  placeholders.** The Snowflake Kafka Connector requires either basic
  auth (deprecated, discouraged) or key-pair auth (recommended). The
  committed config uses key-pair; the private key path points to a
  gitignored `secrets/snowflake_private_key.p8` with inline comments
  explaining how to generate the key pair and attach the public half to
  a Snowflake user. The connector is **not registered** against the
  running Compose Connect — a reader runs `banking-cdc kafka register
  --config snowflake-sink.json` after providing their own account URL
  and key.

- **No `BANKING_DEV` / `BANKING_CI` / `BANKING_PROD` separation on the
  DuckDB side.** DuckDB is a single `banking.duckdb` file. The Snowflake
  three-env pattern is a Snowflake-production concern that doesn't
  translate to a file-based local warehouse. Phase 11's blue/green CI
  demonstrates the pattern against the Snowflake-side DDL only.

- **No dbt yet.** This phase lands the sink and the Snowflake DDL. Phase 4
  points dbt at the DuckDB `raw.*` tables and sets up the dual-target
  `profiles.yml`. Keeping dbt out of Phase 3 keeps each phase one coherent
  thing.

## How to run

Prerequisites: Phase 2 complete and running.

```bash
# Install the warehouse extra (duckdb + kafka-python).
pip install -e ".[dev,postgres,kafka,warehouse]"

# One-time: initialise the DuckDB raw schema.
mkdir -p warehouse
duckdb warehouse/banking.duckdb < warehouse/duckdb/raw_schema.sql

# Run the sink. Blocks until Ctrl-C. Subscribes to all four Debezium topics,
# applies envelope semantics into DuckDB. Commits consumer offsets every
# 1000 records or 5 seconds, whichever comes first.
banking-cdc sink run \
    --duckdb-path warehouse/banking.duckdb \
    --kafka-bootstrap localhost:19092 \
    --group-id banking-duckdb-sink

# In another shell, produce some write activity.
banking-cdc seed run --customers 100 --duration 30 --tps 20 --seed 42

# Watch rows land in DuckDB (either poll `banking-cdc sink status` or
# attach a DuckDB REPL on the same file — DuckDB supports read-while-write).
banking-cdc sink status --duckdb-path warehouse/banking.duckdb

duckdb warehouse/banking.duckdb -c "SELECT count(*) FROM raw.transactions;"
duckdb warehouse/banking.duckdb -c "
    SELECT __op, count(*)
    FROM raw.transactions
    GROUP BY __op
    ORDER BY 1;
"
```

Opt-in CDC smoke test (requires the full Phase 2 + Phase 3 stack running):

```bash
pytest -m cdc tests/sink/
```

## Gotchas

- **Snapshot replay is idempotent only within a Kafka consumer group.** If
  you reset the DuckDB file but keep the consumer group's offsets, the
  snapshot messages won't be re-delivered. Either reset the DuckDB file
  and the consumer group together, or wipe both (`docker compose down -v`
  + `rm warehouse/banking.duckdb`) for a clean start.

- **`kafka-python` is in maintenance mode as of 2024.** Fine for a
  portfolio sink; production readers should swap to `confluent-kafka` for
  C-backed throughput + exactly-once support via Kafka transactions.
  Documented in the sink module docstring.

- **DuckDB does not support `MERGE`.** The sink emits DELETE+INSERT for
  updates, wrapped in a transaction. Portfolio-scale ingestion makes this
  a non-issue; a production reader using Snowflake would get `MERGE`
  natively via the Snowflake Kafka Connector (committed config
  demonstrates this).

- **The `op=r` snapshot read can produce a lot of messages at startup.**
  Debezium emits one `r` message per existing row before switching to
  streaming mode. Phase 1's seed defaults land ~thousands of rows; the
  sink handles the volume fine, but a reader seeding 1M rows for load
  testing should expect a multi-minute snapshot replay.

- **DuckDB file locking.** DuckDB allows one writer and many readers.
  Running the sink and a `duckdb warehouse/banking.duckdb` REPL
  simultaneously works for reads; a second writer process will fail with
  a lock error. The sink itself holds the write lock continuously.

- **Snowflake Kafka Connector `private.key` config.** The connector
  config expects the private key as a *string*, not a file path. The
  committed JSON uses a placeholder and documents the `openssl genrsa`
  + `openssl pkcs8 -topk8` incantation inline. Readers must substitute
  their own key before registering.

- **Snowflake resource monitors are account-level, not warehouse-level,
  for the top-level cap.** The committed `03-resource-monitors.sql`
  defines both per-warehouse monitors and a single account-level monitor
  with a monthly credit cap — the belt-and-braces pattern most
  finance-sector Snowflake deployments use.

## Nike + compliance notes

- **No Snowflake signup required.** Nothing in this phase creates or
  authenticates against an external cloud service. The Snowflake
  artifacts ship as code — reviewable, applicable, but not live.
- Everything else runs in Colima (per the Oct 16 2026 Docker Desktop ban).
- No Nike corp credentials, no Nike SSO, no Nike-adjacent config touched.
- The Snowflake Kafka Connector config references key-pair auth with
  placeholder paths; no real credentials are committed anywhere.
- The DuckDB file lives at `warehouse/banking.duckdb` and is gitignored —
  the `warehouse/` directory is already in `.gitignore` from Phase 0.

## References

- DuckDB docs: <https://duckdb.org/docs/>
- dbt-duckdb adapter: <https://github.com/duckdb/dbt-duckdb>
- Debezium Postgres envelope semantics: <https://debezium.io/documentation/reference/stable/connectors/postgresql.html#postgresql-events>
- Snowflake Kafka Connector (production target): <https://docs.snowflake.com/en/user-guide/kafka-connector>
- Snowflake access-role / functional-role pattern: <https://docs.snowflake.com/en/user-guide/security-access-control-considerations>
- Snowflake resource monitors: <https://docs.snowflake.com/en/user-guide/resource-monitors>
- Snowflake Kafka Connector key-pair auth: <https://docs.snowflake.com/en/user-guide/kafka-connector-install#using-key-pair-authentication-key-rotation>
