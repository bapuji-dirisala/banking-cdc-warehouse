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
> deterministic synthetic transaction generator is live. Thirteen-phase
> roadmap below (plus an optional 14th), weighted for **dbt + Snowflake
> depth**; every phase gets a dedicated design doc under [`docs/`](docs/).

## What this project demonstrates

- **CDC capture** — Debezium reading the Postgres WAL into Kafka with
  `REPLICA IDENTITY FULL`, LSN-ordered delivery, snapshot + streaming
  modes; kept deliberately minimal so dbt + Snowflake stay the focus
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
- **Snowflake specifics** — role hierarchy (SYSADMIN / SECURITYADMIN /
  functional + access roles), warehouse sizing + auto-suspend, resource
  monitors with credit quotas, query-tag-per-dbt-model cost attribution,
  **Streams + Tasks** (as an in-warehouse orchestration alternative to
  Airflow, built here side-by-side), time travel + zero-copy clones,
  clustering keys with query-profile before/after screenshots
- **Enterprise governance** — Snowflake dynamic data masking on PII,
  row access policies for customer segmentation, grants managed via
  dbt post-hooks
- **Regulatory data quality** — Great Expectations gates at every
  layer, row-count reconciliation, referential integrity, source
  freshness, and a reconciliation suite that proves fact grains tie
  back to source WAL event counts
- **Senior-level CI** — blue/green deploys using Snowflake **zero-copy
  clones** per PR, dbt in `--defer --state:modified+` mode, lineage
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

| Phase | Focus | Status | Notes |
|-------|-------|--------|-------|
| 0 | Repo scaffolding, tooling, CI | ✅ done | [docs/phase-00-scaffolding.md](docs/phase-00-scaffolding.md) |
| 1 | Postgres OLTP schema + synthetic transaction generator | ✅ done | [docs/phase-01-postgres-oltp.md](docs/phase-01-postgres-oltp.md) |
| 2 | Debezium + Kafka Connect — minimal CDC capture | ⏳ next | [docs/phase-02-debezium-kafka.md](docs/phase-02-debezium-kafka.md) |
| 3 | Snowflake account + governance + Kafka Connector → `raw` schema | ⏳ planned | |
| 4 | dbt-snowflake foundation: profiles, sources (with freshness), staging | ⏳ planned | |
| 5 | Intermediate + marts: `dim_customer` / `dim_account` SCD2, `fact_transaction`, `fact_balance_daily` | ⏳ planned | |
| 6 | Snowflake Streams + Tasks (in-warehouse orchestration, compared to Airflow) | ⏳ planned | |
| 7 | Package authoring: `dbt_banking` with custom macros + banking-specific tests | ⏳ planned | |
| 8 | PII governance: dynamic masking + row access policies + grants via post-hooks | ⏳ planned | |
| 9 | Data quality: full test suite + source freshness + reconciliation + GE per layer | ⏳ planned | |
| 10 | Snowflake cost + perf: resource monitors, query tags, warehouse sizing, clustering | ⏳ planned | |
| 11 | Blue/green CI with zero-copy clones (`--defer --state:modified+`), PR lineage diff | ⏳ planned | |
| 12 | dbt docs site + exposures + metrics + architecture diagrams + README polish | ⏳ planned | |
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
pytest -m cdc
```

Later phases land Snowflake (Phase 3), dbt + marts (Phases 4–7), governance
(Phase 8), quality + reconciliation (Phase 9), cost + perf (Phase 10),
zero-copy-clone CI (Phase 11), and dbt docs (Phase 12). See the per-phase
docs in [`docs/`](docs/) as they land.

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
