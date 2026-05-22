{#
    `amount` arrives from Debezium as a string because the connector is
    configured with `decimal.handling.mode=string` (see pg-source.json).
    Casting back to NUMERIC(18,4) here gives downstream marts a typed
    column without having to re-interpret it on every call.
#}

{{ config(materialized='view') }}

select
    id                                                 as transaction_id_pk,
    transaction_id                                     as transaction_uuid,
    account_id,
    cast(amount as numeric(18, 4))                     as amount,
    currency,
    direction,
    transaction_type,
    status                                             as transaction_status,
    description,
    posted_at,
    created_at,
    updated_at,

    __op                                               as _cdc_op,
    (__op = 'd')                                       as _is_deleted,
    __source_ts_ms                                     as _cdc_source_ts_ms,
    __lsn                                              as _cdc_lsn,
    __ingested_at                                      as _cdc_ingested_at

from {{ source('banking_raw', 'transactions') }}

qualify row_number() over (
    partition by id
    order by __lsn desc, __source_ts_ms desc
) = 1
