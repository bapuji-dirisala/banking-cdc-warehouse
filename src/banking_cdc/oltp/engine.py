"""SQLAlchemy engine factory. Reads ``BANKING_CDC_DB_URL`` with a sensible default."""

from __future__ import annotations

import os

from sqlalchemy import Engine, create_engine

DEFAULT_DB_URL = "postgresql+psycopg://banking:banking@localhost:5432/banking_oltp"
"""Matches the credentials baked into ``compose/docker-compose.yml``."""


def create_engine_from_env(*, echo: bool = False) -> Engine:
    """Build a SQLAlchemy Engine from ``BANKING_CDC_DB_URL`` (or the default)."""
    url = os.environ.get("BANKING_CDC_DB_URL", DEFAULT_DB_URL)
    return create_engine(url, echo=echo, future=True)
