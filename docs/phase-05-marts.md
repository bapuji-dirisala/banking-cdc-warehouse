# Phase 5 — intermediate + marts

**Status:** shipped (2026-10-25)
**Depends on:** Phase 4 staging (4 `stg_banking__*` views + envelope-aware dedup)

## Goal

Turn the Phase 4 staging layer into a working star schema plus the first
two business-level aggregates. Everything built in this phase is what a
Finance analyst or a BI tool would actually point at.

## Shape added

```
dbt/models/
├── intermediate/
│   └── int_banking__transactions_enriched.sql   -- ephemeral join of txn → acct → cust
└── marts/
    ├── core/                                     -- generic star schema
    │   ├── dim_customer.sql                      -- SCD1 (SCD2 in P6)
    │   ├── dim_account.sql                       -- SCD1 w/ customer_sk
    │   ├── fct_transactions.sql                  -- OLTP-txn grain
    │   └── fct_card_events.sql                   -- card lifecycle grain
    └── finance/                                  -- business subject area
        ├── agg_daily_account_balance.sql         -- (account, date) grain
        └── agg_monthly_customer_revenue.sql      -- (customer, month) grain
```

Materialization defaults, from `dbt_project.yml`:

| Layer         | Materialization | Rationale                                     |
|---------------|-----------------|-----------------------------------------------|
| staging       | view            | Thin, free to re-scan                         |
| intermediate  | ephemeral       | One consumer, folds in as a CTE               |
| marts         | table           | Pay-once / read-many — BI tools hit these     |

## Dimensional model

```
                   ┌──────────────────┐
                   │   dim_customer   │  SCD1, PK=customer_sk
                   └────────┬─────────┘
                            │
                            │ customer_sk
                            ▼
                   ┌──────────────────┐
                   │   dim_account    │  SCD1, PK=account_sk, FK=customer_sk
                   └────────┬─────────┘
                            │
                            │ account_sk, customer_sk
                   ┌────────┴─────────┐
                   ▼                  ▼
         ┌─────────────────┐  ┌──────────────────┐
         │ fct_transactions│  │ fct_card_events  │
         └────────┬────────┘  └──────────────────┘
                  │
                  │ consumed by
                  ▼
    ┌──────────────────────────────┐
    │ agg_daily_account_balance    │ (account, date)
    │ agg_monthly_customer_revenue │ (customer, month)
    └──────────────────────────────┘
```

Every fact carries **both** `account_sk` and `customer_sk` — standard
denormalization so a "revenue by customer segment" query doesn't need a
dim_account → dim_customer join.

## Surrogate keys

`dim_customer`, `dim_account`, `fct_transactions`, and `fct_card_events`
all use `dbt_utils.generate_surrogate_key(['natural_key'])` to produce
hashed surrogate keys that are:

- stable across runs (deterministic hash of the natural key)
- adapter-portable (dbt_utils dispatches to the right hash function)
- SCD2-ready (Phase 6 will swap the surrogate to a composite hash that
  includes the validity window — downstream fct FK references
  automatically pick up the right version)

Facts always reference dims by surrogate key. Natural keys are also kept
on the fact for ad-hoc querying.

## Delete semantics

Different layers handle CDC deletes differently, by design:

| Layer           | Handles delete how?                                     |
|-----------------|---------------------------------------------------------|
| raw             | append-only in prod, DELETE-INSERT in dev (per sink)    |
| staging         | kept, flagged `_is_deleted = true`                      |
| intermediate    | passes through staging flag                             |
| **dim** (dim_customer, dim_account) | **filtered out** (`where not _is_deleted`) |
| **fct** (fct_transactions, fct_card_events) | **retained** (an event that happened cannot un-happen) |
| **agg**         | inherits from fct — includes deletes, filtered by status |

If the regulatory review needs "give me every customer that ever existed",
the staging layer is the source. The dim is for live reporting.

## Enum decoding

Every fact/dim exposes both the raw code **and** a human label:

| raw code    | label             |
|-------------|-------------------|
| `verified`  | `Verified`        |
| `pending`   | `Pending Review`  |
| `fee`       | `Fee`             |
| `transfer_in` | `Transfer In`   |

The code column stays the join key; the label column is for display.
BI tools shouldn't own `CASE WHEN` logic — the warehouse owns semantic
labels.

## Measures

`fct_transactions` adds:

- `signed_amount` — debits negative, credits positive from the
  account-holder's perspective. Sums across an account give you a
  balance delta directly, no `CASE WHEN direction` in every query.
- `is_debit` / `is_revenue_txn` — boolean classifiers for cheap filters
- `posted_date` — truncated for grouping (saves a cast on every query)

## Aggregates

**`agg_daily_account_balance`** — grain (account, date). Columns:
`net_change`, `credits`, `debits`, `txn_count`, `distinct_type_count`.
Only `posted` transactions are included; `pending` and `reversed` are
excluded per regulatory balance-reporting rules.

**`agg_monthly_customer_revenue`** — grain (customer, month). Columns:
`fees_revenue`, `interest_revenue`, `total_revenue`, `revenue_txn_count`.
Bank-side revenue only (fees paid by the customer + interest earned by
the bank on the customer's debt products).

Both aggregates have a `unique_combination_of_columns` test from
`dbt_utils` on their composite grain so a surprise duplicate would
fail CI immediately.

## Tests

Per model:

| model                             | PK unique+not_null | dim FK relationships | enum accepted_values | composite PK |
|-----------------------------------|:------------------:|:--------------------:|:--------------------:|:------------:|
| `dim_customer`                    | ✓ (sk + natural)   | —                    | kyc_status           | —            |
| `dim_account`                     | ✓ (sk + natural)   | → dim_customer       | type, status         | —            |
| `fct_transactions`                | ✓ (sk + natural + uuid) | → dim_account + dim_customer | direction, type, status | — |
| `fct_card_events`                 | ✓ (sk + natural + uuid) | → dim_account   | event_type           | —            |
| `agg_daily_account_balance`       | —                  | → dim_account + dim_customer | —           | (account_sk, business_date) |
| `agg_monthly_customer_revenue`    | —                  | → dim_customer       | —                    | (customer_sk, business_month) |

## Fixture tweaks

`sql/duckdb/raw_fixture.sql` picks up two more transactions so the
revenue agg is non-empty in CI:

- txn id=4: `fee`, 5.00 USD (debit) — monthly service fee
- txn id=5: `interest`, 1.25 USD (credit) — savings interest paid

These are what makes `agg_monthly_customer_revenue` produce two rows
instead of zero in the CI run.

## What this phase explicitly does NOT ship

- SCD2 history (Phase 6 — dbt snapshots over raw CDC log)
- Streams / Tasks for incremental Snowflake materialization (Phase 6)
- `dbt_banking` package extraction (Phase 7)
- PII masking (Phase 8 — Snowflake dynamic masking policies as code)
- Reconciliation + GE quality gates (Phase 9)
- `metric_revenue` semantic layer definition (Phase 7)
- Risk / fraud subject area (Phase 9+)

## Local dev loop

```bash
cd dbt
dbt build --profiles-dir . --target dev --select +marts.core --fail-fast
dbt build --profiles-dir . --target dev --select +marts.finance --fail-fast

# inspect
dbt show --profiles-dir . --target dev --inline "
    select customer_sk, full_name, kyc_status_label, age_years
    from {{ ref('dim_customer') }}
"
```

## Next phase

**Phase 6** — snapshots + SCD2. Use dbt snapshots over the raw
`__ingested_at` to produce `snap_customer` / `snap_account` type-2
tables; wire a Snowflake Streams-and-Tasks pattern as code so the
mart layer can go incremental.
