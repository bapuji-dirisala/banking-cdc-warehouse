# Snowflake PII governance (as code)

Everything in this directory is **code-only** — reviewable SQL that
runs in prod, not deployed by this repo. All PII enforcement here is
engine-level: Snowflake applies masking + row-access policies at query
time based on `CURRENT_ROLE()`, so no model logic has to know who is
asking.

## The three primitives

| Primitive | Purpose |
|---|---|
| **Object tags** | Inventory of which columns contain which kind of PII. A tag on `EMAIL` saying `PII_LEVEL = 'high'` makes "find every high-PII column in the warehouse" a 3-line query. |
| **Masking policies** | Column-level functions that transform the stored value based on role. `BANKING_ANALYST` sees `***@domain.com`, `BANKING_ENGINEER` sees the raw email, both from the same SELECT. |
| **Row access policies** | Table-level predicates that filter rows based on role. `BANKING_CREDIT_ANALYST` only sees transactions on credit-card accounts; default roles see all. |

## Files

| File | Purpose |
|---|---|
| `01-tags.sql` | `CREATE TAG` definitions + grants + inventory query |
| `02-masking-policies.sql` | 4 masking policies: email, phone, DOB, card_last4 |
| `03-apply-masking.sql` | `ALTER COLUMN SET MASKING POLICY` + tag assignment on every PII column |
| `04-row-access-policies.sql` | Row-access policy on `fct_transactions` + attach |
| `05-admin.sql` | `SHOW POLICIES`, inventory queries, role-swap test harness |
| `06-erasure-template.sql` | Phase 9 — GDPR Article 17 right-to-be-forgotten template (cross-layer delete + anonymise) |

## Apply order

```bash
# All files are idempotent (CREATE OR REPLACE).
snowsql -c banking_admin -f snowflake/governance/01-tags.sql
snowsql -c banking_admin -f snowflake/governance/02-masking-policies.sql
snowsql -c banking_admin -f snowflake/governance/03-apply-masking.sql
snowsql -c banking_admin -f snowflake/governance/04-row-access-policies.sql
# then verify with:
snowsql -c banking_admin -f snowflake/governance/05-admin.sql
```

## Why not enforce PII in dbt?

Short answer: because then every model has to know what every role is
allowed to see, and the warehouse engine (which has `CURRENT_ROLE()`
and session context) has to re-decide at query time anyway.

Longer answer: dbt models are **compile-time** — they project a shape.
Masking + row-access decisions are **query-time** — they depend on the
caller's identity. Mixing the two produces either:

- dbt models with role-specific branches (brittle; grows O(roles × models))
- dbt models with masked columns baked in (loses the "privileged role
  can read raw" use case)

Snowflake's split — policies owned by SecurityAdmin, models owned by
dbt — is the right boundary. This directory is the policy half.

## Dev-vs-prod matrix

| Concern | DuckDB dev | Snowflake prod |
|---|---|---|
| RBAC | none (single local user) | `BANKING_*` role hierarchy from Phase 3 |
| Masking | no PII enforcement; dev uses synthetic data | dynamic masking policies attached per column |
| Row access | not applicable | row access policy on `fct_transactions` |
| Audit | n/a | Snowflake `ACCESS_HISTORY` view captures every role→data access |

The honest story: PII governance is enforced in prod, not in dev. Dev
tolerance is acceptable because the sink runs against synthetic data
only (Phase 1 `banking-cdc seed run` generates fake customers via Faker).

## Role → access matrix

| Role                     | Email | Phone | DOB | Card last4 | Credit txns | Other txns |
|--------------------------|-------|-------|-----|------------|-------------|------------|
| `BANKING_ENGINEER`       | raw   | raw   | raw | raw        | ✓           | ✓          |
| `BANKING_READER_PII`     | raw   | raw   | raw | raw        | ✓           | ✓          |
| `BANKING_FRAUD_OPS`      | masked| raw   | raw | raw        | ✓           | ✓          |
| `BANKING_CREDIT_ANALYST` | masked| masked| year-only | masked | ✓     | **blocked** |
| `BANKING_ANALYST`        | masked| masked| year-only | masked | ✓     | ✓          |
| `ACCOUNTADMIN`           | raw   | raw   | raw | raw        | ✓           | ✓          |

See `02-masking-policies.sql` + `04-row-access-policies.sql` for the
authoritative rules; this table is a doc-level summary.
