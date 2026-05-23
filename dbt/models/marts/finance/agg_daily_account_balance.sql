{#
    Daily net balance delta per account.

    Grain: one row per (account, business_date). The sum of `net_change`
    across all dates for an account is the account's current balance
    (modulo starting balance, which Phase 7 — dbt_banking package — adds
    as a snapshot-based opening-balance anchor).

    Only `posted` transactions move balances; pending and reversed are
    excluded. This is intentional and matches regulatory reporting rules.
#}

with transactions as (
    select *
    from {{ ref('fct_transactions') }}
    where transaction_status = 'posted'
)

select
    account_sk,
    customer_sk,
    account_id,
    cast(posted_at as date)                                    as business_date,

    sum(signed_amount)                                         as net_change,
    sum(case when direction = 'credit' then amount else 0 end) as credits,
    sum(case when direction = 'debit'  then amount else 0 end) as debits,
    count(*)                                                   as txn_count,
    count(distinct transaction_type)                           as distinct_type_count,
    max(currency)                                              as currency

from transactions
group by account_sk, customer_sk, account_id, cast(posted_at as date)
