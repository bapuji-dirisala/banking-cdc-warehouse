{#
    Nightly cross-layer reconciliation for the posted-transactions sum.

    Reads the posted-amount totals at three layers and surfaces the diff:

        staging  — stg_banking__transactions
        fact     — fct_transactions
        agg      — agg_daily_account_balance (summed back to one total)

    A healthy warehouse has stg_total = fct_total = agg_total within
    pennies (DECIMAL(18,4) tolerance).

    Pattern lifted from the regulatory-reporting "controls" discipline:
    every published number must be traceable to the raw it came from.
    Dashboards point here first on any discrepancy ticket.

    Output: one row with the per-layer totals + two signed diffs.
    Downstream alerting checks `has_discrepancy = true` and pages.

    Materialised as view (per the marts.quality default) so every query
    is a fresh snapshot. A persistence story (daily history, trend
    chart) is Phase 10 scope.
#}

with staging as (
    select coalesce(sum(amount), 0) as stg_total
    from {{ ref('stg_banking__transactions') }}
    where transaction_status = 'posted'
      and not _is_deleted
),

fact as (
    select coalesce(sum(amount), 0) as fct_total
    from {{ ref('fct_transactions') }}
    where transaction_status = 'posted'
),

aggregate as (
    select coalesce(sum(credits + debits), 0) as agg_total
    from {{ ref('agg_daily_account_balance') }}
)

select
    current_timestamp                       as checked_at,
    staging.stg_total,
    fact.fct_total,
    aggregate.agg_total,
    fact.fct_total - staging.stg_total      as fct_minus_stg,
    aggregate.agg_total - fact.fct_total    as agg_minus_fct,
    (
        abs(fact.fct_total - staging.stg_total) > 0.0001
        or
        abs(aggregate.agg_total - fact.fct_total) > 0.0001
    )                                        as has_discrepancy
from staging, fact, aggregate
