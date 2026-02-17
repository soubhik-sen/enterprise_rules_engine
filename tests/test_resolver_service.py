from types import SimpleNamespace
import os
import sys

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import backend.main as main_module
from backend.database import get_db
from backend.resolver_service import (
    AttributeResolverService,
)
from backend.resolver_errors import ResolverConfigurationError, ResolverDataError


class _FakeQuery:
    def __init__(self, rows):
        self._rows = rows

    def filter(self, *args, **kwargs):
        return self

    def order_by(self, *args, **kwargs):
        return self

    def all(self):
        return self._rows


class _HydrationDb:
    def __init__(self, *, rows, sql_db: Session):
        self._rows = rows
        self._sql_db = sql_db

    def query(self, model):
        return _FakeQuery(self._rows)

    def execute(self, *args, **kwargs):
        return self._sql_db.execute(*args, **kwargs)


def _seed_sqlite_session() -> Session:
    engine = create_engine("sqlite+pysqlite:///:memory:", future=True)
    db = Session(engine)
    db.execute(text("CREATE TABLE po_headers (id TEXT PRIMARY KEY, date TEXT)"))
    db.execute(
        text(
            "CREATE TABLE shipments ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "po_id TEXT, "
            "status TEXT, "
            "updated_at INTEGER)"
        )
    )
    db.execute(
        text("INSERT INTO po_headers (id, date) VALUES (:id, :date)"),
        {"id": "PO-100", "date": "2026-02-08"},
    )
    db.execute(
        text(
            "INSERT INTO shipments (po_id, status, updated_at) "
            "VALUES (:po_id, :status, :updated_at)"
        ),
        {"po_id": "PO-100", "status": "IN_TRANSIT", "updated_at": 1},
    )
    db.execute(
        text(
            "INSERT INTO shipments (po_id, status, updated_at) "
            "VALUES (:po_id, :status, :updated_at)"
        ),
        {"po_id": "PO-100", "status": "DELIVERED", "updated_at": 2},
    )
    db.commit()
    return db


@pytest.fixture()
def client():
    test_client = TestClient(main_module.app)

    def _override_get_db():
        yield object()

    main_module.app.dependency_overrides[get_db] = _override_get_db
    try:
        yield test_client
    finally:
        main_module.app.dependency_overrides.clear()


def test_resolver_direct_and_association_lookup():
    db = _seed_sqlite_session()
    try:
        direct_value = AttributeResolverService._resolve_direct(
            db,
            {"table": "po_headers", "id_field": "id", "field": "date"},
            object_id="PO-100",
        )
        assert direct_value == "2026-02-08"

        association_value = AttributeResolverService._resolve_association(
            db,
            {
                "base_table": "po_headers",
                "join": "shipments",
                "on": "po_id",
                "field": "status",
                "order_by": "updated_at",
                "order_direction": "desc",
            },
            target_object="PURCHASE_ORDER",
            object_id="PO-100",
        )
        assert association_value == "DELIVERED"
    finally:
        db.close()


def test_hydrate_context_populates_missing_fields():
    sql_db = _seed_sqlite_session()
    try:
        rows = [
            SimpleNamespace(
                target_object="PURCHASE_ORDER",
                attribute_name="po_date",
                resolution_strategy="DIRECT",
                path_logic={"table": "po_headers", "id_field": "id", "field": "date"},
            ),
            SimpleNamespace(
                target_object="PURCHASE_ORDER",
                attribute_name="shipment_status",
                resolution_strategy="ASSOCIATION",
                path_logic={
                    "base_table": "po_headers",
                    "join": "shipments",
                    "on": "po_id",
                    "field": "status",
                    "order_by": "updated_at",
                    "order_direction": "desc",
                },
            ),
        ]
        db = _HydrationDb(rows=rows, sql_db=sql_db)
        hydrated = AttributeResolverService.hydrate_context(
            db,
            object_type="PURCHASE_ORDER",
            object_id="PO-100",
            required_attributes=["po_date", "shipment_status"],
            context={},
        )
        assert hydrated["po_date"] == "2026-02-08"
        assert hydrated["shipment_status"] == "DELIVERED"
    finally:
        sql_db.close()


def test_hydrate_context_rejects_missing_registry():
    sql_db = _seed_sqlite_session()
    try:
        rows = [
            SimpleNamespace(
                target_object="PURCHASE_ORDER",
                attribute_name="po_date",
                resolution_strategy="DIRECT",
                path_logic={"table": "po_headers", "id_field": "id", "field": "date"},
            ),
        ]
        db = _HydrationDb(rows=rows, sql_db=sql_db)
        with pytest.raises(ResolverConfigurationError):
            AttributeResolverService.hydrate_context(
                db,
                object_type="PURCHASE_ORDER",
                object_id="PO-100",
                required_attributes=["po_date", "shipment_status"],
                context={},
            )
    finally:
        sql_db.close()


def test_hydrate_context_reports_unresolved_values():
    sql_db = _seed_sqlite_session()
    try:
        rows = [
            SimpleNamespace(
                target_object="PURCHASE_ORDER",
                attribute_name="shipment_status",
                resolution_strategy="ASSOCIATION",
                path_logic={
                    "base_table": "po_headers",
                    "join": "shipments",
                    "on": "po_id",
                    "field": "status",
                },
            ),
        ]
        db = _HydrationDb(rows=rows, sql_db=sql_db)
        with pytest.raises(ResolverDataError):
            AttributeResolverService.hydrate_context(
                db,
                object_type="PURCHASE_ORDER",
                object_id="PO-404",
                required_attributes=["shipment_status"],
                context={},
            )
    finally:
        sql_db.close()


def test_metadata_endpoint_returns_allowed_attributes(client, monkeypatch):
    rows = [
        SimpleNamespace(
            target_object="PURCHASE_ORDER",
            attribute_name="po_date",
            resolution_strategy="DIRECT",
            path_logic={"table": "po_headers", "id_field": "id", "field": "date"},
        ),
        SimpleNamespace(
            target_object="PURCHASE_ORDER",
            attribute_name="shipment_status",
            resolution_strategy="ASSOCIATION",
            path_logic={"join": "shipments", "on": "po_id", "field": "status"},
        ),
    ]
    monkeypatch.setattr(
        main_module.AttributeResolverService,
        "list_attributes",
        lambda db, object_type: rows,
    )

    response = client.get("/metadata/attributes/PURCHASE_ORDER")
    assert response.status_code == 200
    payload = response.json()
    assert [row["attribute_name"] for row in payload] == [
        "po_date",
        "shipment_status",
    ]


def test_evaluate_uses_object_id_for_resolution(client, monkeypatch):
    fake_table = SimpleNamespace(
        slug="po_decision",
        hit_policy="FIRST_HIT",
        input_schema={"shipment_status": "string"},
        rules=[
            SimpleNamespace(
                id="r1",
                priority=1,
                logic={
                    "inputs": {"shipment_status": "DELIVERED"},
                    "outputs": {"release_flag": "Y"},
                },
            )
        ],
    )

    monkeypatch.setattr(
        main_module,
        "get_decision_table_by_slug",
        lambda db, table_slug: fake_table if table_slug == "po_decision" else None,
    )

    calls = {}

    def _hydrate_context(db, **kwargs):
        calls.update(kwargs)
        return {"shipment_status": "DELIVERED"}

    monkeypatch.setattr(
        main_module.AttributeResolverService,
        "hydrate_context",
        _hydrate_context,
    )

    response = client.post(
        "/evaluate",
        json={
            "table_slug": "po_decision",
            "object_id": "PO-100",
            "object_type": "PURCHASE_ORDER",
            "context": {},
        },
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["result"] == {"release_flag": "Y"}
    assert calls["object_id"] == "PO-100"
    assert calls["required_attributes"] == ["shipment_status"]


def test_evaluate_returns_not_found_when_resolution_data_missing(client, monkeypatch):
    fake_table = SimpleNamespace(
        slug="po_decision",
        hit_policy="FIRST_HIT",
        input_schema={"shipment_status": "string"},
        rules=[],
    )
    monkeypatch.setattr(
        main_module,
        "get_decision_table_by_slug",
        lambda db, table_slug: fake_table if table_slug == "po_decision" else None,
    )

    def _raise_missing(db, **kwargs):
        raise ResolverDataError("Could not resolve attributes for PURCHASE_ORDER PO-404")

    monkeypatch.setattr(
        main_module.AttributeResolverService,
        "hydrate_context",
        _raise_missing,
    )

    response = client.post(
        "/evaluate",
        json={
            "table_slug": "po_decision",
            "object_id": "PO-404",
            "object_type": "PURCHASE_ORDER",
            "context": {},
        },
    )
    assert response.status_code == 404
    assert "Could not resolve attributes" in response.json()["detail"]


def test_external_resolution_groups_requests_and_extracts_values():
    sql_db = _seed_sqlite_session()
    try:
        rows = [
            SimpleNamespace(
                target_object="PURCHASE_ORDER",
                attribute_name="po_status",
                resolution_strategy="EXTERNAL",
                path_logic={
                    "source_service": "PO_SERVICE",
                    "endpoint": "/po/{object_id}",
                    "jsonpath": "$.status",
                },
            ),
            SimpleNamespace(
                target_object="PURCHASE_ORDER",
                attribute_name="po_amount",
                resolution_strategy="EXTERNAL",
                path_logic={
                    "source_service": "PO_SERVICE",
                    "endpoint": "/po/{object_id}",
                    "jsonpath": "$.amount",
                },
            ),
        ]
        db = _HydrationDb(rows=rows, sql_db=sql_db)

        class _FakeExternalClient:
            def __init__(self):
                self.calls = []

            def fetch_json(self, **payload):
                self.calls.append(payload)
                return {"status": "APPROVED", "amount": 2500}

        client = _FakeExternalClient()
        hydrated = AttributeResolverService.hydrate_context(
            db,
            object_type="PURCHASE_ORDER",
            object_id="PO-555",
            required_attributes=["po_status", "po_amount"],
            context={},
            external_client=client,
        )
        assert hydrated["po_status"] == "APPROVED"
        assert hydrated["po_amount"] == 2500
        assert len(client.calls) == 1
    finally:
        sql_db.close()
