from __future__ import annotations

import time
from dataclasses import dataclass

import httpx


@dataclass
class _JwksEntry:
    keys_by_kid: dict[str, dict]
    expires_at: float


class JwksCache:
    """
    Lightweight in-process JWKS cache.

    Keeps key material for a short TTL to avoid repeated remote calls while
    still allowing key rotation to be picked up quickly.
    """

    def __init__(self, *, ttl_sec: int = 300, timeout_sec: int = 5) -> None:
        self._ttl_sec = max(0, int(ttl_sec))
        self._timeout_sec = max(1, int(timeout_sec))
        self._cache_by_uri: dict[str, _JwksEntry] = {}

    def get_key(self, jwks_uri: str, kid: str) -> dict | None:
        if not jwks_uri or not kid:
            return None

        now = time.monotonic()
        current = self._cache_by_uri.get(jwks_uri)
        if current is not None and now < current.expires_at:
            key = current.keys_by_kid.get(kid)
            if key is not None:
                return key

        refreshed = self._refresh(jwks_uri)
        if refreshed is None:
            # If refresh fails, allow stale cache as last resort.
            if current is not None:
                return current.keys_by_kid.get(kid)
            return None
        return refreshed.keys_by_kid.get(kid)

    def _refresh(self, jwks_uri: str) -> _JwksEntry | None:
        response = httpx.get(jwks_uri, timeout=self._timeout_sec)
        response.raise_for_status()
        payload = response.json()
        keys = payload.get("keys") if isinstance(payload, dict) else None
        if not isinstance(keys, list):
            return None

        keys_by_kid: dict[str, dict] = {}
        for key in keys:
            if not isinstance(key, dict):
                continue
            kid = str(key.get("kid") or "").strip()
            if not kid:
                continue
            keys_by_kid[kid] = key

        entry = _JwksEntry(
            keys_by_kid=keys_by_kid,
            expires_at=time.monotonic() + self._ttl_sec if self._ttl_sec > 0 else time.monotonic(),
        )
        self._cache_by_uri[jwks_uri] = entry
        return entry
