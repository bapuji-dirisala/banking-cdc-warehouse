# Phase 11 — blue/green CI with zero-copy clones

**Status:** shipped (2026-10-25)
**Depends on:** Phase 3 (role hierarchy, baseline warehouses), Phase 10
(dev-tier warehouse `WH_TRANSFORM_S_DEV`)

## Goal

Make PR builds **fast + cheap + safe**:

- **Fast**: `--defer --state:modified+` rebuilds only models the PR
  touched + their descendants. A typo fix in a staging model doesn't
  re-materialise 158 downstream objects.
- **Cheap**: every PR gets a zero-copy clone of `BANKING_PROD`; writes
  during the build fork new micro-partitions but reads reuse source
  partitions for free. A full clone of a 10 TB prod is ~0 credits + 0
  storage at creation.
- **Safe**: promotion to prod is an atomic `ALTER DATABASE ... SWAP WITH`,
  not a 2-step rename. Readers see one side or the other, never a mix.
  Rollback is one line (another SWAP).

## Shape added

```
snowflake/ci/
├── 01-clone-baseline.sql           -- per-PR: CLONE prod -> BANKING_CI_PR_<n>
├── 02-promote-blue-green.sql       -- per-merge: SWAP clone -> prod
├── 03-cleanup-clones.sql           -- one-time: install sweeper task + proc
└── README.md

dbt/
├── profiles.yml                    -- new `ci` target (DuckDB defer path)
└── macros/
    ├── clone_prod_to_ci.sql        -- adapter-dispatched clone macro
    └── drop_ci_clone.sql           -- adapter-dispatched drop macro

.github/workflows/
├── ci.yml                          -- main-branch jobs now upload the baseline manifest
├── pr-lineage.yml                  -- NEW: PR-only --defer --state:modified+ job
└── snowflake-blue-green.yml.disabled -- committed Snowflake workflow template

scripts/
└── pr-rowcount-delta.py            -- NEW: per-model row-count delta for PR sticky comment
```

## The DuckDB defer workflow (actually runs)

Every push to main:
1. `ci.yml` builds + tests the full DAG against DuckDB.
2. On success it uploads `dbt/target/manifest.json` as artifact
   `dbt-manifest-main` with 14-day retention.

Every PR:
1. `pr-lineage.yml` downloads the newest `dbt-manifest-main` artifact
   from main (uses `dawidd6/action-download-artifact` which can reach
   across workflow runs).
2. Runs `dbt build --target ci --defer --state state/ --select state:modified+`
   — only the PR's touched models + descendants build.
3. Executes `scripts/pr-rowcount-delta.py` to produce a Markdown
   delta table and posts it as a sticky PR comment.

**First-run bootstrap:** if no main manifest exists yet (brand-new
repo), the download step soft-fails and the whole PR workflow
short-circuits with a `::notice::`. The main `ci.yml` full-build job
still runs as a safety net.

## The Snowflake blue/green workflow (code-only)

The `.disabled` suffix on `snowflake-blue-green.yml.disabled` keeps GHA
from executing it. To enable, rename + provision secrets. The workflow
has four jobs:

| Trigger | Job | Snowflake action |
|---|---|---|
| PR opened/sync | `clone` | `dbt run-operation clone_prod_to_ci` → `CREATE OR REPLACE DATABASE BANKING_CI_PR_<n> CLONE BANKING_PROD` |
| PR opened/sync | `build` | `dbt build --target prod --defer --state state/ --select state:modified+` into the clone |
| PR merged | `promote` | `snowflake/ci/02-promote-blue-green.sql` — atomic `SWAP` |
| PR closed (any) | `drop` | `dbt run-operation drop_ci_clone` → `DROP DATABASE IF EXISTS` |

A `BANKING_CI` role must be added to `snowflake/ddl/01-roles.sql` before
enabling — documented as a TODO in the role file.

## Why SWAP vs CLONE+rename?

| Primitive | Atomicity | Reader visibility | Rollback |
|---|---|---|---|
| `ALTER DATABASE X SWAP WITH Y` | **Atomic** | Sees old-fully OR new-fully, never both | Another SWAP |
| `DROP X` + `ALTER DATABASE Y RENAME TO X` | **Not atomic** | 50-500ms window where `X` doesn't exist → BI query errors | Have to restore from backup |

`SWAP` is the only correct primitive for zero-downtime promotion.
`CLONE+rename` is listed in some older docs; it's a trap.

## Why a task-based sweeper vs a GHA cron?

| Approach | Pros | Cons |
|---|---|---|
| **Snowflake TASK** (shipped) | No external auth; reads `ACCOUNT_USAGE.DATABASES` directly; survives GHA outages | Costs a few credits/day; must be ACCOUNTADMIN-owned |
| **GHA cron** | Centralised with the rest of the CI; visible in Actions UI | Needs long-lived Snowflake creds in GHA secrets; sensitive to runner outages |

The task-based path is shipped (`03-cleanup-clones.sql`) because the
operational blast radius is smaller. A GHA cron is listed in the
"what this phase does NOT ship" section as a documented alternative.

## Storage cost arithmetic for zero-copy clones

A worked example from the Snowflake docs (restated for clarity):

- Prod database: 10 TB of micro-partitions
- Clone at `t0`: **0 bytes extra** (clone + source share partitions)
- PR's dbt build rewrites `fct_transactions` incremental slice: **1 GB
  forked**
- PR's dbt build rebuilds `agg_daily_account_balance` (table materialization):
  **200 MB forked**
- Clone storage at `t_build_done`: **1.2 GB** (not 10 TB)
- Clone drop at `t_merge`: **1.2 GB reclaimed** (immediate for retention=0)

Multiply by N open PRs/day → total CI storage is bounded by (N × avg
model rewrite size), not by (N × prod size). Independent of prod data
volume.

## The TODO list to make this operational

- [ ] Add `BANKING_CI` role to `snowflake/ddl/01-roles.sql`
- [ ] Add `GRANT CREATE DATABASE ON ACCOUNT TO ROLE BANKING_CI` (needs
      `ACCOUNTADMIN` one-time)
- [ ] Provision the `nightly-sf-manifest` workflow that publishes the
      main-branch Snowflake manifest (so the SF `build` job's `--defer`
      has a baseline to read)
- [ ] Switch the dev-tier role to key-pair auth for use in GHA
      (`externalbrowser` won't work headlessly)
- [ ] Build out `scripts/pr-rowcount-delta.py` to also pull the
      baseline counts from a persisted-counts file (Phase 12 scope)

## What this phase explicitly does NOT ship

- An enabled Snowflake workflow (project-wide convention; code-only)
- The `BANKING_CI` role itself (listed as the Phase 11 operator TODO)
- A full baseline rowcount file (deferred to Phase 12 docs site, which
  will publish per-model counts as a static JSON alongside the manifest)
- Nightly SF manifest publishing (deferred — the dev loop uses defer
  against the DuckDB baseline only)
- Alert hooks on sweep-task failures (standard Snowflake pattern —
  `CREATE ALERT ON SNOWFLAKE.ALERT.TASK_HISTORY`)

## Local verification

```bash
# Confirm the clone macro renders cleanly on DuckDB (no-op log):
cd dbt
dbt run-operation clone_prod_to_ci \
    --profiles-dir . --target dev \
    --args '{pr_id: "123"}'
# → [clone_prod_to_ci] no-op on adapter duckdb — would clone BANKING_PROD
#   to BANKING_CI_PR_123 on snowflake. See snowflake/ci/01-clone-baseline.sql
#   for the real DDL.

# Confirm defer works end-to-end against two local DuckDB files:
#   1. Build the "baseline" into dev
dbt build --profiles-dir . --target dev --fail-fast

#   2. Save its manifest as the state/ reference
cp target/manifest.json state/manifest.json

#   3. Build only state:modified+ into the ci target (should be empty)
dbt build --profiles-dir . --target ci \
    --defer --state state/ \
    --select state:modified+ \
    --fail-fast
# → "No nodes selected" because nothing changed since the baseline.
```

## Next phase

**Phase 12** — hosted dbt docs site, exposures, dbt-docs-generate +
GitHub Pages publishing, column-level lineage diagrams, README polish,
and the per-model rowcount baseline file that fills the gap in
Phase 11's PR delta table.
