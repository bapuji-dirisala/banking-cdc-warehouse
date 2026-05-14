# Phase 1 — Postgres OLTP + synthetic transaction generator

## Goal

Stand up a realistic retail-banking OLTP source that Phase 2 can point
Debezium at without any further changes. Everything that lands in later
phases (bronze CDC, staging, snapshots, marts) is a downstream projection
of the rows this phase produces, so the schema needs to look like a real
banking system and the workload needs to look like real customer activity.

## What this phase delivers

- **`compose/` docker stack** — Postgres 16, `wal_level=logical`,
  `max_wal_senders=8`, `max_replication_slots=8`; a named volume for data
  and a bind-mounted init directory that applies schema on first boot
- **Canonical DDL** at `compose/postgres/init/00-schema.sql` — four tables
  (`customers`, `accounts`, `transactions`, `card_events`) with realistic
  columns, foreign keys, indexes, and `updated_at` triggers
- **`REPLICA IDENTITY FULL`** on every table — richer CDC events (full
  before-image on updates) at the cost of a bit more WAL volume; the right
  trade for a portfolio-scale workload where clarity beats micro-optimisation
- **SQLAlchemy 2.0 models** at `src/banking_cdc/oltp/models.py` — same
  schema, expressed as declarative models, kept in sync with the SQL by a
  DDL-rendering unit test
- **`banking_cdc.seed` package** — synthetic workload generator using
  Faker with weighted transaction flows (mostly `purchase`, some
  `deposit`/`withdrawal`, occasional `fee`), correlated `card_events` for
  purchase transactions, and deterministic runs via `--seed`
- **`banking-cdc` CLI** — a small argparse entry point with three
  commands: `oltp init` (idempotent schema apply), `oltp print-ddl`
  (emits DDL to stdout for diffing against the checked-in SQL), and
  `seed run` (drives the generator)
- **Unit tests** — the generator is exercised with a fixed seed and its
  distributions asserted (transaction type mix, direction sign convention,
  amount ranges) without touching a database
- **Integration test** (marker `integration`, deselected by default) —
  spins the schema up against a running compose Postgres, seeds a small
  batch, asserts row counts + referential integrity, and cleans up

## Design decisions

- **Schema is small on purpose.** Four tables — customer, account,
  transaction, card event — cover every CDC pattern the later phases
  need: a slowly-changing dimension (customer email/phone/kyc_status),
  an SCD2-worthy dimension with lifecycle (account status), a
  high-volume append-mostly fact (transaction), and a keyed event stream
  (card_events). Adding more tables now would only pad the diff — the
  interesting downstream work is on these four.

- **`REPLICA IDENTITY FULL` everywhere, not `DEFAULT`.** Debezium can
  work with `DEFAULT` (the primary key) for updates on non-key columns,
  but the resulting change events omit the full old row. For a portfolio
  project where readers want to *see* CDC working, `FULL` produces the
  more useful before/after payload. The WAL cost is negligible at
  portfolio scale.

- **`wal_level=logical`, not `replica`.** Logical decoding is the
  Debezium prerequisite. Setting it now (rather than in Phase 2) keeps
  the Postgres stack immutable across phases — Phase 2 only *adds*
  Debezium; it doesn't reconfigure Postgres.

- **Named volume for data, bind mount for init.** Data survives
  `docker compose down`; init scripts re-run only when the volume is
  wiped. This mirrors how a real ops team would run a stateful service
  locally.

- **SQLAlchemy models exist alongside the SQL, not instead of it.** The
  checked-in `00-schema.sql` is what Postgres actually runs on boot — no
  ORM at container-start time. The models exist so the generator has a
  typed handle on the rows and so tests can call `create_all()` in an
  ephemeral database. A unit test compares the model-rendered DDL to
  the checked-in SQL to catch drift.

- **argparse, not click/typer.** The CLI is three commands with a
  handful of flags. Stdlib argparse keeps the `postgres` extra minimal
  (SQLAlchemy + psycopg + Faker only) and matches the "no dependency
  unless the phase truly needs it" discipline from Phase 0.

- **Deterministic generator via `--seed`.** The unit tests need
  reproducible output; the integration test needs a stable footprint;
  a reader running the compose stack should be able to reproduce the
  same synthetic history a screenshot shows. All three are served by
  a single `--seed` flag that fans out to `random.Random`, `Faker`,
  and any timestamp jitter.

- **No Alembic yet.** One schema, one file, applied at first boot.
  Alembic earns its place when there is a second schema version to
  migrate to. Introducing it now would be architecture-astronaut work.

## How to run

Prerequisites: Docker Desktop (or equivalent), Python 3.11+, the repo's
`.venv` from Phase 0 already active.

```bash
# One-time: install the postgres extra.
pip install -e ".[dev,postgres]"

# Bring up Postgres 16 with logical WAL.
docker compose -f compose/docker-compose.yml up -d

# Apply schema (idempotent; the compose init already ran it once,
# but this is what a bare-metal Postgres would use).
banking-cdc oltp init

# Seed a small deterministic batch — 200 customers, 60 seconds of
# simulated activity at ~20 transactions per second.
banking-cdc seed run --customers 200 --duration 60 --tps 20 --seed 42

# Confirm.
docker compose -f compose/docker-compose.yml exec postgres \
  psql -U banking -d banking_oltp -c "SELECT count(*) FROM transactions;"
```

Fast, hermetic tests (Phase 0 baseline) still pass with just:

```bash
pytest
```

Integration tests require the compose stack running:

```bash
docker compose -f compose/docker-compose.yml up -d
pytest -m integration
```

## Gotchas

- **`wal_level` changes require a full restart, not a reload.** If a
  reader edits `postgresql.conf` after the container is up, they need
  `docker compose restart postgres`, not `SELECT pg_reload_conf()`.

- **`REPLICA IDENTITY FULL` on a large table is a rewrite.** Not a
  problem at portfolio scale; worth flagging in the doc so nobody
  copy-pastes the pattern onto a production billion-row table.

- **The synthetic generator uses `random`, not `secrets`.** It has to be
  reproducible. Do not swap it for `secrets` "for security" — the seed
  data is public and non-sensitive by design.

- **`psycopg[binary]` vs `psycopg`.** The binary distribution ships
  libpq inside the wheel; the pure-Python one needs `libpq-dev` on the
  host. Phase 1 pins `psycopg[binary]` for zero-hassle local install.
  A future ops-focused phase can revisit.

- **Faker locales.** The generator uses the default (`en_US`) locale so
  test assertions on name/email shape are stable. Switching to
  multi-locale customers is a Phase-1.1 nice-to-have, not a blocker.

## References

- Debezium Postgres connector requirements: <https://debezium.io/documentation/reference/stable/connectors/postgresql.html#postgresql-server-configuration>
- Postgres logical replication concepts: <https://www.postgresql.org/docs/16/logical-replication.html>
- `REPLICA IDENTITY` semantics: <https://www.postgresql.org/docs/16/sql-altertable.html#SQL-ALTERTABLE-REPLICA-IDENTITY>
- SQLAlchemy 2.0 declarative style: <https://docs.sqlalchemy.org/en/20/orm/quickstart.html>
- Faker: <https://faker.readthedocs.io/en/master/>
