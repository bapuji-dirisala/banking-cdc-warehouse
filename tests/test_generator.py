"""Unit tests for the synthetic OLTP generator.

Runs entirely in-memory — no Postgres required. The tests lock in the
shape of a synthetic batch (row counts, sign conventions, amount ranges,
FK coherence) so downstream phases can rely on it.
"""

from __future__ import annotations

from decimal import Decimal

import pytest

from banking_cdc.oltp.models import (
    AccountStatus,
    CardEventType,
    TxnDirection,
    TxnStatus,
    TxnType,
)
from banking_cdc.seed import GeneratorConfig, generate_batch


@pytest.fixture(scope="module")
def batch():
    # A modest size that is still cheap to run every commit.
    config = GeneratorConfig(customers=50, duration_seconds=30, tps=10, seed=42)
    return generate_batch(config)


def test_customer_count_matches_config(batch) -> None:
    assert len(batch.customers) == 50


def test_every_customer_has_at_least_one_account(batch) -> None:
    customer_ids_with_account = {a.customer for a in batch.accounts}
    assert customer_ids_with_account == set(batch.customers)


def test_transaction_count_matches_duration_times_tps(batch) -> None:
    assert len(batch.transactions) == 30 * 10


def test_direction_matches_transaction_type(batch) -> None:
    debit_types = {
        TxnType.PURCHASE,
        TxnType.WITHDRAWAL,
        TxnType.TRANSFER_OUT,
        TxnType.FEE,
    }
    for txn in batch.transactions:
        expected = (
            TxnDirection.DEBIT if txn.transaction_type in debit_types else TxnDirection.CREDIT
        )
        assert txn.direction is expected, txn.transaction_type


def test_amounts_are_positive_decimals(batch) -> None:
    for txn in batch.transactions:
        assert isinstance(txn.amount, Decimal)
        assert txn.amount > 0


def test_all_transactions_start_posted(batch) -> None:
    assert all(t.status is TxnStatus.POSTED for t in batch.transactions)


def test_all_accounts_start_active(batch) -> None:
    assert all(a.status is AccountStatus.ACTIVE for a in batch.accounts)


def test_card_events_only_for_purchases(batch) -> None:
    purchase_txn_ids = {
        t.transaction_id for t in batch.transactions if t.transaction_type is TxnType.PURCHASE
    }
    card_txn_ids = {ce.transaction_id for ce in batch.card_events}
    assert card_txn_ids == purchase_txn_ids


def test_card_events_are_captures_with_positive_amounts(batch) -> None:
    for ce in batch.card_events:
        assert ce.event_type is CardEventType.CAPTURE
        assert ce.amount > 0
        assert len(ce.card_last4) == 4
        assert ce.merchant_mcc is not None
        assert len(ce.merchant_mcc) == 4


def test_generator_is_deterministic() -> None:
    config = GeneratorConfig(customers=10, duration_seconds=5, tps=4, seed=1234)
    a = generate_batch(config)
    b = generate_batch(config)
    assert [c.email for c in a.customers] == [c.email for c in b.customers]
    assert [str(t.transaction_id) for t in a.transactions] == [
        str(t.transaction_id) for t in b.transactions
    ]
    assert [str(ce.event_id) for ce in a.card_events] == [str(ce.event_id) for ce in b.card_events]


def test_different_seeds_produce_different_output() -> None:
    a = generate_batch(GeneratorConfig(customers=10, duration_seconds=5, tps=4, seed=1))
    b = generate_batch(GeneratorConfig(customers=10, duration_seconds=5, tps=4, seed=2))
    assert [c.email for c in a.customers] != [c.email for c in b.customers]
