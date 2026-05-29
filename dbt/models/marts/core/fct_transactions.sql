{#
    Transaction fact — grain is one row per OLTP transaction (business
    PK = transaction_id_pk). Deletes are **retained** here (unlike the
    dims) because a deleted transaction is still a historical event you
    want in reporting; the regulatory ask is "what happened and when",
    not "what currently exists".

    `fct_transactions` carries both `account_sk` and `customer_sk` so a
    typical star-schema query only hits one dim per subject area, not two.

    Phase 7 — switched to **incremental** using `_cdc_lsn` as the
    watermark. This is the dbt-native alternative to the Phase 6
    Snowflake Streams + Tasks pattern: both ways work, both are shipped,
    the right choice depends on cadence (incremental dbt = batch,
    streams/tasks = sub-minute). `delete+insert` strategy is portable
    across DuckDB (default) and Snowflake. Run with `--full-refresh` to
    rebuild from scratch, e.g. after a schema change.
#}

{{ config(
    materialized='incremental',
    unique_key='transaction_sk',
    incremental_strategy='delete+insert',
) }}

with enriched as (
    select * from {{ ref('int_banking__transactions_enriched') }}

    {% if is_incremental() %}
        -- Only pull rows whose CDC LSN is newer than the max we've
        -- already materialised. coalesce protects the first incremental
        -- run after a full refresh (max over empty table is NULL).
        where _cdc_lsn > (select coalesce(max(source_lsn), 0) from {{ this }})
    {% endif %}
),

accounts as (
    select account_id, account_sk, customer_sk
    from {{ ref('dim_account') }}
)

select
    -- surrogate + natural keys
    {{ dbt_utils.generate_surrogate_key(['enriched.transaction_id_pk']) }} as transaction_sk,
    enriched.transaction_id_pk,
    enriched.transaction_uuid,

    -- dim FKs
    accounts.account_sk,
    accounts.customer_sk,
    enriched.account_id,
    enriched.customer_id,

    -- measures
    enriched.amount,
    enriched.signed_amount,
    enriched.transaction_currency                                           as currency,
    enriched.is_debit,
    enriched.is_revenue_txn,

    -- enum code + label pairs
    enriched.direction,
    {{ banking_cdc.initcap('enriched.direction') }}                         as direction_label,

    enriched.transaction_type,
    case enriched.transaction_type
        when 'purchase'      then 'Purchase'
        when 'deposit'       then 'Deposit'
        when 'withdrawal'    then 'Withdrawal'
        when 'transfer_in'   then 'Transfer In'
        when 'transfer_out'  then 'Transfer Out'
        when 'fee'           then 'Fee'
        when 'interest'      then 'Interest'
    end                                                                     as transaction_type_label,

    enriched.transaction_status,
    {{ banking_cdc.initcap('enriched.transaction_status') }}                as transaction_status_label,

    enriched.description,

    -- time
    enriched.posted_at,
    cast(enriched.posted_at as date)                                        as posted_date,
    enriched.created_at,
    enriched.updated_at,

    -- audit
    enriched._cdc_op                                                        as source_cdc_op,
    enriched._cdc_lsn                                                       as source_lsn,
    enriched._cdc_ingested_at                                               as source_ingested_at

from enriched
left join accounts
    on enriched.account_id = accounts.account_id
