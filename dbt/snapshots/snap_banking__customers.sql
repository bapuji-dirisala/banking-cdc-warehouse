{#
    SCD2 history for customers.

    Reads from stg_banking__customers (which already de-dupes the raw
    CDC log to current-state per customer) and tracks changes over time
    via dbt's `timestamp` strategy on `updated_at`.

    Deleted customers are filtered out of the source; dbt's
    `invalidate_hard_deletes: true` (set in dbt_project.yml) then
    closes the current SCD2 row by setting `dbt_valid_to`. This gives
    us the regulatory-friendly shape:

        - a row disappears from the OLTP → snapshot closes its last version
        - a row's attributes change → snapshot opens a new version
        - a row never changes → snapshot stays as one open version

    The snapshot table itself IS the SCD2 — dbt adds `dbt_valid_from`,
    `dbt_valid_to`, `dbt_scd_id`, `dbt_updated_at`. The thin
    `dim_customer_scd2` view in marts/core renames these for business
    consumption.
#}

{% snapshot snap_banking__customers %}

    {{
        config(
            unique_key='customer_id',
        )
    }}

    select
        customer_id,
        external_id,
        first_name,
        last_name,
        email,
        phone,
        date_of_birth,
        kyc_status,
        created_at,
        updated_at
    from {{ ref('stg_banking__customers') }}
    where not _is_deleted

{% endsnapshot %}
