-- Singular test — fails if the posted-transactions SUM(amount) diverges
-- between staging and fact.
--
-- Complements assert_fct_matches_stg_rowcount: same row count but
-- wrong amounts would pass that test and fail this one (e.g. a column
-- rename that silently dropped decimal digits).

with staging as (
    select coalesce(sum(amount), 0) as total
    from {{ ref('stg_banking__transactions') }}
    where transaction_status = 'posted'
      and not _is_deleted
),

fact as (
    select coalesce(sum(amount), 0) as total
    from {{ ref('fct_transactions') }}
    where transaction_status = 'posted'
)

select
    'posted sum mismatch between stg_banking__transactions and fct_transactions' as failure_mode,
    staging.total                                                                 as stg_total,
    fact.total                                                                    as fct_total,
    fact.total - staging.total                                                    as fct_minus_stg
from staging, fact
where abs(staging.total - fact.total) > 0.0001
