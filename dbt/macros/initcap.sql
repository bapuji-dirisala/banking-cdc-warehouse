{#
    Portable title-case for a single-word column.

    Snowflake and Postgres ship `INITCAP(col)`; DuckDB does not. This
    macro dispatches on adapter type so the mart SQL stays identical:

        {{ banking_cdc.initcap('account_type') }}

    Caveat: like Snowflake's own INITCAP, this only promotes the first
    character. For multi-word strings use an explicit CASE expression
    with the canonical label (preferable anyway, since enum display
    strings often don't follow strict title-case rules —
    e.g. `transfer_in` → `Transfer In`, not `Transfer_in`).
#}
{% macro initcap(col) %}
    {{ return(adapter.dispatch('initcap', 'banking_cdc')(col)) }}
{% endmacro %}

{% macro default__initcap(col) %}
    initcap({{ col }})
{% endmacro %}

{% macro duckdb__initcap(col) %}
    upper(substr({{ col }}, 1, 1)) || lower(substr({{ col }}, 2))
{% endmacro %}
