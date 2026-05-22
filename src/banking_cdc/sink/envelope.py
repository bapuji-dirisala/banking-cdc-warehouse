"""Debezium envelope parser.

Pure functions with no external dependencies. Parses the JSON structure
Debezium 2.x emits for the Postgres connector with
``value.converter.schemas.enable=false``.

A ``ChangeEvent`` describes one row-level change; the sink
(``banking_cdc.sink.duckdb_sink``) consumes these and writes them to DuckDB.
Keeping the parser pure means it is trivially unit-testable without any
Kafka or warehouse infrastructure.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal

Op = Literal["c", "r", "u", "d"]


@dataclass(frozen=True)
class ChangeEvent:
    """One row-level change extracted from a Debezium envelope.

    Attributes
    ----------
    op
        Operation code: ``c`` create, ``r`` read (snapshot), ``u`` update,
        ``d`` delete.
    table
        Source table name, e.g. ``customers``.
    schema
        Source schema name, usually ``public``.
    before
        Row image before the change. ``None`` for ``c`` / ``r`` events.
    after
        Row image after the change. ``None`` for ``d`` events.
    source_ts_ms
        Timestamp (ms since epoch) of the source Postgres event.
    lsn
        Postgres log sequence number — monotonic per source cluster.
    """

    op: Op
    table: str
    schema: str
    before: dict[str, Any] | None
    after: dict[str, Any] | None
    source_ts_ms: int
    lsn: int


class EnvelopeParseError(ValueError):
    """Raised when a Kafka message is not a valid Debezium envelope."""


def parse_envelope(value: Any) -> ChangeEvent:
    """Parse a Debezium 2.x value envelope into a :class:`ChangeEvent`.

    Raises :class:`EnvelopeParseError` if the envelope shape is invalid for
    the operation code. Malformed messages are expected to be rare but real
    (e.g. a message produced by a different Debezium version); the sink's
    main loop logs + skips them rather than crashing.
    """
    if not isinstance(value, dict):
        raise EnvelopeParseError(f"expected dict envelope, got {type(value).__name__}")

    op = value.get("op")
    if op not in {"c", "r", "u", "d"}:
        raise EnvelopeParseError(f"unknown op {op!r}; expected one of c|r|u|d")

    source = value.get("source") or {}
    if not isinstance(source, dict):
        raise EnvelopeParseError(f"source block is not a dict: {source!r}")
    table = source.get("table")
    schema = source.get("schema")
    if not table or not schema:
        raise EnvelopeParseError(
            f"source.table / source.schema missing; source keys={list(source)}"
        )

    before = value.get("before")
    after = value.get("after")

    if op in ("c", "r") and after is None:
        raise EnvelopeParseError(f"op={op} requires 'after' field")
    if op == "d" and before is None:
        raise EnvelopeParseError("op=d requires 'before' field")
    if op == "u" and (before is None or after is None):
        raise EnvelopeParseError("op=u requires both 'before' and 'after'")

    return ChangeEvent(
        op=op,  # type: ignore[arg-type]  # narrowed by the membership check above
        table=str(table),
        schema=str(schema),
        before=before if isinstance(before, dict) else None,
        after=after if isinstance(after, dict) else None,
        source_ts_ms=int(source.get("ts_ms") or 0),
        lsn=int(source.get("lsn") or 0),
    )


def primary_key(event: ChangeEvent, pk_field: str = "id") -> Any:
    """Extract the primary-key value for a change event.

    Uses ``after.{pk_field}`` for ``c`` / ``r`` / ``u`` (fresh identity) and
    ``before.{pk_field}`` for ``d`` (the row that's going away). All Phase 1
    tables share the ``id`` PK column, so the default suits every topic the
    sink subscribes to.
    """
    if event.op == "d":
        if event.before is None or pk_field not in event.before:
            raise EnvelopeParseError(f"delete event missing before.{pk_field}")
        return event.before[pk_field]
    if event.after is None or pk_field not in event.after:
        raise EnvelopeParseError(f"{event.op} event missing after.{pk_field}")
    return event.after[pk_field]
