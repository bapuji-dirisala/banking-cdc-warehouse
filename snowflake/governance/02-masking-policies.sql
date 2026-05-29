-- Dynamic data masking policies.
--
-- Shape: `policy_fn(val) -> transformed_val`. Snowflake evaluates these
-- lazily at query time with the caller's role in CURRENT_ROLE(), so the
-- same SELECT returns different data per role. No model logic has to
-- branch on role; the engine does it.
--
-- Policy functions MUST be pure (deterministic, no side effects) and
-- return the same type as the input column. Snowflake rejects attach
-- otherwise.

USE DATABASE BANKING_PROD;
USE SCHEMA GOVERNANCE;
USE ROLE SECURITYADMIN;

-- Helper CTE pattern used in every policy: "privileged roles see raw".
-- Keeping the role list in sync across policies is a known maintenance
-- cost; a mature setup extracts it into a UDF or a reference table.

-- ---------------------------------------------------------------------
-- Email — mask local part, keep domain.
--
-- Rationale: analysts need the domain for cohort analysis
-- ("gmail users convert at X%") but not the identifier. Keeping the
-- domain visible also prevents accidental re-identification via
-- joining to third-party data.
-- ---------------------------------------------------------------------
CREATE OR REPLACE MASKING POLICY MASK_EMAIL AS
    (val VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN (
            'ACCOUNTADMIN',
            'BANKING_ENGINEER',
            'BANKING_READER_PII'
        ) THEN val
        WHEN val IS NULL THEN NULL
        ELSE REGEXP_REPLACE(val, '^[^@]+', '***')
    END
    COMMENT = 'Keep domain, hide local part. Privileged roles see raw.';

-- ---------------------------------------------------------------------
-- Phone — mask every digit, keep format hints (dashes etc.).
--
-- Fraud ops needs the raw number to call customers; analysts don't.
-- ---------------------------------------------------------------------
CREATE OR REPLACE MASKING POLICY MASK_PHONE AS
    (val VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN (
            'ACCOUNTADMIN',
            'BANKING_ENGINEER',
            'BANKING_READER_PII',
            'BANKING_FRAUD_OPS'
        ) THEN val
        WHEN val IS NULL THEN NULL
        ELSE REGEXP_REPLACE(val, '[0-9]', '*')
    END
    COMMENT = 'Mask all digits, preserve separators. Fraud ops sees raw.';

-- ---------------------------------------------------------------------
-- Date of birth — show year only (for age cohorts) when masked.
--
-- year-only is still a quasi-identifier; a mature setup would
-- generalise further ("1980s" bucket) depending on the privacy budget.
-- ---------------------------------------------------------------------
CREATE OR REPLACE MASKING POLICY MASK_DATE_OF_BIRTH AS
    (val DATE) RETURNS DATE ->
    CASE
        WHEN CURRENT_ROLE() IN (
            'ACCOUNTADMIN',
            'BANKING_ENGINEER',
            'BANKING_READER_PII',
            'BANKING_FRAUD_OPS'
        ) THEN val
        WHEN val IS NULL THEN NULL
        ELSE DATE_FROM_PARTS(YEAR(val), 1, 1)
    END
    COMMENT = 'Collapse to Jan 1 of birth year — preserves age cohort, drops month/day.';

-- ---------------------------------------------------------------------
-- Card last-4 — full redaction except for fraud + privileged roles.
-- ---------------------------------------------------------------------
CREATE OR REPLACE MASKING POLICY MASK_CARD_LAST4 AS
    (val VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN (
            'ACCOUNTADMIN',
            'BANKING_ENGINEER',
            'BANKING_READER_PII',
            'BANKING_FRAUD_OPS'
        ) THEN val
        ELSE '****'
    END
    COMMENT = 'Card digits are PCI-adjacent — mask fully for non-privileged roles.';

-- Verify.
SHOW MASKING POLICIES IN SCHEMA BANKING_PROD.GOVERNANCE;
