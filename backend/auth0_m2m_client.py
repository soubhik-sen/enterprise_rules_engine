import os
import threading
import time

import httpx

from backend.resolver_errors import ResolverConfigurationError, ResolverDataError


class Auth0M2MClient:
    """Fetches and caches Auth0 M2M access tokens for backend-to-backend calls."""

    def __init__(
        self,
        *,
        domain: str | None = None,
        audience: str | None = None,
        client_id: str | None = None,
        client_secret: str | None = None,
        token_url: str | None = None,
        timeout_seconds: float | None = None,
        leeway_seconds: int | None = None,
    ):
        self._domain = (domain or os.getenv("AUTH0_DOMAIN", "")).strip()
        self._audience = (audience or os.getenv("AUTH0_AUDIENCE", "")).strip()
        self._client_id = (
            client_id
            or os.getenv("AUTH0_M2M_CLIENT_ID", "")
            or os.getenv("AUTH0_CLIENT_ID", "")
        ).strip()
        self._client_secret = (
            client_secret
            or os.getenv("AUTH0_M2M_CLIENT_SECRET", "")
            or os.getenv("AUTH0_CLIENT_SECRET", "")
        ).strip()
        self._token_url = (
            token_url or os.getenv("AUTH0_M2M_TOKEN_URL", "") or self._derive_token_url()
        ).strip()
        self._timeout_seconds = timeout_seconds or float(os.getenv("AUTH0_M2M_TIMEOUT_SECONDS", "6"))
        self._leeway_seconds = max(0, leeway_seconds or int(os.getenv("AUTH0_M2M_TOKEN_LEEWAY_SECONDS", "60")))

        self._lock = threading.Lock()
        self._access_token: str | None = None
        self._expires_at_epoch_seconds: float = 0

    def get_access_token(self) -> str:
        now = time.time()
        with self._lock:
            if self._access_token and (now + self._leeway_seconds) < self._expires_at_epoch_seconds:
                return self._access_token

            token, expires_in_seconds = self._request_new_token()
            self._access_token = token
            self._expires_at_epoch_seconds = now + max(1, expires_in_seconds)
            return token

    def _derive_token_url(self) -> str:
        if not self._domain:
            return ""
        return f"https://{self._domain}/oauth/token"

    def _request_new_token(self) -> tuple[str, int]:
        self._validate_configuration()

        payload = {
            "grant_type": "client_credentials",
            "client_id": self._client_id,
            "client_secret": self._client_secret,
            "audience": self._audience,
        }
        headers = {"Content-Type": "application/json"}
        try:
            response = httpx.post(
                self._token_url,
                json=payload,
                headers=headers,
                timeout=self._timeout_seconds,
            )
        except httpx.HTTPError as e:
            raise ResolverDataError(f"Auth0 token request failed: {e}") from e

        if response.status_code >= 400:
            raise ResolverDataError(
                f"Auth0 token request failed with HTTP {response.status_code}"
            )

        try:
            token_payload = response.json()
        except ValueError as e:
            raise ResolverDataError("Auth0 token endpoint returned invalid JSON.") from e

        token = str(token_payload.get("access_token", "")).strip()
        if not token:
            raise ResolverDataError("Auth0 token endpoint response missing access_token.")

        expires_in_raw = token_payload.get("expires_in", 3600)
        try:
            expires_in = int(expires_in_raw)
        except (TypeError, ValueError):
            expires_in = 3600

        return token, expires_in

    def _validate_configuration(self) -> None:
        missing: list[str] = []
        if not self._token_url:
            missing.append("AUTH0_M2M_TOKEN_URL/AUTH0_DOMAIN")
        if not self._audience:
            missing.append("AUTH0_AUDIENCE")
        if not self._client_id:
            missing.append("AUTH0_M2M_CLIENT_ID/AUTH0_CLIENT_ID")
        if not self._client_secret:
            missing.append("AUTH0_M2M_CLIENT_SECRET/AUTH0_CLIENT_SECRET")
        if missing:
            raise ResolverConfigurationError(
                f"Missing Auth0 M2M configuration: {', '.join(missing)}"
            )
