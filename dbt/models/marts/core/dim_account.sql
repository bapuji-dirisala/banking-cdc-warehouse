{#
    Account dimension — SCD1 (current-state only).

    Carries `customer_sk` directly so fct_transactions can roll up to
    customer without a dim_account → dim_customer hop. This is standard
    star-schema denormalization: the fact table references the
    lowest-grain dim (account), which carries forward the higher-grain
    dim keys (customer) it belongs to.
#}

with accounts as (
    select *
    from {{ ref('stg_banking__accounts') }}
    where not _is_deleted
),

customers as (
    select customer_id, customer_sk
    from {{ ref('dim_customer') }}
)

select
    -- surrogate + natural keys
    {{ dbt_utils.generate_surrogate_key(['accounts.account_id']) }}  as account_sk,
    accounts.account_id,
    accounts.account_number,

    -- customer FK (both forms — surrogate for star-schema joins,
    -- natural for ad-hoc queries)
    customers.customer_sk,
    accounts.customer_id,

    -- account attributes
    accounts.account_type,
    {{ banking_cdc.initcap('accounts.account_type') }}               as account_type_label,
    accounts.currency,
    accounts.account_status,
    case accounts.account_status
        when 'active' then 'Active'
        when 'frozen' then 'Frozen'
        when 'closed' then 'Closed'
    end                                                              as account_status_label,

    -- lifecycle
    accounts.opened_at,
    accounts.closed_at,
    accounts.updated_at,
    (accounts.closed_at is not null)                                 as is_closed,

    -- audit
    accounts._cdc_lsn                                                as source_lsn,
    accounts._cdc_ingested_at                                        as source_ingested_at

from accounts
left join customers
    on accounts.customer_id = customers.customer_id
