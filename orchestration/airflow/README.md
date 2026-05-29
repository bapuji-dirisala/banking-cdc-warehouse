# Orchestration — Airflow DAG example

Everything in this directory is **example code** showing how to schedule
the dbt pipeline on Apache Airflow (self-hosted, MWAA, or Astronomer).
It isn't deployed by this repo and isn't exercised by CI.

## Why this file lives here

The Phase 6 Snowflake Streams-and-Tasks DAG covers the native prod path
on Snowflake. For teams running dbt elsewhere (DuckDB, BigQuery, hybrid)
the orchestrator is usually Airflow or dbt Cloud. This DAG example is
the Airflow equivalent — a parallel option a reader of the portfolio
can see without searching another repo.

## What `dags/banking_cdc_dbt.py` ships

| Task | Responsibility |
|---|---|
| `dbt_source_freshness` | Fail-fast if raw.* tables are stale (upstream CDC pipeline is behind) |
| `dbt_deps`             | Install any new packages added since last run |
| `dbt_build_staging`    | Run + test staging models |
| `dbt_build_marts`      | Run + test marts (depends on staging) |
| `dbt_snapshot`         | Append SCD2 rows for customer / account |
| `dbt_docs_generate`    | Generate docs; upload to S3 in prod (commented placeholder) |

The DAG is **idempotent** — re-runs the same logical day produce the
same output (via `catchup=False` + `max_active_runs=1`). Phase 11's
blue/green zero-copy-clone CI model slots underneath this cleanly: the
"PR" variant of this DAG runs `dbt build --target ci` against a cloned
schema and tears down on PR merge.

## Why not dbt Cloud?

dbt Cloud is the easiest path for most teams and is the recommended
default when you have the budget. The Airflow example is here because
(a) it's free, (b) it's self-hostable, (c) it shows the orchestration
primitives explicitly rather than hiding them behind a job UI.

## Local sanity check

The DAG file imports cleanly without an Airflow runtime — it only uses
stdlib + typing + Airflow stubs that resolve lazily. Verify with:

```bash
python -c "import ast, sys; ast.parse(open('orchestration/airflow/dags/banking_cdc_dbt.py').read()); print('syntax ok')"
```

For a real Airflow test, drop the file into any Airflow 2.x `dags/`
folder and inspect the rendered graph in the UI.
