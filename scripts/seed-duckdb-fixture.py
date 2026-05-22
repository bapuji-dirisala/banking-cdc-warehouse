#!/usr/bin/env python
"""Apply the DuckDB raw schema + a tiny deterministic fixture.

Powers the CI ``dbt build (duckdb)`` job so dbt can compile and test
against realistic shapes without needing the full compose stack. Also
handy for a cold-start local dev loop:

    python scripts/seed-duckdb-fixture.py
    cd dbt && dbt build --profiles-dir . --target dev

Idempotent — the fixture SQL deletes-then-inserts by PK, so re-running
leaves the warehouse in the same state.
"""

from __future__ import annotations

import sys
from pathlib import Path

import duckdb

REPO_ROOT = Path(__file__).resolve().parents[1]
RAW_SCHEMA_SQL = REPO_ROOT / "sql" / "duckdb" / "raw_schema.sql"
RAW_FIXTURE_SQL = REPO_ROOT / "sql" / "duckdb" / "raw_fixture.sql"


def main() -> int:
    db_path = Path(sys.argv[1] if len(sys.argv) > 1 else REPO_ROOT / "warehouse" / "banking.duckdb")
    db_path.parent.mkdir(parents=True, exist_ok=True)

    conn = duckdb.connect(str(db_path))
    try:
        conn.execute(RAW_SCHEMA_SQL.read_text())
        conn.execute(RAW_FIXTURE_SQL.read_text())
    finally:
        conn.close()

    print(f"Seeded raw schema + fixture into {db_path}")
    print("Next: cd dbt && dbt deps --profiles-dir . && dbt build --profiles-dir . --target dev")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
