import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, Column, String, Integer, ForeignKey, JSON, TypeDecorator, CHAR, event
from sqlalchemy.orm import sessionmaker, declarative_base, relationship
import uuid
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
    input_schema = Column(JSON, nullable=False, default=dict)
    output_schema = Column(JSON, nullable=False, default=dict)
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

SQLALCHEMY_DATABASE_URL = "sqlite:///./test_meta_v2.db"
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

def test_ghost_column_attack():
    """Create a table with 'age'. Try to add a rule that uses 'age' AND 'height'."""
    table_slug = f"ghost_{uuid.uuid4().hex[:8]}"
    table_resp = client.post("/tables", json={
        "slug": table_slug,
        "input_schema": {"age": "number"},
        "output_schema": {"eligible": "boolean"}
    })
    table_id = table_resp.json()["id"]

    # Rule with 'age' (valid) and 'height' (Ghost Column)
    rule_logic = {
        "inputs": {"age": "18..30", "height": "180"},
        "outputs": {"eligible": True}
    }
    rule_resp = client.post(f"/tables/{table_id}/rules", json={"priority": 1, "logic": rule_logic})
    
    assert rule_resp.status_code == 400
    assert "not defined in table schema" in rule_resp.json()["detail"]

def test_type_poisoning():
    """Boolean schema field vs Range logic."""
    table_slug = f"poison_{uuid.uuid4().hex[:8]}"
    table_resp = client.post("/tables", json={
        "slug": table_slug,
        "input_schema": {"is_active": "boolean"},
        "output_schema": {"ok": "boolean"}
    })
    table_id = table_resp.json()["id"]

    # Range logic on boolean
    rule_logic = {
        "inputs": {"is_active": "10..50"},
        "outputs": {"ok": True}
    }
    rule_resp = client.post(f"/tables/{table_id}/rules", json={"priority": 1, "logic": rule_logic})
    
    assert rule_resp.status_code == 400
    assert "does not support range or comparison logic" in rule_resp.json()["detail"]

def test_empty_logic_against_required_fields():
    """Try to create a rule missing schema fields."""
    table_slug = f"empty_{uuid.uuid4().hex[:8]}"
    table_resp = client.post("/tables", json={
        "slug": table_slug,
        "input_schema": {"age": "number", "region": "string"},
        "output_schema": {"ok": "boolean"}
    })
    table_id = table_resp.json()["id"]

    # Rule missing 'region'
    rule_logic = {
        "inputs": {"age": "18..65"},
        "outputs": {"ok": True}
    }
    rule_resp = client.post(f"/tables/{table_id}/rules", json={"priority": 1, "logic": rule_logic})
    
    assert rule_resp.status_code == 400
    assert "Missing required input field 'region'" in rule_resp.json()["detail"]

def test_schema_evolution_prevention():
    """Prevent removing a column from schema if rules use it."""
    table_slug = f"evolution_{uuid.uuid4().hex[:8]}"
    table_resp = client.post("/tables", json={
        "slug": table_slug,
        "input_schema": {"age": "number", "status": "string"},
        "output_schema": {"ok": "boolean"}
    })
    table_id = table_resp.json()["id"]

    # Add valid rule using 'age' and 'status'
    rule_logic = {"inputs": {"age": "25", "status": "active"}, "outputs": {"ok": True}}
    client.post(f"/tables/{table_id}/rules", json={"priority": 1, "logic": rule_logic})

    # Try to UPDATE table to remove 'status' from input_schema
    update_data = {
        "slug": table_slug,
        "input_schema": {"age": "number"}, # 'status' removed
        "output_schema": {"ok": "boolean"}
    }
    update_resp = client.put(f"/tables/{table_id}", json=update_data)
    
    assert update_resp.status_code == 400
    assert "depends on it" in update_resp.json()["detail"]

def test_python_injection_literal_handling():
    """Verify system treats code injection as literal strings (secure)."""
    table_slug = f"safe_{uuid.uuid4().hex[:8]}"
    client.post("/tables", json={
        "slug": table_slug,
        "input_schema": {"name": "string"},
        "output_schema": {"ok": "boolean"}
    }).json()
    table_id = client.get(f"/evaluate", params={"table_slug": table_slug}).json() # Wait, need ID.
    # Just get it from create resp
    resp_create = client.post("/tables", json={"slug": table_slug+"_v2", "input_schema":{"name":"string"}, "output_schema":{"ok":"boolean"}})
    table_id = resp_create.json()["id"]

    injection = "__import__('os').system('ls')"
    rule_logic = {"inputs": {"name": injection}, "outputs": {"ok": True}}
    
    resp = client.post(f"/tables/{table_id}/rules", json={"priority": 1, "logic": rule_logic})
    assert resp.status_code == 201
    
    eval_resp = client.post("/evaluate", json={"table_slug": table_slug+"_v2", "context": {"name": "Alice"}})
    assert eval_resp.json()["rule_id"] is None

if __name__ == "__main__":
    pytest.main([__file__])
