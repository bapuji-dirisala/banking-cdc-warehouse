-- Three-env namespace: BANKING_DEV / BANKING_CI / BANKING_PROD.
--
-- Every environment carries the same schema layout so dbt profiles can
-- target any env with identical model code. Phase 11 (blue/green CI with
-- zero-copy clones) uses BANKING_CI as the ephemeral PR database.
--
-- Schema layer:
--   RAW           — bronze CDC landing (Snowflake Kafka Connector target)
--   STAGING       — dbt staging layer
--   INTERMEDIATE  — dbt intermediate layer
--   MARTS         — business marts (dim_customer, dim_account, etc.)
--   SNAPSHOTS     — dbt snapshots (SCD2 history preservation)
--
-- Each schema carries a COMMENT describing its owner + purpose so Snowsight
-- shows helpful context in the schema browser.

USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS BANKING_DEV
    COMMENT = 'Developer sandbox — ephemeral, wiped between dbt builds.';
CREATE DATABASE IF NOT EXISTS BANKING_CI
    COMMENT = 'CI builds — zero-copy clones of PROD per PR; dropped after merge.';
CREATE DATABASE IF NOT EXISTS BANKING_PROD
    COMMENT = 'Production warehouse. Only the Kafka Connector + dbt prod runs write here.';

-- Schemas, replicated across all three databases. The repetition is
-- intentional: a reader can diff-check that nothing differs between envs
-- without jumping between files. In a real deployment a reader would
-- templatise this via jinja / Terraform / dbt macros to avoid the copy
-- (recommended for teams of >2 engineers).

USE DATABASE BANKING_DEV;
CREATE SCHEMA IF NOT EXISTS RAW          COMMENT = 'Bronze CDC landing — Snowflake Kafka Connector target.';
CREATE SCHEMA IF NOT EXISTS STAGING      COMMENT = 'dbt staging layer — cast + rename, 1:1 with raw.';
CREATE SCHEMA IF NOT EXISTS INTERMEDIATE COMMENT = 'dbt intermediate layer — joins + dedup + SCD2 preparation.';
CREATE SCHEMA IF NOT EXISTS MARTS        COMMENT = 'Business marts — dim_customer, dim_account, fact_transaction, fact_balance_daily.';
CREATE SCHEMA IF NOT EXISTS SNAPSHOTS    COMMENT = 'dbt snapshots — SCD2 history preservation.';

USE DATABASE BANKING_CI;
CREATE SCHEMA IF NOT EXISTS RAW          COMMENT = 'Bronze CDC landing (CI zero-copy clones).';
CREATE SCHEMA IF NOT EXISTS STAGING      COMMENT = 'dbt staging (CI).';
CREATE SCHEMA IF NOT EXISTS INTERMEDIATE COMMENT = 'dbt intermediate (CI).';
CREATE SCHEMA IF NOT EXISTS MARTS        COMMENT = 'Business marts (CI).';
CREATE SCHEMA IF NOT EXISTS SNAPSHOTS    COMMENT = 'dbt snapshots (CI).';

USE DATABASE BANKING_PROD;
CREATE SCHEMA IF NOT EXISTS RAW          COMMENT = 'Bronze CDC landing (production).';
CREATE SCHEMA IF NOT EXISTS STAGING      COMMENT = 'dbt staging (production).';
CREATE SCHEMA IF NOT EXISTS INTERMEDIATE COMMENT = 'dbt intermediate (production).';
CREATE SCHEMA IF NOT EXISTS MARTS        COMMENT = 'Business marts (production).';
CREATE SCHEMA IF NOT EXISTS SNAPSHOTS    COMMENT = 'dbt snapshots (production).';
