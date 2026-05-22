{{ config(materialized='view') }}

select
    id                                                 as card_event_id_pk,
    event_id                                           as card_event_uuid,
    account_id,
    transaction_id                                     as transaction_uuid,
    card_last4,
    event_type                                         as card_event_type,
    cast(amount as numeric(18, 4))                     as amount,
    currency,
    merchant_name,
    merchant_mcc,
    occurred_at,
    created_at,

    __op                                               as _cdc_op,
    (__op = 'd')                                       as _is_deleted,
    __source_ts_ms                                     as _cdc_source_ts_ms,
    __lsn                                              as _cdc_lsn,
    __ingested_at                                      as _cdc_ingested_at

from {{ source('banking_raw', 'card_events') }}

qualify row_number() over (
    partition by id
    order by __lsn desc, __source_ts_ms desc
) = 1
