{#
    Phase 10 — JSON query-tag emitter for Snowflake cost attribution.

    Two layers of macro here:

    1. `query_tag_json()` — the renderable payload. Adapter-dispatched
       so Snowflake gets a rich JSON tag and every other adapter gets
       an empty string. Also usable ad-hoc:
           `{{ log(query_tag_json(), info=True) }}` from `dbt run-operation`.

    2. `set_query_tag()` + `unset_query_tag()` — override the dbt-snowflake
       hooks that the adapter calls automatically before/after every
       model, test, snapshot, seed, and run-operation. dbt-duckdb never
       calls these hooks, so this file is a no-op in dev; no DuckDB
       guard is needed. See dbt-snowflake source:
           https://github.com/dbt-labs/dbt-snowflake/blob/main/dbt/include/snowflake/macros/apply_grants.sql
       (set_query_tag is a public override point documented in the
       dbt-snowflake README under "Query tags".)

    Why a hook override instead of `+query_tag` in dbt_project.yml?
    `+query_tag` is parsed in a limited Jinja context that doesn't
    include user macros, so `+query_tag: "{{ query_tag_json() }}"` fails
    to compile. The `set_query_tag()` override runs in the full dbt
    render context where `model`, `invocation_id`, `target`, and
    `project_name` are all defined — the Jinja state we actually need.
#}

{% macro query_tag_json() %}
    {{ return(adapter.dispatch('query_tag_json', 'banking_cdc')()) }}
{% endmacro %}


{% macro default__query_tag_json() %}
    {# Default (DuckDB + any other non-Snowflake adapter) — empty string. #}
    {{ return('') }}
{% endmacro %}


{% macro snowflake__query_tag_json() %}
    {# Full JSON — single line is intentional so the tag column is grep-friendly. #}
    {%- set tag = {
        'project'       : project_name,
        'dbt_target'    : target.name,
        'invocation_id' : invocation_id,
        'model'         : (model.name if model is defined and model is not none else 'on-run'),
        'materialization': (model.config.materialized
                            if model is defined
                               and model is not none
                               and model.config is defined
                            else 'none'),
        'resource_type' : (model.resource_type
                           if model is defined and model is not none
                           else 'none')
    } -%}
    {{ return(tojson(tag)) }}
{% endmacro %}


{#
    dbt-snowflake override — called automatically before each model /
    test / snapshot build. Setting the session tag here means every
    statement that dbt-snowflake emits (CREATE TABLE, MERGE, SELECT for
    tests, etc.) inherits the tag without any per-model wiring.
#}
{% macro set_query_tag() %}
    {%- set tag = query_tag_json() -%}
    {%- if tag -%}
        {%- do run_query("alter session set query_tag = '" ~ tag | replace("'", "''") ~ "'") -%}
    {%- endif -%}
    {{ return('') }}
{% endmacro %}


{#
    dbt-snowflake override — called automatically AFTER each model build.
    Resets the session tag so a subsequent ad-hoc query in the same
    session isn't misattributed to the last model dbt ran.
#}
{% macro unset_query_tag(original_query_tag) %}
    {%- if original_query_tag -%}
        {%- do run_query("alter session set query_tag = '" ~ original_query_tag | replace("'", "''") ~ "'") -%}
    {%- else -%}
        {%- do run_query("alter session unset query_tag") -%}
    {%- endif -%}
    {{ return('') }}
{% endmacro %}


{#
    Smoke-test operation — exercise the macro from the shell so a reader
    can verify the dispatch without a real Snowflake connection:

        dbt run-operation print_query_tag --profiles-dir . --target dev
        → "" (empty — DuckDB)

        dbt run-operation print_query_tag --profiles-dir . --target prod
        → '{"project":"banking_cdc_warehouse","dbt_target":"prod",...}'
#}
{% macro print_query_tag() %}
    {%- set rendered = query_tag_json() -%}
    {{ log("query_tag_json() rendered to: '" ~ rendered ~ "'", info=True) }}
{% endmacro %}
