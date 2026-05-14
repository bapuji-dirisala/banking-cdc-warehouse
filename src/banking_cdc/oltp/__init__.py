"""OLTP source of truth — SQLAlchemy models and engine factory."""

from __future__ import annotations

from banking_cdc.oltp.engine import DEFAULT_DB_URL, create_engine_from_env
from banking_cdc.oltp.models import (
    Account,
    AccountStatus,
    AccountType,
    Base,
    CardEvent,
    CardEventType,
    Customer,
    KycStatus,
    Transaction,
    TxnDirection,
    TxnStatus,
    TxnType,
)

__all__ = [
    "DEFAULT_DB_URL",
    "Account",
    "AccountStatus",
    "AccountType",
    "Base",
    "CardEvent",
    "CardEventType",
    "Customer",
    "KycStatus",
    "Transaction",
    "TxnDirection",
    "TxnStatus",
    "TxnType",
    "create_engine_from_env",
]
