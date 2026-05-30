-- Phase 10 — operational inventory + health queries.
--
-- Runnable immediately after any of 01-05 apply so a reviewer can see
-- what landed. Everything is read-only.

USE ROLE SYSADMIN;

-- 1. All resource monitors with current + remaining credits.
SHOW RESOURCE MONITORS;
SELECT
    "name",
    "credit_quota",
    "used_credits",
    "remaining_credits",
    "frequency",
    "level",
    "start_time",
    "end_time",
    "suspend_at",
    "suspend_immediately_at"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";

-- 2. Warehouses + tuning parameters.
SHOW WAREHOUSES;
SELECT
    "name",
    "size",
    "min_cluster_count",
    "max_cluster_count",
    "scaling_policy",
    "auto_suspend",
    "auto_resume",
    "resource_monitor",
    "state"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";

-- 3. Current session timeouts per warehouse (requires SHOW PARAMETERS,
-- scoped per-warehouse).
SHOW PARAMETERS LIKE 'STATEMENT_TIMEOUT_IN_SECONDS' IN WAREHOUSE WH_TRANSFORM_S;
SHOW PARAMETERS LIKE 'STATEMENT_QUEUED_TIMEOUT_IN_SECONDS' IN WAREHOUSE WH_TRANSFORM_S;

-- 4. Clustering status on marts.FCT_TRANSACTIONS.
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'BANKING_PROD.MARTS.FCT_TRANSACTIONS',
    '(posted_date, account_id)'
) AS fct_transactions_clustering;

-- 5. Smoke-test the notification integration (dry-run, no email sent).
SHOW INTEGRATIONS LIKE 'NI_BANKING_CDC_PAGER';

-- 6. "Did the dbt query_tag macro land?" — look for recent tagged queries.
USE ROLE ACCOUNTADMIN;
SELECT
    START_TIME,
    WAREHOUSE_NAME,
    QUERY_TAG,
    LEFT(QUERY_TEXT, 120)                   AS query_preview
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
  AND QUERY_TAG ILIKE '%banking_cdc_warehouse%'
ORDER BY START_TIME DESC
LIMIT 10;
