{#
    PII mask dispatchers.

    These macros exist so a model can expose a *deterministically masked*
    column (e.g. `email_masked`) that behaves consistently in dev + prod:

    - Snowflake prod: the raw column has a MASKING POLICY attached (see
      `snowflake/governance/02-masking-policies.sql`). The underlying
      storage is clear; the mask is applied at query time per role.
      These macros return the column unchanged — the policy owns the
      transformation.

    - DuckDB dev: there's no RBAC and no masking policies. These macros
      return a deterministic SQL-level mask so a `vw_customer_marketing`
      view or similar renders consistently in both environments.

    Semantic contract: a mart column named `*_masked` is *always*
    masked, regardless of adapter + role. A column named without that
    suffix is subject to runtime policy on Snowflake, raw on DuckDB.
#}

-- mask_email -----------------------------------------------------------
{% macro mask_email(col) %}
    {{ return(adapter.dispatch('mask_email', 'banking_cdc')(col)) }}
{% endmacro %}

{% macro default__mask_email(col) %}
    {{ col }}
{% endmacro %}

{% macro duckdb__mask_email(col) %}
    case
        when {{ col }} is null then null
        else substr({{ col }}, 1, 1) || '***@' || split_part({{ col }}, '@', 2)
    end
{% endmacro %}

-- mask_phone -----------------------------------------------------------
{% macro mask_phone(col) %}
    {{ return(adapter.dispatch('mask_phone', 'banking_cdc')(col)) }}
{% endmacro %}

{% macro default__mask_phone(col) %}
    {{ col }}
{% endmacro %}

{% macro duckdb__mask_phone(col) %}
    case
        when {{ col }} is null then null
        else regexp_replace({{ col }}, '[0-9]', '*', 'g')
    end
{% endmacro %}
