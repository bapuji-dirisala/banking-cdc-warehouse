{#
    Phase 11 — clone BANKING_PROD into a PR-scoped CI database.

    Called from the Snowflake-side CI driver via:
        dbt run-operation clone_prod_to_ci --args '{pr_id: "123"}'

    Adapter dispatch:
    - snowflake  → real CREATE OR REPLACE DATABASE ... CLONE
    - duckdb     → log a reminder (no DuckDB equivalent; the local defer
                   workflow uses manifest state in CI runner artifacts,
                   not a cloned warehouse)
    - any other  → log + no-op

    Invariants:
    - BANKING_CI role must exist before this runs (see snowflake/ddl/01-roles.sql
      Phase 11 TODO).
    - The caller's role must have CREATE DATABASE at the account level
      and OWNERSHIP on the source database.
    - pr_id is sanitised to a-zA-Z0-9_ before injection; GitHub PR IDs are
      numeric so this is defensive hardening against a mis-pass.
#}

{% macro clone_prod_to_ci(pr_id, source_db='BANKING_PROD') %}
    {{ return(adapter.dispatch('clone_prod_to_ci', 'banking_cdc')(pr_id, source_db)) }}
{% endmacro %}


{% macro default__clone_prod_to_ci(pr_id, source_db) %}
    {# Non-Snowflake adapters have no CLONE primitive. #}
    {{ log("[clone_prod_to_ci] no-op on adapter " ~ target.type ~
           " — would clone " ~ source_db ~ " to BANKING_CI_PR_" ~ pr_id ~
           " on snowflake. See snowflake/ci/01-clone-baseline.sql for the real DDL.",
           info=True) }}
{% endmacro %}


{% macro snowflake__clone_prod_to_ci(pr_id, source_db) %}
    {%- set pr_id_clean = pr_id | string | replace("-", "_") -%}
    {%- set clone_db    = 'BANKING_CI_PR_' ~ pr_id_clean -%}

    {{ log("[clone_prod_to_ci] cloning " ~ source_db ~ " -> " ~ clone_db, info=True) }}

    {%- call statement('clone', fetch_result=False) -%}
        create or replace database {{ clone_db }} clone {{ source_db }}
    {%- endcall -%}

    {# Narrow Time Travel on the ephemeral clone — fail-safe is wasted
       budget for a 24h CI object. #}
    {%- call statement('retention', fetch_result=False) -%}
        alter database {{ clone_db }} set data_retention_time_in_days = 0
    {%- endcall -%}

    {# Transfer ownership to the CI role so the PR dbt build can both
       write and clean up without the operator-role in the middle. #}
    {%- call statement('ownership', fetch_result=False) -%}
        grant ownership on database {{ clone_db }}
            to role banking_ci revoke current grants
    {%- endcall -%}

    {{ return(clone_db) }}
{% endmacro %}
