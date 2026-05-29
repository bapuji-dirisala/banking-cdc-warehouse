{#
    First consumer-ready view that composes the Phase 8 PII mask macros.
    Serves the Marketing team's cohort + outreach workflows: enough
    identity to send an email, nowhere near enough to re-identify.

    What Snowflake does with the base columns:
        email -> masking policy fires per CURRENT_ROLE() (see
                 snowflake/governance/02-masking-policies.sql)
        phone -> same
    What this view does with the macros:
        banking_cdc.mask_email / mask_phone compile to:
          - Snowflake: `email` (identity — the policy already handles it)
          - DuckDB:    deterministic SQL mask so dev-mode output looks
                       the same as prod does to a Marketing-role query
    Net: a Marketing analyst querying this view sees the same shape
    (a***@domain.com) regardless of which environment they're in.
#}

{{ config(materialized='view', schema='consumer') }}

select
    customer_sk,
    external_id,

    -- Masked identity — safe for marketing cohort work, campaign exports.
    {{ banking_cdc.mask_email('email') }}       as email_masked,
    {{ banking_cdc.mask_phone('phone') }}       as phone_masked,

    -- Demographic cohort — more useful than raw DOB for segmentation.
    age_years,
    case
        when age_years < 25 then 'under_25'
        when age_years < 40 then '25_to_39'
        when age_years < 60 then '40_to_59'
        when age_years is not null then '60_plus'
    end                                          as age_cohort,

    -- Status label (not the raw code) — consumer surfaces speak business.
    kyc_status_label,

    -- Audit lineage — same column names across every consumer view.
    source_lsn,
    source_ingested_at

from {{ ref('dim_customer') }}
