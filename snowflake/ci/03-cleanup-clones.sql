-- Phase 11 — scheduled sweeper for PR clones + aged rollback markers.
--
-- Clones are "free" at creation but every write to the clone forks a
-- micro-partition that counts against active storage. A PR open for weeks
-- that keeps rebuilding → quietly growing storage cost. A merged PR whose
-- clone wasn't dropped at merge-time (e.g. CI timeout) → same.
--
-- The sweeper runs twice daily:
--   • Drops BANKING_CI_PR_* clones older than 7 days (open-PR TTL)
--   • Drops BANKING_ROLLBACK_* older than 7 days (rollback TTL)
--
-- Why a Task vs a GHA cron?
--   • Lives inside Snowflake — no external authentication needed
--   • Can read SNOWFLAKE.ACCOUNT_USAGE.DATABASES directly to get
--     accurate created_on timestamps
--   • Survives GHA runner outages / token expiration
--   • One place to tune the TTL

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_TRANSFORM_S_DEV;
USE DATABASE BANKING_PROD;
USE SCHEMA ADMIN;   -- Phase 10 landing-zone for operator-side objects

----------------------------------------------------------------------
-- 1. Stored procedure that enumerates sweep candidates and drops them.
--
-- Owner's rights so the task can run as SYSADMIN-equivalent without the
-- scheduler needing explicit permissions on every PR clone.
----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ADMIN.SWEEP_CI_CLONES(ttl_days NUMBER DEFAULT 7)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    cur CURSOR FOR
        SELECT DATABASE_NAME, CREATED
        FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES
        WHERE DELETED IS NULL
          AND (
                DATABASE_NAME LIKE 'BANKING_CI_PR_%'
             OR DATABASE_NAME LIKE 'BANKING_ROLLBACK_%'
          )
          AND CREATED < DATEADD('day', -:ttl_days, CURRENT_TIMESTAMP());
    dropped ARRAY DEFAULT ARRAY_CONSTRUCT();
    db_name STRING;
BEGIN
    FOR row IN cur DO
        db_name := row.DATABASE_NAME;
        -- EXECUTE IMMEDIATE is the only way to interpolate a database
        -- name into a DROP statement from inside a stored procedure.
        EXECUTE IMMEDIATE 'DROP DATABASE IF EXISTS "' || :db_name || '"';
        dropped := ARRAY_APPEND(dropped, :db_name);
    END FOR;
    RETURN OBJECT_CONSTRUCT(
        'swept_at',  CURRENT_TIMESTAMP(),
        'ttl_days',  :ttl_days,
        'dropped',   :dropped,
        'n_dropped', ARRAY_SIZE(:dropped)
    );
END;
$$;

----------------------------------------------------------------------
-- 2. Scheduled task — twice-daily sweep.
--
-- CRON: 06:00 + 18:00 UTC. Picks hours when the warehouse is likely idle
-- and the ACCOUNT_USAGE latency window has settled.
----------------------------------------------------------------------
CREATE OR REPLACE TASK ADMIN.T_SWEEP_CI_CLONES
    WAREHOUSE = WH_TRANSFORM_S_DEV
    SCHEDULE  = 'USING CRON 0 6,18 * * * UTC'
    COMMENT   = 'Phase 11 — drops BANKING_CI_PR_* + BANKING_ROLLBACK_* older than 7 days.'
AS
    CALL ADMIN.SWEEP_CI_CLONES(ttl_days => 7);

-- Tasks are created SUSPENDED; resume to activate.
ALTER TASK ADMIN.T_SWEEP_CI_CLONES RESUME;

----------------------------------------------------------------------
-- 3. On-demand run — safe to invoke by hand after a bad PR merge.
----------------------------------------------------------------------
CALL ADMIN.SWEEP_CI_CLONES(ttl_days => 7);

----------------------------------------------------------------------
-- 4. Observability — recent sweeper runs.
----------------------------------------------------------------------
SELECT
    QUERY_START_TIME,
    STATE,
    ERROR_MESSAGE,
    RETURN_VALUE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP()),
    TASK_NAME                  => 'T_SWEEP_CI_CLONES'
))
ORDER BY QUERY_START_TIME DESC;
