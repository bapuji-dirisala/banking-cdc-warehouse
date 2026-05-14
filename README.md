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

> **Status:** Phase 1 — Postgres OLTP source with logical WAL + a
> deterministic synthetic transaction generator is live. Eleven-phase
> roadmap below; every phase gets a dedicated design doc under
> [`docs/`](docs/).

## What this project demonstrates

- **CDC from first principles** — Debezium reading the Postgres WAL,
  exactly-once ordering guarantees via LSN, ordered delivery to Kafka
- **dbt at expert level** — sources, staging, intermediate, marts,
  snapshots (SCD2), exposures, tests, macros, docs, incremental models
- **Dimensional modelling for banking** — Kimball star schema on a
  realistic OLTP domain: `dim_customer`, `dim_account` (SCD2),
  `fact_transaction`, `fact_balance_daily`, `fact_card_events`
- **Snowflake specifics** — warehouses, credits, time travel, streams,
  tasks, incremental micro-partition pruning
- **Regulatory data quality** — Great Expectations gates at every layer,
  row-count reconciliation, referential integrity, PII column-level masking
- **Audit lineage** — every row-level change traceable from mart back to
  the originating WAL event
- **Jenkins declarative pipeline** as a first-class deliverable, not just a
  portfolio artefact

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

| Phase | Focus | Status | Notes |
|-------|-------|--------|-------|
| 0 | Repo scaffolding, tooling, CI | ✅ done | [docs/phase-00-scaffolding.md](docs/phase-00-scaffolding.md) |
| 1 | Postgres OLTP schema + synthetic transaction generator | ✅ done | [docs/phase-01-postgres-oltp.md](docs/phase-01-postgres-oltp.md) |
| 2 | Debezium + Kafka (CDC capture, docker-compose) | ⏳ planned | |
| 3 | Bronze CDC landing — raw change events into Snowflake | ⏳ planned | |
| 4 | dbt sources + staging models | ⏳ planned | |
| 5 | dbt snapshots — SCD2 on `dim_customer`, `dim_account` | ⏳ planned | |
| 6 | dbt marts — `fact_transaction`, `fact_balance_daily`, `fact_card_events` | ⏳ planned | |
| 7 | Great Expectations quality gates + dbt tests | ⏳ planned | |
| 8 | PII column-level masking + row-level audit log | ⏳ planned | |
| 9 | Airflow orchestration (daily incremental) | ⏳ planned | |
| 10 | Jenkins declarative pipeline + dbt docs + CI polish | ⏳ planned | |

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

Later phases add Debezium, Kafka, Snowflake, dbt, and Airflow — see the
per-phase docs in [`docs/`](docs/) as they land.

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
