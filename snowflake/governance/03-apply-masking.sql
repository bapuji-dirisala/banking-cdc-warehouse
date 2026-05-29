-- Attach masking policies to PII columns + apply inventory tags.
--
-- Both operations are declarative + idempotent. Running this file after
-- a new mart column lands is the one-step "classify + protect" ritual.
--
-- Pattern per column:
--   1. SET MASKING POLICY  — hooks the policy function
--   2. SET TAG PII_LEVEL   — classifies for inventory + reporting
--
-- Policies and tags are independent — a column can have a tag without
-- a policy (classify-only, e.g. for data minimisation audits) or a
-- policy without a tag (protect-only, legacy columns pre-tagging).

USE DATABASE BANKING_PROD;
USE ROLE SECURITYADMIN;

-- =====================================================================
-- STAGING layer — the Snowflake-task-managed STG_* tables from Phase 6.
-- =====================================================================

-- Customers
ALTER TABLE BANKING_PROD.STAGING.STG_CUSTOMERS MODIFY COLUMN EMAIL
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_EMAIL,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high',
    SET TAG BANKING_PROD.GOVERNANCE.DATA_DOMAIN = 'identity';

ALTER TABLE BANKING_PROD.STAGING.STG_CUSTOMERS MODIFY COLUMN PHONE
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_PHONE,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high',
    SET TAG BANKING_PROD.GOVERNANCE.DATA_DOMAIN = 'identity';

ALTER TABLE BANKING_PROD.STAGING.STG_CUSTOMERS MODIFY COLUMN DATE_OF_BIRTH
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_DATE_OF_BIRTH,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high',
    SET TAG BANKING_PROD.GOVERNANCE.DATA_DOMAIN = 'identity';

-- =====================================================================
-- MARTS layer — the dbt-built tables. Masking propagates: a view over
-- a masked column returns masked data. No need to re-apply at mart
-- layer for columns that come straight from staging.
--
-- But: a materialised mart that re-copies the data (e.g. table-materialised
-- `dim_customer`) DOES need its own policy — the physical copy is a new
-- object. The pattern below handles that.
-- =====================================================================

ALTER TABLE BANKING_PROD.MARTS.DIM_CUSTOMER MODIFY COLUMN EMAIL
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_EMAIL,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high';

ALTER TABLE BANKING_PROD.MARTS.DIM_CUSTOMER MODIFY COLUMN PHONE
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_PHONE,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high';

ALTER TABLE BANKING_PROD.MARTS.DIM_CUSTOMER MODIFY COLUMN DATE_OF_BIRTH
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_DATE_OF_BIRTH,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high';

-- `full_name` is also a direct identifier. Apply the email policy by
-- analogy, or add a dedicated MASK_NAME policy — kept short here for
-- review brevity; templatise before applying to prod.
-- ALTER TABLE BANKING_PROD.MARTS.DIM_CUSTOMER MODIFY COLUMN FULL_NAME
--     SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_NAME,
--     SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high';

ALTER TABLE BANKING_PROD.MARTS.FCT_CARD_EVENTS MODIFY COLUMN CARD_LAST4
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_CARD_LAST4,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high';

-- =====================================================================
-- SCD2 snapshots — must have policies too; the snapshot is append-only
-- so historical PII sticks around until explicit erasure (GDPR right-
-- to-be-forgotten).
-- =====================================================================
ALTER TABLE BANKING_PROD.SNAPSHOTS.SNAP_BANKING__CUSTOMERS MODIFY COLUMN EMAIL
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_EMAIL,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high',
    SET TAG BANKING_PROD.GOVERNANCE.RETENTION_CLASS = '7y';

ALTER TABLE BANKING_PROD.SNAPSHOTS.SNAP_BANKING__CUSTOMERS MODIFY COLUMN PHONE
    SET MASKING POLICY BANKING_PROD.GOVERNANCE.MASK_PHONE,
    SET TAG BANKING_PROD.GOVERNANCE.PII_LEVEL = 'high',
    SET TAG BANKING_PROD.GOVERNANCE.RETENTION_CLASS = '7y';

-- Verify a column has the expected policy + tags.
-- DESCRIBE TABLE BANKING_PROD.MARTS.DIM_CUSTOMER;
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
--     REF_ENTITY_NAME => 'BANKING_PROD.MARTS.DIM_CUSTOMER',
--     REF_ENTITY_DOMAIN => 'TABLE'
-- ));
