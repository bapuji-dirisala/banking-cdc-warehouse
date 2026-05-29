"""Airflow DAG — scheduled refresh of the banking CDC warehouse via dbt.

Not deployed by this repo. Drop into any Airflow 2.x `dags/` directory
to adopt. See `orchestration/airflow/README.md` for the full design
rationale and the per-task responsibility matrix.

Design decisions worth highlighting in a code review:

- **`BashOperator` wrapping `dbt build`**, not `KubernetesPodOperator`,
  so the DAG runs anywhere Airflow runs. Teams with heavy ELT might
  prefer K8s pods for isolation; swap `BashOperator` → `KubernetesPodOperator`
  with no other DAG changes.
- **`catchup=False` + `max_active_runs=1`** so a backlog of missed
  schedules doesn't produce N concurrent `dbt build` runs fighting for
  the warehouse. Idempotency is the dbt model's responsibility
  (incremental watermarks, snapshot timestamp strategy).
- **Source freshness first**, before any transform runs. A stale raw
  layer means a stale mart; fail fast rather than publish nonsense.
- **Snapshots are a separate task**, not folded into `dbt build`, so
  SCD2 history captures can be retried independently of mart failures.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.empty import EmptyOperator

# ---------------------------------------------------------------------------
# Config — real deployments pull these from Airflow Variables or Connections.
# Keeping them inline here makes the example self-contained.
# ---------------------------------------------------------------------------
DBT_PROJECT_DIR = "/opt/airflow/dbt"
DBT_PROFILES_DIR = "/opt/airflow/dbt"
DBT_TARGET = "prod"  # swap to "ci" for the PR variant (Phase 11)

DEFAULT_ARGS = {
    "owner": "banking-platform",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": True,
    "email_on_retry": False,
}


def _dbt(cmd: str) -> str:
    """Compose a dbt command with the project-wide flags.

    Keeping this in one place means ``--profiles-dir`` / ``--target``
    changes don't require editing six operator definitions.
    """
    return (
        f"cd {DBT_PROJECT_DIR} && dbt {cmd} --profiles-dir {DBT_PROFILES_DIR} --target {DBT_TARGET}"
    )


# ---------------------------------------------------------------------------
# DAG — 15-minute schedule in prod (adjust to match your Snowflake sink
# cadence). Phase 10 cost runbook has the recommendation table.
# ---------------------------------------------------------------------------
with DAG(
    dag_id="banking_cdc_dbt",
    description="Scheduled dbt build of the banking CDC warehouse.",
    start_date=datetime(2026, 1, 1),
    schedule="*/15 * * * *",
    catchup=False,
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    tags=["banking", "cdc", "dbt"],
) as dag:
    start = EmptyOperator(task_id="start")

    source_freshness = BashOperator(
        task_id="dbt_source_freshness",
        bash_command=_dbt("source freshness"),
        # Don't retry — stale source is usually an upstream pipeline alert,
        # not a transient Airflow issue.
        retries=0,
    )

    deps = BashOperator(
        task_id="dbt_deps",
        bash_command=_dbt("deps"),
    )

    build_staging = BashOperator(
        task_id="dbt_build_staging",
        bash_command=_dbt("build --select +staging --fail-fast"),
    )

    build_marts = BashOperator(
        task_id="dbt_build_marts",
        bash_command=_dbt("build --select intermediate+ marts+ --fail-fast"),
    )

    run_snapshots = BashOperator(
        task_id="dbt_snapshot",
        bash_command=_dbt("snapshot"),
    )

    docs_generate = BashOperator(
        task_id="dbt_docs_generate",
        bash_command=_dbt("docs generate"),
        # Prod version uploads to S3; CI version keeps artifacts local.
        # bash_command=_dbt("docs generate") + " && aws s3 sync target/ s3://.../dbt-docs/",
    )

    done = EmptyOperator(task_id="done")

    # Pipeline:
    #   start → source_freshness → deps → build_staging → build_marts → done
    #                                   ↘ snapshot (parallel to marts) ↗
    #                                   ↘ docs_generate (parallel) ↗
    start >> source_freshness >> deps >> build_staging
    build_staging >> [build_marts, run_snapshots, docs_generate] >> done
