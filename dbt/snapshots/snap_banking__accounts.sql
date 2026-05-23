{#
    SCD2 history for accounts. Same pattern as snap_banking__customers:
    read from the deduped staging view, track changes on `updated_at`,
    invalidate deleted accounts via hard-delete semantics.

    Business reason this matters more for accounts than customers:
    `account_status` flips (active → frozen → closed) are
    audit-critical. Any investigation into "when did this account get
    frozen?" reads directly from the snapshot — no mart gymnastics.
#}

{% snapshot snap_banking__accounts %}

    {{
        config(
            unique_key='account_id',
        )
    }}

    select
        account_id,
        account_number,
        customer_id,
        account_type,
        currency,
        account_status,
        opened_at,
        closed_at,
        updated_at
    from {{ ref('stg_banking__accounts') }}
    where not _is_deleted

{% endsnapshot %}
