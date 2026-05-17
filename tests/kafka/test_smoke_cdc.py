"""Phase 2 CDC smoke test — opt-in via ``pytest -m cdc``.

Preconditions (not asserted; the test will fail with a clear message if any
are missing):

- The Compose stack is up: ``docker compose -f compose/docker-compose.yml up -d``
- Kafka Connect is reachable: ``banking-cdc kafka wait``
- The Debezium Postgres connector is registered: ``banking-cdc kafka register``

These three steps are what Phase 2's "How to run" section in the design doc
walks a reader through. The test is deliberately dependency-light — just
``requests`` (which is in the ``kafka`` extra) — so it can run anywhere the
Connect REST API is reachable.
"""

from __future__ import annotations

import os

import pytest

pytestmark = pytest.mark.cdc

try:
    import requests
except ImportError:  # pragma: no cover - exercised when the extra is missing
    pytest.skip(
        "requests not installed; install the 'kafka' extra: pip install -e '.[kafka]'",
        allow_module_level=True,
    )


CONNECT_URL = os.environ.get("BANKING_CDC_CONNECT_URL", "http://localhost:8083")
CONNECTOR_NAME = "banking-postgres-source"
EXPECTED_TOPICS = {
    "banking.public.customers",
    "banking.public.accounts",
    "banking.public.transactions",
    "banking.public.card_events",
}


def test_connect_rest_api_is_up() -> None:
    """The Connect worker answers 200 on its root endpoint."""
    r = requests.get(f"{CONNECT_URL}/", timeout=10)
    assert r.status_code == 200, f"Connect at {CONNECT_URL} returned {r.status_code}"
    body = r.json()
    assert "version" in body, f"unexpected health payload: {body!r}"
    assert "kafka_cluster_id" in body, f"unexpected health payload: {body!r}"


def test_connector_registered_and_running() -> None:
    """The Debezium Postgres connector is registered and all tasks are RUNNING."""
    connectors = requests.get(f"{CONNECT_URL}/connectors", timeout=10).json()
    assert CONNECTOR_NAME in connectors, (
        f"connector {CONNECTOR_NAME!r} not registered; run `banking-cdc kafka register` first"
    )

    status = requests.get(f"{CONNECT_URL}/connectors/{CONNECTOR_NAME}/status", timeout=10).json()
    assert status["connector"]["state"] == "RUNNING", (
        f"connector state is {status['connector']['state']!r}; full status: {status!r}"
    )
    for task in status.get("tasks", []):
        assert task["state"] == "RUNNING", (
            f"task {task['id']} is {task['state']!r}: {task.get('trace', '')[:400]}"
        )


def test_connector_producing_to_expected_topics() -> None:
    """At least one of the four target topics shows up in the connector's output."""
    r = requests.get(f"{CONNECT_URL}/connectors/{CONNECTOR_NAME}/topics", timeout=10)
    r.raise_for_status()
    body = r.json()
    topics = set(body[CONNECTOR_NAME]["topics"])
    overlap = topics & EXPECTED_TOPICS
    assert overlap, (
        "none of the expected Debezium topics are present; "
        f"expected any of {sorted(EXPECTED_TOPICS)}, got {sorted(topics)}. "
        "Did the snapshot finish? Try: `banking-cdc kafka status`."
    )
