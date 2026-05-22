-- DuckDB raw schema — mirrors the Phase 1 Postgres OLTP shape, with four
-- Debezium envelope metadata columns on every table.
--
-- Applied idempotently via `banking-cdc sink init`, or manually:
--     duckdb warehouse/banking.duckdb < sql/duckdb/raw_schema.sql
--
-- The sink (src/banking_cdc/sink/duckdb_sink.py) performs DELETE-then-INSERT
-- against these tables so each message is idempotent and the current-state
-- row-per-pk invariant always holds.
--
-- The Postgres native ENUM types (kyc_status, account_type, etc.) land here
-- as VARCHAR so dbt staging can cast them explicitly without needing a
-- parallel enum definition. The CHECK constraints on the Postgres side are
-- intentionally not reproduced — the raw layer is bronze, not validated;
-- Phase 4 staging enforces shape, and Phase 9 adds the full data-quality
-- test suite.

CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.customers (
    id              BIGINT PRIMARY KEY,
    external_id     UUID,
    first_name      VARCHAR,
    last_name       VARCHAR,
    email           VARCHAR,
    phone           VARCHAR,
    date_of_birth   DATE,
    kyc_status      VARCHAR,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ,
    -- Debezium envelope metadata — Phase 4 staging reads these.
    __op            VARCHAR,            -- c | r | u | d
    __source_ts_ms  BIGINT,             -- source Postgres event time (ms)
    __lsn           BIGINT,             -- Postgres log sequence number
    __ingested_at   TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS raw.accounts (
    id              BIGINT PRIMARY KEY,
    account_number  VARCHAR,
    customer_id     BIGINT,
    account_type    VARCHAR,
    currency        VARCHAR,
    status          VARCHAR,
    opened_at       TIMESTAMPTZ,
    closed_at       TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ,
    __op            VARCHAR,
    __source_ts_ms  BIGINT,
    __lsn           BIGINT,
    __ingested_at   TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS raw.transactions (
    id                BIGINT PRIMARY KEY,
    transaction_id    UUID,
    account_id        BIGINT,
    amount            DECIMAL(18, 4),
    currency          VARCHAR,
    direction         VARCHAR,
    transaction_type  VARCHAR,
    status            VARCHAR,
    description       VARCHAR,
    posted_at         TIMESTAMPTZ,
    created_at        TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ,
    __op              VARCHAR,
    __source_ts_ms    BIGINT,
    __lsn             BIGINT,
    __ingested_at     TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS raw.card_events (
    id              BIGINT PRIMARY KEY,
    event_id        UUID,
    account_id      BIGINT,
    transaction_id  UUID,
    card_last4      VARCHAR,
    event_type      VARCHAR,
    amount          DECIMAL(18, 4),
    currency        VARCHAR,
    merchant_name   VARCHAR,
    merchant_mcc    VARCHAR,
    occurred_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ,
    __op            VARCHAR,
    __source_ts_ms  BIGINT,
    __lsn           BIGINT,
    __ingested_at   TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
