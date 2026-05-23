{#
    Monthly bank-side revenue per customer.

    "Revenue" here = fees and interest the bank earns from the customer.
    This is the headline metric a Finance team dashboards against; the
    Phase 7 `dbt_banking` package will formalise a `metric_revenue`
    semantic layer definition on top.

    Grain: one row per (customer, business_month). An empty result for
    a given month means the customer paid no fees and earned no
    (bank-paid) interest.
#}

with transactions as (
    select *
    from {{ ref('fct_transactions') }}
    where transaction_status = 'posted'
      and is_revenue_txn
)

select
    customer_sk,
    customer_id,
    date_trunc('month', posted_at)                              as business_month,

    sum(case when transaction_type = 'fee'      then amount else 0 end) as fees_revenue,
    sum(case when transaction_type = 'interest' then amount else 0 end) as interest_revenue,
    sum(amount)                                                 as total_revenue,
    count(*)                                                    as revenue_txn_count,
    max(currency)                                               as currency

from transactions
group by customer_sk, customer_id, date_trunc('month', posted_at)
