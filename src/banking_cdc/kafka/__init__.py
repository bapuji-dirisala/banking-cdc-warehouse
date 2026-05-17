"""Kafka Connect helpers for Phase 2 CDC capture.

Thin REST client over the Kafka Connect API plus a connector-config loader.
Pulled into a dedicated package so the ``banking-cdc kafka ...`` CLI
subcommands can lazy-import these dependencies (``requests``) and the rest
of the CLI stays usable without the ``kafka`` extra installed.
"""

from __future__ import annotations

from pathlib import Path

from banking_cdc.kafka.connect import (
    ConnectClient,
    load_connector_config,
    wait_for_connect,
)

# Repo-root-relative path to the committed Debezium connector config.
#   src/banking_cdc/kafka/__init__.py
#   -> parents[3] == <repo root>
DEFAULT_CONNECTOR_PATH: Path = (
    Path(__file__).resolve().parents[3] / "compose" / "connect" / "connectors" / "pg-source.json"
)

__all__ = [
    "DEFAULT_CONNECTOR_PATH",
    "ConnectClient",
    "load_connector_config",
    "wait_for_connect",
]
