{#
    Card-event fact — grain is one row per card lifecycle event
    (authorization / capture / decline / reversal / refund).

    Linked to `fct_transactions` by `transaction_uuid` because some card
    events (declines, authorizations that never capture) don't produce a
    posted transaction — the link is nullable on purpose.
#}

with card_events as (
    select * from {{ ref('stg_banking__card_events') }}
),

accounts as (
    select account_id, account_sk, customer_sk
    from {{ ref('dim_account') }}
)

select
    -- surrogate + natural keys
    {{ dbt_utils.generate_surrogate_key(['card_events.card_event_id_pk']) }} as card_event_sk,
    card_events.card_event_id_pk,
    card_events.card_event_uuid,

    -- dim + fact FKs (transaction_uuid is nullable; declines never post)
    accounts.account_sk,
    accounts.customer_sk,
    card_events.account_id,
    card_events.transaction_uuid,

    -- card attributes
    card_events.card_last4,
    card_events.card_event_type,
    {{ banking_cdc.initcap('card_events.card_event_type') }}                 as card_event_type_label,

    -- measures
    card_events.amount,
    card_events.currency,

    -- merchant
    card_events.merchant_name,
    card_events.merchant_mcc,

    -- time
    card_events.occurred_at,
    cast(card_events.occurred_at as date)                                    as occurred_date,
    card_events.created_at,

    -- audit
    card_events._cdc_op                                                      as source_cdc_op,
    card_events._cdc_lsn                                                     as source_lsn,
    card_events._cdc_ingested_at                                             as source_ingested_at

from card_events
left join accounts
    on card_events.account_id = accounts.account_id
