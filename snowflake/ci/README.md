# snowflake/ci/ — Phase 11 blue/green CI (code-only)

Snowflake-side orchestration for the blue/green CI pattern described in
[`../../docs/phase-11-blue-green-ci.md`](../../docs/phase-11-blue-green-ci.md).
Nothing in this directory is executed by the local DuckDB build; the
companion GitHub Actions workflow lives at
[`../../.github/workflows/snowflake-blue-green.yml.disabled`](../../.github/workflows/snowflake-blue-green.yml.disabled)
and is committed with the `.disabled` suffix so GHA doesn't try to run it
without a real Snowflake account.

## Apply order

| Step | File | Role | Purpose |
|---|---|---|---|
| 1 | `01-clone-baseline.sql` | `SYSADMIN` → `BANKING_CI` | Zero-copy clone `BANKING_PROD` → `BANKING_CI_PR_<n>` on PR open |
| 2 | `02-promote-blue-green.sql` | `SYSADMIN` | Atomic SWAP of the built clone into prod on merge-to-main |
| 3 | `03-cleanup-clones.sql` | `ACCOUNTADMIN` | One-time install of the sweeper task + stored proc; runs twice daily |

Step 1 runs **per PR**, step 2 runs **per merge**, step 3 runs **once**
at bootstrap (the task takes over after that).

## The three Snowflake primitives this phase relies on

| Primitive | What it does | Why it matters here |
|---|---|---|
| `CREATE DATABASE … CLONE` | Metadata-only snapshot; shares micro-partitions with the source until a write forks them | PR clones cost ~0 at creation; writes during `dbt build` are the only real spend |
| `ALTER DATABASE … SWAP WITH …` | Atomic rename-exchange; readers see one or the other, never a mix | Zero-downtime promotion; BI tools never see a half-built state |
| `TASK` + `STORED PROCEDURE` | Native scheduler + owner-rights execution | Sweeper runs without external auth; survives GHA outages |

## The dbt wiring

See [`../../dbt/macros/clone_prod_to_ci.sql`](../../dbt/macros/clone_prod_to_ci.sql)
and [`../../dbt/macros/drop_ci_clone.sql`](../../dbt/macros/drop_ci_clone.sql).
Both are adapter-dispatched — Snowflake variants render real DDL,
DuckDB variants log a no-op reminder so a reader running the macro
locally sees "this would clone BANKING_PROD on Snowflake" instead of a
cryptic failure.

The `--defer --state:modified+` wiring is adapter-agnostic — it runs on
every `ci` target build, including the DuckDB defer workflow in
[`../../.github/workflows/pr-lineage.yml`](../../.github/workflows/pr-lineage.yml).

## Rollback

Promotion is a `SWAP`. The ex-prod is renamed `BANKING_ROLLBACK_<timestamp>`.
Reverting is one line (template in `02-promote-blue-green.sql`):

```sql
ALTER DATABASE BANKING_PROD SWAP WITH BANKING_ROLLBACK_<timestamp>;
```

Also atomic. Readers mid-query at the moment of revert see one side or
the other.

## Related

- [`../ddl/01-roles.sql`](../ddl/01-roles.sql) — role hierarchy (needs
  `BANKING_CI` added as a sibling of `BANKING_ENGINEER` before any of
  this runs; TODO documented in Phase 11 doc)
- [`../cost-perf/02-warehouse-tuning.sql`](../cost-perf/02-warehouse-tuning.sql)
  — Phase 10 provisioned the `WH_TRANSFORM_S_DEV` warehouse this phase's
  clones + sweeper use
- [`../../docs/phase-11-blue-green-ci.md`](../../docs/phase-11-blue-green-ci.md)
  — design doc with the sequence diagrams + storage-cost arithmetic
