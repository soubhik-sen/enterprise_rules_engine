import os
import sys

import pytest

# Add backend package root to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from backend.auth0_m2m_client import Auth0M2MClient


def test_auth0_m2m_client_fetches_and_caches_token(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("AUTH0_DOMAIN", "tenant.example.auth0.com")
    monkeypatch.setenv("AUTH0_AUDIENCE", "comexwise")
    monkeypatch.setenv("AUTH0_M2M_CLIENT_ID", "m2m-client-id")
    monkeypatch.setenv("AUTH0_M2M_CLIENT_SECRET", "m2m-client-secret")

    calls = {"count": 0}

    class _FakeResponse:
        status_code = 200

        @staticmethod
        def json():
            return {"access_token": "token-abc", "expires_in": 3600}

    def _fake_post(url, json=None, headers=None, timeout=None):  # noqa: A002
        calls["count"] += 1
        assert url == "https://tenant.example.auth0.com/oauth/token"
        assert json["grant_type"] == "client_credentials"
        assert json["audience"] == "comexwise"
        return _FakeResponse()

    monkeypatch.setattr("backend.auth0_m2m_client.httpx.post", _fake_post)

    client = Auth0M2MClient()
    first = client.get_access_token()
    second = client.get_access_token()

    assert first == "token-abc"
    assert second == "token-abc"
    assert calls["count"] == 1
