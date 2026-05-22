"""DuckDB sink for Debezium CDC events (Phase 3).

Subscribes to the four Phase 2 Kafka topics
(``banking.public.{customers,accounts,transactions,card_events}``), parses
each message's Debezium envelope, and applies the row-level change into
DuckDB's ``raw.*`` schema.

Semantics
---------

Each poll of the consumer yields a batch of messages. The entire batch is
applied inside one DuckDB transaction, then the Kafka consumer offsets are
committed. This gives at-least-once delivery:

- If the sink crashes between the DuckDB commit and the Kafka commit,
  restart will replay the batch. The DELETE-first strategy makes replay
  idempotent for ``c`` / ``r`` / ``u`` / ``d``.
- If the sink crashes before the DuckDB commit, the transaction rolls back
  and the batch is replayed from the last committed offset.

Operation handling
------------------

- ``op=c`` (create) and ``op=r`` (read/snapshot): ``DELETE WHERE id = pk``
  (no-op if row doesn't exist), then ``INSERT`` the ``after`` payload with
  envelope metadata appended.
- ``op=u`` (update): ``DELETE WHERE id = pk`` of the old row, then
  ``INSERT`` the new row from ``after``. DuckDB has no ``MERGE``, so
  DELETE-then-INSERT is the idiomatic alternative.
- ``op=d`` (delete): ``DELETE WHERE id = pk`` from ``before``. No INSERT.

Alternatives for production
---------------------------

- ``kafka-python`` is in maintenance mode. A production reader should
  swap to ``confluent-kafka`` for higher throughput + exactly-once support
  via Kafka transactions.
- The Snowflake Kafka Connector (config committed at
  ``compose/connect/connectors/snowflake-sink.json``) handles the
  production path. This Python sink exists so the project runs end-to-end
  against a free local DuckDB warehouse without a Snowflake account.
"""

from __future__ import annotations

import json
import logging
import signal
import time
from pathlib import Path
from typing import TYPE_CHECKING, Any

from banking_cdc.sink.envelope import (
    EnvelopeParseError,
    parse_envelope,
    primary_key,
)

if TYPE_CHECKING:
    import duckdb

log = logging.getLogger("banking_cdc.sink")

# Debezium topic → DuckDB table. One-to-one: our Phase 2 connector uses
# ``topic.prefix=banking`` and the ``public`` schema, so every Postgres
# table lands on its own topic.
TOPIC_TO_TABLE: dict[str, str] = {
    "banking.public.customers": "raw.customers",
    "banking.public.accounts": "raw.accounts",
    "banking.public.transactions": "raw.transactions",
    "banking.public.card_events": "raw.card_events",
}

# Business columns per table, in the order the raw_schema.sql CREATE
# statements declare them. Envelope metadata columns (``__op`` etc.) are
# appended by the writer, not listed here.
TABLE_COLUMNS: dict[str, list[str]] = {
    "raw.customers": [
        "id",
        "external_id",
        "first_name",
        "last_name",
        "email",
        "phone",
        "date_of_birth",
        "kyc_status",
        "created_at",
        "updated_at",
    ],
    "raw.accounts": [
        "id",
        "account_number",
        "customer_id",
        "account_type",
        "currency",
        "status",
        "opened_at",
        "closed_at",
        "updated_at",
    ],
    "raw.transactions": [
        "id",
        "transaction_id",
        "account_id",
        "amount",
        "currency",
        "direction",
        "transaction_type",
        "status",
        "description",
        "posted_at",
        "created_at",
        "updated_at",
    ],
    "raw.card_events": [
        "id",
        "event_id",
        "account_id",
        "transaction_id",
        "card_last4",
        "event_type",
        "amount",
        "currency",
        "merchant_name",
        "merchant_mcc",
        "occurred_at",
        "created_at",
    ],
}


class DuckDBSink:
    """Applies parsed ChangeEvents into DuckDB.

    Caller is responsible for transaction boundaries — the sink only issues
    DELETE / INSERT statements and never commits.
    """

    def __init__(self, conn: duckdb.DuckDBPyConnection) -> None:
        self.conn = conn

    def apply(self, topic: str, event: Any) -> None:
        """Apply one ChangeEvent to the DuckDB table that corresponds to ``topic``."""
        table = TOPIC_TO_TABLE.get(topic)
        if table is None:
            log.warning("ignoring event from unknown topic %s", topic)
            return

        pk = primary_key(event)

        # DELETE-then-INSERT keeps all four ops uniform and makes replay
        # idempotent. For op=d we stop after the DELETE.
        self.conn.execute(f"DELETE FROM {table} WHERE id = ?", [pk])

        if event.op == "d":
            return

        columns = TABLE_COLUMNS[table]
        values = [event.after.get(col) for col in columns]

        # Append envelope metadata columns.
        all_columns = [*columns, "__op", "__source_ts_ms", "__lsn"]
        all_values = [*values, event.op, event.source_ts_ms, event.lsn]
        placeholders = ", ".join(["?"] * len(all_columns))
        self.conn.execute(
            f"INSERT INTO {table} ({', '.join(all_columns)}) VALUES ({placeholders})",
            all_values,
        )


def run_sink(
    duckdb_path: Path,
    kafka_bootstrap: str,
    group_id: str = "banking-duckdb-sink",
    batch_size: int = 1000,
    commit_interval_s: float = 5.0,
) -> None:
    """Block in a Kafka → DuckDB consume loop until SIGINT or SIGTERM.

    Imports ``duckdb`` and ``kafka-python`` lazily so this module stays
    importable without the ``warehouse`` extra for the pure-parser unit
    tests to work in default CI.
    """
    import duckdb
    from kafka import KafkaConsumer

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    duckdb_path.parent.mkdir(parents=True, exist_ok=True)
    log.info("opening DuckDB at %s", duckdb_path)
    conn = duckdb.connect(str(duckdb_path))
    sink = DuckDBSink(conn)

    log.info("subscribing to %s (group=%s)", list(TOPIC_TO_TABLE), group_id)
    consumer = KafkaConsumer(
        *TOPIC_TO_TABLE.keys(),
        bootstrap_servers=kafka_bootstrap,
        group_id=group_id,
        enable_auto_commit=False,
        auto_offset_reset="earliest",
        value_deserializer=lambda v: json.loads(v.decode("utf-8")) if v else None,
    )

    # Graceful shutdown — commit outstanding batch and release resources.
    shutdown = {"requested": False}

    def _on_signal(signum: int, _frame: Any) -> None:
        log.info("received signal %d — shutting down after current batch", signum)
        shutdown["requested"] = True

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)

    processed = 0
    last_log = 0
    last_commit = time.monotonic()
    try:
        while not shutdown["requested"]:
            batch = consumer.poll(timeout_ms=500, max_records=batch_size)
            if not batch:
                # Idle — commit on time if the interval has passed, else loop.
                if time.monotonic() - last_commit >= commit_interval_s:
                    consumer.commit()
                    last_commit = time.monotonic()
                continue

            # All messages in this poll apply atomically in one DuckDB txn.
            conn.execute("BEGIN")
            try:
                for topic_partition, messages in batch.items():
                    for message in messages:
                        try:
                            event = parse_envelope(message.value)
                        except EnvelopeParseError as e:
                            log.warning(
                                "skipping malformed envelope on %s offset=%d: %s",
                                topic_partition.topic,
                                message.offset,
                                e,
                            )
                            continue
                        sink.apply(topic_partition.topic, event)
                        processed += 1
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise

            # DuckDB commit succeeded — now commit Kafka offsets.
            consumer.commit()
            last_commit = time.monotonic()

            if processed - last_log >= batch_size:
                log.info("processed %d messages total", processed)
                last_log = processed

    finally:
        log.info("final offset commit + closing")
        try:
            consumer.commit()
        except Exception as e:  # noqa: BLE001 - best-effort final commit
            log.warning("final commit failed: %s", e)
        consumer.close()
        conn.close()
        log.info("sink stopped — processed %d messages total", processed)


def row_counts(duckdb_path: Path) -> dict[str, int]:
    """Return a map of raw table name → row count.

    Returns -1 for tables that don't exist yet (schema not applied). The
    CLI formats this into a readable status table.
    """
    import duckdb

    if not duckdb_path.exists():
        return dict.fromkeys(sorted(TOPIC_TO_TABLE.values()), -1)

    conn = duckdb.connect(str(duckdb_path), read_only=True)
    try:
        counts: dict[str, int] = {}
        for table in sorted(TOPIC_TO_TABLE.values()):
            try:
                row = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
                counts[table] = int(row[0]) if row else -1
            except duckdb.CatalogException:
                counts[table] = -1  # table missing (schema not applied)
        return counts
    finally:
        conn.close()


def apply_schema(duckdb_path: Path, schema_sql_path: Path) -> None:
    """Idempotently apply the raw schema to a DuckDB file."""
    import duckdb

    duckdb_path.parent.mkdir(parents=True, exist_ok=True)
    schema_sql = schema_sql_path.read_text()
    conn = duckdb.connect(str(duckdb_path))
    try:
        conn.execute(schema_sql)
    finally:
        conn.close()
