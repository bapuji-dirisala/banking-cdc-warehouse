{#
    Customer dimension — SCD1 (current-state only). SCD2 history lands in
    Phase 6 via dbt snapshots over the raw CDC log.

    Deleted customers are filtered out at the dim layer: the business
    question "who are our active customers?" expects a clean surface, not
    a tombstone-aware boolean. The audit trail stays in staging and in
    the (future) P6 snapshot.
#}

with staging as (
    select *
    from {{ ref('stg_banking__customers') }}
    where not _is_deleted
)

select
    -- surrogate + natural keys
    {{ dbt_utils.generate_surrogate_key(['customer_id']) }}  as customer_sk,
    customer_id,
    external_id,

    -- personally identifying info — Phase 8 adds Snowflake dynamic masking
    first_name,
    last_name,
    first_name || ' ' || last_name                           as full_name,
    email,
    phone,

    -- demographic
    date_of_birth,
    datediff('year', date_of_birth, current_date)            as age_years,

    -- status
    kyc_status,
    case kyc_status
        when 'verified' then 'Verified'
        when 'pending'  then 'Pending Review'
        when 'rejected' then 'Rejected'
    end                                                      as kyc_status_label,

    -- audit
    created_at,
    updated_at,
    _cdc_lsn                                                 as source_lsn,
    _cdc_ingested_at                                         as source_ingested_at

from staging
