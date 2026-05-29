-- Object tags for PII inventory + data-domain classification.
--
-- Tags are reference data: they let any auditor answer "which columns
-- in BANKING_PROD carry high-sensitivity PII?" with a 3-line query
-- against ACCOUNT_USAGE, without having to grep SQL files.
--
-- Tags are also the lever for tag-based masking policy assignment: in
-- a mature setup, `ALTER TAG ... SET MASKING POLICY ...` means a
-- policy applies to every column that carries that tag, instead of
-- having to attach to each column individually. This repo uses the
-- simpler column-attached pattern in 03-apply-masking.sql so review
-- can focus on the policy logic, not the cross-cutting rigging.

USE DATABASE BANKING_PROD;
USE ROLE SECURITYADMIN;

CREATE SCHEMA IF NOT EXISTS BANKING_PROD.GOVERNANCE
    COMMENT = 'PII tags, masking policies, row-access policies.';

-- ---------------------------------------------------------------------
-- Classification tags.
-- ---------------------------------------------------------------------

CREATE OR REPLACE TAG BANKING_PROD.GOVERNANCE.PII_LEVEL
    ALLOWED_VALUES 'none', 'low', 'high'
    COMMENT = 'PII sensitivity. ''high'' = direct identifier (email, phone, DOB), ''low'' = quasi-identifier (segment, country).';

CREATE OR REPLACE TAG BANKING_PROD.GOVERNANCE.DATA_DOMAIN
    ALLOWED_VALUES 'identity', 'financial', 'behavioral', 'technical'
    COMMENT = 'Data classification for data-mesh ownership + GDPR Article 30 processing records.';

CREATE OR REPLACE TAG BANKING_PROD.GOVERNANCE.RETENTION_CLASS
    ALLOWED_VALUES '7y', '10y', 'indefinite'
    COMMENT = 'Legal + regulatory retention requirement.';

-- Grant tag usage so SysAdmins + dbt service account can assign tags
-- during routine model builds. The GOVERNANCE role owns tag definitions;
-- others only USE them.
GRANT USAGE ON SCHEMA BANKING_PROD.GOVERNANCE TO ROLE BANKING_ENGINEER;
GRANT APPLY TAG ON ACCOUNT TO ROLE BANKING_ENGINEER;

-- ---------------------------------------------------------------------
-- Inventory query — the one every audit asks for first.
-- Returns: object, column, tag_name, tag_value — one row per tagged attribute.
-- ---------------------------------------------------------------------
-- SELECT
--     OBJECT_DATABASE   AS db,
--     OBJECT_SCHEMA     AS schema,
--     OBJECT_NAME       AS object,
--     COLUMN_NAME       AS column_name,
--     TAG_NAME,
--     TAG_VALUE
-- FROM TABLE(SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES_ALL_COLUMNS(
--     'BANKING_PROD.MARTS.DIM_CUSTOMER', 'TABLE'
-- ))
-- WHERE TAG_NAME = 'PII_LEVEL' AND TAG_VALUE = 'high';
