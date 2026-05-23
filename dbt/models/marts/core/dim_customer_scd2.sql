{#
    SCD2 customer dimension. One row per (customer, version) — unlike
    dim_customer which only has the current version.

    Materialized as a view because the underlying snapshot is already
    a managed table; wrapping it in another table would just duplicate
    bytes. If a Phase 7 metric needs a persistent SCD2 table (e.g. for
    an exported dataset), swap `view` → `table` in a model-level config.

    Surrogate-key convention: hash(customer_id || valid_from), so each
    historical version has a unique key. fct_* models wanting to join
    to the customer dim "as it was on posted_date" use:

        join dim_customer_scd2 c
            on fct.customer_id = c.customer_id
            and fct.posted_at >= c.valid_from
            and (fct.posted_at < c.valid_to or c.valid_to is null)

    This is the standard point-in-time SCD2 join.
#}

{{ config(materialized='view') }}

select
    {{ dbt_utils.generate_surrogate_key(['customer_id', 'dbt_valid_from']) }}  as customer_scd2_sk,
    customer_id,
    external_id,
    first_name,
    last_name,
    first_name || ' ' || last_name                                             as full_name,
    email,
    phone,
    date_of_birth,
    kyc_status,
    case kyc_status
        when 'verified' then 'Verified'
        when 'pending'  then 'Pending Review'
        when 'rejected' then 'Rejected'
    end                                                                         as kyc_status_label,
    created_at,
    updated_at,

    dbt_valid_from                                                              as valid_from,
    dbt_valid_to                                                                as valid_to,
    (dbt_valid_to is null)                                                      as is_current,
    dbt_scd_id

from {{ ref('snap_banking__customers') }}
