"""Synthetic OLTP workload generator — Faker + weighted transaction flows."""

from __future__ import annotations

from banking_cdc.seed.generator import (
    GeneratorConfig,
    SyntheticBatch,
    generate_batch,
    persist_batch,
)

__all__ = [
    "GeneratorConfig",
    "SyntheticBatch",
    "generate_batch",
    "persist_batch",
]
