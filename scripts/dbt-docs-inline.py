"""Phase 12 — collapse dbt docs' three-file output into a single-file
static site for GitHub Pages.

Reads from --target (default: dbt/target):
    index.html       — the dbt docs app shell
    manifest.json    — the DAG + metadata
    catalog.json     — the physical column/stats inventory

Writes to --out (default: site):
    index.html       — the shell with both JSONs inlined as window globals
    404.html         — tiny redirect so deep-linked URLs land on the home

Why not keep the three files separate?
    GitHub Pages serves them fine, but the docs runtime fetches via
    JavaScript which trips on strict CSP in some corporate browsers.
    A single HTML with inlined JSON side-steps the whole class of issue.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target",
        type=Path,
        default=Path("dbt/target"),
        help="Directory containing index.html + manifest.json + catalog.json.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("site"),
        help="Output directory for the assembled site.",
    )
    return parser.parse_args()


def _assemble(target: Path, out: Path) -> int:
    index_path = target / "index.html"
    manifest_path = target / "manifest.json"
    catalog_path = target / "catalog.json"
    for path in (index_path, manifest_path, catalog_path):
        if not path.exists():
            raise SystemExit(f"[dbt-docs-inline] missing {path}")

    manifest = json.loads(manifest_path.read_text())
    catalog = json.loads(catalog_path.read_text())
    html = index_path.read_text()

    # Build the injection block. json.dumps emits JSON with `\u` escapes
    # for non-ASCII — safe inside a <script> tag because the parser
    # treats them as plain string content.
    injection = (
        "<script>"
        f"window.__INITIAL_MANIFEST__ = {json.dumps(manifest)};"
        f"window.__INITIAL_CATALOG__  = {json.dumps(catalog)};"
        "</script>"
    )

    # Hook before </head> so the globals exist before the app's init
    # runs. Use str.replace, NOT re.sub — the injection contains JSON
    # with `\u` escapes which re.sub treats as regex backreferences.
    if "</head>" not in html:
        raise SystemExit("[dbt-docs-inline] no </head> tag in index.html")
    html = html.replace("</head>", injection + "</head>", 1)

    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(html)
    (out / "404.html").write_text(
        '<!DOCTYPE html><meta charset="utf-8">'
        "<title>Not Found — banking-cdc-warehouse docs</title>"
        '<meta http-equiv="refresh" content="0; url=./index.html">'
        '<p>Redirecting to <a href="./index.html">the docs home</a>…</p>'
    )
    size_kb = (out / "index.html").stat().st_size / 1024
    print(f"[dbt-docs-inline] wrote {out}/index.html ({size_kb:,.1f} KB) + 404.html")
    return 0


def main() -> int:
    args = _parse_args()
    return _assemble(args.target, args.out)


if __name__ == "__main__":
    raise SystemExit(main())
