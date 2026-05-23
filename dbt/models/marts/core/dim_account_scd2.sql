{#
    SCD2 account dimension. See dim_customer_scd2 for the full rationale
    on surrogate-key composition and point-in-time join pattern.
#}

{{ config(materialized='view') }}

select
    {{ dbt_utils.generate_surrogate_key(['account_id', 'dbt_valid_from']) }}  as account_scd2_sk,
    account_id,
    account_number,
    customer_id,
    account_type,
    {{ banking_cdc.initcap('account_type') }}                                 as account_type_label,
    currency,
    account_status,
    case account_status
        when 'active' then 'Active'
        when 'frozen' then 'Frozen'
        when 'closed' then 'Closed'
    end                                                                        as account_status_label,
    opened_at,
    closed_at,
    (closed_at is not null)                                                    as is_closed,
    updated_at,

    dbt_valid_from                                                             as valid_from,
    dbt_valid_to                                                               as valid_to,
    (dbt_valid_to is null)                                                     as is_current,
    dbt_scd_id

from {{ ref('snap_banking__accounts') }}
