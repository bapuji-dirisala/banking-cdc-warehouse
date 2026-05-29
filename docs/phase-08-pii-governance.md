# Phase 8 — PII governance as code

**Status:** shipped (2026-10-25)
**Depends on:** Phase 3 (role hierarchy), Phase 5 (marts), Phase 6 (snapshots)

## Goal

Make PII enforcement a reviewable, versioned artifact — the same way
dbt models are. Four primitives land in this phase:

1. **Object tags** for PII inventory and compliance-report automation
2. **Dynamic masking policies** that transform columns per role at query time
3. **Row access policies** that filter whole rows per role
4. **Dbt dispatch macros** (`banking_cdc.mask_email`, `mask_phone`) so
   consumer views can expose deterministically masked columns in both
   dev and prod

## Shape added

```
snowflake/governance/
├── README.md                        -- role→access matrix, apply order, dev-vs-prod story
├── 01-tags.sql                      -- PII_LEVEL / DATA_DOMAIN / RETENTION_CLASS
├── 02-masking-policies.sql          -- MASK_EMAIL / MASK_PHONE / MASK_DATE_OF_BIRTH / MASK_CARD_LAST4
├── 03-apply-masking.sql             -- ALTER COLUMN SET MASKING POLICY + SET TAG for every PII column
├── 04-row-access-policies.sql       -- row access policy on fct_transactions + agg_daily_account_balance
└── 05-admin.sql                     -- SHOW/inventory queries + role-swap test harness

dbt/macros/
└── pii.sql                          -- banking_cdc.mask_email() + mask_phone() dispatchers
```

## The core insight: enforcement is engine-level, not model-level

The "right place" to enforce PII is Snowflake, not dbt. Rationale:

- Snowflake has `CURRENT_ROLE()` and session identity; dbt builds don't.
- Masking + row-access decisions depend on the caller, which the query
  engine knows and the compile-time model layer doesn't.
- Mixing them produces either role-branching dbt models (brittle, grows
  O(roles × models)) or baked-in masks (loses the privileged-read case).

This phase's split:

| Owner | Concern |
|---|---|
| **SecurityAdmin** | masking + row-access policies, tag definitions, role → policy assignments |
| **dbt (BankingEngineer)** | models + physical materialization + idempotent re-apply after `--full-refresh` |
| **Analysts (BankingAnalyst, CreditAnalyst)** | query the marts; see whatever the policies decided |

## Masking policy pattern

Every policy has the same shape:

```sql
CREATE OR REPLACE MASKING POLICY MASK_<COLUMN> AS
    (val <TYPE>) RETURNS <TYPE> ->
    CASE
        WHEN CURRENT_ROLE() IN (<privileged roles>) THEN val
        WHEN val IS NULL THEN NULL
        ELSE <transform>
    END;
```

The 4 policies shipped:

| Policy | Column | Privileged roles see | Masked view |
|---|---|---|---|
| `MASK_EMAIL`         | `email`         | raw | `***@domain.com` |
| `MASK_PHONE`         | `phone`         | raw | all digits → `*`, separators kept |
| `MASK_DATE_OF_BIRTH` | `date_of_birth` | raw | Jan 1 of birth year |
| `MASK_CARD_LAST4`    | `card_last4`    | raw | `****` |

Why keep the domain / preserve format / show year? Because analysts
still need **statistical shape** of the data (cohort analysis, age
distribution, format validation) without the identifier. Over-masking
breaks analytics; under-masking breaks privacy. Each policy is a
privacy-vs-utility judgment call documented in its `COMMENT`.

## Role → access matrix

| Role                     | email | phone | DOB | card_last4 | credit txns | non-credit txns |
|--------------------------|-------|-------|-----|------------|-------------|-----------------|
| `BANKING_ENGINEER`       | raw   | raw   | raw | raw        | ✓           | ✓               |
| `BANKING_READER_PII`     | raw   | raw   | raw | raw        | ✓           | ✓               |
| `BANKING_FRAUD_OPS`      | ***@  | raw   | raw | raw        | ✓           | ✓               |
| `BANKING_CREDIT_ANALYST` | ***@  | ***   | yr  | ****       | ✓           | **blocked**     |
| `BANKING_ANALYST`        | ***@  | ***   | yr  | ****       | ✓           | ✓               |
| `ACCOUNTADMIN`           | raw   | raw   | raw | raw        | ✓           | ✓               |

## Row access policy

`RAP_FCT_TRANSACTIONS_BY_ACCOUNT_TYPE` demonstrates row-level scoping:
`BANKING_CREDIT_ANALYST` sees only transactions on `account_type =
'credit'` accounts; privileged roles see all; **any other role is
denied by default**. Attach is to `fct_transactions.account_sk` and the
same policy is reused on `agg_daily_account_balance` for consistency.

Default-deny is important here: a new role added later without an
explicit policy branch gets zero rows, surfacing the gap immediately.

## Why dbt macros at all?

Two use cases where consumer-side determinism matters:

1. **Consumer views with always-masked columns** — e.g.
   `vw_customer_marketing(email_masked, phone_masked, segment)` that
   always shows masks regardless of the role of the caller. Snowflake
   policy would NOT fire because the policy fires on the base column
   `email`, not on the view column `email_masked`.
2. **Dev-mode parity** — a developer running dbt against DuckDB wants
   `email_masked` to look like a mask, not raw.

The two dispatch macros shipped:

```sql
{{ banking_cdc.mask_email('customer.email') }}
-- Snowflake: returns `customer.email` (base column still has policy)
-- DuckDB:    returns substr+split masking as a SQL expression

{{ banking_cdc.mask_phone('customer.phone') }}
-- Snowflake: returns `customer.phone`
-- DuckDB:    returns regexp_replace masking
```

**Phase 8 does not add consumer views using these macros** — the macros
land now, the consumer views land in Phase 9+ alongside the GE/
reconciliation layer where they naturally fit.

## GDPR Right-to-be-Forgotten note

Dynamic masking **hides** data; it doesn't erase it. Erasure (GDPR
Art. 17) is a separate workflow:

1. Identify every table carrying the subject's rows (`SNAPSHOTS.*`,
   `MARTS.*`, `STAGING.*`, `RAW.*`)
2. Issue `DELETE` statements (or `UPDATE` to a tombstoned row)
3. Document in the compliance log

Phase 9's reconciliation runbook will ship the executable erasure
template.

## What this phase explicitly does NOT ship

- Consumer views using the dbt mask macros (Phase 9+)
- Tag-based policy assignment (used column-attached form here for
  review focus; mature setups use `ALTER TAG ... SET MASKING POLICY`
  pattern — one-line swap)
- A `MASK_NAME` policy (template commented in 03-apply-masking.sql)
- Erasure template (Phase 9 operational runbook)
- Great Expectations / GE suite (Phase 9)
- Snowflake Native Apps / Secure Data Sharing boundary (Phase 10+)

## Next phase

**Phase 9** — Data quality + reconciliation. Great Expectations suite
sitting next to dbt, nightly reconciliation job that cross-checks
`SUM(amount)` across OLTP ↔ raw ↔ marts, GDPR erasure template, and
the first batch of consumer-ready views using the Phase 8 mask macros.
