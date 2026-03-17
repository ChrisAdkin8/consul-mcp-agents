"""Vault authentication and GCP token generation via hvac."""

from __future__ import annotations

import logging
import os
import time
from typing import Optional

import hvac

logger = logging.getLogger(__name__)

# Default timeout for Vault API calls (seconds).
_VAULT_TIMEOUT = int(os.environ.get("VAULT_CLIENT_TIMEOUT", "30"))

# Retry config for transient Vault failures (GCP token generation).
_MAX_RETRIES = 3
_RETRY_BACKOFF_BASE = 1.0  # seconds; doubles each retry


class VaultClient:
    """Thin wrapper around hvac for userpass auth and GCP token generation."""

    def __init__(self, address: str, namespace: str = "") -> None:
        self._address = address
        self._namespace = namespace or None
        self._client: Optional[hvac.Client] = None

    def login_userpass(self, username: str, password: str) -> dict:
        """Authenticate with Vault userpass and return auth info."""
        client = hvac.Client(
            url=self._address,
            namespace=self._namespace,
            timeout=_VAULT_TIMEOUT,
        )
        result = client.auth.userpass.login(username=username, password=password)
        client.token = result["auth"]["client_token"]
        self._client = client
        return result["auth"]

    @property
    def token(self) -> Optional[str]:
        return self._client.token if self._client else None

    def get_policies(self) -> list[str]:
        """Return the list of policies attached to the current token."""
        if not self._client:
            return []
        try:
            info = self._client.auth.token.lookup_self()
            return info["data"].get("policies", [])
        except Exception:
            logger.exception("Failed to look up token policies")
            return []

    def generate_gcp_token(self, gcp_mount: str, roleset: str) -> Optional[str]:
        """Generate a short-lived GCP access token via the Vault GCP secrets engine.

        Retries transient failures with exponential backoff.
        Returns the access token string, or None if all attempts fail.
        """
        if not self._client:
            return None
        for attempt in range(_MAX_RETRIES):
            try:
                result = self._client.read(f"{gcp_mount}/token/{roleset}")
                if result and "data" in result:
                    return result["data"].get("token")
            except Exception:
                wait = _RETRY_BACKOFF_BASE * (2 ** attempt)
                logger.warning(
                    "GCP token generation attempt %d/%d failed (mount=%s, roleset=%s), retrying in %.1fs",
                    attempt + 1, _MAX_RETRIES, gcp_mount, roleset, wait,
                )
                if attempt < _MAX_RETRIES - 1:
                    time.sleep(wait)
        logger.error("All %d attempts to generate GCP token failed (mount=%s, roleset=%s)", _MAX_RETRIES, gcp_mount, roleset)
        return None

    def determine_role(self, policies: list[str]) -> Optional[str]:
        """Infer the user role from their Vault policies.

        Precedence: operator > analyst > viewer.
        Returns the role name, or None if no recognised policy is found.
        """
        for role in ("operator", "analyst", "viewer"):
            if f"{role}-policy" in policies:
                return role
        return None
