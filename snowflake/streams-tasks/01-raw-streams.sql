-- Streams on every raw table so downstream Tasks can consume only the
-- rows that are new since their last run.
--
-- `APPEND_ONLY = FALSE` means the stream also tracks updates + deletes,
-- not just inserts. Each row returned by SELECT * FROM <stream> carries:
--
--   METADATA$ACTION    = 'INSERT' | 'DELETE'
--   METADATA$ISUPDATE  = TRUE | FALSE   (an update is DELETE + INSERT)
--   METADATA$ROW_ID    = internal row id
--
-- `SHOW_INITIAL_ROWS = TRUE` on first consume returns the full table
-- state, treating the whole existing contents as "change rows" — makes
-- the first downstream run a clean full-refresh without special-casing.
--
-- Streams are consumed on COMMIT; once a transaction reads the stream and
-- commits, those rows no longer appear on next read. For debugging,
-- `SYSTEM$STREAM_HAS_DATA('<stream>')` returns TRUE if there are
-- unconsumed rows waiting.

USE DATABASE BANKING_PROD;
USE ROLE BANKING_ENGINEER;

CREATE SCHEMA IF NOT EXISTS BANKING_PROD.STAGING
    COMMENT = 'dbt-managed + stream-fed clean layer on top of RAW.';

-- ---------------------------------------------------------------------
-- Streams on raw.* — one per source table.
-- ---------------------------------------------------------------------
CREATE OR REPLACE STREAM BANKING_PROD.STAGING.STRM_RAW_CUSTOMERS
    ON TABLE BANKING_PROD.RAW.CUSTOMERS
    APPEND_ONLY = FALSE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'CDC-on-CDC: new rows arriving from Snowflake Kafka Connector into RAW.CUSTOMERS.';

CREATE OR REPLACE STREAM BANKING_PROD.STAGING.STRM_RAW_ACCOUNTS
    ON TABLE BANKING_PROD.RAW.ACCOUNTS
    APPEND_ONLY = FALSE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'CDC-on-CDC: new rows in RAW.ACCOUNTS.';

CREATE OR REPLACE STREAM BANKING_PROD.STAGING.STRM_RAW_TRANSACTIONS
    ON TABLE BANKING_PROD.RAW.TRANSACTIONS
    APPEND_ONLY = FALSE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'CDC-on-CDC: new rows in RAW.TRANSACTIONS.';

CREATE OR REPLACE STREAM BANKING_PROD.STAGING.STRM_RAW_CARD_EVENTS
    ON TABLE BANKING_PROD.RAW.CARD_EVENTS
    APPEND_ONLY = FALSE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'CDC-on-CDC: new rows in RAW.CARD_EVENTS.';

-- Verify.
SHOW STREAMS IN SCHEMA BANKING_PROD.STAGING;
