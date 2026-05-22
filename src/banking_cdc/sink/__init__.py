"""DuckDB sink for Debezium CDC events (Phase 3).

Only the pure ``envelope`` module is re-exported at the package root so this
package can be imported in environments without the ``warehouse`` extra
installed (e.g. the default CI image, which runs the envelope unit tests
without needing duckdb or kafka-python).

The runtime sink (``banking_cdc.sink.duckdb_sink``) lazy-imports duckdb and
kafka-python inside the functions that need them.

See ``docs/phase-03-warehouse-foundation.md`` for the design rationale.
"""

from __future__ import annotations

from banking_cdc.sink.envelope import (
    ChangeEvent,
    EnvelopeParseError,
    parse_envelope,
    primary_key,
)

__all__ = [
    "ChangeEvent",
    "EnvelopeParseError",
    "parse_envelope",
    "primary_key",
]
