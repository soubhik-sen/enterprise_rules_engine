from __future__ import annotations

from functools import lru_cache
import os
from typing import Any

from fastapi import Header, HTTPException

from backend.security.auth0_jwt_verifier import (
    Auth0JWTVerifier,
    AuthTokenValidationError,
)
from backend.security.jwks_cache import JwksCache


def _as_bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def _as_int(value: str | None, default: int) -> int:
    if value is None:
        return default
    try:
        return int(value.strip())
    except Exception:
        return default


def _normalized_auth_mode() -> str:
    raw = (os.getenv("AUTH_MODE", "jwt_only") or "jwt_only").strip().lower()
    if raw in {"legacy_header", "dual", "jwt_only"}:
        return raw
    return "jwt_only"


def _auth0_issuer() -> str:
    issuer = (os.getenv("AUTH0_ISSUER", "") or "").strip()
    if issuer:
        return issuer if issuer.endswith("/") else f"{issuer}/"
    domain = (os.getenv("AUTH0_DOMAIN", "") or "").strip()
    if not domain:
        return ""
    return f"https://{domain}/"


def _auth0_jwks_uri() -> str:
    jwks_uri = (os.getenv("AUTH0_JWKS_URI", "") or "").strip()
    if jwks_uri:
        return jwks_uri
    domain = (os.getenv("AUTH0_DOMAIN", "") or "").strip()
    if not domain:
        return ""
    return f"https://{domain}/.well-known/jwks.json"


@lru_cache(maxsize=1)
def _get_verifier() -> Auth0JWTVerifier:
    algorithms = [
        token.strip().upper()
        for token in (os.getenv("AUTH_JWT_ALGORITHMS", "RS256") or "RS256").split(",")
        if token.strip()
    ]
    return Auth0JWTVerifier(
        issuer=_auth0_issuer(),
        audience=(os.getenv("AUTH0_AUDIENCE", "") or "").strip(),
        jwks_uri=_auth0_jwks_uri(),
        algorithms=algorithms or ["RS256"],
        jwks_cache=JwksCache(
            ttl_sec=_as_int(os.getenv("AUTH_JWKS_CACHE_TTL_SEC"), 300),
            timeout_sec=_as_int(os.getenv("AUTH_JWKS_TIMEOUT_SEC"), 5),
        ),
        leeway_sec=_as_int(os.getenv("AUTH_JWT_CLOCK_SKEW_SEC"), 60),
        allow_insecure_dev_tokens=_as_bool(
            os.getenv("AUTH_ALLOW_INSECURE_DEV_TOKENS"),
            False,
        ),
    )


def _extract_bearer_token(authorization: str | None) -> str | None:
    header = authorization or ""
    prefix = "Bearer "
    if not header.startswith(prefix):
        return None
    token = header[len(prefix) :].strip()
    return token or None


def require_evaluate_token(
    authorization: str | None = Header(default=None, alias="Authorization"),
) -> dict[str, Any]:
    mode = _normalized_auth_mode()
    if mode != "jwt_only":
        return {}

    token = _extract_bearer_token(authorization)
    if not token:
        raise HTTPException(status_code=401, detail="Missing Bearer access token.")

    try:
        return _get_verifier().verify(token)
    except AuthTokenValidationError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc
