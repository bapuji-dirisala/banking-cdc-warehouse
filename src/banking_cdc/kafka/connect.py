"""Thin wrapper around the Kafka Connect REST API.

Only the endpoints Phase 2 actually needs: health, list, register
(idempotent via ``PUT /connectors/{name}/config``), status, delete.
``wait_for_connect`` is a small polling helper for scripts and tests —
Kafka Connect takes 30-60s on first boot and the REST API 404s on
``/connectors`` until the worker fully initialises.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

import requests

# Default Connect REST URL — overridable via env for tests / alt hosts.
DEFAULT_CONNECT_URL = "http://localhost:8083"
ENV_CONNECT_URL = "BANKING_CDC_CONNECT_URL"


class ConnectClient:
    """Minimal Kafka Connect REST client scoped to Phase 2 needs."""

    def __init__(self, base_url: str | None = None, timeout: float = 10.0) -> None:
        self.base_url = (base_url or os.environ.get(ENV_CONNECT_URL, DEFAULT_CONNECT_URL)).rstrip(
            "/"
        )
        self.timeout = timeout

    # --- read -----------------------------------------------------------

    def health(self) -> dict[str, Any]:
        """GET ``/`` — returns the worker's version + kafka_cluster_id."""
        r = requests.get(f"{self.base_url}/", timeout=self.timeout)
        r.raise_for_status()
        data: dict[str, Any] = r.json()
        return data

    def list_connectors(self) -> list[str]:
        """GET ``/connectors`` — returns connector names."""
        r = requests.get(f"{self.base_url}/connectors", timeout=self.timeout)
        r.raise_for_status()
        data: list[str] = r.json()
        return data

    def status(self, name: str) -> dict[str, Any]:
        """GET ``/connectors/{name}/status`` — connector + task states."""
        r = requests.get(f"{self.base_url}/connectors/{name}/status", timeout=self.timeout)
        r.raise_for_status()
        data: dict[str, Any] = r.json()
        return data

    # --- write ----------------------------------------------------------

    def register(self, config: dict[str, Any]) -> dict[str, Any]:
        """Create-or-update a connector.

        Uses ``PUT /connectors/{name}/config`` so the call is idempotent —
        re-running ``banking-cdc kafka register`` updates the existing
        connector instead of 409'ing.
        """
        if "name" not in config or "config" not in config:
            raise ValueError("connector config requires top-level 'name' and 'config' keys")
        name = config["name"]
        payload = config["config"]
        r = requests.put(
            f"{self.base_url}/connectors/{name}/config",
            json=payload,
            timeout=self.timeout,
        )
        r.raise_for_status()
        data: dict[str, Any] = r.json()
        return data

    def delete(self, name: str) -> None:
        """DELETE ``/connectors/{name}`` — swallows 404 for idempotence."""
        r = requests.delete(f"{self.base_url}/connectors/{name}", timeout=self.timeout)
        if r.status_code not in (200, 204, 404):
            r.raise_for_status()


def wait_for_connect(base_url: str, timeout_s: float = 120.0) -> None:
    """Poll the Connect REST API until it answers 200 on ``/connectors``.

    Exponential backoff from 1s up to 8s between attempts. Raises
    ``TimeoutError`` if the deadline passes.
    """
    endpoint = f"{base_url.rstrip('/')}/connectors"
    deadline = time.monotonic() + timeout_s
    wait = 1.0
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            r = requests.get(endpoint, timeout=5)
            if r.status_code == 200:
                return
            last_err = RuntimeError(f"HTTP {r.status_code}: {r.text[:200]}")
        except requests.RequestException as e:
            last_err = e
        time.sleep(wait)
        wait = min(wait * 1.5, 8.0)
    raise TimeoutError(
        f"Kafka Connect at {base_url} did not become ready in {timeout_s:.0f}s; "
        f"last error: {last_err}"
    )


def load_connector_config(path: str | Path) -> dict[str, Any]:
    """Load a connector config JSON file and validate its top-level shape."""
    with open(path) as fh:
        config: dict[str, Any] = json.load(fh)
    if not isinstance(config, dict) or "name" not in config or "config" not in config:
        raise ValueError(
            f"invalid connector config at {path}: expected a dict with 'name' and 'config' keys"
        )
    return config
