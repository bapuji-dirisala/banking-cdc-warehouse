-- Phase 10 — ACCOUNT_USAGE investigation set.
--
-- Every query here is runnable as-is against SNOWFLAKE.ACCOUNT_USAGE
-- (ACCOUNTADMIN by default — grant IMPORTED PRIVILEGES ON DATABASE
-- SNOWFLAKE to a FinOps role if you want to delegate).
--
-- Latency note: ACCOUNT_USAGE views have a documented latency of up to
-- 45 min for the usage views and up to 3 hours for query_history. For
-- real-time investigation use INFORMATION_SCHEMA.QUERY_HISTORY (last 7
-- days, same shape, no delay).
--
-- Grouping:
--   §1  — top-cost consumers (who's burning credits?)
--   §2  — slow queries (where to spend the perf-tuning hour?)
--   §3  — warehouse health (sized right? queueing? spilling?)
--   §4  — storage + cloud-services credits (the hidden-cost drawer)

USE ROLE ACCOUNTADMIN;

----------------------------------------------------------------------
-- §1 — Top-cost consumers (last 30 days).
----------------------------------------------------------------------

-- Credits by warehouse.
SELECT
    WAREHOUSE_NAME,
    SUM(CREDITS_USED)                               AS warehouse_credits,
    SUM(CREDITS_USED_CLOUD_SERVICES)                AS cloud_services_credits,
    ROUND(SUM(CREDITS_USED) * 2.00, 2)              AS approx_usd_at_std_rate
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY warehouse_credits DESC;

-- Credits by user (identifies the human / service account burning the most).
SELECT
    USER_NAME,
    COUNT(*)                                        AS n_queries,
    SUM(TOTAL_ELAPSED_TIME) / 1000.0 / 3600.0       AS warehouse_hours,
    SUM(CREDITS_USED_CLOUD_SERVICES)                AS cloud_services_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY warehouse_hours DESC
LIMIT 25;

-- Credits by model (requires Phase 10 query-tag macro to be wired).
SELECT
    PARSE_JSON(QUERY_TAG):model::STRING             AS model_name,
    PARSE_JSON(QUERY_TAG):materialization::STRING   AS materialization,
    COUNT(*)                                        AS n_runs,
    AVG(TOTAL_ELAPSED_TIME) / 1000.0                AS avg_seconds,
    SUM(TOTAL_ELAPSED_TIME) / 1000.0 / 3600.0       AS total_warehouse_hours
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND PARSE_JSON(QUERY_TAG):project::STRING = 'banking_cdc_warehouse'
  AND PARSE_JSON(QUERY_TAG):model IS NOT NULL
GROUP BY 1, 2
ORDER BY total_warehouse_hours DESC
LIMIT 25;

----------------------------------------------------------------------
-- §2 — Slow queries (last 7 days).
----------------------------------------------------------------------

-- Slowest 25 queries, excluding the obvious ETL loads.
SELECT
    QUERY_ID,
    START_TIME,
    USER_NAME,
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    TOTAL_ELAPSED_TIME / 1000               AS seconds,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    BYTES_SCANNED,
    BYTES_SPILLED_TO_LOCAL_STORAGE,
    BYTES_SPILLED_TO_REMOTE_STORAGE,
    PERCENTAGE_SCANNED_FROM_CACHE,
    LEFT(QUERY_TEXT, 200)                   AS query_preview
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
  AND QUERY_TYPE = 'SELECT'
ORDER BY TOTAL_ELAPSED_TIME DESC
LIMIT 25;

-- Queries with REMOTE spill — the smoking gun for undersized warehouses.
-- Any non-zero remote spill means Snowflake was swapping to object
-- storage because warehouse memory couldn't hold the working set.
SELECT
    QUERY_ID,
    START_TIME,
    USER_NAME,
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    TOTAL_ELAPSED_TIME / 1000               AS seconds,
    BYTES_SPILLED_TO_REMOTE_STORAGE / POW(1024,3) AS gb_spilled_remote,
    LEFT(QUERY_TEXT, 200)                   AS query_preview
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND BYTES_SPILLED_TO_REMOTE_STORAGE > 0
ORDER BY BYTES_SPILLED_TO_REMOTE_STORAGE DESC
LIMIT 25;

-- Queries with poor pruning — PARTITIONS_SCANNED/PARTITIONS_TOTAL > 0.5
-- means the predicate isn't selective. Candidate for a clustering key
-- (if the table is big) or a schema redesign (if it's not).
SELECT
    QUERY_ID,
    START_TIME,
    WAREHOUSE_NAME,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROUND(PARTITIONS_SCANNED * 100.0 / NULLIF(PARTITIONS_TOTAL, 0), 2) AS pct_scanned,
    LEFT(QUERY_TEXT, 200)                   AS query_preview
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND PARTITIONS_TOTAL > 100   -- ignore trivially-small tables
  AND PARTITIONS_SCANNED * 1.0 / PARTITIONS_TOTAL > 0.5
  AND QUERY_TYPE = 'SELECT'
ORDER BY PARTITIONS_SCANNED DESC
LIMIT 25;

----------------------------------------------------------------------
-- §3 — Warehouse health.
----------------------------------------------------------------------

-- Warehouse load percentage — "how busy is this warehouse really?"
-- Values > 50% consistently → candidate for size-up or MAX_CLUSTER_COUNT
-- bump. Values < 10% consistently → candidate for size-down.
SELECT
    WAREHOUSE_NAME,
    DATE_TRUNC('hour', START_TIME)          AS hour,
    AVG(AVG_RUNNING)                        AS avg_running_queries,
    AVG(AVG_QUEUED_LOAD)                    AS avg_queued_on_load,
    AVG(AVG_QUEUED_PROVISIONING)            AS avg_queued_on_provisioning,
    AVG(AVG_BLOCKED)                        AS avg_blocked
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1, 2 DESC;

-- Queueing — if these are chronically > 0, bump MAX_CLUSTER_COUNT.
-- From the 60-30-10 rule in 02-warehouse-tuning.sql: 30%+ queueing →
-- raise the max.
SELECT
    WAREHOUSE_NAME,
    COUNT(*)                                            AS n_queries,
    AVG(QUEUED_PROVISIONING_TIME) / 1000.0              AS avg_queue_seconds,
    SUM(IFF(QUEUED_PROVISIONING_TIME > 0, 1, 0)) * 100.0
        / COUNT(*)                                       AS pct_queries_queued
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY pct_queries_queued DESC;

----------------------------------------------------------------------
-- §4 — Hidden costs: storage + cloud services.
----------------------------------------------------------------------

-- Daily storage credits (dbt builds + Time Travel + Fail-Safe).
SELECT
    USAGE_DATE,
    STORAGE_BYTES          / POW(1024,4) AS tb_active_storage,
    STAGE_BYTES            / POW(1024,4) AS tb_stage_storage,
    FAILSAFE_BYTES         / POW(1024,4) AS tb_failsafe
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY USAGE_DATE DESC;

-- Cloud-services credits (the ones that bite silently). Snowflake only
-- charges for cloud services above 10% of daily warehouse credits —
-- but you still want to see the trend.
SELECT
    DATE_TRUNC('day', START_TIME)          AS activity_day,
    SUM(CREDITS_USED_COMPUTE)              AS compute_credits,
    SUM(CREDITS_USED_CLOUD_SERVICES)       AS cloud_services_credits,
    ROUND(SUM(CREDITS_USED_CLOUD_SERVICES) * 100.0
          / NULLIF(SUM(CREDITS_USED_COMPUTE), 0), 2) AS cloud_svc_pct_of_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1 DESC;
