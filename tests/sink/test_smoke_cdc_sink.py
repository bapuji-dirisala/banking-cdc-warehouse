"""Phase 3 DuckDB sink smoke test — opt-in via ``pytest -m cdc``.

Preconditions (not asserted; the test fails with a clear message if any
are missing):

- The Phase 2 Compose stack is up (Postgres + Zookeeper + Kafka + Connect)
- The Debezium connector is registered: ``banking-cdc kafka register``
- The DuckDB raw schema is applied: ``banking-cdc sink init``
- The sink has run against some seed activity: ``banking-cdc sink run`` +
  ``banking-cdc seed run`` in another shell

This test does not run the sink itself (long-running process); it inspects
the DuckDB file after a sink + seed cycle.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

pytestmark = pytest.mark.cdc

try:
    import duckdb
except ImportError:  # pragma: no cover - exercised only when extra missing
    pytest.skip(
        "duckdb not installed; install the 'warehouse' extra: pip install -e '.[warehouse]'",
        allow_module_level=True,
    )


DUCKDB_PATH = Path(os.environ.get("BANKING_CDC_DUCKDB_PATH", "warehouse/banking.duckdb"))
EXPECTED_TABLES = {
    "raw.customers",
    "raw.accounts",
    "raw.transactions",
    "raw.card_events",
}


@pytest.fixture(scope="module")
def conn() -> duckdb.DuckDBPyConnection:
    if not DUCKDB_PATH.exists():
        pytest.skip(f"DuckDB file not found at {DUCKDB_PATH} — run `banking-cdc sink init`")
    c = duckdb.connect(str(DUCKDB_PATH), read_only=True)
    yield c
    c.close()


def test_raw_schema_exists(conn: duckdb.DuckDBPyConnection) -> None:
    rows = conn.execute(
        "SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema = 'raw'"
    ).fetchall()
    tables = {f"{s}.{t}" for s, t in rows}
    assert EXPECTED_TABLES.issubset(tables), (
        f"missing tables; expected {sorted(EXPECTED_TABLES)}, got {sorted(tables)}"
    )


@pytest.mark.parametrize("table", sorted(EXPECTED_TABLES))
def test_table_has_rows(conn: duckdb.DuckDBPyConnection, table: str) -> None:
    row = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
    count = int(row[0]) if row else 0
    assert count > 0, (
        f"{table} is empty — did the sink run after seeding? "
        "In one shell: `banking-cdc sink run`. In another: `banking-cdc seed run`."
    )


@pytest.mark.parametrize("table", sorted(EXPECTED_TABLES))
def test_envelope_metadata_populated(conn: duckdb.DuckDBPyConnection, table: str) -> None:
    row = conn.execute(
        f"SELECT COUNT(*) FROM {table} WHERE __op IS NULL OR __lsn IS NULL"
    ).fetchone()
    nulls = int(row[0]) if row else 0
    assert nulls == 0, f"{table} has {nulls} rows missing envelope metadata"


def test_only_valid_ops_landed(conn: duckdb.DuckDBPyConnection) -> None:
    """After snapshot + stream, every row should have __op in {r, c, u}.

    No row should have __op='d' — deletes remove rows, they do not leave a
    tombstone with ``__op='d'`` in the current-state schema.
    """
    for table in sorted(EXPECTED_TABLES):
        bad = conn.execute(
            f"SELECT DISTINCT __op FROM {table} WHERE __op NOT IN ('r', 'c', 'u')"
        ).fetchall()
        assert not bad, f"{table} has unexpected __op values: {bad}"
