from __future__ import annotations

import json
from typing import Any

import jwt
from jwt import InvalidTokenError
from jwt.algorithms import RSAAlgorithm

from backend.security.jwks_cache import JwksCache


class AuthTokenValidationError(Exception):
    pass


class Auth0JWTVerifier:
    def __init__(
        self,
        *,
        issuer: str,
        audience: str,
        jwks_uri: str,
        algorithms: list[str] | None = None,
        jwks_cache: JwksCache | None = None,
        leeway_sec: int = 60,
        allow_insecure_dev_tokens: bool = False,
    ) -> None:
        self.issuer = issuer.strip()
        self.audience = audience.strip()
        self.jwks_uri = jwks_uri.strip()
        self.algorithms = algorithms or ["RS256"]
        self.jwks_cache = jwks_cache or JwksCache()
        self.leeway_sec = max(0, int(leeway_sec))
        self.allow_insecure_dev_tokens = bool(allow_insecure_dev_tokens)

    def verify(self, token: str) -> dict[str, Any]:
        raw = (token or "").strip()
        if not raw:
            raise AuthTokenValidationError("Missing access token.")

        if self.allow_insecure_dev_tokens:
            # Explicit dev-only mode for local testing environments.
            try:
                decoded = jwt.decode(
                    raw,
                    options={
                        "verify_signature": False,
                        "verify_aud": False,
                        "verify_iss": False,
                    },
                    algorithms=self.algorithms,
                )
            except InvalidTokenError as exc:
                raise AuthTokenValidationError(f"Invalid dev token: {exc}") from exc
            if not isinstance(decoded, dict):
                raise AuthTokenValidationError("Token payload is not a JSON object.")
            return decoded

        if not self.issuer:
            raise AuthTokenValidationError("JWT issuer is not configured.")
        if not self.audience:
            raise AuthTokenValidationError("JWT audience is not configured.")
        if not self.jwks_uri:
            raise AuthTokenValidationError("JWKS URI is not configured.")

        try:
            unverified_header = jwt.get_unverified_header(raw)
        except InvalidTokenError as exc:
            raise AuthTokenValidationError(f"Invalid token header: {exc}") from exc

        kid = str(unverified_header.get("kid") or "").strip()
        if not kid:
            raise AuthTokenValidationError("Token header missing key id (kid).")

        try:
            jwk = self.jwks_cache.get_key(self.jwks_uri, kid)
        except Exception as exc:
            raise AuthTokenValidationError(f"Failed to load JWKS: {exc}") from exc
        if not jwk:
            raise AuthTokenValidationError("Signing key not found for token kid.")

        try:
            public_key = RSAAlgorithm.from_jwk(json.dumps(jwk))
            decoded = jwt.decode(
                raw,
                key=public_key,
                algorithms=self.algorithms,
                audience=self.audience,
                issuer=self.issuer,
                leeway=self.leeway_sec,
                options={
                    "require": ["exp", "iat", "iss", "aud"],
                },
            )
        except InvalidTokenError as exc:
            raise AuthTokenValidationError(f"Invalid access token: {exc}") from exc

        if not isinstance(decoded, dict):
            raise AuthTokenValidationError("Token payload is not a JSON object.")
        return decoded
