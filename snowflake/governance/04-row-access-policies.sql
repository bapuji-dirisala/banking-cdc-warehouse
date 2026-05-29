-- Row access policies.
--
-- Where masking policies hide specific columns, row access policies
-- hide entire rows. Both evaluate at query time against CURRENT_ROLE().
--
-- Example use case here: a dedicated BANKING_CREDIT_ANALYST role should
-- only see transactions on credit-card accounts (their business
-- jurisdiction), not checking + savings accounts. Default roles
-- continue to see all rows.
--
-- Perf note: the policy body runs per row. The IN-subquery pattern
-- here is readable but Snowflake would ideally evaluate it as a
-- semi-join; in a hot path, a mature setup would materialise
-- `credit_account_sks` into a reference table that the policy reads.

USE DATABASE BANKING_PROD;
USE SCHEMA GOVERNANCE;
USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------
-- Scope fct_transactions by account_type for the credit-analyst role.
-- ---------------------------------------------------------------------
CREATE OR REPLACE ROW ACCESS POLICY RAP_FCT_TRANSACTIONS_BY_ACCOUNT_TYPE AS
    (account_sk VARCHAR) RETURNS BOOLEAN ->
    CASE
        -- Privileged + general roles see everything.
        WHEN CURRENT_ROLE() IN (
            'ACCOUNTADMIN',
            'BANKING_ENGINEER',
            'BANKING_FRAUD_OPS',
            'BANKING_READER_PII',
            'BANKING_ANALYST'
        ) THEN TRUE
        -- Credit analyst sees only credit-card accounts.
        WHEN CURRENT_ROLE() = 'BANKING_CREDIT_ANALYST' THEN
            account_sk IN (
                SELECT account_sk
                FROM BANKING_PROD.MARTS.DIM_ACCOUNT
                WHERE account_type = 'credit'
            )
        -- Explicit deny-by-default for any other role.
        ELSE FALSE
    END
    COMMENT = 'Credit analyst sees only credit accounts; privileged roles see all; everyone else is denied by default.';

-- ---------------------------------------------------------------------
-- Attach the policy to the fact table. One policy -> one column; call
-- again with another column to protect by multiple attributes.
-- ---------------------------------------------------------------------
ALTER TABLE BANKING_PROD.MARTS.FCT_TRANSACTIONS
    ADD ROW ACCESS POLICY BANKING_PROD.GOVERNANCE.RAP_FCT_TRANSACTIONS_BY_ACCOUNT_TYPE
    ON (ACCOUNT_SK);

-- Same policy applies cleanly to the aggregates (they carry account_sk).
-- Guards aggregate exposure consistent with the fact.
ALTER TABLE BANKING_PROD.MARTS.AGG_DAILY_ACCOUNT_BALANCE
    ADD ROW ACCESS POLICY BANKING_PROD.GOVERNANCE.RAP_FCT_TRANSACTIONS_BY_ACCOUNT_TYPE
    ON (ACCOUNT_SK);

-- ---------------------------------------------------------------------
-- Future extensions, documented here for reviewer awareness:
--
-- * Region scoping — `rap_scope_by_region ON (customer_region)` once a
--   region attribute lands on dim_customer / dim_account.
-- * Customer-service scope — "a customer-service rep sees only the
--   customers they're assigned to" via a lookup against an entitlements
--   table. The policy body would subquery that table.
-- * Snowflake Native Apps — row access policies compose correctly with
--   Snowflake Secure Data Sharing; the sharing partner sees only rows
--   the policy allows, with no extra wiring.
-- ---------------------------------------------------------------------
