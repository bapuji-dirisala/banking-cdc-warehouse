-- Day-2 operator ergonomics for the PII governance topology.
-- Every statement here is a read; safe to run anytime, from any role
-- with USAGE on the GOVERNANCE schema.

USE DATABASE BANKING_PROD;
USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------
-- Policy inventory — one row per policy with its last-modified time.
-- ---------------------------------------------------------------------
SHOW MASKING POLICIES IN SCHEMA BANKING_PROD.GOVERNANCE;
SHOW ROW ACCESS POLICIES IN SCHEMA BANKING_PROD.GOVERNANCE;
SHOW TAGS IN SCHEMA BANKING_PROD.GOVERNANCE;

-- ---------------------------------------------------------------------
-- "Which columns have which masking policy attached?"
-- The audit question that gets asked at every quarterly review.
-- ---------------------------------------------------------------------
SELECT
    REF_DATABASE_NAME,
    REF_SCHEMA_NAME,
    REF_ENTITY_NAME       AS table_name,
    REF_COLUMN_NAME       AS column_name,
    POLICY_NAME,
    POLICY_KIND           -- MASKING | ROW_ACCESS
FROM TABLE(SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES(POLICY_NAME => NULL))
WHERE REF_DATABASE_NAME = 'BANKING_PROD'
ORDER BY REF_SCHEMA_NAME, REF_ENTITY_NAME, REF_COLUMN_NAME;

-- ---------------------------------------------------------------------
-- "Which columns are tagged as high-PII?"
-- Powers the data-minimisation audit + Article 30 processing records.
-- ---------------------------------------------------------------------
SELECT
    OBJECT_DATABASE,
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COLUMN_NAME,
    TAG_NAME,
    TAG_VALUE
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE OBJECT_DATABASE = 'BANKING_PROD'
  AND TAG_NAME = 'PII_LEVEL'
  AND TAG_VALUE = 'high'
ORDER BY OBJECT_SCHEMA, OBJECT_NAME, COLUMN_NAME;

-- ---------------------------------------------------------------------
-- Role-swap test harness.
--
-- Pattern: switch role, re-query the same column, confirm the masking
-- rule fires. The expected transformations are documented in the
-- `snowflake/governance/README.md` role-access matrix.
-- ---------------------------------------------------------------------

-- Baseline (privileged — should see raw):
USE ROLE BANKING_ENGINEER;
SELECT customer_id, email, phone, date_of_birth
FROM BANKING_PROD.MARTS.DIM_CUSTOMER
LIMIT 3;

-- Analyst view (should see masked):
USE ROLE BANKING_ANALYST;
SELECT customer_id, email, phone, date_of_birth
FROM BANKING_PROD.MARTS.DIM_CUSTOMER
LIMIT 3;

-- Credit analyst view (masked PII + row-filtered to credit accounts):
USE ROLE BANKING_CREDIT_ANALYST;
SELECT COUNT(*) AS visible_txns
FROM BANKING_PROD.MARTS.FCT_TRANSACTIONS;
-- Expected: strictly fewer than the engineer-visible count.

-- ---------------------------------------------------------------------
-- GDPR right-to-be-forgotten — the one-off override.
--
-- Dynamic masking HIDES data; it doesn't ERASE it. For true erasure
-- (GDPR Art. 17), the workflow is:
--   1. Identify every table carrying the subject's rows
--   2. Issue DELETE statements (or UPDATE to a tombstoned/anonymised row)
--   3. Document the action in the compliance log
--
-- See `snowflake/governance/erasure-template.sql` (not yet shipped — part
-- of Phase 9 operational runbook).
-- ---------------------------------------------------------------------
