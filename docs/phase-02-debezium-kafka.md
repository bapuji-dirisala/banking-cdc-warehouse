# Phase 2 — Debezium + Kafka Connect (minimal CDC capture)

## Goal

Attach Debezium to the Postgres WAL from Phase 1 and publish row-level
change events to Kafka topics (one per table). **Deliberately minimal:**
plumbing that works, not a Kafka deep-dive. The downstream phases
(dbt + Snowflake depth) are where this project earns its interview
value; Phase 2 just has to be correct, visible, and out of the way.

## What this phase delivers

- **Compose stack extensions** — Zookeeper, Kafka, and Kafka Connect
  (Confluent 7.6 images) added to `compose/docker-compose.yml`
  alongside the Phase 1 Postgres service
- **Debezium Postgres connector plugin** installed into Kafka Connect
  via a bind-mounted `compose/connect/plugins/` directory (keeps the
  plugin out of the image build, so swaps don't require a rebuild)
- **One connector config** at `compose/connect/connectors/pg-source.json`
  producing four topics: `banking.public.customers`,
  `banking.public.accounts`, `banking.public.transactions`,
  `banking.public.card_events`
- **Postgres publication + replication slot** added as an idempotent
  init script at `compose/postgres/init/02-cdc-publication.sql`
- **CLI additions** to `banking-cdc`:
  - `kafka wait` — polls the Kafka Connect REST API until it's healthy
  - `kafka register` — POSTs the connector config to Connect
  - `kafka status` — lists connectors + their task state + any errors
- **Smoke test** (marker `cdc`, deselected by default) — seeds via the
  Phase 1 generator, tails each topic, asserts `op=c|u|d` events
  arrive with the expected `before` / `after` payloads
- **Design doc gotchas section** — pre-flight checklist for Nike
  corp network (image pulls, Colima resource sizing) + how to
  recover from a broken replication slot

## Design decisions

- **Kafka Connect, not standalone Debezium server.** Kafka Connect is
  the industry standard for Debezium deployments. Same JVM runs many
  connectors, same REST API manages them, same scaling story. Real
  banks run connector *fleets* this way, not one Debezium process per
  source. Setting the pattern now matches what Phase 3 (adding the
  Snowflake sink connector to the *same* Connect cluster) needs.

- **Confluent 7.6 images, not vanilla Apache.** They bundle sensible
  defaults, health probes, a working JMX config, and converters we'd
  otherwise install by hand. Trade-off: dockerhub pull size is larger.
  Fine for portfolio scale; Colima can hold them.

- **`pgoutput` plugin, not `wal2json` or `decoderbufs`.** `pgoutput`
  is Postgres-native (no extensions required), is the Debezium default
  since 1.2, and matches what every managed Postgres (Cloud SQL, RDS,
  Aiven, Supabase) ships. `wal2json` would mean installing a Postgres
  extension; `decoderbufs` is EOL. Easy call.

- **JSON converter, no Schema Registry.** The Confluent default would
  be Avro + Schema Registry (an extra container, extra config,
  schema-evolution story). JSON keeps the Compose stack at three new
  containers (Zookeeper + Kafka + Connect). Phase 3 lands into
  Snowflake variants that absorb schema evolution anyway. If we need
  Avro later (interviewer asks about schema evolution) it's a
  Phase 2.5 add-on, not a Phase 2 blocker.

- **One topic per table, keyed by primary key, one partition each.**
  The classic Debezium default. Keying by PK gives
  per-row-ordering guarantees; one partition keeps the local stack
  simple. Partitioning sensibly for throughput is a production topic
  worth discussing in README; implementing it here would be noise.

- **Snapshot mode `initial`.** First connector start reads a consistent
  snapshot of each table (populates topics with current state as
  `op=r` read events), then streams WAL. Means Phase 3 bronze always
  has full history, even for rows that existed before Debezium
  attached. The alternative (`never`) would mean missing pre-existing
  rows; `always` would re-snapshot on every restart and is wrong for
  our use case.

- **Replication slot pinned in Postgres init.** We create
  `banking_slot` with `pgoutput` via an init SQL script (idempotent
  via `IF NOT EXISTS` check). Debezium attaches to the existing slot
  instead of creating one — gives us a stable slot name across
  connector recreates, and makes the Postgres-side state auditable
  (`SELECT * FROM pg_replication_slots`).

- **Zookeeper, not KRaft.** Confluent 7.6 supports both. KRaft removes
  one container but requires an extra config step for cluster metadata
  bootstrap. Zookeeper is still the on-prem default across banks (what
  interviewers will have seen) and is one fewer config knob. Can swap
  to KRaft in a Phase 2.1 if it comes up.

- **Bind-mounted plugin dir, not a baked image.** Dropping Debezium
  jars into `compose/connect/plugins/debezium-connector-postgres/` on
  the host and bind-mounting into the container means plugin swaps
  don't require a Compose rebuild. Trade-off: a `.gitkeep` is checked
  in but the actual jars are downloaded on first `up` via a tiny
  shell helper (`scripts/fetch-debezium.sh`); the jars themselves are
  gitignored. Keeps the repo lean.

- **Topic auto-create left ON for Phase 2.** Lets the Debezium
  connector create its four output topics plus the Connect-internal
  `connect-offsets` / `connect-configs` / `connect-status` topics.
  Phase 3 will lock this down (`auto.create.topics.enable=false` +
  explicit topic creation in a bootstrap script) when we add the
  Snowflake sink and need production-grade topic configs
  (compaction, retention).

- **No Avro, no Schema Registry, no transformations (SMTs).** Any one
  of these could be a mini-phase. For a minimal-plumbing Phase 2,
  they're scope creep. The Snowflake sink in Phase 3 handles raw
  Debezium JSON natively via the official Snowflake Kafka Connector.

- **Smoke test as a `pytest -m cdc` marker, not an integration test.**
  The Phase 1 `integration` marker needs a live Postgres; `cdc` needs
  Postgres *and* Connect *and* a seeded workload. Keeping it on its
  own marker means CI only runs it in a dedicated job that's explicit
  about the dependencies.

## How to run

Prerequisites: **Colima running** (we're Docker-Desktop-free per Nike
IT; Colima is the approved replacement), repo's `.venv` from Phase 0
active, Phase 1 `postgres` extra installed.

```bash
# Colima VM (one-time per boot; replaces Docker Desktop at Nike).
colima start

# Pull Debezium plugin jars into the bind-mount dir (idempotent).
./scripts/fetch-debezium.sh

# Bring up the full stack: Postgres + Zookeeper + Kafka + Connect.
docker compose -f compose/docker-compose.yml up -d

# Wait for Kafka Connect REST API to come up (~30s on first boot).
banking-cdc kafka wait

# Register the Postgres source connector (POSTs pg-source.json to Connect).
banking-cdc kafka register

# Confirm the connector + all four task slots are RUNNING.
banking-cdc kafka status

# Seed some OLTP activity so WAL has events to decode.
banking-cdc seed run --customers 100 --duration 30 --tps 20 --seed 42

# Tail a topic from the Kafka container to see change events.
docker compose -f compose/docker-compose.yml exec kafka \
    kafka-console-consumer \
    --bootstrap-server kafka:9092 \
    --topic banking.public.transactions \
    --from-beginning \
    --max-messages 5 \
    --property print.key=true
```

Fast tests still pass hermetically:

```bash
pytest
```

The CDC smoke test opts in explicitly and expects the stack to be up:

```bash
docker compose -f compose/docker-compose.yml up -d
banking-cdc kafka wait && banking-cdc kafka register
pytest -m cdc
```

## Gotchas

- **`REPLICA IDENTITY FULL` already set in Phase 1.** No action needed
  here; mentioning only so a reader skipping Phase 1 doesn't go hunting.

- **Replication slot survives container restarts.** If Debezium is
  stopped for days while the generator keeps writing, the slot pins
  WAL retention and the Postgres disk fills. Monitor
  `pg_replication_slots.active` and `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)`.
  For a stuck-slot recovery: drop the connector via Connect REST API,
  then `SELECT pg_drop_replication_slot('banking_slot')` from psql,
  then re-register the connector. A dedicated CLI subcommand
  (`banking-cdc kafka reset-slot`) ships here to automate that
  recovery.

- **Colima default resource sizing is tight.** Kafka + Zookeeper + Connect
  + Postgres together want ~3 GB RAM. Default Colima VM is 2 GB. First
  boot: `colima start --cpu 4 --memory 6 --disk 30`. Verify with
  `colima status`. If images OOM-kill, bump memory further.

- **Nike egress may rate-limit docker.io pulls.** Confluent images are
  ~500 MB each; three of them = ~1.5 GB. If Colima pull stalls on
  corp VPN, run `colima stop && colima start` after switching to home
  wifi for the initial pulls — Colima caches images in the VM, so
  subsequent `up` calls work on any network.

- **Kafka Connect takes 30–60s to come up.** The REST API returns
  404 for connector registration until the worker fully initialises.
  `banking-cdc kafka wait` polls `/connectors` with exponential backoff
  so Phase 2 scripts don't flake.

- **Topic names are case-sensitive and include the database name.**
  Our connector produces `banking.public.customers`, not
  `public.customers` or `customers`. Phase 3's Snowflake sink config
  must match exactly.

- **`port 9092` is the Kafka listener used *inside* the Compose network.**
  Clients on the host (e.g., the `kafka-console-consumer` on the Kafka
  container above, or a Snowflake Kafka Connector *inside* the same
  Compose network in Phase 3) use `kafka:9092`. A host-side consumer
  from the laptop needs a separate advertised listener (`localhost:19092`
  in our setup) to avoid the classic Kafka hostname-mismatch error.

## Nike + compliance notes

- Everything in this phase runs in **Colima** (Docker-Desktop-free,
  per the Oct 16 2026 Nike IT policy). Verified in the pre-flight
  audit: `/Applications/Docker.app` absent, `com.docker.vmnetd`
  helper absent, `docker context` defaults to `colima`.
- No external service accounts needed for this phase. Phase 3 is the
  first phase to sign up for an external service (Snowflake trial).
- All images pull from the public `docker.io` registry; no Nike
  internal registries, no Nike SSO, no corporate credentials touched.
- Corp CA bundle (`SSL_CERT_FILE=/etc/ssl/cert.pem` etc.) is already
  persisted in `~/.zprofile`; `requests` and `urllib3` from the
  Phase 2 CLI commands resolve TLS correctly through Nike's forward
  proxy.
- The commit-msg hook from Phase 0 continues to strip any
  accidental AI trailers; commits land as `Bapuji Dirisala
  <dirisala.bapuji@gmail.com>` per the repo-local git config.

## References

- Debezium Postgres connector: <https://debezium.io/documentation/reference/stable/connectors/postgresql.html>
- Kafka Connect REST API: <https://docs.confluent.io/platform/current/connect/references/restapi.html>
- `pgoutput` plugin in Postgres: <https://www.postgresql.org/docs/16/logical-replication.html>
- Snowflake Kafka Connector (Phase 3 preview): <https://docs.snowflake.com/en/user-guide/kafka-connector>
- Confluent platform images: <https://hub.docker.com/u/confluentinc>
