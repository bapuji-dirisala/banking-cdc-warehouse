-- Canonical DDL for the banking OLTP source.
--
-- Applied automatically on first boot of the compose Postgres (via
-- /docker-entrypoint-initdb.d). Also emitted by `banking-cdc oltp print-ddl`
-- so drift between the SQLAlchemy models and this file is unit-tested.

BEGIN;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

CREATE TYPE kyc_status AS ENUM ('pending', 'verified', 'rejected');
CREATE TYPE account_type AS ENUM ('checking', 'savings', 'credit');
CREATE TYPE account_status AS ENUM ('active', 'frozen', 'closed');
CREATE TYPE txn_direction AS ENUM ('debit', 'credit');
CREATE TYPE txn_type AS ENUM (
    'purchase',
    'deposit',
    'withdrawal',
    'transfer_in',
    'transfer_out',
    'fee',
    'interest'
);
CREATE TYPE txn_status AS ENUM ('pending', 'posted', 'reversed');
CREATE TYPE card_event_type AS ENUM (
    'authorization',
    'capture',
    'decline',
    'reversal',
    'refund'
);

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE customers (
    id             BIGSERIAL PRIMARY KEY,
    external_id    UUID NOT NULL UNIQUE,
    first_name     TEXT NOT NULL,
    last_name      TEXT NOT NULL,
    email          TEXT NOT NULL UNIQUE,
    phone          TEXT,
    date_of_birth  DATE NOT NULL,
    kyc_status     kyc_status NOT NULL DEFAULT 'pending',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
    id              BIGSERIAL PRIMARY KEY,
    account_number  TEXT NOT NULL UNIQUE,
    customer_id     BIGINT NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    account_type    account_type NOT NULL,
    currency        CHAR(3) NOT NULL DEFAULT 'USD',
    status          account_status NOT NULL DEFAULT 'active',
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at       TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_accounts_customer_id ON accounts (customer_id);
CREATE INDEX ix_accounts_status      ON accounts (status);

CREATE TABLE transactions (
    id                BIGSERIAL PRIMARY KEY,
    transaction_id    UUID NOT NULL UNIQUE,
    account_id        BIGINT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
    amount            NUMERIC(18, 4) NOT NULL,
    currency          CHAR(3) NOT NULL DEFAULT 'USD',
    direction         txn_direction NOT NULL,
    transaction_type  txn_type NOT NULL,
    status            txn_status NOT NULL DEFAULT 'posted',
    description       TEXT,
    posted_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_transactions_amount_nonneg CHECK (amount >= 0)
);
CREATE INDEX ix_transactions_account_id ON transactions (account_id);
CREATE INDEX ix_transactions_posted_at  ON transactions (posted_at);
CREATE INDEX ix_transactions_type       ON transactions (transaction_type);

CREATE TABLE card_events (
    id              BIGSERIAL PRIMARY KEY,
    event_id        UUID NOT NULL UNIQUE,
    account_id      BIGINT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
    transaction_id  UUID REFERENCES transactions(transaction_id) ON DELETE SET NULL,
    card_last4      CHAR(4) NOT NULL,
    event_type      card_event_type NOT NULL,
    amount          NUMERIC(18, 4) NOT NULL,
    currency        CHAR(3) NOT NULL DEFAULT 'USD',
    merchant_name   TEXT,
    merchant_mcc    CHAR(4),
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_card_events_amount_nonneg CHECK (amount >= 0)
);
CREATE INDEX ix_card_events_account_id ON card_events (account_id);
CREATE INDEX ix_card_events_occurred_at ON card_events (occurred_at);
CREATE INDEX ix_card_events_event_type  ON card_events (event_type);

-- ---------------------------------------------------------------------------
-- updated_at trigger — realistic CDC signal on every mutation
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_customers_updated_at    BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_accounts_updated_at     BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_transactions_updated_at BEFORE UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;
