-- Phase 11 — blue/green promotion via Snowflake database SWAP.
--
-- The promotion step every nightly build runs after a successful full
-- build on a clone of prod. Semantics:
--
--   BEFORE:   BANKING_PROD   ← readers (BI, Airflow, consumers)
--             BANKING_BUILD  ← freshly-built clone, dbt build succeeded
--
--   SWAP:     ALTER DATABASE BANKING_PROD SWAP WITH BANKING_BUILD;
--
--   AFTER:    BANKING_PROD   ← freshly-built data (atomic from readers)
--             BANKING_BUILD  ← previous prod (becomes the rollback snapshot)
--
-- SWAP is atomic — a reader querying `BANKING_PROD.MARTS.FCT_TRANSACTIONS`
-- at the moment of swap sees either the old content (fully) or the new
-- content (fully), never a mix. No lock-step orchestration with BI tools
-- required.
--
-- Rollback: run the SWAP again — the old prod is still sitting there as
-- BANKING_BUILD. Zero-downtime, zero-data-loss revert.
--
-- Grants: SWAP preserves grants on the names, not on the content. The
-- GRANT USAGE on BANKING_PROD stays attached to the name BANKING_PROD —
-- so BI readers never lose access and never need to switch connection
-- strings.
--
-- Why not CLONE + rename? Because rename isn't atomic from the reader's
-- POV. A dashboard mid-query during a 2-step rename would get a "database
-- doesn't exist" error. SWAP is the only correct primitive.

USE ROLE SYSADMIN;

-- These are set by the CI driver; drop in defaults for a local dry-run.
SET pr_id                = COALESCE($PR_ID, 'DRYRUN');
SET build_db_name        = COALESCE($BUILD_DB, 'BANKING_CI_PR_' || $pr_id);
SET prod_db_name         = COALESCE($PROD_DB,  'BANKING_PROD');
SET rollback_marker      = 'BANKING_ROLLBACK_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS');

----------------------------------------------------------------------
-- Preflight — fail loud if the build clone is missing or empty.
----------------------------------------------------------------------
EXECUTE IMMEDIATE $$
    DECLARE
        n_rows NUMBER;
    BEGIN
        SELECT COUNT(*) INTO :n_rows
        FROM IDENTIFIER($build_db_name || '.MARTS.FCT_TRANSACTIONS');
        IF (:n_rows = 0) THEN
            RAISE STATEMENT_ERROR;
            -- A sophisticated version would include RETURN a message here;
            -- shortened for template clarity.
        END IF;
    END;
$$;

----------------------------------------------------------------------
-- Promotion — the atomic swap. Readers see new content immediately.
----------------------------------------------------------------------
ALTER DATABASE IDENTIFIER($prod_db_name)
    SWAP WITH IDENTIFIER($build_db_name);

-- After the swap:
--   The NAME `BANKING_PROD` now points at the freshly-built content.
--   The NAME `BANKING_CI_PR_<n>` now points at the previous prod — our
--   zero-cost rollback snapshot.

-- Rename the ex-prod to a date-stamped rollback marker so a future
-- `03-cleanup-clones.sql` run doesn't sweep it with the regular PR clones.
ALTER DATABASE IDENTIFIER($build_db_name)
    RENAME TO IDENTIFIER($rollback_marker);

-- Narrow retention on the rollback copy; keep 7 days of history then let
-- the cleanup sweeper drop it.
ALTER DATABASE IDENTIFIER($rollback_marker)
    SET DATA_RETENTION_TIME_IN_DAYS = 7;

----------------------------------------------------------------------
-- Verification — basic row counts on the new prod.
----------------------------------------------------------------------
USE DATABASE IDENTIFIER($prod_db_name);
SELECT 'dim_customer'       AS table_name, COUNT(*) AS n FROM MARTS.DIM_CUSTOMER       UNION ALL
SELECT 'dim_account',               COUNT(*)       FROM MARTS.DIM_ACCOUNT              UNION ALL
SELECT 'fct_transactions',          COUNT(*)       FROM MARTS.FCT_TRANSACTIONS         UNION ALL
SELECT 'fct_card_events',           COUNT(*)       FROM MARTS.FCT_CARD_EVENTS;

----------------------------------------------------------------------
-- Rollback template — commented out intentionally. Uncomment + fill in
-- the rollback marker name to restore the previous prod. ONLY run under
-- incident declaration; the swap in BOTH directions is cheap but readers
-- will see the content revert.
----------------------------------------------------------------------
-- ALTER DATABASE BANKING_PROD SWAP WITH BANKING_ROLLBACK_<timestamp>;
