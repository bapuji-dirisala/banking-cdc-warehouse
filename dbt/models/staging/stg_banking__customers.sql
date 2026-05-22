{#
    Staging dimension — latest known state per customer_id.

    The `qualify row_number() over (...) = 1` pattern is the portable
    envelope-aware dedup across both adapters:

    * DuckDB (dev)   — the sink is DELETE-then-INSERT so there's already
                       at most one row per PK; the window is a no-op pass.
    * Snowflake (prod)
                     — the Kafka Connector appends every change event, so
                       the window picks the latest `__lsn`-ordered row.

    Both DuckDB (>=0.9) and Snowflake support QUALIFY — same SQL, both
    adapters. See `docs/phase-04-staging.md` for the full rationale.
#}

{{ config(materialized='view') }}

select
    -- business keys + attributes
    id                                                 as customer_id,
    external_id,
    first_name,
    last_name,
    email,
    phone,
    date_of_birth,
    kyc_status,
    created_at,
    updated_at,

    -- cdc envelope metadata — Phase 5 marts can carry these forward or
    -- drop them; they stay here so lineage from source → mart is auditable.
    __op                                               as _cdc_op,
    (__op = 'd')                                       as _is_deleted,
    __source_ts_ms                                     as _cdc_source_ts_ms,
    __lsn                                              as _cdc_lsn,
    __ingested_at                                      as _cdc_ingested_at

from {{ source('banking_raw', 'customers') }}

qualify row_number() over (
    partition by id
    order by __lsn desc, __source_ts_ms desc
) = 1
