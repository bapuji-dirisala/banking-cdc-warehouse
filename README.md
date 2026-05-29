# banking-cdc-warehouse

[![ci](https://github.com/bapuji-dirisala/banking-cdc-warehouse/actions/workflows/ci.yml/badge.svg)](https://github.com/bapuji-dirisala/banking-cdc-warehouse/actions/workflows/ci.yml)
[![python](https://img.shields.io/badge/python-3.11-blue)](pyproject.toml)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Regulatory-grade banking warehouse built on change-data-capture. A Postgres
OLTP simulates retail-banking activity (customers, accounts, transactions,
card events); Debezium tails the write-ahead log and publishes row-level
changes to Kafka; a Snowflake sink lands raw CDC into a bronze schema;
dbt promotes bronze → staging → intermediate → marts, with SCD2 snapshots
on the slowly-changing dimensions and audit history preserved end-to-end.

> **Status:** Phase 2 — Debezium + Kafka Connect reading the Postgres WAL
> into four JSON topics is live. Thirteen-phase roadmap below (plus an
> optional 14th), weighted for **dbt + Snowflake depth**, running
> **end-to-end on a free local DuckDB warehouse** with all Snowflake
> artifacts committed as reviewable code (zero signup, zero cost, $0
> forever). Every phase gets a dedicated design doc under [`docs/`](docs/).

## What this project demonstrates

- **CDC capture** — Debezium reading the Postgres WAL into Kafka with
  `REPLICA IDENTITY FULL`, LSN-ordered delivery, snapshot + streaming
  modes; kept deliberately minimal so dbt + Snowflake stay the focus
- **CDC sink engineering** — a thin Python consumer subscribes to all four
  Debezium topics, applies envelope semantics (`op=c|r|u|d`) with offset
  management, and lands rows into a local DuckDB `raw` schema; the
  equivalent production Snowflake Kafka Connector config ships committed
  as code alongside
- **Dual-adapter dbt** — `profiles.yml` with two targets (`dev`=DuckDB,
  `prod`=Snowflake) and **dispatch macros** that isolate warehouse-specific
  SQL (date arithmetic, type casts, merge dialects); the same dbt code
  builds on both warehouses — a senior-engineer "warehouse portability"
  discipline most portfolios don't demonstrate
- **dbt at expert level** — sources (with freshness), staging,
  intermediate, marts, SCD2 snapshots, singular + generic + `dbt-utils`
  + `dbt-expectations` tests, incremental models (merge with
  late-arriving handling), dispatch macros, pre/post hooks, exposures,
  metrics (MetricFlow), hosted docs with full lineage
- **Package authoring** — an internal `dbt_banking` package with
  reusable macros (surrogate hash keys, grain reconciliation, PII hash)
  and banking-specific custom tests (`balance_never_negative`,
  `transactions_tie_to_balance`, `scd2_overlap_check`)
- **Dimensional modelling for banking** — Kimball star schema on a
  realistic OLTP domain: `dim_customer` (SCD2), `dim_account` (SCD2),
  `fact_transaction`, `fact_balance_daily`
- **Snowflake specifics shipped as code** — role hierarchy (SYSADMIN /
  SECURITYADMIN / functional + access roles), warehouse sizing +
  auto-suspend, resource monitors with credit quotas, query-tag-per-model
  cost attribution via a dbt macro, **Streams + Tasks** (in-warehouse
  orchestration SQL + commentary, compared side-by-side with Airflow in
  docs), time travel + zero-copy clones (CI orchestration macros committed),
  clustering keys. Every artifact lives under `snowflake/` and the Kafka
  Connector config at `compose/connect/connectors/snowflake-sink.json` —
  reviewable, applicable to any Snowflake account, no trial required to
  explore the design
- **Enterprise governance** — Snowflake dynamic data masking on PII,
  row access policies for customer segmentation, grants managed via
  dbt post-hooks
- **Regulatory data quality** — Great Expectations gates at every
  layer, row-count reconciliation, referential integrity, source
  freshness, and a reconciliation suite that proves fact grains tie
  back to source WAL event counts
- **Senior-level CI** — the full dbt lineage builds against DuckDB on
  every PR (fast, free, deterministic); a Snowflake-dialect compile-only
  pass proves dispatch macros render correctly; the **blue/green
  zero-copy-clone** orchestration macros + GHA workflow ship committed
  for the Snowflake path, with `--defer --state:modified+` + PR lineage
  diff + row-count delta posted into the PR
- **Multi-orchestrator** — Airflow DAG and Jenkins declarative pipeline
  mirror the GitHub Actions pipeline so all three coexist in-repo for
  side-by-side comparison

## Architecture (high level)

```text
              ┌─────────────────────────────┐
              │  Postgres OLTP              │
              │  - customers, accounts,     │
              │    transactions, cards      │
              │  - synthetic write workload │
              └───────────────┬─────────────┘
                              │ WAL
                              ▼
              ┌─────────────────────────────┐
              │  Debezium (Kafka Connect)   │
              │  - one connector per table  │
              │  - snapshot + streaming     │
              └───────────────┬─────────────┘
                              │ change events
                              ▼
              ┌─────────────────────────────┐
              │  Kafka                      │
              │  - one topic per table      │
              │  - keyed by PK              │
              └───────────────┬─────────────┘
                              │ Snowpipe / Kafka connector
                              ▼
      ┌────────────────────────────────────────────┐
      │  Snowflake                                 │
      │                                            │
      │   bronze  →  staging  →  intermediate  →   │
      │   raw CDC    cast +      dedup + SCD2      │
      │              rename      snapshots         │
      │                              │             │
      │                              ▼             │
      │                       ┌───────────────┐    │
      │                       │  marts        │    │
      │                       │  dim_customer │    │
      │                       │  dim_account  │    │
      │                       │  fact_txn     │    │
      │                       │  fact_balance │    │
      │                       └───────┬───────┘    │
      │                               │            │
      │                       Great Expectations   │
      │                       + dbt tests          │
      └────────────────────────────────────────────┘
                              │
                              ▼
                    Airflow (daily incremental)
                    Jenkins (declarative pipeline)
                    dbt docs (column-level lineage)
```

Detailed component topology, ADRs, and design principles land in
`docs/architecture.md` in a later phase.

## Roadmap

Weighted for **dbt + Snowflake depth**. Phase 2 (Debezium + Kafka) is
deliberately compressed to one phase; the saved budget expands dbt
(foundation, marts, package authoring, tests) and Snowflake (governance,
Streams + Tasks, masking, cost + perf, zero-copy-clone CI).

**Hybrid runtime strategy.** The project runs end-to-end on a local
**DuckDB** warehouse (free, file-based, zero signup) with all
Snowflake-specific artifacts committed as reviewable code under
`snowflake/`. Phases marked **🧊 code-only** ship Snowflake SQL + configs +
macros + runbooks but don't execute without a Snowflake account; the dbt
project runs against DuckDB in CI either way.

| Phase | Focus | Status | Notes |
|-------|-------|--------|-------|
| 0 | Repo scaffolding, tooling, CI | ✅ done | [docs/phase-00-scaffolding.md](docs/phase-00-scaffolding.md) |
| 1 | Postgres OLTP schema + synthetic transaction generator | ✅ done | [docs/phase-01-postgres-oltp.md](docs/phase-01-postgres-oltp.md) |
| 2 | Debezium + Kafka Connect — minimal CDC capture | ✅ done | [docs/phase-02-debezium-kafka.md](docs/phase-02-debezium-kafka.md) |
| 3 | Warehouse foundation: DuckDB sink + Snowflake DDL as code + Snowflake Kafka Connector config | ⏳ next | [docs/phase-03-warehouse-foundation.md](docs/phase-03-warehouse-foundation.md) |
| 4 | dbt dual-target: `profiles.yml` (DuckDB + Snowflake), sources (with freshness), staging + dispatch macros | ⏳ planned | |
| 5 | Intermediate + marts: `dim_customer` / `dim_account` SCD2, `fact_transaction`, `fact_balance_daily` (runs on DuckDB) | ⏳ planned | |
| 6 | Snowflake Streams + Tasks (in-warehouse orchestration) 🧊 code-only, compared to Airflow in docs | ⏳ planned | |
| 7 | Package authoring: `dbt_banking` with custom macros + banking-specific tests (runs on DuckDB) | ⏳ planned | |
| 8 | PII governance: dynamic masking + row access policies + grants via post-hooks 🧊 code-only | ⏳ planned | |
| 9 | Data quality: full test suite + source freshness + reconciliation + GE per layer (runs on DuckDB) | ⏳ planned | |
| 10 | Snowflake cost + perf runbook: resource monitors, query tags, warehouse sizing, clustering 🧊 methodology + templates | ⏳ planned | |
| 11 | Blue/green CI: dbt build on DuckDB (runs) + zero-copy-clone orchestration for Snowflake 🧊 workflow + macros committed | ⏳ planned | |
| 12 | dbt docs site + exposures + metrics + architecture diagrams + README polish (runs on DuckDB) | ⏳ planned | |
| 13 | Jenkins declarative pipeline + Airflow DAG (orchestrator comparison) | optional | |

## Tech stack (target)

- **Language:** Python 3.11 · SQL (Snowflake dialect) · Jinja (dbt macros)
- **OLTP source:** Postgres 16
- **CDC:** Debezium (Kafka Connect)
- **Streaming:** Apache Kafka (Redpanda locally)
- **Warehouse:** Snowflake
- **Transformations:** dbt (dbt-core + dbt-snowflake)
- **Quality:** Great Expectations + dbt tests
- **Orchestration:** Apache Airflow
- **CI/CD:** GitHub Actions + Jenkins (declarative pipeline)
- **Containers:** Docker + Docker Compose
- **Dev tooling:** ruff, mypy, pytest, pre-commit

## Getting started

Requires Python 3.11+. Streaming and warehouse phases will additionally
require Docker (for local Postgres + Kafka + Debezium) and a Snowflake
account — both added as prerequisites in their respective phase docs.

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
pre-commit install
pytest                            # fast, hermetic (integration + warehouse skipped)
```

### Phase 1 quickstart — run the OLTP locally

```bash
# Install the postgres extra (SQLAlchemy, psycopg, Faker) + the CLI entrypoint.
pip install -e ".[dev,postgres]"

# Bring up Postgres 16 with wal_level=logical (init scripts apply the schema).
docker compose -f compose/docker-compose.yml up -d

# Seed a deterministic batch — 200 customers, 60 seconds of activity at ~20 TPS.
banking-cdc seed run --customers 200 --duration 60 --tps 20 --seed 42

# Peek at what landed.
docker compose -f compose/docker-compose.yml exec postgres \
    psql -U banking -d banking_oltp -c "SELECT count(*) FROM transactions;"
```

### Phase 2 quickstart — attach Debezium + Kafka

```bash
# Install the kafka extra (requests) in addition to the postgres extra.
pip install -e ".[dev,postgres,kafka]"

# One-time: fetch the Debezium Postgres connector plugin into
# compose/connect/plugins/ (idempotent, respects corp CA env).
./scripts/fetch-debezium.sh

# Bring up Postgres + Zookeeper + Kafka + Kafka Connect.
docker compose -f compose/docker-compose.yml up -d

# Wait for Kafka Connect's REST API (~30-60s on first boot).
banking-cdc kafka wait

# Register the Debezium Postgres source connector (idempotent — safe to re-run).
banking-cdc kafka register

# Verify the connector + its tasks are RUNNING.
banking-cdc kafka status

# Produce some write activity so WAL has change events to decode.
banking-cdc seed run --customers 100 --duration 30 --tps 20 --seed 42

# Tail a topic from inside the Kafka container (change events as JSON).
docker compose -f compose/docker-compose.yml exec kafka \
    kafka-console-consumer \
    --bootstrap-server kafka:9092 \
    --topic banking.public.transactions \
    --from-beginning \
    --max-messages 5 \
    --property print.key=true

# Optional: run the Phase 2 smoke test (opt-in via marker).
pytest -m cdc tests/kafka/
```

### Phase 3 quickstart — DuckDB sink + Snowflake-as-code

Phase 3 lands the warehouse layer: a Python CDC sink into local **DuckDB**
plus the production Snowflake artifacts committed under
[`snowflake/`](snowflake/). The sink is what makes the CDC pipeline
visible end-to-end on a free local warehouse — the Snowflake side is
reviewable code, not a running deployment.

```bash
# Install the warehouse extra (duckdb + kafka-python).
pip install -e ".[dev,postgres,kafka,warehouse]"

# One-time: initialise the DuckDB raw schema.
banking-cdc sink init

# Run the sink. Blocks until Ctrl-C. Subscribes to all four Debezium topics,
# applies envelope semantics (c|r|u|d) into DuckDB raw.* tables.
# Open a second shell for the next commands.
banking-cdc sink run

# In another shell, produce write activity so the sink has something to do.
banking-cdc seed run --customers 100 --duration 30 --tps 20 --seed 42

# Check what landed.
banking-cdc sink status

# Attach a DuckDB REPL on the same file (reads are safe while the sink
# holds the write lock).
duckdb warehouse/banking.duckdb -c "SELECT COUNT(*) FROM raw.transactions"
duckdb warehouse/banking.duckdb -c "
    SELECT __op, COUNT(*) FROM raw.transactions GROUP BY 1 ORDER BY 1
"

# Opt-in Phase 3 smoke test (requires the full stack + sink + seed above).
pytest -m cdc tests/sink/
```

### Snowflake path (code-only — not deployed by this repo)

The production path replaces the Python DuckDB sink with the official
Snowflake Kafka Connector. All Snowflake artifacts live under
[`snowflake/`](snowflake/) — role hierarchy, warehouses, resource
monitors, database/schema layout, grants — plus the connector config at
[`compose/connect/connectors/snowflake-sink.json`](compose/connect/connectors/snowflake-sink.json).
See [`snowflake/README.md`](snowflake/README.md) and
[`docs/phase-03-warehouse-foundation.md`](docs/phase-03-warehouse-foundation.md)
for the full rationale and application steps.

### Phase 4 quickstart — dbt staging (dual-adapter)

Phase 4 lands the first dbt layer: four staging views that project
Debezium raw rows into a clean dimensional shape, with envelope-aware
latest-LSN-wins deduplication. The dbt project is **dual-target** —
same SQL runs against local DuckDB (`dev`) and Snowflake (`prod`).

```bash
# Install the dbt extra (pulls dbt-core + dbt-duckdb; adds no runtime
# weight to the sink).
pip install -e ".[dev,postgres,kafka,warehouse,dbt]"

# One-shot: apply the raw schema and seed a tiny deterministic fixture.
# (In normal dev you'd use `banking-cdc sink run` + `banking-cdc seed run`
# instead to populate raw.* from a real CDC stream.)
python scripts/seed-duckdb-fixture.py

# Install dbt packages (currently just dbt_utils).
cd dbt
dbt deps --profiles-dir .

# Build every staging model + run every test. --fail-fast surfaces the
# first failing test instead of running the whole DAG.
dbt build --profiles-dir . --target dev --fail-fast

# Query the latest-wins dedup result.
duckdb ../warehouse/banking.duckdb -c "
    SELECT customer_id, first_name, kyc_status, _cdc_op, _cdc_lsn
    FROM staging.stg_banking__customers
    ORDER BY customer_id
"
```

The Snowflake production target lives in the same
[`dbt/profiles.yml`](dbt/profiles.yml) under `prod:` — every secret is
sourced from `env_var()` so the file is safe to commit. See
[`docs/phase-04-staging.md`](docs/phase-04-staging.md) for the full
dedup rationale and dispatch-macro plan for the two places DuckDB and
Snowflake SQL legitimately diverge.

### Phase 5 quickstart — intermediate + marts

Phase 5 lands the first star schema on top of staging: two dims, two
facts, and two business-level aggregates. Every mart carries both
surrogate keys (for star-schema joins) and natural keys (for ad-hoc
queries); facts expose both raw enum codes and display labels.

```bash
# `dbt build` from Phase 4 already builds the full DAG — same command,
# more models + tests behind it.
cd dbt
dbt build --profiles-dir . --target dev --fail-fast

# A couple of inspect queries that showcase what landed.
duckdb ../warehouse/banking.duckdb -c "
    SELECT customer_sk, full_name, kyc_status_label, age_years
    FROM marts.dim_customer ORDER BY customer_id
"
duckdb ../warehouse/banking.duckdb -c "
    SELECT account_sk, posted_date, net_change, credits, debits, txn_count
    FROM marts.agg_daily_account_balance ORDER BY posted_date
"
duckdb ../warehouse/banking.duckdb -c "
    SELECT customer_sk, business_month, fees_revenue, interest_revenue, total_revenue
    FROM marts.agg_monthly_customer_revenue ORDER BY customer_sk
"
```

See [`docs/phase-05-marts.md`](docs/phase-05-marts.md) for the full
dimensional model, delete-semantics-per-layer table, and the measure +
label conventions.

### Phase 6 quickstart — SCD2 snapshots + Snowflake Streams/Tasks

Phase 6 adds SCD2 history for `customers` + `accounts` via `dbt
snapshot`, and commits the Snowflake Streams-and-Tasks topology under
[`snowflake/streams-tasks/`](snowflake/streams-tasks/) as the production
CDC-on-CDC pattern (reviewable code, not deployed here).

```bash
# Snapshots run as part of `dbt build` — no new commands needed.
cd dbt
dbt build --profiles-dir . --target dev --fail-fast

# The snapshot table itself IS the SCD2 (dbt adds dbt_valid_from etc.).
# Inspect:
duckdb ../warehouse/banking.duckdb -c "
    SELECT customer_id, kyc_status, dbt_valid_from, dbt_valid_to
    FROM snapshots.snap_banking__customers
    ORDER BY customer_id, dbt_valid_from
"

# Point-in-time join via the dim_customer_scd2 wrapper view:
duckdb ../warehouse/banking.duckdb -c "
    SELECT t.transaction_id_pk, t.posted_at, t.amount,
           c.full_name, c.kyc_status_label
    FROM marts.fct_transactions t
    JOIN marts.dim_customer_scd2 c
      ON t.customer_id = c.customer_id
     AND t.posted_at >= c.valid_from
     AND (t.posted_at < c.valid_to OR c.valid_to IS NULL)
    ORDER BY t.posted_at
"
```

See [`docs/phase-06-snapshots-streams.md`](docs/phase-06-snapshots-streams.md)
for the full SCD2 semantics, the dev-vs-prod matrix, and
[`snowflake/streams-tasks/README.md`](snowflake/streams-tasks/README.md)
for the Streams + Tasks DAG design + apply order.

### Phase 7 quickstart — incremental + metrics + Airflow

Phase 7 lands four production-grade concerns:

1. **`fct_transactions` is now incremental** — uses `_cdc_lsn` as the
   watermark; portable across DuckDB and Snowflake via `delete+insert`.
2. **`banking_cdc.*` macro namespace** fleshed out with `safe_divide`
   and `audit_columns` alongside the Phase 5 `initcap` dispatch.
3. **Semantic layer** definitions in
   [`dbt/models/marts/finance/_finance__metrics.yml`](dbt/models/marts/finance/_finance__metrics.yml)
   — five named metrics (`bank_revenue_usd`, `revenue_per_transaction_usd`,
   etc.) over fct_transactions, consumable by any MetricFlow-aware BI tool.
4. **Airflow DAG example** at
   [`orchestration/airflow/dags/banking_cdc_dbt.py`](orchestration/airflow/dags/banking_cdc_dbt.py)
   wiring source freshness → deps → build → snapshot + docs.

```bash
cd dbt

# First run — fct_transactions is incremental; starts with a full build.
dbt build --profiles-dir . --target dev --fail-fast

# Steady-state — later runs only materialise new _cdc_lsn rows.
# (In dev with the fixture, no new rows arrive, so this is a no-op
# incremental run that proves the plumbing works.)
dbt run  --profiles-dir . --target dev --select fct_transactions

# Force a full rebuild when the fct schema changes.
dbt run  --profiles-dir . --target dev --select fct_transactions --full-refresh

# Semantic layer: no runtime without MetricFlow, but the yml is parsed
# and validated by every dbt build. Phase 7 docs explain the MetricFlow
# install if you want to query metrics via `mf query ...`.
```

See [`docs/phase-07-packages-metrics.md`](docs/phase-07-packages-metrics.md)
for the Streams-vs-incremental decision matrix, the dispatch-macro
pattern, and the Airflow DAG design rationale.

Later phases land dbt dual-target (DuckDB `dev` + Snowflake `prod`) marts
(Phases 4–5), Snowflake Streams + Tasks as code (Phase 6), the
`dbt_banking` package (Phase 7), PII governance as code (Phase 8), the
reconciliation + QA layer (Phase 9), the Snowflake cost/perf runbook
(Phase 10), the blue/green zero-copy-clone CI (Phase 11), and the hosted
dbt docs site (Phase 12). See the per-phase docs in [`docs/`](docs/) as
they land.

## Two operating modes

The project is designed to run in either of two cost profiles:

- **Free-tier local**: Postgres + Redpanda + Debezium in docker-compose,
  Snowflake trial (30-day, $400 credits), local Airflow. Zero recurring cost
  once the trial ends if the warehouse-side dbt runs are paused.
- **Cloud paid (small)**: same stack, but a paid Snowflake XS warehouse
  running on a schedule (typically pennies per day for a portfolio-scale
  workload). Free-tier limits removed.

Both paths are exercised in the phase docs so a reader can follow along
without a credit card if they prefer.

## Development

- **Format & lint:** `ruff check --fix .` and `ruff format .` (both run on
  every commit via pre-commit)
- **Type check:** `mypy src/`
- **Test:** `pytest`

## License

MIT — see [LICENSE](LICENSE).
