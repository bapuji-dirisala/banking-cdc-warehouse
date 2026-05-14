"""Integration test — hits a live Postgres from ``compose/docker-compose.yml``.

Deselected by default (marker ``integration``). Run with::

    docker compose -f compose/docker-compose.yml up -d
    pytest -m integration

The test uses an isolated schema (``phase1_integration``) so it doesn't
collide with a developer's ``public`` seed data and cleans up after itself
regardless of pass/fail.
"""

from __future__ import annotations

import pytest
from sqlalchemy import text
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from banking_cdc.oltp import Base, create_engine_from_env
from banking_cdc.seed import GeneratorConfig, generate_batch, persist_batch

SCHEMA = "phase1_integration"

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def engine():
    engine = create_engine_from_env()
    try:
        with engine.connect() as conn:
            conn.execute(text(f'DROP SCHEMA IF EXISTS "{SCHEMA}" CASCADE'))
            conn.execute(text(f'CREATE SCHEMA "{SCHEMA}"'))
            conn.commit()
    except OperationalError as exc:  # pragma: no cover - env-dependent
        pytest.skip(f"Postgres not reachable at {engine.url}: {exc}")

    # Bind every model to the isolated schema for the duration of the test.
    for table in Base.metadata.tables.values():
        table.schema = SCHEMA
    Base.metadata.create_all(engine)

    yield engine

    for table in Base.metadata.tables.values():
        table.schema = None
    with engine.connect() as conn:
        conn.execute(text(f'DROP SCHEMA IF EXISTS "{SCHEMA}" CASCADE'))
        conn.commit()
    engine.dispose()


def test_seed_and_read_back(engine) -> None:
    config = GeneratorConfig(customers=25, duration_seconds=10, tps=5, seed=7)
    batch = generate_batch(config)

    with Session(engine) as session:
        persist_batch(session, batch)

    with engine.connect() as conn:
        customers = conn.execute(text(f'SELECT count(*) FROM "{SCHEMA}".customers')).scalar_one()
        accounts = conn.execute(text(f'SELECT count(*) FROM "{SCHEMA}".accounts')).scalar_one()
        txns = conn.execute(text(f'SELECT count(*) FROM "{SCHEMA}".transactions')).scalar_one()
        card_events = conn.execute(
            text(f'SELECT count(*) FROM "{SCHEMA}".card_events')
        ).scalar_one()

    assert customers == 25
    assert accounts == len(batch.accounts)
    assert txns == 10 * 5
    assert card_events == len(batch.card_events)


def test_referential_integrity_is_enforced(engine) -> None:
    with engine.connect() as conn:
        orphaned_txns = conn.execute(
            text(
                f'''
                SELECT count(*)
                FROM "{SCHEMA}".transactions t
                LEFT JOIN "{SCHEMA}".accounts a ON a.id = t.account_id
                WHERE a.id IS NULL
                '''
            )
        ).scalar_one()
    assert orphaned_txns == 0
