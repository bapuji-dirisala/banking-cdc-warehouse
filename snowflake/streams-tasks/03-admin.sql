-- Day-2 operator ergonomics for the Streams + Tasks topology.
-- All commands are idempotent and safe to re-run.

USE DATABASE BANKING_PROD;
USE ROLE BANKING_ENGINEER;

-- ---------------------------------------------------------------------
-- First-time bring-up: resume the DAG in child → root order (Snowflake
-- requires children to be resumed first, because the root fires them).
-- ---------------------------------------------------------------------
ALTER TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_CUSTOMERS   RESUME;
-- ALTER TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_ACCOUNTS    RESUME;
-- ALTER TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_TRANSACTIONS RESUME;
-- ALTER TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_CARD_EVENTS RESUME;
ALTER TASK BANKING_PROD.STAGING.TSK_STAGING_ROOT             RESUME;

-- ---------------------------------------------------------------------
-- Shutdown: suspend root first so no new fan-outs trigger, then children.
-- ---------------------------------------------------------------------
-- ALTER TASK BANKING_PROD.STAGING.TSK_STAGING_ROOT             SUSPEND;
-- ALTER TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_CUSTOMERS   SUSPEND;
-- ALTER TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_ACCOUNTS    SUSPEND;
-- ALTER TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_TRANSACTIONS SUSPEND;
-- ALTER TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_CARD_EVENTS SUSPEND;

-- ---------------------------------------------------------------------
-- Observability — one-shot queries any on-call engineer can run.
-- ---------------------------------------------------------------------

-- What's the current state of each task?
SHOW TASKS IN SCHEMA BANKING_PROD.STAGING;

-- Which streams currently have unconsumed data?
SELECT
    'STRM_RAW_CUSTOMERS'   AS stream_name,
    SYSTEM$STREAM_HAS_DATA('BANKING_PROD.STAGING.STRM_RAW_CUSTOMERS')   AS has_data
UNION ALL SELECT 'STRM_RAW_ACCOUNTS',
    SYSTEM$STREAM_HAS_DATA('BANKING_PROD.STAGING.STRM_RAW_ACCOUNTS')
UNION ALL SELECT 'STRM_RAW_TRANSACTIONS',
    SYSTEM$STREAM_HAS_DATA('BANKING_PROD.STAGING.STRM_RAW_TRANSACTIONS')
UNION ALL SELECT 'STRM_RAW_CARD_EVENTS',
    SYSTEM$STREAM_HAS_DATA('BANKING_PROD.STAGING.STRM_RAW_CARD_EVENTS');

-- Task run history — last 24 h of every task in this schema.
SELECT
    NAME,
    STATE,                      -- SUCCEEDED | FAILED | SKIPPED | ...
    SCHEDULED_TIME,
    COMPLETED_TIME,
    DATEDIFF(ms, QUERY_START_TIME, COMPLETED_TIME) AS duration_ms,
    ERROR_CODE,
    ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(hour, -24, CURRENT_TIMESTAMP()),
    TASK_NAME => 'TSK_STAGING_ROOT'
))
ORDER BY SCHEDULED_TIME DESC
LIMIT 50;

-- Count of change rows waiting in each stream (expensive — only run on-demand).
-- SELECT 'customers' AS t, COUNT(*) AS pending FROM BANKING_PROD.STAGING.STRM_RAW_CUSTOMERS
-- UNION ALL SELECT 'accounts',  COUNT(*) FROM BANKING_PROD.STAGING.STRM_RAW_ACCOUNTS;

-- ---------------------------------------------------------------------
-- Troubleshooting playbook (one-liners referenced from the Phase 10 runbook).
-- ---------------------------------------------------------------------

-- "Stream X is stale" (data older than its DATA_RETENTION_TIME_IN_DAYS):
-- recreate the stream, acknowledging that un-consumed data is lost.
-- CREATE OR REPLACE STREAM BANKING_PROD.STAGING.STRM_RAW_CUSTOMERS ...

-- "Task is skipping" — WHEN predicate evaluates false. Check with:
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'TSK_STAGING_ROOT'))
-- WHERE STATE = 'SKIPPED' ORDER BY SCHEDULED_TIME DESC LIMIT 20;

-- "I want to force one run right now, outside the schedule":
-- EXECUTE TASK BANKING_PROD.STAGING.TSK_STAGING_ROOT;
