{#
    Phase 11 — drop a PR-scoped CI clone.

    Called from the Snowflake-side CI driver on PR close / merge:
        dbt run-operation drop_ci_clone --args '{pr_id: "123"}'

    Adapter dispatch mirrors clone_prod_to_ci.sql:
    - snowflake  → DROP DATABASE IF EXISTS
    - duckdb     → no-op log
#}

{% macro drop_ci_clone(pr_id) %}
    {{ return(adapter.dispatch('drop_ci_clone', 'banking_cdc')(pr_id)) }}
{% endmacro %}


{% macro default__drop_ci_clone(pr_id) %}
    {{ log("[drop_ci_clone] no-op on adapter " ~ target.type ~
           " — would drop BANKING_CI_PR_" ~ pr_id ~ " on snowflake. " ~
           "See snowflake/ci/03-cleanup-clones.sql for the sweeper task.",
           info=True) }}
{% endmacro %}


{% macro snowflake__drop_ci_clone(pr_id) %}
    {%- set pr_id_clean = pr_id | string | replace("-", "_") -%}
    {%- set clone_db    = 'BANKING_CI_PR_' ~ pr_id_clean -%}

    {{ log("[drop_ci_clone] dropping " ~ clone_db, info=True) }}

    {%- call statement('drop', fetch_result=False) -%}
        drop database if exists {{ clone_db }}
    {%- endcall -%}
{% endmacro %}
