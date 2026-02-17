from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from sqlalchemy import or_
from backend import models
from backend.schemas import TableCreate, RuleCreate
from backend.rule_parser import validate_syntax, validate_rule_against_schema
from fastapi import HTTPException, status
import uuid


def _supports_schema_fields(table_or_model) -> bool:
    return hasattr(table_or_model, "input_schema") and hasattr(table_or_model, "output_schema")


def _supports_description_field(table_or_model) -> bool:
    return hasattr(table_or_model, "description")


def _supports_object_type_field(table_or_model) -> bool:
    return hasattr(table_or_model, "object_type")


def _is_schema_enforced(table_or_model) -> bool:
    if not _supports_schema_fields(table_or_model):
        return False
    input_schema = getattr(table_or_model, "input_schema", {}) or {}
    output_schema = getattr(table_or_model, "output_schema", {}) or {}
    return bool(input_schema) or bool(output_schema)


def list_decision_tables(db: Session, search: str | None = None):
    query = db.query(models.DecisionTable)
    if search:
        needle = f"%{search}%"
        if _supports_description_field(models.DecisionTable):
            query = query.filter(
                or_(
                    models.DecisionTable.slug.ilike(needle),
                    models.DecisionTable.description.ilike(needle),
                )
            )
        else:
            query = query.filter(models.DecisionTable.slug.ilike(needle))
    return query.order_by(models.DecisionTable.slug.asc()).all()


def get_decision_table_by_slug(db: Session, slug: str):
    return db.query(models.DecisionTable).filter(models.DecisionTable.slug == slug).first()


def delete_decision_table(db: Session, table_id: uuid.UUID):
    table = db.query(models.DecisionTable).filter(models.DecisionTable.id == table_id).first()
    if not table:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Table not found")
    db.delete(table)
    db.commit()


def list_rules_for_table(db: Session, table_id: uuid.UUID):
    table = db.query(models.DecisionTable).filter(models.DecisionTable.id == table_id).first()
    if not table:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Table not found")
    return db.query(models.DecisionRule).filter(models.DecisionRule.table_id == table_id).order_by(models.DecisionRule.priority.asc()).all()


def create_decision_table(db: Session, table_schema: TableCreate):
    """Creates a new decision table with schemas."""
    kwargs = dict(
        slug=table_schema.slug,
        hit_policy=table_schema.hit_policy,
    )
    if _supports_description_field(models.DecisionTable):
        kwargs["description"] = table_schema.description
    if _supports_object_type_field(models.DecisionTable):
        kwargs["object_type"] = table_schema.object_type or ""
    if _supports_schema_fields(models.DecisionTable):
        kwargs["input_schema"] = table_schema.input_schema
        kwargs["output_schema"] = table_schema.output_schema

    db_table = models.DecisionTable(**kwargs)
    try:
        db.add(db_table)
        db.commit()
        db.refresh(db_table)
    except IntegrityError as e:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Table slug '{table_schema.slug}' already exists. "
                "Use a unique slug or load the existing table by slug."
            ),
        ) from e
    return db_table

def add_rule_to_table(db: Session, table_id: uuid.UUID, rule_schema: RuleCreate):
    """
    Adds a rule to a decision table with validation.
    Enterprise Requirement: Validation Hook for syntax and schema integrity.
    """
    # 1. Fetch table for schema validation
    table = db.query(models.DecisionTable).filter(models.DecisionTable.id == table_id).first()
    if not table:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Table not found")

    # 2. Schema Validation
    logic = rule_schema.logic.model_dump()

    if _is_schema_enforced(table):
        try:
            validate_rule_against_schema(logic, table.input_schema, table.output_schema)
        except ValueError as e:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    # 3. Syntax Validation
    inputs = logic.get("inputs", {})
    for key, condition in inputs.items():
        if not validate_syntax(condition):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid syntax for field '{key}': '{condition}'"
            )

    # 4. Persistence
    db_rule = models.DecisionRule(
        table_id=table_id,
        priority=rule_schema.priority,
        logic=logic
    )
    db.add(db_rule)
    db.commit()
    db.refresh(db_rule)
    return db_rule


def replace_rules_for_table(db: Session, table_id: uuid.UUID, rules: list[RuleCreate]):
    """
    Replaces all rules in a table using a validated rule set.
    """
    table = db.query(models.DecisionTable).filter(models.DecisionTable.id == table_id).first()
    if not table:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Table not found")

    validated_rules: list[tuple[int, dict]] = []
    for rule_schema in rules:
        logic = rule_schema.logic.model_dump()
        if _is_schema_enforced(table):
            try:
                validate_rule_against_schema(logic, table.input_schema, table.output_schema)
            except ValueError as e:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

        inputs = logic.get("inputs", {})
        for key, condition in inputs.items():
            if not validate_syntax(condition):
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Invalid syntax for field '{key}': '{condition}'"
                )

        validated_rules.append((rule_schema.priority, logic))

    db.query(models.DecisionRule).filter(models.DecisionRule.table_id == table_id).delete(synchronize_session=False)

    created_rules = []
    for priority, logic in sorted(validated_rules, key=lambda item: item[0]):
        db_rule = models.DecisionRule(
            table_id=table_id,
            priority=priority,
            logic=logic,
        )
        db.add(db_rule)
        created_rules.append(db_rule)

    db.commit()
    for rule in created_rules:
        db.refresh(rule)
    return created_rules

def update_decision_table(db: Session, table_id: uuid.UUID, table_schema: TableCreate):
    """Updates a decision table, preventing schema changes that orphan rules."""
    table = db.query(models.DecisionTable).filter(models.DecisionTable.id == table_id).first()
    if not table:
        raise HTTPException(status_code=404, detail="Table not found")

    if _is_schema_enforced(table):
        # Schema Evolution Check:
        # If the user is removing columns from input/output schema,
        # ensure existing rules do not reference them.
        for rule in table.rules:
            inputs = rule.logic.get("inputs", {})
            for key in inputs:
                if key not in table_schema.input_schema:
                    raise HTTPException(
                        status_code=status.HTTP_400_BAD_REQUEST,
                        detail=f"Cannot remove field '{key}' from schema: Rule '{rule.id}' depends on it."
                    )
            outputs = rule.logic.get("outputs", {})
            for key in outputs:
                if key not in table_schema.output_schema:
                    raise HTTPException(
                        status_code=status.HTTP_400_BAD_REQUEST,
                        detail=f"Cannot remove output field '{key}' from schema: Rule '{rule.id}' depends on it."
                    )

    table.slug = table_schema.slug
    if _supports_description_field(table):
        table.description = table_schema.description
    if _supports_object_type_field(table):
        table.object_type = table_schema.object_type or ""
    table.hit_policy = table_schema.hit_policy
    if _supports_schema_fields(table):
        table.input_schema = table_schema.input_schema
        table.output_schema = table_schema.output_schema
    
    try:
        db.commit()
        db.refresh(table)
    except IntegrityError as e:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Table slug '{table_schema.slug}' is already in use by another table."
            ),
        ) from e
    return table
