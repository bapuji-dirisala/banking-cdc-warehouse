-- Phase 10 — query tags for cost attribution.
--
-- Snowflake associates every query with a QUERY_TAG string that lands
-- in ACCOUNT_USAGE.QUERY_HISTORY. By convention we tag with a JSON blob
-- so downstream FinOps queries can slice by (project, model, materialization,
-- invocation_id, dbt_target).
--
-- Three patterns demonstrated:
--   1. Session-level tag — set once per connection, every query inherits.
--   2. Statement-level override — a single ad-hoc query can carry its
--      own tag without disturbing the session tag.
--   3. dbt-managed tag — the macro at dbt/macros/query_tag.sql emits
--      the JSON, wired to every model via `+query_tag` in dbt_project.yml.
--      That's the canonical path; the SQL below is for ad-hoc + BI tools
--      that don't go through dbt.
--
-- Why JSON? JSON_EXTRACT() is cheap at query time; grep-like string
-- parsing is not. Tag `{"project":"banking_cdc","model":"fct_transactions"}`
-- → `WHERE PARSE_JSON(QUERY_TAG):model::STRING = 'fct_transactions'`.

USE ROLE SYSADMIN;

----------------------------------------------------------------------
-- 1. Session-level tag — typical BI tool / Streamlit app pattern.
----------------------------------------------------------------------

-- Snowsight worksheet / Streamlit app sets this once on connect:
ALTER SESSION SET QUERY_TAG = $$
{
    "project": "banking_cdc_warehouse",
    "surface": "streamlit",
    "app":     "finance-dashboard",
    "user":    "<set by caller>"
}
$$;

-- Verify it's taken:
SELECT CURRENT_SESSION(), CURRENT_USER(), CURRENT_WAREHOUSE();
SHOW PARAMETERS LIKE 'QUERY_TAG' IN SESSION;

----------------------------------------------------------------------
-- 2. Statement-level override — one-off tagging without touching session.
--
-- Snowflake treats the tag inside a single-statement script as scoped
-- to that statement when inside a transaction block.
----------------------------------------------------------------------

BEGIN;
    ALTER SESSION SET QUERY_TAG = $${"ad_hoc": true, "ticket": "DATA-1234"}$$;
    SELECT COUNT(*) FROM BANKING_PROD.MARTS.FCT_TRANSACTIONS;
COMMIT;
-- Session tag reverts to the outer value after COMMIT.

----------------------------------------------------------------------
-- 3. Verifying dbt-emitted tags.
--
-- After a dbt run (or on-run-start) sets the tag via
-- `banking_cdc.query_tag_json()`, this query confirms the shape:
----------------------------------------------------------------------
SELECT
    QUERY_ID,
    START_TIME,
    WAREHOUSE_NAME,
    PARSE_JSON(QUERY_TAG):project::STRING          AS project,
    PARSE_JSON(QUERY_TAG):dbt_target::STRING       AS dbt_target,
    PARSE_JSON(QUERY_TAG):model::STRING            AS model_name,
    PARSE_JSON(QUERY_TAG):materialization::STRING  AS mat,
    PARSE_JSON(QUERY_TAG):invocation_id::STRING    AS invocation_id,
    TOTAL_ELAPSED_TIME / 1000                       AS seconds,
    CREDITS_USED_CLOUD_SERVICES
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND QUERY_TAG ILIKE '%banking_cdc_warehouse%'
ORDER BY START_TIME DESC
LIMIT 100;

----------------------------------------------------------------------
-- 4. Cost-per-model, cost-per-invocation reports.
--
-- The payoff of tagging: these aggregates would be impossible to build
-- without the per-query attribution.
----------------------------------------------------------------------

-- Cost per model, last 30 days.
SELECT
    PARSE_JSON(QUERY_TAG):model::STRING  AS model_name,
    COUNT(*)                              AS n_runs,
    SUM(TOTAL_ELAPSED_TIME) / 1000.0      AS total_seconds,
    SUM(CREDITS_USED_CLOUD_SERVICES)      AS cloud_services_credits,
    -- Compute approx warehouse credits: credits/hour × warehouse-size-multiplier
    -- is Snowflake-doc public; keeping the arithmetic explicit here.
    ROUND(
        SUM(TOTAL_ELAPSED_TIME) / 1000.0 / 3600.0
        * CASE WAREHOUSE_SIZE
            WHEN 'X-Small'  THEN 1
            WHEN 'Small'    THEN 2
            WHEN 'Medium'   THEN 4
            WHEN 'Large'    THEN 8
            WHEN 'X-Large'  THEN 16
            ELSE 1
          END,
        4
    ) AS approx_warehouse_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND PARSE_JSON(QUERY_TAG):project::STRING = 'banking_cdc_warehouse'
  AND PARSE_JSON(QUERY_TAG):model IS NOT NULL
GROUP BY 1
ORDER BY approx_warehouse_credits DESC NULLS LAST;

-- Cost per dbt invocation — pinpoint the "nightly build that blew the budget".
SELECT
    PARSE_JSON(QUERY_TAG):invocation_id::STRING  AS invocation_id,
    MIN(START_TIME)                               AS started_at,
    MAX(END_TIME)                                 AS finished_at,
    COUNT(*)                                      AS n_statements,
    SUM(TOTAL_ELAPSED_TIME) / 1000.0              AS total_seconds,
    SUM(CREDITS_USED_CLOUD_SERVICES)              AS cloud_services_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND PARSE_JSON(QUERY_TAG):project::STRING = 'banking_cdc_warehouse'
GROUP BY 1
ORDER BY started_at DESC;
