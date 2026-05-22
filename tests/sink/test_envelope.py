"""Unit tests for the Debezium envelope parser.

Pure stdlib + the parser itself — no DuckDB, no Kafka, no network. Runs in
default CI alongside the Phase 1 generator tests.
"""

from __future__ import annotations

from typing import Any

import pytest

from banking_cdc.sink.envelope import (
    EnvelopeParseError,
    parse_envelope,
    primary_key,
)


def _envelope(
    op: str,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
    *,
    table: str = "customers",
    schema: str = "public",
    ts_ms: int = 1697000000000,
    lsn: int = 123456789,
) -> dict[str, Any]:
    """Build a minimal Debezium 2.x value envelope for testing."""
    return {
        "op": op,
        "before": before,
        "after": after,
        "source": {
            "version": "2.6.2.Final",
            "connector": "postgresql",
            "name": "banking",
            "ts_ms": ts_ms,
            "snapshot": "false",
            "db": "banking_oltp",
            "schema": schema,
            "table": table,
            "lsn": lsn,
        },
        "ts_ms": ts_ms + 1,
    }


# ---------------------------------------------------------------------------
# parse_envelope — happy path
# ---------------------------------------------------------------------------


class TestParseEnvelopeHappyPath:
    def test_create_event_parses(self) -> None:
        env = _envelope("c", after={"id": 1, "email": "a@b.com"})
        event = parse_envelope(env)
        assert event.op == "c"
        assert event.table == "customers"
        assert event.schema == "public"
        assert event.before is None
        assert event.after == {"id": 1, "email": "a@b.com"}
        assert event.source_ts_ms == 1697000000000
        assert event.lsn == 123456789

    def test_snapshot_read_event_parses(self) -> None:
        env = _envelope("r", after={"id": 2})
        event = parse_envelope(env)
        assert event.op == "r"
        assert event.before is None
        assert event.after == {"id": 2}

    def test_update_event_parses(self) -> None:
        env = _envelope(
            "u",
            before={"id": 1, "email": "a@b.com"},
            after={"id": 1, "email": "x@y.com"},
        )
        event = parse_envelope(env)
        assert event.op == "u"
        assert event.before == {"id": 1, "email": "a@b.com"}
        assert event.after == {"id": 1, "email": "x@y.com"}

    def test_delete_event_parses(self) -> None:
        env = _envelope("d", before={"id": 1})
        event = parse_envelope(env)
        assert event.op == "d"
        assert event.before == {"id": 1}
        assert event.after is None

    def test_source_metadata_captured(self) -> None:
        env = _envelope(
            "c",
            after={"id": 3},
            table="accounts",
            schema="public",
            ts_ms=1700000000000,
            lsn=999999,
        )
        event = parse_envelope(env)
        assert event.table == "accounts"
        assert event.schema == "public"
        assert event.source_ts_ms == 1700000000000
        assert event.lsn == 999999


# ---------------------------------------------------------------------------
# parse_envelope — error paths
# ---------------------------------------------------------------------------


class TestParseEnvelopeErrors:
    def test_non_dict_raises(self) -> None:
        with pytest.raises(EnvelopeParseError, match="expected dict"):
            parse_envelope("not a dict")

    def test_missing_op_raises(self) -> None:
        with pytest.raises(EnvelopeParseError, match="unknown op"):
            parse_envelope({"source": {"table": "customers", "schema": "public"}})

    def test_unknown_op_raises(self) -> None:
        with pytest.raises(EnvelopeParseError, match="unknown op"):
            parse_envelope({"op": "z"})

    def test_missing_source_raises(self) -> None:
        with pytest.raises(EnvelopeParseError, match="source.table"):
            parse_envelope({"op": "c", "after": {"id": 1}})

    def test_create_without_after_raises(self) -> None:
        env = _envelope("c")  # after is None
        with pytest.raises(EnvelopeParseError, match="op=c requires 'after'"):
            parse_envelope(env)

    def test_snapshot_without_after_raises(self) -> None:
        env = _envelope("r")
        with pytest.raises(EnvelopeParseError, match="op=r requires 'after'"):
            parse_envelope(env)

    def test_delete_without_before_raises(self) -> None:
        env = _envelope("d")
        with pytest.raises(EnvelopeParseError, match="op=d requires 'before'"):
            parse_envelope(env)

    def test_update_without_before_raises(self) -> None:
        env = _envelope("u", after={"id": 1})
        with pytest.raises(EnvelopeParseError, match="op=u requires both"):
            parse_envelope(env)

    def test_update_without_after_raises(self) -> None:
        env = _envelope("u", before={"id": 1})
        with pytest.raises(EnvelopeParseError, match="op=u requires both"):
            parse_envelope(env)


# ---------------------------------------------------------------------------
# primary_key
# ---------------------------------------------------------------------------


class TestPrimaryKey:
    def test_create_uses_after(self) -> None:
        env = _envelope("c", after={"id": 42, "email": "x@y.com"})
        event = parse_envelope(env)
        assert primary_key(event) == 42

    def test_update_uses_after(self) -> None:
        env = _envelope(
            "u",
            before={"id": 42, "email": "a"},
            after={"id": 42, "email": "b"},
        )
        event = parse_envelope(env)
        assert primary_key(event) == 42

    def test_delete_uses_before(self) -> None:
        env = _envelope("d", before={"id": 42, "email": "a"})
        event = parse_envelope(env)
        assert primary_key(event) == 42

    def test_custom_pk_field(self) -> None:
        env = _envelope("c", after={"transaction_id": "abc-123"})
        event = parse_envelope(env)
        assert primary_key(event, pk_field="transaction_id") == "abc-123"

    def test_missing_pk_in_after_raises(self) -> None:
        env = _envelope("c", after={"email": "x@y.com"})  # no id
        event = parse_envelope(env)
        with pytest.raises(EnvelopeParseError, match="missing after.id"):
            primary_key(event)

    def test_missing_pk_in_before_for_delete_raises(self) -> None:
        env = _envelope("d", before={"email": "x@y.com"})  # no id
        event = parse_envelope(env)
        with pytest.raises(EnvelopeParseError, match="missing before.id"):
            primary_key(event)
