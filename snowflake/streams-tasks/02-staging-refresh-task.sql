-- Root Task + per-table child Tasks that drain each raw stream into the
-- staging layer. Root task owns the schedule; children run as a DAG
-- after root succeeds.
--
-- This Phase 6 artifact shows the Snowflake-native refresh path. The
-- dbt-managed staging layer (`stg_banking__*` views) and the Snowflake
-- task-managed staging tables defined here are the same shape — in a
-- hybrid prod setup you'd pick one owner per table based on refresh
-- cadence (dbt for hourly batch, task for sub-minute near-real-time).

USE DATABASE BANKING_PROD;
USE ROLE BANKING_ENGINEER;

-- ---------------------------------------------------------------------
-- Stored procedure invoked by each child task. Merges stream deltas
-- into the staging layer's current-state table. Latest-LSN-wins per PK.
--
-- Pattern per table:
--   1. DELETE from staging target where PK is in the stream (handles d)
--   2. INSERT the latest row per PK from the stream for all other ops
--
-- Reading the stream in a MERGE statement is the Snowflake-recommended
-- pattern for exactly-once consumption — the stream advances only when
-- the transaction commits.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE BANKING_PROD.STAGING.SP_REFRESH_STG_CUSTOMERS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Latest row per customer_id from the stream, excluding deletes.
    MERGE INTO BANKING_PROD.STAGING.STG_CUSTOMERS target
    USING (
        SELECT * FROM (
            SELECT
                CUSTOMERS.*,
                ROW_NUMBER() OVER (PARTITION BY ID ORDER BY __LSN DESC) AS _rn
            FROM BANKING_PROD.STAGING.STRM_RAW_CUSTOMERS AS CUSTOMERS
        ) WHERE _rn = 1
    ) source
    ON target.CUSTOMER_ID = source.ID
    WHEN MATCHED AND source.__OP = 'd' THEN DELETE
    WHEN MATCHED AND source.__OP <> 'd' THEN UPDATE SET
        EXTERNAL_ID    = source.EXTERNAL_ID,
        FIRST_NAME     = source.FIRST_NAME,
        LAST_NAME      = source.LAST_NAME,
        EMAIL          = source.EMAIL,
        PHONE          = source.PHONE,
        DATE_OF_BIRTH  = source.DATE_OF_BIRTH,
        KYC_STATUS     = source.KYC_STATUS,
        CREATED_AT     = source.CREATED_AT,
        UPDATED_AT     = source.UPDATED_AT,
        _CDC_OP        = source.__OP,
        _CDC_LSN       = source.__LSN
    WHEN NOT MATCHED AND source.__OP <> 'd' THEN INSERT
        (CUSTOMER_ID, EXTERNAL_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE,
         DATE_OF_BIRTH, KYC_STATUS, CREATED_AT, UPDATED_AT, _CDC_OP, _CDC_LSN)
        VALUES
        (source.ID, source.EXTERNAL_ID, source.FIRST_NAME, source.LAST_NAME,
         source.EMAIL, source.PHONE, source.DATE_OF_BIRTH, source.KYC_STATUS,
         source.CREATED_AT, source.UPDATED_AT, source.__OP, source.__LSN);
    RETURN 'ok';
END;
$$;

-- (02-staging-refresh-task.sql continues for the other three tables —
-- same pattern, templatise before applying to prod. Kept short here
-- for review brevity; the dim pattern is identical.)

-- ---------------------------------------------------------------------
-- Task DAG — root on 5-minute schedule, children fan out from root.
-- Root uses WHEN to short-circuit when no streams have data (saves
-- warehouse credits during quiet periods).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TASK BANKING_PROD.STAGING.TSK_STAGING_ROOT
    WAREHOUSE = WH_INGEST_XS
    SCHEDULE = '5 MINUTE'
    COMMENT = 'Root task — fan-out to per-table staging refresh children.'
    WHEN SYSTEM$STREAM_HAS_DATA('BANKING_PROD.STAGING.STRM_RAW_CUSTOMERS')
      OR SYSTEM$STREAM_HAS_DATA('BANKING_PROD.STAGING.STRM_RAW_ACCOUNTS')
      OR SYSTEM$STREAM_HAS_DATA('BANKING_PROD.STAGING.STRM_RAW_TRANSACTIONS')
      OR SYSTEM$STREAM_HAS_DATA('BANKING_PROD.STAGING.STRM_RAW_CARD_EVENTS')
AS
    SELECT 1;  -- no-op; children carry the actual work

CREATE OR REPLACE TASK BANKING_PROD.STAGING.TSK_REFRESH_STG_CUSTOMERS
    WAREHOUSE = WH_INGEST_XS
    AFTER BANKING_PROD.STAGING.TSK_STAGING_ROOT
    COMMENT = 'Drain STRM_RAW_CUSTOMERS → STG_CUSTOMERS via SP_REFRESH_STG_CUSTOMERS.'
AS
    CALL BANKING_PROD.STAGING.SP_REFRESH_STG_CUSTOMERS();

-- (TSK_REFRESH_STG_ACCOUNTS / _TRANSACTIONS / _CARD_EVENTS follow the
-- same AFTER root pattern.)
