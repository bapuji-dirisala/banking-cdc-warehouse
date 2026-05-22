{#
    Override of dbt's default `generate_schema_name` so a model's
    `+schema:` config maps **directly** onto the final warehouse schema
    (no `<target_schema>_<custom_schema>` prefix).

    This keeps DEV and PROD symmetric:

        duckdb dev  → raw / staging / intermediate / marts
        snowflake   → RAW / STAGING / INTERMEDIATE / MARTS

    The default dbt behaviour would give us `main_staging` in DuckDB and
    `PUBLIC_STAGING` in Snowflake, which is noise, not information.

    The one exception is any model that doesn't declare `+schema:` — those
    fall back to `target.schema`, which is `main` in dev and `STAGING` in
    prod per profiles.yml. That's intentional: an un-schema'd model is a
    coding mistake we want to be visible.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema | trim }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
