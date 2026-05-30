-- Phase 11 — zero-copy clone a prod baseline into a PR-scoped database.
--
-- The core Snowflake trick: `CREATE DATABASE ... CLONE` is metadata-only.
-- The clone shares every micro-partition with the source until something
-- is written. A full clone of a 10TB prod database costs ~0 credits + 0
-- storage until the dbt build starts writing deltas.
--
-- Blue/green workflow this file participates in:
--
--   1. On every PR open / sync:
--        a. This script runs → clones BANKING_PROD → BANKING_CI_PR_<id>
--        b. dbt build --target ci --select state:modified+ runs against
--           the clone (only touched + descendant models rebuild)
--        c. Row-count delta vs the real prod table is posted to the PR
--   2. On merge to main:
--        d. 02-promote-blue-green.sql swaps the clone into prod
--        e. 03-cleanup-clones.sql drops the clone (task-scheduled sweeper
--           handles abandoned PR branches)
--
-- The clone's lifecycle is tied to the PR, so the clone name encodes the
-- GitHub PR number. The CI driver (`.github/workflows/snowflake-blue-green.yml`)
-- passes PR_ID as a bind variable.
--
-- Idempotence: `CREATE OR REPLACE` so a re-pushed PR gets a fresh clone
-- (same name, dropped and recloned). Side effect: the PR dbt run always
-- starts from the latest prod — no stale CI state from the previous push.

USE ROLE SYSADMIN;

-- PR_ID is injected by the CI workflow. For local dry-run use a sentinel.
SET pr_id             = COALESCE($PR_ID, 'DRYRUN');
SET clone_db_name     = 'BANKING_CI_PR_' || $pr_id;
SET source_db_name    = COALESCE($SOURCE_DB, 'BANKING_PROD');

-- Zero-copy clone — share micro-partitions with the source. Any WRITE
-- the dbt build does will fork a new partition; reads of unchanged
-- tables cost nothing additional.
--
-- At statement time Snowflake snapshots the source database; subsequent
-- writes to BANKING_PROD do NOT propagate to the clone (and vice versa).
-- That's the "point-in-time" guarantee that makes CI reproducible.
CREATE OR REPLACE DATABASE IDENTIFIER($clone_db_name)
    CLONE IDENTIFIER($source_db_name);

-- Narrow the data-retention window on the clone — Time Travel default is
-- 1 day; CI clones are short-lived, so 1 day is wasteful. 0 saves fail-
-- safe credits because the clone will be dropped within hours.
ALTER DATABASE IDENTIFIER($clone_db_name)
    SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- Grants: the CI role needs full ownership of its clone (to write + drop)
-- but no access to the source. Transfer ownership so the role can both
-- modify and clean up without SYSADMIN intervention.
GRANT OWNERSHIP ON DATABASE IDENTIFIER($clone_db_name)
    TO ROLE BANKING_CI
    REVOKE CURRENT GRANTS;

GRANT USAGE ON WAREHOUSE WH_TRANSFORM_S_DEV TO ROLE BANKING_CI;

-- Verification — the clone + its row counts.
USE ROLE BANKING_CI;
USE DATABASE IDENTIFIER($clone_db_name);
SHOW SCHEMAS;

-- Headline sanity queries — every mart should have the same row count as
-- the moment the clone was taken. Run before any dbt build; expect
-- parity. Run AFTER the dbt build; the diff shows which models changed.
SELECT 'dim_customer'       AS table_name, COUNT(*) AS n FROM MARTS.DIM_CUSTOMER       UNION ALL
SELECT 'dim_account',               COUNT(*)       FROM MARTS.DIM_ACCOUNT              UNION ALL
SELECT 'fct_transactions',          COUNT(*)       FROM MARTS.FCT_TRANSACTIONS         UNION ALL
SELECT 'fct_card_events',           COUNT(*)       FROM MARTS.FCT_CARD_EVENTS;
