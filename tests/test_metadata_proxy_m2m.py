import os
import sys

import pytest
from fastapi.testclient import TestClient

# Add backend package root to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import backend.main as main


def test_proxy_metadata_attributes_calls_upstream_with_m2m(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("ATTRIBUTE_REGISTRY_BASE_URL", "http://registry.local")

    class _FakeM2M:
        @staticmethod
        def get_access_token() -> str:
            return "m2m-token-123"

    monkeypatch.setattr(main, "get_auth0_m2m_client", lambda: _FakeM2M())

    captured = {}

    class _FakeResponse:
        status_code = 200

        @staticmethod
        def json():
            return {"attributes": [{"key": "po_number", "type": "string", "label": "PO Number"}]}

    def _fake_get(url, params=None, headers=None, timeout=None):
        captured["url"] = url
        captured["params"] = params
        captured["headers"] = headers
        return _FakeResponse()

    monkeypatch.setattr(main.httpx, "get", _fake_get)

    client = TestClient(main.app)
    response = client.get("/proxy/metadata/attributes/PURCHASE_ORDER", params={"scope": "default"})

    assert response.status_code == 200
    assert response.json() == {
        "attributes": [{"key": "po_number", "type": "string", "label": "PO Number"}]
    }
    assert captured["url"] == "http://registry.local/metadata/attributes/PURCHASE_ORDER"
    assert captured["params"] == {"scope": "default"}
    assert captured["headers"]["Authorization"] == "Bearer m2m-token-123"


def test_proxy_metadata_attributes_normalizes_list_payload(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("ATTRIBUTE_REGISTRY_BASE_URL", "http://registry.local")

    class _FakeM2M:
        @staticmethod
        def get_access_token() -> str:
            return "m2m-token-123"

    monkeypatch.setattr(main, "get_auth0_m2m_client", lambda: _FakeM2M())

    class _FakeResponse:
        status_code = 200

        @staticmethod
        def json():
            return [
                {"attribute_name": "incoterm", "attribute_type": "string"},
                {"name": "currency", "data_type": "string", "display_name": "Currency"},
            ]

    monkeypatch.setattr(main.httpx, "get", lambda *args, **kwargs: _FakeResponse())

    client = TestClient(main.app)
    response = client.get("/proxy/metadata/attributes/PURCHASE_ORDER")

    assert response.status_code == 200
    assert response.json() == {
        "attributes": [
            {"key": "incoterm", "type": "string", "label": "incoterm"},
            {"key": "currency", "type": "string", "label": "Currency"},
        ]
    }
