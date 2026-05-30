-- Phase 10 — clustering keys on the biggest table + maintenance queries.
--
-- Clustering is Snowflake's answer to "how do we keep a 100TB table
-- scanning-cheap?". It's a background re-ordering of the table's
-- micro-partitions by a chosen key. Reads that filter on that key skip
-- vast swathes of partitions (SNOWFLAKE$CLUSTERING_INFORMATION reports
-- the quality; QUERY_HISTORY.PARTITIONS_SCANNED proves the payoff).
--
-- When to cluster vs when NOT to cluster — the decision tree:
--
--   • Table > ~1 TB and growing fast                → candidate
--   • Dominant query predicate on 1-3 columns       → candidate
--   • Query predicate on high-cardinality column    → good key
--   • Query predicate on low-cardinality column     → BAD key
--     (bool, 5-value enum) — micro-partitions are
--     already selective enough on their own
--   • High-churn table (many UPDATEs)               → bad fit;
--     auto-clustering fights every merge
--   • Append-mostly table                           → ideal fit
--
-- fct_transactions in prod meets every criterion: multi-TB after a few
-- months, dominant predicate on (posted_date, account_id), high
-- cardinality on both, append-only (Phase 7 incremental uses
-- delete+insert but the delete window is small).
--
-- fct_card_events + dim_customer_scd2 do NOT justify clustering:
-- card_events is small, dim_customer_scd2 is read full-scan most of the
-- time (snapshot joins).

USE ROLE SYSADMIN;
USE DATABASE BANKING_PROD;

----------------------------------------------------------------------
-- 1. Attach a clustering key to fct_transactions.
--
-- Key design:
--   • posted_date first — most queries filter by date range
--   • account_id second — second-most-common predicate (per-account
--     statements, per-account recon)
--
-- Dropping transaction_id / currency / amount from the key: they're
-- query-time filters only ~10% of the time; adding them to the key
-- would thrash auto-clustering for little scan-reduction benefit.
----------------------------------------------------------------------

ALTER TABLE BANKING_PROD.MARTS.FCT_TRANSACTIONS
    CLUSTER BY (posted_date, account_id);

-- Auto-clustering is on by default when CLUSTER BY is set, but call it
-- out explicitly so a future reader knows we deliberately kept it on.
ALTER TABLE BANKING_PROD.MARTS.FCT_TRANSACTIONS RESUME RECLUSTER;

----------------------------------------------------------------------
-- 2. Clustering-quality maintenance queries.
--
-- Run weekly; alert if `average_depth` creeps above ~5 (table is losing
-- its clustering). Snowflake auto-reclusters in the background, but
-- high ingest + high UPDATE churn can outpace it.
----------------------------------------------------------------------

-- Per-table clustering depth summary.
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'BANKING_PROD.MARTS.FCT_TRANSACTIONS',
    '(posted_date, account_id)'
) AS clustering_info;

-- Per-table clustering depth — pretty-print the JSON.
WITH ci AS (
    SELECT PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION(
        'BANKING_PROD.MARTS.FCT_TRANSACTIONS',
        '(posted_date, account_id)'
    )) AS j
)
SELECT
    j:cluster_by_keys::STRING                             AS cluster_key,
    j:total_partition_count::NUMBER                        AS total_partitions,
    j:total_constant_partition_count::NUMBER               AS constant_partitions,
    j:average_overlaps::FLOAT                              AS avg_overlaps,
    j:average_depth::FLOAT                                 AS avg_depth,
    j:partition_depth_histogram                            AS depth_histogram
FROM ci;

-- Historical reclustering credit burn.
SELECT
    START_TIME::DATE                 AS activity_day,
    TABLE_NAME,
    COUNT(*)                         AS n_recluster_runs,
    SUM(CREDITS_USED)                AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND TABLE_NAME = 'FCT_TRANSACTIONS'
GROUP BY 1, 2
ORDER BY 1 DESC;

----------------------------------------------------------------------
-- 3. Proof-of-value query — compare partitions scanned before/after.
--
-- Run the same analytic query, inspect QUERY_HISTORY, and confirm
-- PARTITIONS_SCANNED dropped meaningfully. A healthy clustering key
-- cuts the number scanned by at least an order of magnitude for the
-- target predicate.
----------------------------------------------------------------------

-- Example query that benefits from the clustering key.
SELECT COUNT(*) AS n_posted_q1_2025
FROM BANKING_PROD.MARTS.FCT_TRANSACTIONS
WHERE posted_date BETWEEN '2025-01-01' AND '2025-03-31';

-- Then inspect:
SELECT
    QUERY_ID,
    QUERY_TEXT,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROUND(PARTITIONS_SCANNED * 100.0 / NULLIF(PARTITIONS_TOTAL, 0), 2) AS pct_scanned,
    BYTES_SCANNED,
    PERCENTAGE_SCANNED_FROM_CACHE
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TEXT ILIKE '%fct_transactions%posted_date BETWEEN%'
  AND START_TIME >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC
LIMIT 5;

----------------------------------------------------------------------
-- 4. Panic button — suspend reclustering if its credit burn spikes.
----------------------------------------------------------------------
-- ALTER TABLE BANKING_PROD.MARTS.FCT_TRANSACTIONS SUSPEND RECLUSTER;
-- ALTER TABLE BANKING_PROD.MARTS.FCT_TRANSACTIONS DROP CLUSTERING KEY;
