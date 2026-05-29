-- Singular test — fails if staging and fact disagree on transaction count.
--
-- A dbt singular test returns 0 rows on PASS. Any returned row is a
-- failure and dbt build halts (or warns if `severity: warn` is set in
-- the test yml — not used here; this is a hard contract).
--
-- Why this test matters: a plumbing bug that silently drops rows
-- between staging and fct (incremental-model watermark too tight,
-- a `where` clause typo, etc.) would show up here immediately.

with staging as (
    select count(*) as n
    from {{ ref('stg_banking__transactions') }}
    where not _is_deleted
),

fact as (
    select count(*) as n
    from {{ ref('fct_transactions') }}
)

select
    'row count mismatch between stg_banking__transactions and fct_transactions' as failure_mode,
    staging.n                                                                    as stg_count,
    fact.n                                                                       as fct_count,
    staging.n - fact.n                                                           as stg_minus_fct
from staging, fact
where staging.n <> fact.n
