-- GDPR Article 17 — Right-to-be-Forgotten erasure template.
--
-- Dynamic masking (02-masking-policies.sql) HIDES data. Article 17
-- requires ERASURE — physical deletion or irreversible anonymisation.
-- Masking + erasure are complementary, not alternatives.
--
-- Workflow:
--   1. Legal receives + validates the data subject's request.
--   2. Platform engineer runs this template, filling in the SUBJECT_*
--      bind variables. Snowflake-connector-python / snowsql both
--      support positional / named bind variables; the template uses
--      :subject_customer_id for clarity.
--   3. Platform engineer uploads the audit log entry to the
--      compliance system (see Phase 10 operational runbook — not yet
--      shipped).
--
-- Idempotence note: safe to re-run. Rows already deleted are no-ops.
-- The audit log row is INSERTed every time to document each attempt.
--
-- Transaction note: everything runs inside one explicit transaction so
-- a partial failure rolls back cleanly. The compliance audit INSERT
-- is intentionally OUTSIDE the transaction — we want the attempt
-- logged even if the erasure itself fails.

USE DATABASE BANKING_PROD;
USE ROLE BANKING_ENGINEER;  -- requires DELETE on every schema below

-- Fill in before running:
SET subject_customer_id       = -1;                        -- the BIGINT PK from OLTP
SET subject_external_id       = '00000000-0000-0000-0000-000000000000';
SET erasure_ticket_id         = 'LEGAL-TICKET-REPLACE-ME';
SET requested_by              = 'legal.erasure@banking.example';

BEGIN TRANSACTION;

-- Delete from every mart that materialises the subject's attributes.
DELETE FROM BANKING_PROD.MARTS.DIM_CUSTOMER
    WHERE customer_id = $subject_customer_id;

DELETE FROM BANKING_PROD.MARTS.DIM_CUSTOMER_SCD2
    WHERE customer_id = $subject_customer_id;

-- Facts: we DO retain the transaction's financial facts (regulatory
-- reporting trumps erasure for ledger entries — this is a documented
-- carve-out under GDPR Article 17(3)(b)), but we tombstone the
-- customer linkage so the row can't be re-identified.
UPDATE BANKING_PROD.MARTS.FCT_TRANSACTIONS
    SET customer_sk = NULL,
        customer_id = NULL
    WHERE customer_id = $subject_customer_id;

UPDATE BANKING_PROD.MARTS.FCT_CARD_EVENTS
    SET customer_sk = NULL
    WHERE account_sk IN (
        SELECT account_sk
        FROM BANKING_PROD.MARTS.DIM_ACCOUNT
        WHERE customer_id = $subject_customer_id
    );

-- Delete from the aggregates — they're derived; recomputed on next
-- dbt build will omit the deleted rows naturally.
DELETE FROM BANKING_PROD.MARTS.AGG_MONTHLY_CUSTOMER_REVENUE
    WHERE customer_id = $subject_customer_id;

-- Delete from the consumer views? No — they're views over marts, so
-- the deletion cascades automatically on next query.

-- SCD2 snapshot — the full history goes.
DELETE FROM BANKING_PROD.SNAPSHOTS.SNAP_BANKING__CUSTOMERS
    WHERE customer_id = $subject_customer_id;

-- Staging and raw retain the data for the full regulatory window
-- (RETENTION_CLASS = '7y' per the Phase 8 tag). Erasure flips those
-- to anonymised placeholders so no identifier survives:
UPDATE BANKING_PROD.STAGING.STG_CUSTOMERS
    SET email         = NULL,
        phone         = NULL,
        first_name    = '[ERASED]',
        last_name     = '[ERASED]',
        date_of_birth = NULL,
        external_id   = NULL
    WHERE customer_id = $subject_customer_id;

-- Raw.* is append-only in prod; UPDATE rewrites the stored row image.
-- A mature setup would also schedule a FAIL-SAFE expiry (DATA_RETENTION
-- + Time Travel) rollback window — Snowflake retains deleted rows for
-- up to 90 days by default. Document this to Legal: erasure is "logical
-- in 0s, physical in 90 days".
UPDATE BANKING_PROD.RAW.CUSTOMERS
    SET email         = NULL,
        phone         = NULL,
        first_name    = '[ERASED]',
        last_name     = '[ERASED]',
        date_of_birth = NULL,
        external_id   = NULL
    WHERE id = $subject_customer_id;

COMMIT;

-- Audit log — INSERT runs regardless of transaction success/failure.
-- (The ADMIN schema + ERASURE_AUDIT_LOG table are Phase 10 artifacts;
-- stub shown here so the end-to-end flow is reviewable.)
--
-- INSERT INTO BANKING_PROD.ADMIN.ERASURE_AUDIT_LOG (
--     erasure_ticket_id, subject_customer_id, subject_external_id,
--     requested_by, executed_by, executed_at
-- ) VALUES (
--     $erasure_ticket_id, $subject_customer_id, $subject_external_id,
--     $requested_by, CURRENT_USER(), CURRENT_TIMESTAMP()
-- );
