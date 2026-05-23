{#
    Joins transactions → accounts → customers once, decodes enums, and
    adds derived measures. Downstream `fct_transactions` consumes this
    exactly once, so ephemeral materialization keeps the warehouse clean
    (the SQL inlines as a CTE) while still giving us a reusable, tested
    shape.
#}

with transactions as (
    select * from {{ ref('stg_banking__transactions') }}
),

accounts as (
    select * from {{ ref('stg_banking__accounts') }}
),

customers as (
    select * from {{ ref('stg_banking__customers') }}
)

select
    -- business + envelope keys
    transactions.transaction_id_pk,
    transactions.transaction_uuid,
    accounts.account_id,
    accounts.account_number,
    accounts.account_type,
    accounts.account_status,
    accounts.currency                                  as account_currency,
    customers.customer_id,
    customers.external_id                              as customer_external_id,

    -- transaction attributes
    transactions.amount,
    transactions.currency                              as transaction_currency,
    transactions.direction,
    transactions.transaction_type,
    transactions.transaction_status,
    transactions.description,

    -- derived measures
    case
        when transactions.direction = 'debit'  then -1 * transactions.amount
        when transactions.direction = 'credit' then      transactions.amount
    end                                                as signed_amount,
    (transactions.direction = 'debit')                 as is_debit,
    (transactions.transaction_type in ('fee', 'interest')) as is_revenue_txn,

    -- time
    transactions.posted_at,
    transactions.created_at,
    transactions.updated_at,

    -- cdc lineage — carries through from staging so marts can expose it
    transactions._cdc_op,
    transactions._cdc_lsn,
    transactions._cdc_source_ts_ms,
    transactions._cdc_ingested_at

from transactions
left join accounts
    on transactions.account_id = accounts.account_id
left join customers
    on accounts.customer_id = customers.customer_id
