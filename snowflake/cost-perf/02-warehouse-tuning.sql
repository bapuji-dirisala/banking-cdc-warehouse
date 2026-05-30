-- Phase 10 — warehouse tuning on top of Phase 3's baseline.
--
-- Patterns demonstrated:
--   1. STATEMENT_TIMEOUT_IN_SECONDS — kills runaway queries. Set per
--      warehouse because a 2-hour timeout appropriate for a nightly
--      backfill is pathological for a dashboard warehouse.
--   2. STATEMENT_QUEUED_TIMEOUT_IN_SECONDS — kills queries that queue
--      forever instead of silently wasting user time.
--   3. SCALING_POLICY swap: STANDARD (default) vs ECONOMY.
--      - STANDARD scales out on queue; good for BI (unpredictable load).
--      - ECONOMY batches queries; cheaper for dbt (predictable, batchy).
--   4. Dev-tier warehouse clones at tighter settings — a dev that
--      wants to iterate against prod-shaped data without burning prod
--      credits uses zero-copy clones + its own warehouse.
--   5. The size-up decision: when to upgrade XSMALL → SMALL → MEDIUM.
--      The 60-30-10 rule shows up in the comments.

USE ROLE SYSADMIN;

----------------------------------------------------------------------
-- Tune the Phase 3 production warehouses.
----------------------------------------------------------------------

-- WH_INGEST_XS — Kafka Connector. Tight timeouts because sink batches
-- that take longer than a few minutes indicate a plumbing bug.
ALTER WAREHOUSE WH_INGEST_XS SET
    STATEMENT_TIMEOUT_IN_SECONDS        = 600       -- 10 min hard kill
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 60        -- don't queue sink batches
    SCALING_POLICY                      = STANDARD;

-- WH_TRANSFORM_S — dbt. Longer timeout for the few long full-refresh
-- rebuilds; ECONOMY scaling because dbt invocations arrive in predictable
-- batches (nightly + CI) and we're happy to queue briefly to save credits.
ALTER WAREHOUSE WH_TRANSFORM_S SET
    STATEMENT_TIMEOUT_IN_SECONDS        = 7200      -- 2h cap for full-refresh
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 600       -- 10 min queue tolerance
    SCALING_POLICY                      = ECONOMY;

-- WH_REPORT_XS — BI. Shorter timeout than TRANSFORM; a BI query that
-- takes more than 5 min is probably a mis-filter. STANDARD scaling so
-- a dashboard refresh storm scales out immediately.
ALTER WAREHOUSE WH_REPORT_XS SET
    STATEMENT_TIMEOUT_IN_SECONDS        = 300       -- 5 min for BI
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 30        -- don't frustrate dashboards
    SCALING_POLICY                      = STANDARD;

----------------------------------------------------------------------
-- Dev-tier transform warehouse.
--
-- Zero-copy clones of prod data land in BANKING_DEV; developers use
-- this warehouse to iterate. Deliberately slower auto-resume behaviour
-- is NOT needed — the dev-tier RM already caps the damage.
----------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM_S_DEV
    WAREHOUSE_SIZE                      = XSMALL   -- half the compute of prod
    AUTO_SUSPEND                        = 60       -- aggressive — dev is bursty
    AUTO_RESUME                         = TRUE
    INITIALLY_SUSPENDED                 = TRUE
    MIN_CLUSTER_COUNT                   = 1
    MAX_CLUSTER_COUNT                   = 1        -- no scale-out in dev
    SCALING_POLICY                      = ECONOMY
    STATEMENT_TIMEOUT_IN_SECONDS        = 1800     -- 30 min cap
    STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 60
    COMMENT = 'Phase 10 — developer iteration warehouse. Cheap, strict, zero-copy-clone target.';

-- Attach the dev-tier RM created in 01-resource-monitor-tuning.sql.
ALTER WAREHOUSE WH_TRANSFORM_S_DEV SET RESOURCE_MONITOR = RM_DEV_TRANSFORM_MONTHLY;

GRANT USAGE ON WAREHOUSE WH_TRANSFORM_S_DEV TO ROLE BANKING_ENGINEER;

----------------------------------------------------------------------
-- Size-up decision reference (NOT a DDL — comment is the artifact).
--
-- The "60-30-10 rule" of warehouse sizing:
--
--   • If the warehouse spends 60%+ of its runtime at MAX_CLUSTER_COUNT
--     AND the slowest queries are still slow, size UP (XS → S → M).
--   • If the warehouse spends 30%+ of its runtime QUEUEING (visible in
--     QUERY_HISTORY.QUEUED_PROVISIONING_TIME), raise MAX_CLUSTER_COUNT.
--   • If the warehouse spends 10%+ of its runtime SPILLING (visible in
--     QUERY_HISTORY.BYTES_SPILLED_TO_LOCAL_STORAGE > 0), size UP first;
--     a bigger warehouse means more memory per query.
--
-- The investigation queries in 05-performance-queries.sql compute each
-- of these percentages directly.
----------------------------------------------------------------------
