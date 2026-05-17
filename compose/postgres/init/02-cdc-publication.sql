-- Phase 2: CDC publication + replication slot for the Debezium Postgres
-- connector. Runs after 00-schema.sql and 01-replica-identity.sql so the
-- tables and their REPLICA IDENTITY are already in place.
--
-- Idempotent: both blocks guard with existence checks so re-running the
-- init (e.g. after `docker compose down -v`) does not error.

-- Publication covers exactly the four Phase 1 tables. Adding a table in
-- a later phase requires `ALTER PUBLICATION banking_publication ADD TABLE ...`
-- via a new init script, not an edit to this one.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication WHERE pubname = 'banking_publication'
    ) THEN
        CREATE PUBLICATION banking_publication
            FOR TABLE customers, accounts, transactions, card_events;
    END IF;
END$$;

-- Replication slot is pinned to a stable name so Debezium can detach and
-- reattach (connector delete/re-register) without creating orphan slots.
-- `pgoutput` is the Postgres-native logical decoding plugin — matches what
-- the Debezium connector config requests.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_replication_slots WHERE slot_name = 'banking_slot'
    ) THEN
        PERFORM pg_create_logical_replication_slot('banking_slot', 'pgoutput');
    END IF;
END$$;
