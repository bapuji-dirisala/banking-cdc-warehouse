# Phase 9 — data quality + reconciliation

**Status:** shipped (2026-10-25)
**Depends on:** Phase 5 (marts), Phase 7 (incremental fct), Phase 8 (mask macros)

## Goal

Raise test coverage from "schema shape" (Phases 4–8) to "data truth"
(this phase):

1. **GE-style assertions** on business-critical columns via
   `dbt_expectations` — regex, value range, exact length — so
   contract drift fails CI, not production dashboards.
2. **Cross-layer reconciliation** — row count + posted sum must agree
   staging ↔ fact ↔ aggregate. Shipped as two singular tests plus a
   persistent `recon_transaction_amounts` view for dashboards.
3. **First consumer surface** that uses the Phase 8 mask macros,
   proving the dev-vs-prod mask parity promise.
4. **GDPR Art. 17 erasure template** — reviewable SQL that walks the
   cross-layer deletion / anonymisation.

## Shape added

```
dbt/
├── packages.yml                              -- adds metaplane/dbt_expectations
├── models/marts/
│   ├── consumer/
│   │   ├── vw_customer_marketing.sql         -- always-masked view (uses Phase 8 macros)
│   │   └── _consumer__models.yml
│   └── quality/
│       ├── recon_transaction_amounts.sql     -- one-row cross-layer diff
│       └── _quality__models.yml
└── tests/
    ├── assert_fct_matches_stg_rowcount.sql       -- singular test
    └── assert_fct_matches_stg_posted_sum.sql     -- singular test

snowflake/governance/
└── 06-erasure-template.sql                   -- cross-layer DELETE + anonymise
```

## Test taxonomy

| Kind | Where | When fires | Example |
|---|---|---|---|
| **Schema tests** (`unique`, `not_null`, `relationships`, `accepted_values`) | model yml | every build | PKs unique, FKs resolve |
| **GE-style column tests** (dbt_expectations) | model yml | every build | email matches regex, amount ≥ 0 |
| **Singular tests** (standalone SQL) | `dbt/tests/` | every build | cross-table recon (stg vs fct) |
| **Recon models** (materialized) | marts/quality/ | every build | one-row dashboard-ready diff |

All four live inside `dbt build` — same command runs schema + GE +
singular + recon. No parallel GE install, no separate orchestrator step.

## Why `dbt_expectations` instead of standalone Great Expectations

Standalone GE is a bigger surface:

- separate yaml + Python project (`great_expectations.yml`,
  `expectations/`, `checkpoints/`)
- separate runtime (`great_expectations checkpoint run`)
- its own concept of validation suites, docs sites, data assets

`dbt_expectations` ports the valuable assertions
(`expect_column_values_to_match_regex`,
`expect_column_sum_to_be_between`, etc.) into dbt's native test runner.
You get 80% of the GE expressiveness with 20% of the operational cost,
and it runs in the same `dbt build` command the rest of the pipeline
uses.

Standalone GE wins when:
- the quality team is separate from the dbt team (different sprint cadence)
- validation needs to run outside the warehouse (e.g. on CSV uploads)
- Great Expectations' docs site is a reporting requirement

None of those apply here. `dbt_expectations` is the right scope.

## The three cross-layer invariants

All checked on every build. In order of what-to-fix-first severity:

1. **Row count: `stg` ↔ `fct`** — `assert_fct_matches_stg_rowcount.sql`
   catches the "rows silently dropped" bug class (incremental watermark
   too tight, `where` typo, filter joining a dim that wasn't fully loaded).
2. **Posted sum: `stg` ↔ `fct`** — `assert_fct_matches_stg_posted_sum.sql`
   catches "same rows, wrong amounts" (column rename, cast truncation,
   missing enum branch).
3. **Published total: `stg` / `fct` / `agg`** — `recon_transaction_amounts`
   is the dashboard view. Alerting reads `has_discrepancy` and pages.

In a healthy warehouse all three are TRUE / zero-rows. A single failure
narrows the search to one layer boundary.

## The first consumer surface — `vw_customer_marketing`

Marketing team's authorised surface for cohort + outreach work. Projects
`customer_sk`, `external_id`, `email_masked`, `phone_masked`, `age_cohort`,
`kyc_status_label`. Deliberately excludes raw `email` / `phone` / `DOB`
so a stolen view credential can't re-identify customers.

**Dev-vs-prod rendering contract:**

| Column | Dev (DuckDB) | Prod (Snowflake, Marketing role) |
|---|---|---|
| `email_masked` | `a***@example.com` (macro output) | `a***@example.com` (base column + policy output) |
| `phone_masked` | `***-****` | `***-****` |

Same visible shape in both environments. The test
(`dbt_expectations.expect_column_values_to_match_regex` with
`severity: warn`) is a dev-mode shape guard that would surface a macro
regression.

## GDPR Article 17 — the erasure template

`snowflake/governance/06-erasure-template.sql` walks the cross-layer
deletion / anonymisation in one transaction, with the ledger-side carve-out
documented inline:

- **Deleted outright** (right-to-be-forgotten): dim_customer,
  dim_customer_scd2, snap_banking__customers, agg_monthly_customer_revenue
- **Customer linkage nulled** (regulatory ledger retention): fct_transactions,
  fct_card_events — the financial facts stay for ledger-reporting
  obligations (GDPR Art. 17(3)(b)); only the customer identifier is dropped
- **Anonymised, not deleted** (regulatory retention window): raw.customers,
  staging.stg_customers — fields replaced with `[ERASED]` placeholders so
  the row count stays stable for recon but no identifier survives

**Snowflake Time Travel caveat documented in the template:** erasure is
"logical in 0s, physical in 90 days" — the fail-safe retention window
keeps the row image recoverable for the default `DATA_RETENTION_TIME_IN_DAYS`.
Legal must be told this.

## What this phase explicitly does NOT ship

- Standalone Great Expectations install (`dbt_expectations` covers the
  need)
- Historical reconciliation (`recon_transaction_amounts` is a view —
  Phase 10 adds a daily-snapshot variant for trend charts)
- Alerting integration (Phase 10 — PagerDuty / Slack hook via Airflow
  task that polls `has_discrepancy`)
- Erasure audit log table (`BANKING_PROD.ADMIN.ERASURE_AUDIT_LOG` —
  Phase 10)
- Consumer views beyond `vw_customer_marketing` (e.g.
  `vw_account_overview`, `vw_fraud_review`) — add as other teams
  onboard
- Freshness tests (Phase 10 — meaningful only on a live sink)

## Local verification

```bash
cd dbt
dbt deps --profiles-dir .
dbt build --profiles-dir . --target dev --fail-fast

# Expect: all tests pass including the new singular + GE tests.
# Query the recon view directly:
duckdb ../warehouse/banking.duckdb -c "
    SELECT stg_total, fct_total, agg_total, has_discrepancy
    FROM quality.recon_transaction_amounts
"
```

## Next phase

**Phase 10** — cost + performance runbook. Snowflake warehouse sizing
notes, resource-monitor tuning table, query performance queries over
`ACCOUNT_USAGE.QUERY_HISTORY`, DuckDB-side profiling via `.timer on` +
`EXPLAIN ANALYZE`, and the "when to go incremental" decision table that
makes Phase 6 Streams vs Phase 7 incremental vs Phase 10 materialized
views a reviewable call.
