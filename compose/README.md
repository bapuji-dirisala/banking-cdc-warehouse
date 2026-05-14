# compose/

Local infra for the CDC warehouse. Phase 1 ships a Postgres 16 OLTP source
with logical decoding enabled. Phase 2 will add Redpanda + Kafka Connect +
Debezium to this same file.

## Postgres 16 (Phase 1)

```bash
# Bring it up (idempotent).
docker compose -f compose/docker-compose.yml up -d

# Watch the logs while init scripts apply the schema.
docker compose -f compose/docker-compose.yml logs -f postgres

# Connect.
docker compose -f compose/docker-compose.yml exec postgres \
    psql -U banking -d banking_oltp

# Wipe everything (data volume + init replays on next up).
docker compose -f compose/docker-compose.yml down -v
```

Connection string used by the rest of the repo:

```
postgresql+psycopg://banking:banking@localhost:5432/banking_oltp
```

The `banking-cdc` CLI (installed via `pip install -e ".[dev,postgres]"`)
reads that URL from `BANKING_CDC_DB_URL`, falling back to the value above.
