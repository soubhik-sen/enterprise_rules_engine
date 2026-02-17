from fastapi.testclient import TestClient

from backend.main import app


client = TestClient(app)


def _base_table():
    return {
        "slug": "consistency_check_table",
        "description": "bulk upload validation",
        "hit_policy": "FIRST_HIT",
        "input_schema": {"age": "number", "is_active": "boolean"},
        "output_schema": {"score": "decimal"},
    }


def test_rules_consistency_check_zero_errors():
    payload = {
        "table": _base_table(),
        "rules": [
            {
                "local_id": "r1",
                "priority": 1,
                "logic": {
                    "inputs": {"age": "18..40", "is_active": "True"},
                    "outputs": {"score": 10.5},
                },
            },
            {
                "local_id": "r2",
                "priority": 2,
                "logic": {
                    "inputs": {"age": ">=41", "is_active": "False"},
                    "outputs": {"score": 3.25},
                },
            },
        ],
    }

    resp = client.post("/rules/consistency-check", json=payload)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total_rules"] == 2
    assert body["error_count"] == 0
    assert body["errors"] == []


def test_rules_consistency_check_collects_row_errors():
    payload = {
        "table": _base_table(),
        "rules": [
            {
                "local_id": "r1",
                "priority": 1,
                "logic": {
                    "inputs": {"age": "invalid range", "is_active": ">1"},
                    "outputs": {"score": 1.0},
                },
            },
            {
                "local_id": "r2",
                "priority": 2,
                "logic": {
                    "inputs": {"age": "10..20"},
                    "outputs": {"score": 2.0},
                },
            },
        ],
    }

    resp = client.post("/rules/consistency-check", json=payload)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total_rules"] == 2
    assert body["error_count"] >= 2
    messages = [e["message"] for e in body["errors"]]
    assert any("does not support range or comparison logic" in msg for msg in messages)
    assert any("Missing required input field" in msg for msg in messages)
