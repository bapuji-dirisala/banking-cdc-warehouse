"""SQLAlchemy 2.0 declarative models for the banking OLTP source.

The canonical DDL lives in ``compose/postgres/init/00-schema.sql``. These
models mirror it and give the generator + tests a typed handle on the rows.
A drift-detection unit test compares the DDL rendered from these models
against the checked-in SQL.
"""

from __future__ import annotations

import enum
import uuid
from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Numeric,
    String,
    Uuid,
    func,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    """Declarative base for every OLTP model."""


# ---------------------------------------------------------------------------
# Enums — mirror the CREATE TYPE statements in 00-schema.sql exactly
# ---------------------------------------------------------------------------


class KycStatus(enum.StrEnum):
    PENDING = "pending"
    VERIFIED = "verified"
    REJECTED = "rejected"


class AccountType(enum.StrEnum):
    CHECKING = "checking"
    SAVINGS = "savings"
    CREDIT = "credit"


class AccountStatus(enum.StrEnum):
    ACTIVE = "active"
    FROZEN = "frozen"
    CLOSED = "closed"


class TxnDirection(enum.StrEnum):
    DEBIT = "debit"
    CREDIT = "credit"


class TxnType(enum.StrEnum):
    PURCHASE = "purchase"
    DEPOSIT = "deposit"
    WITHDRAWAL = "withdrawal"
    TRANSFER_IN = "transfer_in"
    TRANSFER_OUT = "transfer_out"
    FEE = "fee"
    INTEREST = "interest"


class TxnStatus(enum.StrEnum):
    PENDING = "pending"
    POSTED = "posted"
    REVERSED = "reversed"


class CardEventType(enum.StrEnum):
    AUTHORIZATION = "authorization"
    CAPTURE = "capture"
    DECLINE = "decline"
    REVERSAL = "reversal"
    REFUND = "refund"


# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------


class Customer(Base):
    __tablename__ = "customers"

    id: Mapped[int] = mapped_column(primary_key=True)
    external_id: Mapped[uuid.UUID] = mapped_column(Uuid, unique=True, nullable=False)
    first_name: Mapped[str] = mapped_column(String, nullable=False)
    last_name: Mapped[str] = mapped_column(String, nullable=False)
    email: Mapped[str] = mapped_column(String, unique=True, nullable=False)
    phone: Mapped[str | None] = mapped_column(String)
    date_of_birth: Mapped[date] = mapped_column(nullable=False)
    kyc_status: Mapped[KycStatus] = mapped_column(
        Enum(KycStatus, name="kyc_status", native_enum=True),
        nullable=False,
        default=KycStatus.PENDING,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    accounts: Mapped[list[Account]] = relationship(back_populates="customer")


class Account(Base):
    __tablename__ = "accounts"

    id: Mapped[int] = mapped_column(primary_key=True)
    account_number: Mapped[str] = mapped_column(String, unique=True, nullable=False)
    customer_id: Mapped[int] = mapped_column(
        ForeignKey("customers.id", ondelete="RESTRICT"), nullable=False
    )
    account_type: Mapped[AccountType] = mapped_column(
        Enum(AccountType, name="account_type", native_enum=True), nullable=False
    )
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    status: Mapped[AccountStatus] = mapped_column(
        Enum(AccountStatus, name="account_status", native_enum=True),
        nullable=False,
        default=AccountStatus.ACTIVE,
    )
    opened_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    customer: Mapped[Customer] = relationship(back_populates="accounts")
    transactions: Mapped[list[Transaction]] = relationship(back_populates="account")

    __table_args__ = (
        Index("ix_accounts_customer_id", "customer_id"),
        Index("ix_accounts_status", "status"),
    )


class Transaction(Base):
    __tablename__ = "transactions"

    id: Mapped[int] = mapped_column(primary_key=True)
    transaction_id: Mapped[uuid.UUID] = mapped_column(Uuid, unique=True, nullable=False)
    account_id: Mapped[int] = mapped_column(
        ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    direction: Mapped[TxnDirection] = mapped_column(
        Enum(TxnDirection, name="txn_direction", native_enum=True), nullable=False
    )
    transaction_type: Mapped[TxnType] = mapped_column(
        Enum(TxnType, name="txn_type", native_enum=True), nullable=False
    )
    status: Mapped[TxnStatus] = mapped_column(
        Enum(TxnStatus, name="txn_status", native_enum=True),
        nullable=False,
        default=TxnStatus.POSTED,
    )
    description: Mapped[str | None] = mapped_column(String)
    posted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    account: Mapped[Account] = relationship(back_populates="transactions")

    __table_args__ = (
        CheckConstraint("amount >= 0", name="ck_transactions_amount_nonneg"),
        Index("ix_transactions_account_id", "account_id"),
        Index("ix_transactions_posted_at", "posted_at"),
        Index("ix_transactions_type", "transaction_type"),
    )


class CardEvent(Base):
    __tablename__ = "card_events"

    id: Mapped[int] = mapped_column(primary_key=True)
    event_id: Mapped[uuid.UUID] = mapped_column(Uuid, unique=True, nullable=False)
    account_id: Mapped[int] = mapped_column(
        ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    transaction_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.transaction_id", ondelete="SET NULL")
    )
    card_last4: Mapped[str] = mapped_column(String(4), nullable=False)
    event_type: Mapped[CardEventType] = mapped_column(
        Enum(CardEventType, name="card_event_type", native_enum=True), nullable=False
    )
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    merchant_name: Mapped[str | None] = mapped_column(String)
    merchant_mcc: Mapped[str | None] = mapped_column(String(4))
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )

    account: Mapped[Account] = relationship()

    __table_args__ = (
        CheckConstraint("amount >= 0", name="ck_card_events_amount_nonneg"),
        Index("ix_card_events_account_id", "account_id"),
        Index("ix_card_events_occurred_at", "occurred_at"),
        Index("ix_card_events_event_type", "event_type"),
    )
