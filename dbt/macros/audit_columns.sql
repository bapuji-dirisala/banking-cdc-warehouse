{#
    Emits the standard audit column block used by every mart in this
    project. Keeping this in one macro means a schema change (e.g. add
    `source_connector_id` once a second CDC source lands) is one edit,
    not twelve.

    Usage inside a model:

        select
            customer_id,
            ...,
            {{ banking_cdc.audit_columns('_cdc_lsn', '_cdc_ingested_at') }}
        from ...

    Produces:

            _cdc_lsn           as source_lsn,
            _cdc_ingested_at   as source_ingested_at,
            current_timestamp  as model_built_at
#}
{% macro audit_columns(lsn_col='_cdc_lsn', ingested_col='_cdc_ingested_at') %}
    {{ lsn_col }}            as source_lsn,
    {{ ingested_col }}       as source_ingested_at,
    current_timestamp        as model_built_at
{% endmacro %}
