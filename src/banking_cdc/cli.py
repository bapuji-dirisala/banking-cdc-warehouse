"""``banking-cdc`` command-line entry point.

Three subcommands so far, each corresponding to a Phase 1 deliverable:

- ``banking-cdc oltp init``       — idempotently create every table via SQLAlchemy
- ``banking-cdc oltp print-ddl``  — emit the model-rendered DDL to stdout
- ``banking-cdc seed run``        — drive the synthetic workload generator

argparse (stdlib) is used deliberately so the ``postgres`` extra stays
minimal (SQLAlchemy + psycopg + Faker only).
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
        description="Banking CDC warehouse — Phase 1 OLTP tooling.",
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

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "oltp":
        return _handle_oltp(args)
    if args.command == "seed":
        return _handle_seed(args)

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


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
