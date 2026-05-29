{#
    Portable divide-by-zero handling.

    Snowflake has `DIV0NULL(num, denom)` which returns NULL on zero
    denominator. DuckDB has no built-in; the division just returns NaN /
    Infinity for floats and errors for integers. This macro dispatches
    so you can write:

        {{ banking_cdc.safe_divide('revenue', 'txn_count') }}

    …without branching per adapter in your mart SQL. In both cases a
    zero (or NULL) denominator returns NULL — the semantically correct
    answer for "what's the per-txn revenue when there are no txns".
#}
{% macro safe_divide(numerator, denominator) %}
    {{ return(adapter.dispatch('safe_divide', 'banking_cdc')(numerator, denominator)) }}
{% endmacro %}

{% macro default__safe_divide(numerator, denominator) %}
    div0null({{ numerator }}, {{ denominator }})
{% endmacro %}

{% macro duckdb__safe_divide(numerator, denominator) %}
    case
        when {{ denominator }} is null or {{ denominator }} = 0 then null
        else {{ numerator }} / {{ denominator }}
    end
{% endmacro %}
