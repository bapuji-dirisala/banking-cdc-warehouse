-- Three warehouses sized by consumer role.
--
-- Each warehouse auto-suspends when idle (cost control) and auto-resumes
-- on query submission (zero operator toil). Sizes are intentionally small
-- because this is a portfolio-scale workload; a production reader would
-- tune up with real workload metrics.

USE ROLE SYSADMIN;

-- WH_INGEST_XS — used by the Snowflake Kafka Connector sink. Short,
-- bursty workload; 60s auto-suspend minimises credit burn between batches.
CREATE WAREHOUSE IF NOT EXISTS WH_INGEST_XS
    WAREHOUSE_SIZE       = XSMALL
    AUTO_SUSPEND         = 60
    AUTO_RESUME          = TRUE
    INITIALLY_SUSPENDED  = TRUE
    MIN_CLUSTER_COUNT    = 1
    MAX_CLUSTER_COUNT    = 1
    SCALING_POLICY       = STANDARD
    COMMENT = 'Snowflake Kafka Connector sink — short bursty ingest workload.';

-- WH_TRANSFORM_S — used by dbt. Longer-running queries, larger size since
-- transforms touch join + window-function patterns. 300s auto-suspend
-- avoids restart cost on back-to-back dbt invocations.
CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM_S
    WAREHOUSE_SIZE       = SMALL
    AUTO_SUSPEND         = 300
    AUTO_RESUME          = TRUE
    INITIALLY_SUSPENDED  = TRUE
    MIN_CLUSTER_COUNT    = 1
    MAX_CLUSTER_COUNT    = 2
    SCALING_POLICY       = STANDARD
    COMMENT = 'dbt builds + Great Expectations runs. Scales to 2 clusters under contention.';

-- WH_REPORT_XS — used by BI consumers reading marts. Many short queries,
-- small cost per query, aggressive auto-suspend.
CREATE WAREHOUSE IF NOT EXISTS WH_REPORT_XS
    WAREHOUSE_SIZE       = XSMALL
    AUTO_SUSPEND         = 60
    AUTO_RESUME          = TRUE
    INITIALLY_SUSPENDED  = TRUE
    MIN_CLUSTER_COUNT    = 1
    MAX_CLUSTER_COUNT    = 2
    SCALING_POLICY       = STANDARD
    COMMENT = 'BI tools reading marts. Multi-cluster for concurrent dashboard refreshes.';

-- Grant USAGE on warehouses to the roles that need them.
-- Deliberately kept here (not in 05-grants.sql) so the warehouse-to-role
-- mapping is visible alongside the CREATE WAREHOUSE statements.
GRANT USAGE ON WAREHOUSE WH_INGEST_XS    TO ROLE AR_RAW_WRITE;
GRANT USAGE ON WAREHOUSE WH_TRANSFORM_S  TO ROLE BANKING_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_REPORT_XS    TO ROLE BANKING_ANALYST;
GRANT USAGE ON WAREHOUSE WH_REPORT_XS    TO ROLE BANKING_READER;
