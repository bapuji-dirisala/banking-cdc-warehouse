"""Phase 11 — produce a per-model row-count delta between a PR build and
the main-branch baseline.

Reads:
  --duckdb-path   the PR's built DuckDB file
  --manifest      the main-branch manifest (downloaded by pr-lineage.yml)

Writes a Markdown table to stdout, suitable for a GitHub sticky-comment.
Only models whose row count has changed (or whose existence changed)
appear in the table — if nothing changed the output is a short "no
material change" line, keeping the PR UI quiet.

Script is intentionally dependency-light: duckdb (already a project dep)
and the stdlib. The baseline manifest provides the authoritative list of
"models that should exist"; the PR duckdb file provides the actual
counts.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import duckdb


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duckdb-path", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    return parser.parse_args()


def _models_from_manifest(manifest_path: Path) -> list[tuple[str, str, str]]:
    """Return list of (unique_id, schema, name) for each model + snapshot."""
    with manifest_path.open() as fh:
        manifest = json.load(fh)
    out: list[tuple[str, str, str]] = []
    for unique_id, node in manifest.get("nodes", {}).items():
        if node.get("resource_type") not in {"model", "snapshot"}:
            continue
        if node.get("config", {}).get("materialized") == "ephemeral":
            continue
        schema = node.get("schema")
        name = node.get("name")
        if schema and name:
            out.append((unique_id, schema, name))
    return out


def _count_rows(con: duckdb.DuckDBPyConnection, schema: str, name: str) -> int | None:
    """Return COUNT(*) for the table, or None if it doesn't exist in the PR build."""
    try:
        row = con.execute(f'SELECT COUNT(*) FROM "{schema}"."{name}"').fetchone()
    except duckdb.CatalogException:
        return None
    return int(row[0]) if row else 0


def main() -> int:
    args = _parse_args()
    if not args.duckdb_path.exists():
        print(
            "> _No DuckDB file produced by the defer build — "
            "the PR touched no models that materialise on DuckDB._"
        )
        return 0

    con = duckdb.connect(str(args.duckdb_path), read_only=True)
    models = _models_from_manifest(args.manifest)

    rows: list[tuple[str, str, str]] = []  # (name, baseline, pr)
    for _unique_id, schema, name in sorted(models, key=lambda m: (m[1], m[2])):
        pr_n = _count_rows(con, schema, name)
        baseline = "n/a"  # we don't ship a baseline rowcount file yet; see docs
        pr_s = "missing" if pr_n is None else f"{pr_n:,}"
        if pr_s != baseline:
            rows.append((f"{schema}.{name}", baseline, pr_s))

    if not rows:
        print("> _No material row-count change detected in PR build._")
        return 0

    print("### Phase 11 — PR vs main row-count delta\n")
    print("| model | main baseline | PR build |")
    print("|---|---:|---:|")
    for name, baseline, pr in rows:
        print(f"| `{name}` | {baseline} | {pr} |")
    print(
        "\n> Baseline column is a placeholder — the real baseline comes from "
        "`main`'s manifest + a persisted row-count snapshot (shipped in Phase 12). "
        "For now this table shows every model the PR built."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
