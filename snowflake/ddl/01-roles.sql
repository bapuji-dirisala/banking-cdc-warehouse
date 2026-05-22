-- Role hierarchy for the banking CDC warehouse.
--
-- Pattern: FUNCTIONAL role × ACCESS role composition (Snowflake Field
-- Engineering reference pattern). Functional roles represent "who" (what
-- team, what job); access roles represent "what" (what schema × what
-- privilege). Functional roles are composed from access roles via GRANT.
--
-- Benefits:
--   - Adding a new schema or table requires granting only to access roles;
--     functional roles compose automatically.
--   - Audit queries can slice by function ("who are the engineers?") or by
--     access ("who can write to marts?") independently.
--   - Rotating a user's job (analyst to engineer) is a two-grant change,
--     not a wholesale role rewrite.
--
-- Apply as a role with CREATE ROLE privilege (typically SECURITYADMIN).

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- Functional roles — "who you are"
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS BANKING_ENGINEER
    COMMENT = 'Data engineers who build and operate the warehouse pipelines.';

CREATE ROLE IF NOT EXISTS BANKING_ANALYST
    COMMENT = 'Analysts who build dashboards and ad-hoc analyses on marts.';

CREATE ROLE IF NOT EXISTS BANKING_READER
    COMMENT = 'Downstream consumers (BI tools, service accounts) that only read marts.';

-- ---------------------------------------------------------------------------
-- Access roles — "what you can touch"
-- One per (schema layer × privilege). Grants of these onto objects live in
-- 05-grants.sql; grants of these INTO functional roles also live below.
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS AR_RAW_READ          COMMENT = 'Read raw CDC bronze schema.';
CREATE ROLE IF NOT EXISTS AR_RAW_WRITE         COMMENT = 'Write to raw CDC bronze schema (the Kafka Connector).';
CREATE ROLE IF NOT EXISTS AR_STAGING_READ      COMMENT = 'Read staging layer.';
CREATE ROLE IF NOT EXISTS AR_STAGING_WRITE     COMMENT = 'Write to staging layer (dbt).';
CREATE ROLE IF NOT EXISTS AR_INTERMEDIATE_READ  COMMENT = 'Read intermediate layer.';
CREATE ROLE IF NOT EXISTS AR_INTERMEDIATE_WRITE COMMENT = 'Write to intermediate layer (dbt).';
CREATE ROLE IF NOT EXISTS AR_MARTS_READ        COMMENT = 'Read business marts.';
CREATE ROLE IF NOT EXISTS AR_MARTS_WRITE       COMMENT = 'Write to business marts (dbt).';

-- Compose functional roles from access roles. Grants of roles INTO roles.
GRANT ROLE AR_RAW_READ           TO ROLE BANKING_ENGINEER;
GRANT ROLE AR_RAW_WRITE          TO ROLE BANKING_ENGINEER;
GRANT ROLE AR_STAGING_READ       TO ROLE BANKING_ENGINEER;
GRANT ROLE AR_STAGING_WRITE      TO ROLE BANKING_ENGINEER;
GRANT ROLE AR_INTERMEDIATE_READ  TO ROLE BANKING_ENGINEER;
GRANT ROLE AR_INTERMEDIATE_WRITE TO ROLE BANKING_ENGINEER;
GRANT ROLE AR_MARTS_READ         TO ROLE BANKING_ENGINEER;
GRANT ROLE AR_MARTS_WRITE        TO ROLE BANKING_ENGINEER;

GRANT ROLE AR_MARTS_READ         TO ROLE BANKING_ANALYST;
GRANT ROLE AR_INTERMEDIATE_READ  TO ROLE BANKING_ANALYST;

GRANT ROLE AR_MARTS_READ         TO ROLE BANKING_READER;

-- Functional roles roll up into SYSADMIN so the ownership chain remains
-- traceable from the top of the role tree.
GRANT ROLE BANKING_ENGINEER TO ROLE SYSADMIN;
GRANT ROLE BANKING_ANALYST  TO ROLE SYSADMIN;
GRANT ROLE BANKING_READER   TO ROLE SYSADMIN;
