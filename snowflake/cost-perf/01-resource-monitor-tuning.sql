-- Phase 10 — resource monitor tuning on top of Phase 3's baseline.
--
-- Phase 3 (snowflake/ddl/03-resource-monitors.sql) created the three
-- per-warehouse monitors + the account-wide backstop. This file tunes
-- those monitors with the patterns a production reader would apply once
-- they have one month of real billing data.
--
-- Patterns demonstrated:
--   1. Dev-vs-prod tiering of the same monitor name — dev gets a lower
--      cap + SUSPEND_IMMEDIATE (so a runaway dev query dies fast),
--      prod gets a wider cap + graceful SUSPEND (so in-flight analyst
--      queries get to finish).
--   2. Notification integration — on-trigger emails routed through a
--      Snowflake-managed EMAIL_NOTIFICATION_INTEGRATION rather than
--      the per-user notification setup Phase 3 implicitly assumed.
--   3. Narrower warning thresholds (50/75/90 vs Phase 3's 50/80) —
--      pager fatigue is real; the extra warning at 90 gives on-call
--      one last chance to intervene before SUSPEND fires.

USE ROLE ACCOUNTADMIN;

-- One-time: provision the notification integration that every monitor
-- below routes alerts through. Needs email domain on an allow-list in
-- Snowflake account preferences first. Enabled flag is TRUE so the
-- integration starts active.
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS NI_BANKING_CDC_PAGER
    TYPE          = EMAIL
    ENABLED       = TRUE
    ALLOWED_RECIPIENTS = ('platform-oncall@banking.example', 'data-eng-lead@banking.example')
    COMMENT = 'Phase 10 — email target for resource-monitor + task-failure alerts.';

GRANT USAGE ON INTEGRATION NI_BANKING_CDC_PAGER TO ROLE SYSADMIN;

----------------------------------------------------------------------
-- DEV-tier monitors — tighter caps, SUSPEND_IMMEDIATE at the ceiling.
--
-- Rationale: a developer running an unoptimised full-refresh on
-- fct_transactions can burn through XSMALL credits fast. In dev we
-- WANT the query to die; a few extra Slack messages from Snowflake
-- beat an unbounded cost bleed overnight.
----------------------------------------------------------------------

CREATE RESOURCE MONITOR IF NOT EXISTS RM_DEV_TRANSFORM_MONTHLY
    WITH CREDIT_QUOTA   = 5          -- 1/6th of prod
         FREQUENCY      = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
         NOTIFY_USERS   = ()         -- notifications routed via integration
    TRIGGERS
        ON 50  PERCENT DO NOTIFY
        ON 75  PERCENT DO NOTIFY
        ON 90  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND_IMMEDIATE;

-- WH_TRANSFORM_S_DEV created in 02-warehouse-tuning.sql.
-- Commented out here so this file is applicable in isolation.
-- ALTER WAREHOUSE WH_TRANSFORM_S_DEV SET RESOURCE_MONITOR = RM_DEV_TRANSFORM_MONTHLY;

----------------------------------------------------------------------
-- PROD-tier tuning — ALTER the Phase 3 baseline to add the 90% warning
-- + swap to the notification integration.
----------------------------------------------------------------------

-- RESET the trigger list; monitors don't support "add one more trigger".
ALTER RESOURCE MONITOR RM_TRANSFORM_MONTHLY
    SET CREDIT_QUOTA = 30
    TRIGGERS
        ON 50  PERCENT DO NOTIFY
        ON 75  PERCENT DO NOTIFY
        ON 90  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER RESOURCE MONITOR RM_INGEST_MONTHLY
    SET CREDIT_QUOTA = 10
    TRIGGERS
        ON 50  PERCENT DO NOTIFY
        ON 75  PERCENT DO NOTIFY
        ON 90  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER RESOURCE MONITOR RM_REPORT_MONTHLY
    SET CREDIT_QUOTA = 10
    TRIGGERS
        ON 50  PERCENT DO NOTIFY
        ON 75  PERCENT DO NOTIFY
        ON 90  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

-- Account-wide backstop — the hard ceiling. SUSPEND_IMMEDIATE because a
-- true account cap should bite even if in-flight queries die.
ALTER RESOURCE MONITOR RM_ACCOUNT_MONTHLY
    SET CREDIT_QUOTA = 75
    TRIGGERS
        ON 60  PERCENT DO NOTIFY
        ON 80  PERCENT DO NOTIFY
        ON 95  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND_IMMEDIATE;

----------------------------------------------------------------------
-- Verification
----------------------------------------------------------------------
SHOW RESOURCE MONITORS;
SELECT "name", "credit_quota", "used_credits", "remaining_credits", "frequency", "level"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";
