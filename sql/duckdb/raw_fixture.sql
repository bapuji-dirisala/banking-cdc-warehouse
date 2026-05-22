-- Tiny deterministic fixture for the dev + CI dbt loop.
--
-- Three customers, two accounts, three transactions, two card events —
-- enough to exercise:
--   * primary-key uniqueness tests in staging
--   * accepted_values on every enum column
--   * relationships from fact → dim
--   * latest-LSN-wins dedup (customer id=1 has two change events; the
--     later one with __lsn=200 must win)
--
-- This file is intentionally re-runnable: it DELETEs rows by PK before
-- re-inserting, so `dbt build` in CI stays idempotent even if the raw
-- fixture is applied twice. (It won't be in CI, but the discipline
-- matters.)

DELETE FROM raw.card_events  WHERE id IN (1, 2);
DELETE FROM raw.transactions WHERE id IN (1, 2, 3);
DELETE FROM raw.accounts     WHERE id IN (1, 2);
DELETE FROM raw.customers    WHERE id IN (1, 2, 3);

-- customers -------------------------------------------------------------
-- id=1 arrives as a snapshot (op=r) then is updated (op=u). The dedup
-- in staging must emit the kyc_status='verified' row, not 'pending'.
INSERT INTO raw.customers VALUES
  (1, '11111111-1111-1111-1111-111111111111', 'Ada', 'Lovelace',
   'ada@example.com', NULL, DATE '1815-12-10', 'pending',
   TIMESTAMPTZ '2024-01-01 00:00:00Z', TIMESTAMPTZ '2024-01-01 00:00:00Z',
   'r', 1700000000000, 100, CURRENT_TIMESTAMP),
  (1, '11111111-1111-1111-1111-111111111111', 'Ada', 'Lovelace',
   'ada@example.com', '555-0100', DATE '1815-12-10', 'verified',
   TIMESTAMPTZ '2024-02-01 00:00:00Z', TIMESTAMPTZ '2024-02-01 00:00:00Z',
   'u', 1700000001000, 200, CURRENT_TIMESTAMP),

  (2, '22222222-2222-2222-2222-222222222222', 'Grace', 'Hopper',
   'grace@example.com', NULL, DATE '1906-12-09', 'verified',
   TIMESTAMPTZ '2024-01-02 00:00:00Z', TIMESTAMPTZ '2024-01-02 00:00:00Z',
   'c', 1700000010000, 110, CURRENT_TIMESTAMP),

  (3, '33333333-3333-3333-3333-333333333333', 'Alan', 'Turing',
   'alan@example.com', NULL, DATE '1912-06-23', 'rejected',
   TIMESTAMPTZ '2024-01-03 00:00:00Z', TIMESTAMPTZ '2024-01-03 00:00:00Z',
   'c', 1700000020000, 120, CURRENT_TIMESTAMP);

-- accounts --------------------------------------------------------------
INSERT INTO raw.accounts VALUES
  (1, 'ACCT-0001', 1, 'checking', 'USD', 'active',
   TIMESTAMPTZ '2024-01-05 00:00:00Z', NULL, TIMESTAMPTZ '2024-01-05 00:00:00Z',
   'c', 1700000030000, 130, CURRENT_TIMESTAMP),
  (2, 'ACCT-0002', 2, 'savings',  'USD', 'active',
   TIMESTAMPTZ '2024-01-06 00:00:00Z', NULL, TIMESTAMPTZ '2024-01-06 00:00:00Z',
   'c', 1700000040000, 140, CURRENT_TIMESTAMP);

-- transactions ----------------------------------------------------------
-- id=1 flips status pending → posted. Dedup must emit 'posted'.
INSERT INTO raw.transactions VALUES
  (1, '44444444-4444-4444-4444-444444444444', 1, 42.5000, 'USD', 'debit',
   'purchase', 'pending', 'coffee', TIMESTAMPTZ '2024-02-10 09:00:00Z',
   TIMESTAMPTZ '2024-02-10 09:00:00Z', TIMESTAMPTZ '2024-02-10 09:00:00Z',
   'c', 1700000050000, 150, CURRENT_TIMESTAMP),
  (1, '44444444-4444-4444-4444-444444444444', 1, 42.5000, 'USD', 'debit',
   'purchase', 'posted', 'coffee', TIMESTAMPTZ '2024-02-10 09:00:00Z',
   TIMESTAMPTZ '2024-02-10 09:00:00Z', TIMESTAMPTZ '2024-02-10 09:05:00Z',
   'u', 1700000051000, 160, CURRENT_TIMESTAMP),

  (2, '55555555-5555-5555-5555-555555555555', 1, 1500.0000, 'USD', 'credit',
   'deposit', 'posted', 'payroll', TIMESTAMPTZ '2024-02-11 00:00:00Z',
   TIMESTAMPTZ '2024-02-11 00:00:00Z', TIMESTAMPTZ '2024-02-11 00:00:00Z',
   'c', 1700000060000, 170, CURRENT_TIMESTAMP),

  (3, '66666666-6666-6666-6666-666666666666', 2, 200.0000, 'USD', 'debit',
   'withdrawal', 'posted', 'atm', TIMESTAMPTZ '2024-02-12 00:00:00Z',
   TIMESTAMPTZ '2024-02-12 00:00:00Z', TIMESTAMPTZ '2024-02-12 00:00:00Z',
   'c', 1700000070000, 180, CURRENT_TIMESTAMP);

-- card_events -----------------------------------------------------------
INSERT INTO raw.card_events VALUES
  (1, '77777777-7777-7777-7777-777777777777', 1,
   '44444444-4444-4444-4444-444444444444', '4242', 'authorization',
   42.5000, 'USD', 'Coffee Shop', '5814',
   TIMESTAMPTZ '2024-02-10 09:00:00Z', TIMESTAMPTZ '2024-02-10 09:00:00Z',
   'c', 1700000055000, 165, CURRENT_TIMESTAMP),
  (2, '88888888-8888-8888-8888-888888888888', 1,
   '44444444-4444-4444-4444-444444444444', '4242', 'capture',
   42.5000, 'USD', 'Coffee Shop', '5814',
   TIMESTAMPTZ '2024-02-10 09:05:00Z', TIMESTAMPTZ '2024-02-10 09:05:00Z',
   'c', 1700000056000, 175, CURRENT_TIMESTAMP);
