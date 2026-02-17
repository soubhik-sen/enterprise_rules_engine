import json
import os
import threading
import time
from typing import Any

import httpx

from backend.resolver_errors import ResolverConfigurationError, ResolverDataError


class _InMemoryTtlCache:
    def __init__(self, ttl_seconds: int):
        self._ttl = max(1, ttl_seconds)
        self._lock = threading.Lock()
        self._store: dict[str, tuple[float, Any]] = {}

    def get(self, key: str) -> Any | None:
        now = time.time()
        with self._lock:
            value = self._store.get(key)
            if not value:
                return None
            expires_at, payload = value
            if expires_at <= now:
                self._store.pop(key, None)
                return None
            return payload

    def set(self, key: str, value: Any) -> None:
        expires_at = time.time() + self._ttl
        with self._lock:
            self._store[key] = (expires_at, value)


class ExternalDataClient:
    def __init__(
        self,
        *,
        base_url: str | None = None,
        default_ttl_seconds: int | None = None,
        timeout_seconds: float | None = None,
    ):
        self._base_url = base_url or os.getenv("BUSINESS_OBJECT_BASE_URL", "").strip()
        ttl = default_ttl_seconds or int(
            os.getenv("EXTERNAL_CACHE_TTL_SECONDS", "30")
        )
        self._cache = _InMemoryTtlCache(ttl_seconds=ttl)
        self._client = httpx.Client(
            timeout=timeout_seconds or float(os.getenv("EXTERNAL_HTTP_TIMEOUT", "6")),
        )

    def fetch_json(
        self,
        *,
        source_service: str,
        endpoint: str,
        method: str = "GET",
        params: dict[str, Any] | None = None,
        headers: dict[str, Any] | None = None,
    ) -> Any:
        method_upper = method.strip().upper() or "GET"
        url = self._resolve_url(source_service, endpoint)
        params = params or {}
        headers = headers or {}

        cache_key = self._cache_key(
            source_service=source_service,
            method=method_upper,
            url=url,
            params=params,
            headers=headers,
        )
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        try:
            response = self._client.request(
                method_upper,
                url,
                params=params,
                headers=headers,
            )
        except httpx.HTTPError as e:
            raise ResolverDataError(
                f"External service '{source_service}' request failed: {e}"
            ) from e

        if response.status_code >= 400:
            raise ResolverDataError(
                f"External service '{source_service}' returned HTTP {response.status_code}"
            )

        try:
            payload = response.json()
        except ValueError as e:
            raise ResolverDataError(
                f"External service '{source_service}' returned invalid JSON."
            ) from e

        self._cache.set(cache_key, payload)
        return payload

    def _resolve_url(self, source_service: str, endpoint: str) -> str:
        service_name = str(source_service or "").strip()
        if not service_name:
            raise ResolverConfigurationError("source_service is required for EXTERNAL attributes.")

        env_key = f"SERVICE_URL_{service_name.upper()}"
        base_url = os.getenv(env_key, "").strip()
        if not base_url:
            base_url = self._base_url
        if not base_url:
            raise ResolverConfigurationError(
                f"No base URL configured for service '{service_name}'."
            )

        endpoint = (endpoint or "").strip()
        if not endpoint:
            raise ResolverConfigurationError("endpoint is required for EXTERNAL attributes.")

        if endpoint.startswith("http://") or endpoint.startswith("https://"):
            return endpoint

        return f"{base_url.rstrip('/')}/{endpoint.lstrip('/')}"

    def _cache_key(
        self,
        *,
        source_service: str,
        method: str,
        url: str,
        params: dict[str, Any],
        headers: dict[str, Any],
    ) -> str:
        payload = json.dumps(params, sort_keys=True, default=str)
        headers_payload = json.dumps(headers, sort_keys=True, default=str)
        return f"{source_service}|{method}|{url}|{payload}|{headers_payload}"
