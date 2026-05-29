{#
    MetricFlow time spine — one row per day, used by the semantic layer
    to join metrics against calendar dates. Required by any
    `semantic_model` that declares a time dimension / agg_time_dimension.

    Deliberately generous bounds (2020..2027 inclusive) so a user
    querying historical trends against this project's seeded fixture
    (dates in 2024) sees a full picture. In prod, align the end date to
    `current_date + 90 days` via a scheduled rebuild.

    Materialised as table rather than view because a MetricFlow query
    plan reads this per-query — view would re-expand the date_spine
    recursive CTE on every lookup.
#}

{{ config(materialized='table', schema='meta') }}

with days as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2020-01-01' as date)",
        end_date="cast('2027-01-01' as date)",
    ) }}
)

select cast(date_day as date) as date_day
from days
