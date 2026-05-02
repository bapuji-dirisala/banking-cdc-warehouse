# Phase 0 — Repo scaffolding

## Goal

Set up the repo with the same tooling discipline as the wider portfolio so
every subsequent phase can focus on the CDC and warehouse problem rather
than re-litigating Python packaging, linting, or CI conventions.

## What this phase delivers

- `pyproject.toml` with:
  - `hatchling` build backend
  - Python 3.11-3.12 supported
  - MIT license
  - `dev` optional extra (pytest, ruff, mypy, pre-commit) — other extras
    (Postgres, Kafka, dbt, Great Expectations) get added in the phases
    that first need them, keeping early-phase installs small
  - Ruff config with pycodestyle, pyflakes, isort, bugbear, comprehensions,
    pyupgrade, pep8-naming, and simplify rules enabled
- `.pre-commit-config.yaml` with ruff (fix + format) and mypy running on
  every commit
- `.gitignore` — Python, venv, IDE, data, warehouse artefacts, dbt build
  state, Snowflake profiles, secrets, Debezium connector state
- MIT `LICENSE`
- `README.md` — eleven-phase roadmap, tech stack, getting started, and
  the "two operating modes" (free-tier local vs cloud paid) framing
- `.github/workflows/ci.yml` — lint + typecheck + test on push and PR,
  with `concurrency` cancelling superseded runs
- `src/banking_cdc/` package skeleton with a `__version__` string
- `tests/test_smoke.py` — a single test that imports the package and
  asserts the version is set; enough to prove CI wiring works before
  there's any real code

## Design decisions

- **Same conventions as `member-lakehouse` and `rides-telemetry-platform`.**
  The portfolio has a consistent identity: same Python version, same ruff
  config, same pre-commit hooks, same CI shape. A reader who has seen one
  repo can read the next one without re-orienting.

- **No CDC / warehouse deps in the default install.** The `dev` extra
  pulls in just enough to run linting and the smoke test. Postgres, Kafka,
  Debezium, dbt, and Snowflake dependencies live in extras that only get
  added when the corresponding phase lands. This keeps CI fast and cheap
  in the early phases.

- **No Docker / compose yet.** Deliberately deferred to Phase 1 (Postgres
  OLTP) and Phase 2 (Debezium + Kafka), when there's an actual service to
  stand up. Adding infra plumbing before there's a use case for it is a
  common scaffolding trap.

- **Package layout under `src/`.** Prevents accidental imports from the
  repo root during tests and matches the sibling portfolio repos.

- **Two pytest markers (`integration`, `warehouse`) declared upfront.**
  Even though nothing uses them in Phase 0, the marker filter in
  `pyproject.toml` deselects them by default so later phases can add real
  Postgres / Kafka / Snowflake tests without changing the default CI
  behaviour. The pattern mirrors the `spark` marker in the sibling
  streaming repo.

## How to run

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
pre-commit install
pytest
```

Expected: pytest reports `2 passed`.

## Gotchas

- Global `~/.gitconfig` may point at a work email. This repo's local
  `.git/config` overrides `user.email` to `dirisala.bapuji@gmail.com`
  — verify with `git config --show-origin user.email` after cloning
  on a new machine.

- The `.gitignore` excludes `profiles.yml` and any `.snowflake/` config
  aggressively. When dbt lands in Phase 4, keep the profile template
  at `dbt/profiles.template.yml` and let each developer copy it locally.

## References

- Sibling portfolio repos: [`member-lakehouse`](https://github.com/bapuji-dirisala/member-lakehouse), [`rides-telemetry-platform`](https://github.com/bapuji-dirisala/rides-telemetry-platform)
- Hatchling build backend: <https://hatch.pypa.io/latest/config/build/>
- Ruff configuration: <https://docs.astral.sh/ruff/configuration/>
- dbt project layout best practices: <https://docs.getdbt.com/best-practices/how-we-structure/1-guide-overview>
