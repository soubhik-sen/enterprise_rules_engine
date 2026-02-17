import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text, Column, String, Integer, ForeignKey, JSON, TypeDecorator, CHAR
from sqlalchemy.orm import sessionmaker, declarative_base, relationship
import uuid
import time
import sys
import os

# Add backend to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

# GUID implementation for SQLite
class GUID(TypeDecorator):
    impl = CHAR
    cache_ok = True
    def load_dialect_impl(self, dialect):
        return dialect.type_descriptor(CHAR(36))
    def process_bind_param(self, value, dialect):
        if value is None: return value
        else: return str(value)
    def process_result_value(self, value, dialect):
        if value is None: return value
        else: return uuid.UUID(value)

Base = declarative_base()

class DecisionTable(Base):
    __tablename__ = "decision_tables"
    id = Column(GUID, primary_key=True, default=uuid.uuid4)
    slug = Column(String, unique=True, index=True)
    description = Column(String, default="")
    hit_policy = Column(String, default="FIRST_HIT")
    rules = relationship("DecisionRule", back_populates="table", order_by="DecisionRule.priority")

class DecisionRule(Base):
    __tablename__ = "decision_rules"
    id = Column(GUID, primary_key=True, default=uuid.uuid4)
    table_id = Column(GUID, ForeignKey("decision_tables.id"))
    priority = Column(Integer, default=0)
    logic = Column(JSON)
    table = relationship("DecisionTable", back_populates="rules")

import backend.models
backend.models.DecisionTable = DecisionTable
backend.models.DecisionRule = DecisionRule

from backend.main import app
from backend.database import get_db

SQLALCHEMY_DATABASE_URL = "sqlite:///./test.db"
engine = create_engine(SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False})
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base.metadata.drop_all(bind=engine)
Base.metadata.create_all(bind=engine)

def override_get_db():
    db = TestingSessionLocal()
    try:
        yield db
    finally:
        db.close()

app.dependency_overrides[get_db] = override_get_db
client = TestClient(app)

def test_full_lifecycle_tax_engine():
    slug = f"tax_{uuid.uuid4().hex[:8]}"
    resp = client.post("/tables", json={"slug": slug, "hit_policy": "FIRST_HIT"})
    assert resp.status_code == 201
    t_id = resp.json()["id"]

    client.post(f"/tables/{t_id}/rules", json={"priority": 10, "logic": {"inputs": {"income": "0..100000"}, "outputs": {"tax": 0.5}}})
    client.post(f"/tables/{t_id}/rules", json={"priority": 2, "logic": {"inputs": {"income": "10001..50000"}, "outputs": {"tax": 0.2}}})
    
    eval_resp = client.post("/evaluate", json={"table_slug": slug, "context": {"income": 25000}})
    assert eval_resp.json()["result"]["tax"] == 0.2

def test_adversarial_payload_injection():
    slug = f"inj_{uuid.uuid4().hex[:8]}"
    t_id = client.post("/tables", json={"slug": slug}).json()["id"]
    payload = {"inputs": {"age": "__import__('os').system('echo pwned')"}, "outputs": {"ok": False}}
    client.post(f"/tables/{t_id}/rules", json={"priority": 1, "logic": payload})
    eval_resp = client.post("/evaluate", json={"table_slug": slug, "context": {"age": 25}})
    assert eval_resp.json()["rule_id"] is None

def test_circular_priority_tie():
    slug = f"tie_{uuid.uuid4().hex[:8]}"
    t_id = client.post("/tables", json={"slug": slug}).json()["id"]
    client.post(f"/tables/{t_id}/rules", json={"priority": 5, "logic": {"inputs": {"x": "1"}, "outputs": {"v": "A"}}})
    client.post(f"/tables/{t_id}/rules", json={"priority": 5, "logic": {"inputs": {"x": "1"}, "outputs": {"v": "B"}}})
    eval_resp = client.post("/evaluate", json={"table_slug": slug, "context": {"x": 1}})
    assert eval_resp.json()["result"]["v"] in ["A", "B"]

def test_schema_mismatch_graceful():
    slug = f"schema_{uuid.uuid4().hex[:8]}"
    t_id = client.post("/tables", json={"slug": slug}).json()["id"]
    client.post(f"/tables/{t_id}/rules", json={"priority": 1, "logic": {"inputs": {"age": "18..65"}, "outputs": {"ok": True}}})
    eval_resp = client.post("/evaluate", json={"table_slug": slug, "context": {"height": 180}})
    assert eval_resp.json()["rule_id"] is None

def test_creation_loop_stress():
    """Verify system handles rapid creation of 50 rules."""
    slug = f"loop_{uuid.uuid4().hex[:8]}"
    t_id = client.post("/tables", json={"slug": slug}).json()["id"]
    for i in range(50):
        resp = client.post(f"/tables/{t_id}/rules", json={"priority": i, "logic": {"inputs": {"v": str(i)}, "outputs": {"x": i}}})
        assert resp.status_code == 201

def test_garbage_syntax_rejected():
    """Verify that inverted ranges are rejected by validate_syntax in crud.py."""
    slug = f"syntax_{uuid.uuid4().hex[:8]}"
    t_id = client.post("/tables", json={"slug": slug}).json()["id"]
    # Inverted range 50..10 should be rejected by validate_syntax
    resp = client.post(f"/tables/{t_id}/rules", json={"priority": 1, "logic": {"inputs": {"v": "50..10"}, "outputs": {"x": 1}}})
    assert resp.status_code == 400
    assert "Invalid syntax" in resp.json()["detail"]

if __name__ == "__main__":
    pytest.main([__file__])
