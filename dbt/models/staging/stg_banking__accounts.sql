{{ config(materialized='view') }}

select
    id                                                 as account_id,
    account_number,
    customer_id,
    account_type,
    currency,
    status                                             as account_status,
    opened_at,
    closed_at,
    updated_at,

    __op                                               as _cdc_op,
    (__op = 'd')                                       as _is_deleted,
    __source_ts_ms                                     as _cdc_source_ts_ms,
    __lsn                                              as _cdc_lsn,
    __ingested_at                                      as _cdc_ingested_at

from {{ source('banking_raw', 'accounts') }}

qualify row_number() over (
    partition by id
    order by __lsn desc, __source_ts_ms desc
) = 1
