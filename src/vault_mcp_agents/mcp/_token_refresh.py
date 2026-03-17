"""File-based GCP token refresh for vault-agent sidecar integration.

In GKE, vault-agent runs as a sidecar that periodically re-renders
/vault/secrets/gcp-token when the Vault lease expires. This module
watches the file's mtime and refreshes cached GCP clients when the
token changes.

Backward-compatible: falls back to GOOGLE_ACCESS_TOKEN env var when
GCP_TOKEN_FILE is not set (local/stdio mode).
"""

from __future__ import annotations

import logging
import os
import threading
from typing import Optional

logger = logging.getLogger(__name__)


class TokenRefresher:
    """Reads a GCP OAuth2 token from a file, refreshing when the file changes."""

    def __init__(self) -> None:
        self._token_file: str | None = os.environ.get("GCP_TOKEN_FILE")
        self._last_token: str | None = None
        self._last_mtime: float = 0.0
        self._lock = threading.Lock()

    def get_token(self) -> str | None:
        """Return the current GCP token, re-reading from file if changed.

        Thread-safe: multiple asyncio.to_thread() workers may call this
        concurrently.
        """
        if self._token_file:
            with self._lock:
                try:
                    mtime = os.path.getmtime(self._token_file)
                    if mtime != self._last_mtime:
                        with open(self._token_file) as f:
                            self._last_token = f.read().strip()
                        self._last_mtime = mtime
                        logger.info("GCP token refreshed from %s", self._token_file)
                except OSError:
                    logger.warning("Cannot read GCP token file: %s", self._token_file)
                return self._last_token

        # Fallback: env var (local/stdio mode)
        return os.environ.get("GOOGLE_ACCESS_TOKEN")

    @property
    def token_changed(self) -> bool:
        """Check if the token file has been modified since last read."""
        if not self._token_file:
            return False
        try:
            return os.path.getmtime(self._token_file) != self._last_mtime
        except OSError:
            return False
