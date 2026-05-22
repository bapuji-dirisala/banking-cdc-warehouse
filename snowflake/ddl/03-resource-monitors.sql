-- Resource monitors — belt-and-braces credit control.
--
-- Each warehouse has its own monthly monitor. A separate account-level
-- monitor caps total monthly spend across all warehouses as a backstop.
--
-- Actions escalate: NOTIFY at 50% and 80%, SUSPEND at 100%. Not
-- SUSPEND_IMMEDIATE — the handful of in-flight queries that finish at the
-- cap are worth the smoother operator experience over data-platform-wide
-- query failures.
--
-- Thresholds are portfolio-scale (10-30 credits/month per warehouse,
-- 75 account-wide). A production reader would tune these from actual
-- monthly billing data.

USE ROLE ACCOUNTADMIN;

-- WH_INGEST_XS — expected to be very small (Kafka Connector is light).
CREATE RESOURCE MONITOR IF NOT EXISTS RM_INGEST_MONTHLY
    WITH CREDIT_QUOTA   = 10
         FREQUENCY      = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 50  PERCENT DO NOTIFY
        ON 80  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE WH_INGEST_XS SET RESOURCE_MONITOR = RM_INGEST_MONTHLY;

-- WH_TRANSFORM_S — the biggest consumer; dbt builds + GE runs.
CREATE RESOURCE MONITOR IF NOT EXISTS RM_TRANSFORM_MONTHLY
    WITH CREDIT_QUOTA   = 30
         FREQUENCY      = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 50  PERCENT DO NOTIFY
        ON 80  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE WH_TRANSFORM_S SET RESOURCE_MONITOR = RM_TRANSFORM_MONTHLY;

-- WH_REPORT_XS — BI concurrency; generally small per query but many queries.
CREATE RESOURCE MONITOR IF NOT EXISTS RM_REPORT_MONTHLY
    WITH CREDIT_QUOTA   = 10
         FREQUENCY      = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 50  PERCENT DO NOTIFY
        ON 80  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE WH_REPORT_XS SET RESOURCE_MONITOR = RM_REPORT_MONTHLY;

-- Account-level cap — hard ceiling across every warehouse combined. The
-- backstop against runaway bills. SUSPEND_IMMEDIATE at 100% because a true
-- account-wide cap should bite even if that means killing in-flight queries.
CREATE RESOURCE MONITOR IF NOT EXISTS RM_ACCOUNT_MONTHLY
    WITH CREDIT_QUOTA   = 75
         FREQUENCY      = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75  PERCENT DO NOTIFY
        ON 90  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER ACCOUNT SET RESOURCE_MONITOR = RM_ACCOUNT_MONTHLY;
