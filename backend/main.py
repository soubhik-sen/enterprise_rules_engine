from fastapi import FastAPI, Depends, HTTPException, status, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError, OperationalError
from functools import lru_cache
from urllib.parse import quote
import os
import httpx
from backend.database import get_db
from backend.schemas import (
    EvaluationRequest,
    EvaluationResponse,
    SimulationRequest,
    TableCreate,
    TableResponse,
    RuleCreate,
    RuleResponse,
    TableSchemaResponse,
    TableSaveRequest,
    TableSaveResponse,
    RuleSaveResponse,
    RuleValidationRequest,
    RuleValidationResponse,
    RuleValidationIssue,
    AttributeMetadataResponse,
)
from backend.engine import DecisionEngine
from backend.auth0_m2m_client import Auth0M2MClient
from backend.crud import (
    create_decision_table,
    add_rule_to_table,
    update_decision_table,
    list_decision_tables,
    get_decision_table_by_slug,
    delete_decision_table,
    list_rules_for_table,
    replace_rules_for_table,
)
from backend import models
from backend.rule_parser import validate_syntax, validate_rule_against_schema
from backend.resolver_service import AttributeResolverService
from backend.resolver_errors import ResolverConfigurationError, ResolverDataError
import uuid

app = FastAPI(title="BRF+ Zen Enterprise Engine", version="2026.1")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@lru_cache(maxsize=1)
def get_auth0_m2m_client() -> Auth0M2MClient:
    return Auth0M2MClient()


def _get_attribute_registry_base_url() -> str:
    return (
        os.getenv("ATTRIBUTE_REGISTRY_BASE_URL", "").strip()
        or os.getenv("BUSINESS_OBJECT_BASE_URL", "").strip()
        or "http://localhost:8000"
    )


def _normalize_attribute_payload(payload) -> list[dict]:
    rows = payload.get("attributes") if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        return []

    normalized: list[dict] = []
    for raw in rows:
        if not isinstance(raw, dict):
            continue
        key = str(
            raw.get("key")
            or raw.get("attribute_name")
            or raw.get("name")
            or ""
        ).strip()
        if not key:
            continue
        type_name = str(
            raw.get("type")
            or raw.get("data_type")
            or raw.get("attribute_type")
            or "string"
        ).strip() or "string"
        label = str(raw.get("label") or raw.get("display_name") or key).strip() or key
        normalized.append(
            {
                "key": key,
                "type": type_name,
                "label": label,
            }
        )
    return normalized


@app.exception_handler(OperationalError)
def handle_database_operational_error(_: Request, __: OperationalError):
    return Response(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        content="Database temporarily unavailable. Please retry.",
    )


@app.options("/{full_path:path}", include_in_schema=False)
def options_fallback(full_path: str, request: Request):
    """
    Safety net for OPTIONS requests that bypass CORS middleware checks
    (e.g., clients sending raw OPTIONS without complete preflight headers).
    """
    origin = request.headers.get("origin", "*")
    methods = request.headers.get(
        "access-control-request-method",
        "GET,POST,PUT,PATCH,DELETE,OPTIONS",
    )
    headers = request.headers.get("access-control-request-headers", "*")
    return Response(
        status_code=204,
        headers={
            "Access-Control-Allow-Origin": origin,
            "Access-Control-Allow-Methods": methods,
            "Access-Control-Allow-Headers": headers,
            "Access-Control-Allow-Credentials": "true",
            "Vary": "Origin",
        },
    )


def _serialize_table(table) -> TableResponse:
    raw_hit_policy = getattr(table, "hit_policy", "FIRST_HIT")
    hit_policy = raw_hit_policy if isinstance(raw_hit_policy, str) else raw_hit_policy.value
    return TableResponse(
        id=str(table.id),
        slug=table.slug,
        object_type=getattr(table, "object_type", "") or "",
        description=getattr(table, "description", "") or "",
        hit_policy=hit_policy,
        input_schema=getattr(table, "input_schema", {}) or {},
        output_schema=getattr(table, "output_schema", {}) or {},
    )


def _serialize_rule(rule) -> RuleResponse:
    return RuleResponse(
        id=str(rule.id),
        table_id=str(rule.table_id),
        priority=rule.priority,
        logic=rule.logic,
    )


def _serialize_saved_rule(rule, local_id: str | None = None) -> RuleSaveResponse:
    return RuleSaveResponse(
        id=str(rule.id),
        table_id=str(rule.table_id),
        local_id=local_id,
        priority=rule.priority,
        logic=rule.logic,
    )


def _serialize_attribute_registry(entry) -> AttributeMetadataResponse:
    strategy = getattr(entry, "resolution_strategy", "")
    if not isinstance(strategy, str):
        strategy = strategy.value
    return AttributeMetadataResponse(
        target_object=str(getattr(entry, "target_object", "")),
        attribute_name=str(getattr(entry, "attribute_name", "")),
        resolution_strategy=str(strategy),
        path_logic=getattr(entry, "path_logic", {}) or {},
    )


def _is_schema_enforced(table) -> bool:
    input_schema = getattr(table, "input_schema", {}) or {}
    output_schema = getattr(table, "output_schema", {}) or {}
    return bool(input_schema) or bool(output_schema)


def _collect_rule_validation_issues(
    table: TableCreate,
    rules: list,
) -> list[RuleValidationIssue]:
    issues: list[RuleValidationIssue] = []
    input_schema = table.input_schema or {}
    output_schema = table.output_schema or {}

    for idx, rule in enumerate(rules):
        row_num = idx + 2  # CSV-style row index (1 = header)
        local_id = getattr(rule, "local_id", None)
        logic = rule.logic.model_dump()
        try:
            validate_rule_against_schema(logic, input_schema, output_schema)
        except ValueError as e:
            issues.append(
                RuleValidationIssue(
                    row=row_num,
                    local_id=local_id,
                    message=str(e),
                )
            )

        for key, condition in logic.get("inputs", {}).items():
            if not validate_syntax(condition):
                issues.append(
                    RuleValidationIssue(
                        row=row_num,
                        local_id=local_id,
                        field=key,
                        message=f"Invalid syntax for field '{key}': '{condition}'",
                    )
                )

    return issues


@app.get("/health")
def health_check(db: Session = Depends(get_db)):
    """Verifies API and Database connectivity."""
    try:
        db.execute(text("SELECT 1"))
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        return {"status": "unhealthy", "database": str(e)}

@app.get("/tables", response_model=list[TableResponse])
def get_tables(search: str | None = None, db: Session = Depends(get_db)):
    tables = list_decision_tables(db, search)
    return [_serialize_table(table) for table in tables]


@app.get("/tables/by-slug/{table_slug}", response_model=TableResponse)
def get_table_by_slug(table_slug: str, db: Session = Depends(get_db)):
    table = get_decision_table_by_slug(db, table_slug)
    if not table:
        raise HTTPException(status_code=404, detail="Table not found")
    return _serialize_table(table)


@app.delete("/tables/{table_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_table(table_id: uuid.UUID, db: Session = Depends(get_db)):
    delete_decision_table(db, table_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.post("/tables", status_code=status.HTTP_201_CREATED, response_model=TableResponse)
def create_table(table: TableCreate, db: Session = Depends(get_db)):
    """Creates a new decision table."""
    try:
        created = create_decision_table(db, table)
        return _serialize_table(created)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/tables/{table_id}/rules", status_code=status.HTTP_201_CREATED, response_model=RuleResponse)
def create_rule(table_id: uuid.UUID, rule: RuleCreate, db: Session = Depends(get_db)):
    """Adds a rule to a table."""
    created = add_rule_to_table(db, table_id, rule)
    return _serialize_rule(created)


@app.get("/tables/{table_id}/rules", response_model=list[RuleResponse])
def get_table_rules(table_id: uuid.UUID, db: Session = Depends(get_db)):
    rules = list_rules_for_table(db, table_id)
    return [_serialize_rule(rule) for rule in rules]


@app.put("/tables/{table_id}/rules", response_model=list[RuleResponse])
def replace_table_rules(table_id: uuid.UUID, rules: list[RuleCreate], db: Session = Depends(get_db)):
    replaced = replace_rules_for_table(db, table_id, rules)
    return [_serialize_rule(rule) for rule in replaced]


@app.post("/tables/save", response_model=TableSaveResponse)
def save_table_atomic(request: TableSaveRequest, db: Session = Depends(get_db)):
    """
    Atomically saves table metadata/schema and replaces all rules in one transaction.
    """
    table_schema = request.table
    table = None

    try:
        if request.table_id:
            try:
                table_uuid = uuid.UUID(request.table_id)
            except ValueError as e:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="table_id must be a valid UUID",
                ) from e
            table = db.query(models.DecisionTable).filter(models.DecisionTable.id == table_uuid).first()
            if not table:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Table not found")
        else:
            table = models.DecisionTable()
            db.add(table)

        if _is_schema_enforced(table):
            for existing_rule in table.rules:
                inputs = existing_rule.logic.get("inputs", {})
                for key in inputs:
                    if key not in table_schema.input_schema:
                        raise HTTPException(
                            status_code=status.HTTP_400_BAD_REQUEST,
                            detail=f"Cannot remove field '{key}' from schema: Rule '{existing_rule.id}' depends on it.",
                        )
                outputs = existing_rule.logic.get("outputs", {})
                for key in outputs:
                    if key not in table_schema.output_schema:
                        raise HTTPException(
                            status_code=status.HTTP_400_BAD_REQUEST,
                            detail=f"Cannot remove output field '{key}' from schema: Rule '{existing_rule.id}' depends on it.",
                        )

        table.slug = table_schema.slug
        table.description = table_schema.description
        if hasattr(table, "object_type"):
            table.object_type = table_schema.object_type or ""
        table.hit_policy = table_schema.hit_policy
        table.input_schema = table_schema.input_schema
        table.output_schema = table_schema.output_schema
        db.flush()

        validated_rules: list[tuple[int, dict, str | None]] = []
        for rule in request.rules:
            logic = rule.logic.model_dump()
            if _is_schema_enforced(table):
                validate_rule_against_schema(logic, table.input_schema, table.output_schema)

            for key, condition in logic.get("inputs", {}).items():
                if not validate_syntax(condition):
                    raise HTTPException(
                        status_code=status.HTTP_400_BAD_REQUEST,
                        detail=f"Invalid syntax for field '{key}': '{condition}'",
                    )
            validated_rules.append((rule.priority, logic, rule.local_id))

        db.query(models.DecisionRule).filter(
            models.DecisionRule.table_id == table.id
        ).delete(synchronize_session=False)

        created_rules: list[models.DecisionRule] = []
        local_ids: list[str | None] = []
        for priority, logic, local_id in sorted(validated_rules, key=lambda item: item[0]):
            db_rule = models.DecisionRule(
                table_id=table.id,
                priority=priority,
                logic=logic,
            )
            db.add(db_rule)
            created_rules.append(db_rule)
            local_ids.append(local_id)

        db.commit()
        db.refresh(table)
        for rule in created_rules:
            db.refresh(rule)

        saved_rules = [
            _serialize_saved_rule(rule, local_id=local_ids[idx])
            for idx, rule in enumerate(created_rules)
        ]
        return TableSaveResponse(table=_serialize_table(table), rules=saved_rules)
    except HTTPException:
        db.rollback()
        raise
    except IntegrityError as e:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Table slug '{table_schema.slug}' is already in use by another table."
            ),
        ) from e
    except ValueError as e:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e)) from e


@app.post("/rules/consistency-check", response_model=RuleValidationResponse)
def rules_consistency_check(request: RuleValidationRequest):
    issues = _collect_rule_validation_issues(request.table, request.rules)
    return RuleValidationResponse(
        total_rules=len(request.rules),
        error_count=len(issues),
        errors=issues,
    )


@app.get("/proxy/metadata/attributes/{object_type}")
def proxy_object_attributes(object_type: str, scope: str | None = None):
    base_url = _get_attribute_registry_base_url()
    if not base_url:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="ATTRIBUTE_REGISTRY_BASE_URL (or BUSINESS_OBJECT_BASE_URL) is not configured.",
        )

    encoded_object_type = quote(object_type.strip(), safe="")
    upstream_url = f"{base_url.rstrip('/')}/metadata/attributes/{encoded_object_type}"
    params = {}
    if scope and scope.strip():
        params["scope"] = scope.strip()

    try:
        access_token = get_auth0_m2m_client().get_access_token()
        upstream_response = httpx.get(
            upstream_url,
            params=params or None,
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=float(os.getenv("ATTRIBUTE_REGISTRY_TIMEOUT_SECONDS", "6")),
        )
    except ResolverConfigurationError as e:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e)) from e
    except ResolverDataError as e:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(e)) from e
    except httpx.HTTPError as e:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Attribute registry request failed: {e}",
        ) from e

    if upstream_response.status_code >= 400:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=(
                f"Attribute registry returned HTTP {upstream_response.status_code} "
                "for metadata attributes."
            ),
        )

    try:
        payload = upstream_response.json()
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Attribute registry returned invalid JSON.",
        ) from e

    return {"attributes": _normalize_attribute_payload(payload)}


@app.get("/metadata/attributes/{object_type}", response_model=list[AttributeMetadataResponse])
def get_object_attributes(object_type: str, db: Session = Depends(get_db)):
    try:
        rows = AttributeResolverService.list_attributes(db, object_type)
    except ResolverConfigurationError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e)) from e
    return [_serialize_attribute_registry(row) for row in rows]


@app.get("/tables/{table_id}/schema", response_model=TableSchemaResponse)
def get_table_schema(table_id: uuid.UUID, db: Session = Depends(get_db)):
    """Returns the input and output schemas for a table."""
    table = db.query(models.DecisionTable).filter(models.DecisionTable.id == table_id).first()
    if not table:
        raise HTTPException(status_code=404, detail="Table not found")
    return {
        "input_schema": getattr(table, "input_schema", {}) or {},
        "output_schema": getattr(table, "output_schema", {}) or {},
    }

@app.put("/tables/{table_id}", response_model=TableResponse)
def update_table(table_id: uuid.UUID, table: TableCreate, db: Session = Depends(get_db)):
    """Updates a decision table's metadata and schema."""
    updated = update_decision_table(db, table_id, table)
    return _serialize_table(updated)


@app.post("/evaluate", response_model=EvaluationResponse)
def evaluate_rules(request: EvaluationRequest, db: Session = Depends(get_db)):
    """
    Evaluates a specific decision table.
    """
    table = get_decision_table_by_slug(db, request.table_slug)
    if not table:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, 
            detail=f"Decision table with slug '{request.table_slug}' not found"
        )

    context = dict(request.context or {})
    if request.object_id:
        inferred_object_type = (
            request.object_type.strip()
            if request.object_type and request.object_type.strip()
            else request.table_slug.upper()
        )
        required_inputs = list((getattr(table, "input_schema", {}) or {}).keys())
        try:
            context = AttributeResolverService.hydrate_context(
                db,
                object_type=inferred_object_type,
                object_id=request.object_id,
                required_attributes=required_inputs,
                context=context,
            )
        except ResolverConfigurationError as e:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=str(e),
            ) from e
        except ResolverDataError as e:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=str(e),
            ) from e

    hit_policy = getattr(table, "hit_policy", "FIRST_HIT")
    if not isinstance(hit_policy, str):
        hit_policy = hit_policy.value
    normalized_rules = [
        {"id": str(rule.id), "priority": rule.priority, "logic": rule.logic}
        for rule in getattr(table, "rules", [])
    ]
    evaluation = DecisionEngine.evaluate_definition(
        {"hit_policy": hit_policy, "rules": normalized_rules},
        context,
        detailed=request.detailed,
    )

    return EvaluationResponse(**evaluation)


@app.post("/simulate", response_model=EvaluationResponse)
def simulate_rules(request: SimulationRequest):
    """
    Evaluates an in-memory table definition without persisting data.
    """
    table_definition = request.table_definition.model_dump()
    input_schema = table_definition.get("input_schema", {})
    output_schema = table_definition.get("output_schema", {})

    normalized_rules = []
    for rule in table_definition.get("rules", []):
        logic = rule.get("logic", {})
        try:
            validate_rule_against_schema(logic, input_schema, output_schema)
        except ValueError as e:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=str(e)
            ) from e

        for key, condition in logic.get("inputs", {}).items():
            if not validate_syntax(condition):
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Invalid syntax for field '{key}': '{condition}'"
                )

        normalized_rules.append(
            {
                "id": str(rule.get("id") or f"sim-{rule.get('priority', 0)}"),
                "priority": rule.get("priority", 0),
                "logic": logic,
            }
        )

    result = DecisionEngine.evaluate_definition(
        {
            "hit_policy": table_definition.get("hit_policy", "FIRST_HIT"),
            "rules": normalized_rules,
        },
        request.context,
        detailed=request.detailed,
    )
    return EvaluationResponse(**result)
