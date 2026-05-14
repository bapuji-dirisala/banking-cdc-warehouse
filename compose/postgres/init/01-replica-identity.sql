-- Set REPLICA IDENTITY FULL on every CDC table so Debezium change events
-- include the full old row on UPDATE (not just the primary key). See
-- docs/phase-01-postgres-oltp.md for the trade-off rationale.

ALTER TABLE customers    REPLICA IDENTITY FULL;
ALTER TABLE accounts     REPLICA IDENTITY FULL;
ALTER TABLE transactions REPLICA IDENTITY FULL;
ALTER TABLE card_events  REPLICA IDENTITY FULL;
