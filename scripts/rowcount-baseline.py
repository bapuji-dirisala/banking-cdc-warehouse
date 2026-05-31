"""Phase 12 — emit a per-model row-count baseline JSON.

Reads a built DuckDB warehouse + its dbt manifest, SELECTs COUNT(*) for
every materialised model/snapshot, and writes a JSON of the form:

    {
        "generated_at":   "2026-10-25T14:30:00Z",
        "manifest_hash":  "<first 12 chars of a stable manifest ID>",
        "rows_by_model": {
            "staging.stg_banking__customers":          3,
            "marts.dim_customer":                       3,
            "marts.fct_transactions":                   5,
            ...
        }
    }

Published as the `rowcount-baseline-main` GHA artifact on every main-
branch build; consumed by scripts/pr-rowcount-delta.py to fill in the
"main baseline" column of the sticky PR comment.

Dependency-light (duckdb + stdlib).
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import duckdb


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duckdb-path", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("rowcount-baseline.json"),
        help="Where to write the baseline JSON (default: ./rowcount-baseline.json)",
    )
    return parser.parse_args()


def _materialised_models(manifest_path: Path) -> list[tuple[str, str]]:
    """Return list of (schema, name) tuples for every physically-materialised node."""
    with manifest_path.open() as fh:
        manifest = json.load(fh)
    out: list[tuple[str, str]] = []
    for node in manifest.get("nodes", {}).values():
        if node.get("resource_type") not in {"model", "snapshot"}:
            continue
        if node.get("config", {}).get("materialized") == "ephemeral":
            continue
        schema = node.get("schema")
        name = node.get("name")
        if schema and name:
            out.append((schema, name))
    return sorted(out)


def _count(con: duckdb.DuckDBPyConnection, schema: str, name: str) -> int | None:
    try:
        row = con.execute(f'SELECT COUNT(*) FROM "{schema}"."{name}"').fetchone()
    except duckdb.CatalogException:
        return None
    return int(row[0]) if row else 0


def main() -> int:
    args = _parse_args()
    if not args.duckdb_path.exists():
        print(f"[rowcount-baseline] no DuckDB file at {args.duckdb_path}", file=sys.stderr)
        return 1
    if not args.manifest.exists():
        print(f"[rowcount-baseline] no manifest at {args.manifest}", file=sys.stderr)
        return 1

    con = duckdb.connect(str(args.duckdb_path), read_only=True)
    rows_by_model: dict[str, int] = {}
    for schema, name in _materialised_models(args.manifest):
        n = _count(con, schema, name)
        if n is not None:
            rows_by_model[f"{schema}.{name}"] = n

    # A stable manifest "hash" without pulling cryptography: dbt's own
    # project_id makes a sufficient identifier for sanity-checking that
    # a baseline + manifest pair came from the same project.
    with args.manifest.open() as fh:
        manifest = json.load(fh)
    project_id = (manifest.get("metadata") or {}).get("project_id", "unknown")

    out = {
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "project_id": project_id,
        "rows_by_model": rows_by_model,
    }
    args.output.write_text(json.dumps(out, indent=2) + "\n")
    print(
        f"[rowcount-baseline] wrote {args.output} "
        f"({len(rows_by_model)} models, project_id={project_id[:12]})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
