"""Synthetic banking OLTP workload generator.

The generator is intentionally pure — it builds Python lists of model
instances (a :class:`SyntheticBatch`) with no database side-effects. A
separate :func:`persist_batch` helper commits them via SQLAlchemy. This
split makes the generator trivially unit-testable without a running
Postgres and lets the CLI pipe the batch to any Session (compose Postgres,
integration-test ephemeral schema, dry-run debug print, etc.).

Reproducibility is a first-class concern: pass ``seed=`` on
:class:`GeneratorConfig` and the same customers, accounts, transactions,
and card events come out every run. All three sources of randomness
(``random.Random``, Faker, and timestamp jitter) share that single seed.
"""

from __future__ import annotations

import random
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import TypeVar

from faker import Faker
from sqlalchemy.orm import Session

from banking_cdc.oltp.models import (
    Account,
    AccountStatus,
    AccountType,
    CardEvent,
    CardEventType,
    Customer,
    KycStatus,
    Transaction,
    TxnDirection,
    TxnStatus,
    TxnType,
)

# ---------------------------------------------------------------------------
# Distributions
# ---------------------------------------------------------------------------

# Weights are relative — they don't need to sum to 1.
_ACCOUNT_TYPE_WEIGHTS: dict[AccountType, float] = {
    AccountType.CHECKING: 6.0,
    AccountType.SAVINGS: 3.0,
    AccountType.CREDIT: 1.0,
}

_TXN_TYPE_WEIGHTS: dict[TxnType, float] = {
    TxnType.PURCHASE: 60.0,
    TxnType.DEPOSIT: 8.0,
    TxnType.WITHDRAWAL: 12.0,
    TxnType.TRANSFER_IN: 5.0,
    TxnType.TRANSFER_OUT: 8.0,
    TxnType.FEE: 5.0,
    TxnType.INTEREST: 2.0,
}

# Transaction types that produce a "money leaving the account" event.
_DEBIT_TYPES: frozenset[TxnType] = frozenset(
    {TxnType.PURCHASE, TxnType.WITHDRAWAL, TxnType.TRANSFER_OUT, TxnType.FEE}
)

# Card events are emitted only for purchase-style transactions.
_CARD_TXN_TYPES: frozenset[TxnType] = frozenset({TxnType.PURCHASE})

_KYC_WEIGHTS: dict[KycStatus, float] = {
    KycStatus.VERIFIED: 85.0,
    KycStatus.PENDING: 12.0,
    KycStatus.REJECTED: 3.0,
}

_MCC_SAMPLES: tuple[str, ...] = (
    "5411",  # grocery
    "5812",  # restaurants
    "5541",  # gas stations
    "4111",  # transit
    "5732",  # electronics
    "5942",  # bookstores
    "5311",  # department stores
    "5814",  # fast food
)


# ---------------------------------------------------------------------------
# Config + batch container
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class GeneratorConfig:
    """Knobs for a single synthetic run.

    Every run with the same config produces byte-identical output.
    """

    customers: int = 200
    accounts_per_customer_min: int = 1
    accounts_per_customer_max: int = 3
    duration_seconds: int = 60
    tps: float = 20.0
    seed: int = 42
    start_at: datetime | None = None  # defaults to ``duration`` before now-UTC


@dataclass
class SyntheticBatch:
    """The full output of a single generator run."""

    customers: list[Customer] = field(default_factory=list)
    accounts: list[Account] = field(default_factory=list)
    transactions: list[Transaction] = field(default_factory=list)
    card_events: list[CardEvent] = field(default_factory=list)

    @property
    def totals(self) -> dict[str, int]:
        return {
            "customers": len(self.customers),
            "accounts": len(self.accounts),
            "transactions": len(self.transactions),
            "card_events": len(self.card_events),
        }


# ---------------------------------------------------------------------------
# Weighted-choice helper (uses the seeded rng, not the module-level random)
# ---------------------------------------------------------------------------

T = TypeVar("T")


def _weighted_choice(rng: random.Random, weights: dict[T, float]) -> T:
    keys = list(weights.keys())
    values = list(weights.values())
    (choice,) = rng.choices(keys, weights=values, k=1)
    return choice


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------


def generate_batch(config: GeneratorConfig) -> SyntheticBatch:
    """Build a fully-formed :class:`SyntheticBatch` from a config.

    Pure function — no database access, no wall-clock reads outside the
    single ``datetime.now`` fallback when ``start_at`` is omitted.
    """
    rng = random.Random(config.seed)
    fake = Faker()
    Faker.seed(config.seed)

    batch = SyntheticBatch()

    start_at = config.start_at or (
        datetime.now(tz=UTC) - timedelta(seconds=config.duration_seconds)
    )

    _populate_customers_and_accounts(batch, config, rng, fake, start_at)
    _populate_transactions_and_card_events(batch, config, rng, fake, start_at)
    return batch


def _populate_customers_and_accounts(
    batch: SyntheticBatch,
    config: GeneratorConfig,
    rng: random.Random,
    fake: Faker,
    start_at: datetime,
) -> None:
    # Use a stable "account_number" counter so runs are deterministic even
    # though we don't yet know the DB-assigned IDs.
    account_counter = 100_000_000

    for _ in range(config.customers):
        first = fake.first_name()
        last = fake.last_name()
        # Suffix ensures uniqueness even with Faker collisions.
        email = f"{first}.{last}.{rng.randint(1000, 9999)}@example.com".lower()
        customer = Customer(
            external_id=uuid.UUID(int=rng.getrandbits(128)),
            first_name=first,
            last_name=last,
            email=email,
            phone=fake.msisdn(),
            date_of_birth=fake.date_of_birth(minimum_age=18, maximum_age=85),
            kyc_status=_weighted_choice(rng, _KYC_WEIGHTS),
            created_at=start_at,
            updated_at=start_at,
        )
        batch.customers.append(customer)

        n_accounts = rng.randint(
            config.accounts_per_customer_min,
            config.accounts_per_customer_max,
        )
        for _ in range(n_accounts):
            account_counter += 1
            batch.accounts.append(
                Account(
                    account_number=str(account_counter),
                    customer=customer,
                    account_type=_weighted_choice(rng, _ACCOUNT_TYPE_WEIGHTS),
                    currency="USD",
                    status=AccountStatus.ACTIVE,
                    opened_at=start_at,
                    updated_at=start_at,
                )
            )


def _populate_transactions_and_card_events(
    batch: SyntheticBatch,
    config: GeneratorConfig,
    rng: random.Random,
    fake: Faker,
    start_at: datetime,
) -> None:
    if not batch.accounts:
        return

    total_txns = int(config.duration_seconds * config.tps)
    if total_txns <= 0:
        return

    # Spread transactions uniformly across the window, then jitter each by
    # up to half a slot so they don't align on tick boundaries.
    slot = timedelta(seconds=config.duration_seconds / total_txns)

    for i in range(total_txns):
        account = rng.choice(batch.accounts)
        txn_type = _weighted_choice(rng, _TXN_TYPE_WEIGHTS)
        direction = TxnDirection.DEBIT if txn_type in _DEBIT_TYPES else TxnDirection.CREDIT
        amount = _sample_amount(rng, txn_type)
        occurred_at = (
            start_at + slot * i + timedelta(seconds=rng.uniform(0, slot.total_seconds() / 2))
        )
        txn = Transaction(
            transaction_id=uuid.UUID(int=rng.getrandbits(128)),
            account=account,
            amount=amount,
            currency="USD",
            direction=direction,
            transaction_type=txn_type,
            status=TxnStatus.POSTED,
            description=_describe(rng, txn_type, fake),
            posted_at=occurred_at,
            created_at=occurred_at,
            updated_at=occurred_at,
        )
        batch.transactions.append(txn)

        if txn_type in _CARD_TXN_TYPES:
            # Passing ``account=account`` (the relationship attribute) lets
            # SQLAlchemy resolve ``account_id`` on flush after the accounts
            # table gets its DB-assigned ids.
            batch.card_events.append(
                CardEvent(
                    event_id=uuid.UUID(int=rng.getrandbits(128)),
                    account=account,
                    transaction_id=txn.transaction_id,
                    card_last4=f"{rng.randint(0, 9999):04d}",
                    event_type=CardEventType.CAPTURE,
                    amount=amount,
                    currency="USD",
                    merchant_name=fake.company(),
                    merchant_mcc=rng.choice(_MCC_SAMPLES),
                    occurred_at=occurred_at,
                    created_at=occurred_at,
                )
            )


def _sample_amount(rng: random.Random, txn_type: TxnType) -> Decimal:
    """Amount distributions per transaction type (all in USD)."""
    ranges: dict[TxnType, tuple[float, float]] = {
        TxnType.PURCHASE: (2.00, 250.00),
        TxnType.DEPOSIT: (100.00, 3_000.00),
        TxnType.WITHDRAWAL: (20.00, 500.00),
        TxnType.TRANSFER_IN: (50.00, 2_000.00),
        TxnType.TRANSFER_OUT: (50.00, 2_000.00),
        TxnType.FEE: (1.00, 35.00),
        TxnType.INTEREST: (0.05, 15.00),
    }
    lo, hi = ranges[txn_type]
    return Decimal(f"{rng.uniform(lo, hi):.2f}")


def _describe(rng: random.Random, txn_type: TxnType, fake: Faker) -> str:
    if txn_type is TxnType.PURCHASE:
        return f"POS {fake.company()}"
    if txn_type is TxnType.DEPOSIT:
        return "ACH deposit"
    if txn_type is TxnType.WITHDRAWAL:
        return "ATM withdrawal"
    if txn_type is TxnType.TRANSFER_IN:
        return "Incoming transfer"
    if txn_type is TxnType.TRANSFER_OUT:
        return "Outgoing transfer"
    if txn_type is TxnType.FEE:
        return rng.choice(("Monthly maintenance fee", "Overdraft fee", "Wire fee"))
    return "Interest payment"


# ---------------------------------------------------------------------------
# Persistence — kept out of the pure generator for testability
# ---------------------------------------------------------------------------


def persist_batch(session: Session, batch: SyntheticBatch) -> None:
    """Insert every row in ``batch`` in the correct FK order and commit once."""
    session.add_all(batch.customers)
    session.flush()  # assign customer.id so account FKs resolve
    session.add_all(batch.accounts)
    session.flush()  # assign account.id so transaction FKs resolve
    session.add_all(batch.transactions)
    session.flush()
    session.add_all(batch.card_events)
    session.commit()
