"""``banking-cdc`` command-line entry point.

Subcommand groups track phase deliverables:

- ``banking-cdc oltp init``       — idempotently create every table via SQLAlchemy
- ``banking-cdc oltp print-ddl``  — emit the model-rendered DDL to stdout
- ``banking-cdc seed run``        — drive the synthetic workload generator
- ``banking-cdc kafka wait``      — block until Kafka Connect REST is up
- ``banking-cdc kafka register``  — register the Debezium Postgres connector
- ``banking-cdc kafka status``    — show connector + task states
- ``banking-cdc kafka reset-slot`` — drop the connector + replication slot (recovery)

argparse (stdlib) is used deliberately so the ``postgres`` and ``kafka``
extras stay minimal.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

from sqlalchemy.orm import Session
from sqlalchemy.schema import CreateTable

from banking_cdc.oltp import Base, create_engine_from_env
from banking_cdc.seed import GeneratorConfig, generate_batch, persist_batch


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="banking-cdc",
        description="Banking CDC warehouse — OLTP + CDC capture tooling.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # --- oltp ------------------------------------------------------------
    oltp = subparsers.add_parser("oltp", help="OLTP schema operations.")
    oltp_sub = oltp.add_subparsers(dest="oltp_command", required=True)

    oltp_sub.add_parser("init", help="Create all tables (idempotent).")
    oltp_sub.add_parser("print-ddl", help="Print the model-rendered DDL to stdout.")

    # --- seed ------------------------------------------------------------
    seed = subparsers.add_parser("seed", help="Synthetic workload generator.")
    seed_sub = seed.add_subparsers(dest="seed_command", required=True)

    seed_run = seed_sub.add_parser("run", help="Generate and persist a synthetic batch.")
    seed_run.add_argument("--customers", type=int, default=200)
    seed_run.add_argument("--duration", type=int, default=60, help="Duration in seconds.")
    seed_run.add_argument("--tps", type=float, default=20.0, help="Transactions per second.")
    seed_run.add_argument("--seed", type=int, default=42, help="RNG seed for reproducibility.")
    seed_run.add_argument(
        "--dry-run",
        action="store_true",
        help="Build the batch but skip the DB commit; prints per-table row counts.",
    )

    # --- kafka -----------------------------------------------------------
    kafka = subparsers.add_parser(
        "kafka", help="Kafka Connect / Debezium operations (Phase 2 CDC capture)."
    )
    kafka_sub = kafka.add_subparsers(dest="kafka_command", required=True)

    kafka_sub.add_parser("wait", help="Block until the Kafka Connect REST API is reachable.")
    kafka_sub.add_parser(
        "register", help="Register (or update) the Debezium Postgres source connector."
    )
    kafka_sub.add_parser("status", help="Show the state of every registered connector + its tasks.")
    kafka_sub.add_parser(
        "reset-slot",
        help="Drop the Debezium connector and its Postgres replication slot (recovery).",
    )

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "oltp":
        return _handle_oltp(args)
    if args.command == "seed":
        return _handle_seed(args)
    if args.command == "kafka":
        return _handle_kafka(args)

    parser.error(f"unknown command: {args.command}")
    return 2  # unreachable — argparse exits — but appeases the type checker


def _handle_oltp(args: argparse.Namespace) -> int:
    if args.oltp_command == "init":
        engine = create_engine_from_env()
        Base.metadata.create_all(engine)
        print(f"Applied schema to {engine.url}")
        return 0

    if args.oltp_command == "print-ddl":
        # We render against a bound engine (Postgres dialect) so enum types
        # emit as CREATE TYPE, matching the checked-in SQL.
        engine = create_engine_from_env()
        for table in Base.metadata.sorted_tables:
            print(str(CreateTable(table).compile(engine)).rstrip() + ";")
        return 0

    return 2


def _handle_seed(args: argparse.Namespace) -> int:
    if args.seed_command != "run":
        return 2

    config = GeneratorConfig(
        customers=args.customers,
        duration_seconds=args.duration,
        tps=args.tps,
        seed=args.seed,
    )
    batch = generate_batch(config)

    if args.dry_run:
        for k, v in batch.totals.items():
            print(f"{k:>14}: {v}")
        return 0

    engine = create_engine_from_env()
    with Session(engine) as session:
        persist_batch(session, batch)
    for k, v in batch.totals.items():
        print(f"{k:>14}: {v}")
    return 0


def _handle_kafka(args: argparse.Namespace) -> int:
    # Lazy-imported so the ``kafka`` extra (requests) is only required
    # when a user actually runs a ``banking-cdc kafka ...`` subcommand.
    from banking_cdc.kafka import (
        DEFAULT_CONNECTOR_PATH,
        ConnectClient,
        load_connector_config,
        wait_for_connect,
    )

    client = ConnectClient()

    if args.kafka_command == "wait":
        wait_for_connect(client.base_url)
        print(f"Kafka Connect is ready at {client.base_url}")
        return 0

    if args.kafka_command == "register":
        config = load_connector_config(DEFAULT_CONNECTOR_PATH)
        client.register(config)
        print(f"Registered connector: {config['name']}")
        return 0

    if args.kafka_command == "status":
        connectors = client.list_connectors()
        if not connectors:
            print("(no connectors registered)")
            return 0
        for name in connectors:
            status = client.status(name)
            cstate = status["connector"]["state"]
            tasks = status.get("tasks", [])
            tstates = ", ".join(f"{t['id']}:{t['state']}" for t in tasks) or "(no tasks)"
            print(f"{name:30s} connector={cstate:10s} tasks=[{tstates}]")
        return 0

    if args.kafka_command == "reset-slot":
        from sqlalchemy import text

        print("WARNING: this will drop the Debezium connector and the Postgres")
        print("replication slot. Expect a snapshot re-run on next `kafka register`.")
        try:
            client.delete("banking-postgres-source")
            print("Deleted connector: banking-postgres-source")
        except Exception as exc:  # noqa: BLE001 - best-effort recovery path
            print(f"Connector delete skipped: {exc}")

        engine = create_engine_from_env()
        with engine.connect() as conn:
            conn.execute(
                text(
                    "SELECT pg_drop_replication_slot(slot_name) "
                    "FROM pg_replication_slots WHERE slot_name = 'banking_slot'"
                )
            )
            conn.commit()
        print("Dropped replication slot (if it existed): banking_slot")
        print("Re-run `banking-cdc kafka register` to re-attach.")
        return 0

    return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
