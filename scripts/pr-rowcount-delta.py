"""Phase 11 (+ Phase 12 baseline-counts upgrade) — produce a per-model
row-count delta between a PR build and the main-branch baseline.

Reads:
  --duckdb-path       the PR's built DuckDB file
  --manifest          the main-branch manifest (dbt-manifest-main artifact)
  --baseline-counts   OPTIONAL — the main-branch rowcount-baseline.json
                      (rowcount-baseline-main artifact, Phase 12).
                      Without it the "main baseline" column is "n/a";
                      with it the delta column shows signed deltas and
                      only rows with a non-zero delta are listed.

Writes a Markdown table to stdout, suitable for a GitHub sticky-comment.

The script's lifecycle:
  - Phase 11 shipped the delta scaffold with every column populated
    from the PR side only; baseline was placeholder "n/a".
  - Phase 12 fills the baseline column + adds the signed-delta semantics
    + the "quiet mode" (no change -> short one-liner, don't spam the PR).
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
    parser.add_argument(
        "--baseline-counts",
        type=Path,
        default=None,
        help="Optional path to the Phase 12 rowcount-baseline.json artifact.",
    )
    return parser.parse_args()


def _models_from_manifest(manifest_path: Path) -> list[tuple[str, str, str]]:
    """Return (unique_id, schema, name) per model + snapshot."""
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
    try:
        row = con.execute(f'SELECT COUNT(*) FROM "{schema}"."{name}"').fetchone()
    except duckdb.CatalogException:
        return None
    return int(row[0]) if row else 0


def _load_baseline(path: Path | None) -> dict[str, int]:
    if path is None or not path.exists():
        return {}
    with path.open() as fh:
        payload = json.load(fh)
    rows = payload.get("rows_by_model") or {}
    return {k: int(v) for k, v in rows.items()}


def _fmt(n: int | None) -> str:
    if n is None:
        return "missing"
    return f"{n:,}"


def _fmt_delta(baseline: int | None, pr: int | None) -> str:
    if baseline is None or pr is None:
        return "—"
    delta = pr - baseline
    if delta == 0:
        return "·"
    sign = "+" if delta > 0 else ""
    return f"{sign}{delta:,}"


def main() -> int:
    args = _parse_args()
    if not args.duckdb_path.exists():
        print(
            "> _No DuckDB file produced by the defer build — "
            "the PR touched no models that materialise on DuckDB._"
        )
        return 0

    con = duckdb.connect(str(args.duckdb_path), read_only=True)
    baseline = _load_baseline(args.baseline_counts)
    have_baseline = bool(baseline)
    models = _models_from_manifest(args.manifest)

    rows: list[tuple[str, int | None, int | None, str]] = []
    for _unique_id, schema, name in sorted(models, key=lambda m: (m[1], m[2])):
        key = f"{schema}.{name}"
        pr_n = _count_rows(con, schema, name)
        base_n = baseline.get(key) if have_baseline else None
        # If we have a real baseline, only show rows with a non-zero delta
        # OR with a missing side (keeps PR noise down).
        if have_baseline:
            if pr_n is None and base_n is None:
                continue
            if pr_n == base_n:
                continue
        rows.append((key, base_n, pr_n, _fmt_delta(base_n, pr_n)))

    if not rows:
        if have_baseline:
            print("> _No row-count change vs the `main` baseline._")
        else:
            print("> _No material row-count change detected in PR build._")
        return 0

    header = (
        "### Phase 11/12 — PR vs `main` row-count delta\n"
        if have_baseline
        else "### Phase 11 — PR build row counts (no `main` baseline available)\n"
    )
    print(header)
    print("| model | main baseline | PR build | Δ |")
    print("|---|---:|---:|---:|")
    for key, base_n, pr_n, delta in rows:
        base_s = _fmt(base_n) if have_baseline else "n/a"
        print(f"| `{key}` | {base_s} | {_fmt(pr_n)} | {delta} |")

    if not have_baseline:
        print(
            "\n> _Baseline column is `n/a` — this run of `main` hasn't published "
            "a `rowcount-baseline-main` artifact yet. The next merge to `main` will._"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
