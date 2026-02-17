import re
from pydantic import BaseModel, Field, field_validator, model_validator
from typing import Any, Dict, List
from backend.models import HitPolicy

_SLUG_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")
_ALLOWED_SCHEMA_TYPES = {"string", "number", "decimal", "boolean"}


def _normalize_schema_map(schema: Dict[str, str]) -> Dict[str, str]:
    normalized: Dict[str, str] = {}
    for raw_key, raw_type in schema.items():
        key = str(raw_key).strip()
        if not key:
            raise ValueError("Schema field names cannot be empty.")
        data_type = str(raw_type).strip().lower()
        if data_type not in _ALLOWED_SCHEMA_TYPES:
            allowed = ", ".join(sorted(_ALLOWED_SCHEMA_TYPES))
            raise ValueError(
                f"Unsupported schema type '{raw_type}' for field '{key}'. Allowed types: {allowed}."
            )
        normalized[key] = data_type
    return normalized


class RuleLogic(BaseModel):
    inputs: Dict[str, Any] = Field(default_factory=dict)
    outputs: Dict[str, Any] = Field(default_factory=dict)


# Evaluation Models
class EvaluationRequest(BaseModel):
    table_slug: str = Field(..., description="Unique slug of the decision table to evaluate")
    context: Dict[str, Any] = Field(default_factory=dict, description="Key-value pairs representing the input context")
    detailed: bool = Field(
        default=False,
        description="When true, include per-rule evaluation trace details.",
    )
    object_id: str | None = Field(
        default=None,
        description="Optional business object id used by resolver to hydrate context.",
    )
    object_type: str | None = Field(
        default=None,
        description="Optional object type; defaults to table slug upper-case if omitted.",
    )


class SimulationRule(BaseModel):
    id: str | None = None
    priority: int = Field(default=0)
    logic: RuleLogic


class TableDefinition(BaseModel):
    slug: str
    hit_policy: HitPolicy = Field(default=HitPolicy.FIRST_HIT)
    input_schema: Dict[str, str] = Field(default_factory=dict)
    output_schema: Dict[str, str] = Field(default_factory=dict)
    rules: List[SimulationRule] = Field(default_factory=list)

    @field_validator("slug")
    @classmethod
    def validate_slug(cls, value: str) -> str:
        slug = value.strip()
        if not slug:
            raise ValueError("Table slug is required.")
        if not _SLUG_PATTERN.fullmatch(slug):
            raise ValueError(
                "Table slug can use letters, numbers, underscore, and hyphen."
            )
        return slug

    @field_validator("input_schema", "output_schema")
    @classmethod
    def validate_schema_types(cls, value: Dict[str, str]) -> Dict[str, str]:
        return _normalize_schema_map(value)

    @model_validator(mode="after")
    def validate_schema_overlap(self):
        overlap = set(self.input_schema).intersection(self.output_schema)
        if overlap:
            raise ValueError(
                f"Input and output field names must be distinct. Overlap: {sorted(overlap)}"
            )
        return self


class SimulationRequest(BaseModel):
    context: Dict[str, Any]
    table_definition: TableDefinition
    detailed: bool = Field(
        default=False,
        description="When true, include per-rule evaluation trace details.",
    )


class EvaluationResponse(BaseModel):
    result: Dict[str, Any] = Field(..., description="The output produced by the rule engine")
    hit_policy: HitPolicy = Field(..., description="The hit policy applied during evaluation")
    rule_id: str | None = Field(None, description="The primary matching rule ID (if applicable)")
    matched_rule_ids: List[str] = Field(default_factory=list, description="All matched rule IDs by priority")
    error: str | None = Field(None, description="Evaluation error details (if applicable)")
    trace: List[Dict[str, Any]] = Field(
        default_factory=list,
        description="Optional per-rule evaluation trace when detailed mode is enabled.",
    )


# Management Models
class TableCreate(BaseModel):
    slug: str = Field(..., description="Unique slug for the decision table")
    object_type: str | None = Field(
        default="",
        description="Optional object type for resolver metadata (e.g. PURCHASE_ORDER).",
    )
    description: str = Field(default="", description="Short table description")
    hit_policy: HitPolicy = Field(default=HitPolicy.FIRST_HIT)
    input_schema: Dict[str, str] = Field(default_factory=dict, description="Schema for inputs: {'name': 'type'}")
    output_schema: Dict[str, str] = Field(default_factory=dict, description="Schema for outputs: {'name': 'type'}")

    @field_validator("slug")
    @classmethod
    def validate_slug(cls, value: str) -> str:
        slug = value.strip()
        if not slug:
            raise ValueError("Table slug is required.")
        if not _SLUG_PATTERN.fullmatch(slug):
            raise ValueError(
                "Table slug can use letters, numbers, underscore, and hyphen."
            )
        return slug

    @field_validator("description")
    @classmethod
    def validate_description(cls, value: str) -> str:
        text = value.strip()
        if len(text) > 240:
            raise ValueError("Description must be 240 characters or less.")
        return text

    @field_validator("input_schema", "output_schema")
    @classmethod
    def validate_schema_types(cls, value: Dict[str, str]) -> Dict[str, str]:
        return _normalize_schema_map(value)

    @field_validator("object_type")
    @classmethod
    def validate_object_type(cls, value: str | None) -> str:
        if value is None:
            return ""
        text = value.strip()
        if not text:
            return ""
        if not _SLUG_PATTERN.fullmatch(text):
            raise ValueError(
                "Object type can use letters, numbers, underscore, and hyphen."
            )
        return text

    @model_validator(mode="after")
    def validate_schema_overlap(self):
        overlap = set(self.input_schema).intersection(self.output_schema)
        if overlap:
            raise ValueError(
                f"Input and output field names must be distinct. Overlap: {sorted(overlap)}"
            )
        return self


class TableSchemaResponse(BaseModel):
    input_schema: Dict[str, str]
    output_schema: Dict[str, str]


class TableResponse(BaseModel):
    id: str
    slug: str
    object_type: str = ""
    description: str = ""
    hit_policy: HitPolicy
    input_schema: Dict[str, str]
    output_schema: Dict[str, str]


class RuleCreate(BaseModel):
    priority: int = Field(default=0)
    logic: RuleLogic = Field(..., description="The rule logic containing inputs and outputs")


class RuleResponse(BaseModel):
    id: str
    table_id: str
    priority: int
    logic: RuleLogic


class RuleSaveRequest(BaseModel):
    local_id: str | None = Field(default=None, description="Frontend local rule id")
    priority: int = Field(default=0)
    logic: RuleLogic = Field(..., description="The rule logic containing inputs and outputs")


class TableSaveRequest(BaseModel):
    table_id: str | None = Field(default=None, description="Existing table UUID to update")
    table: TableCreate
    rules: List[RuleSaveRequest] = Field(default_factory=list)


class RuleSaveResponse(BaseModel):
    id: str
    table_id: str
    local_id: str | None = None
    priority: int
    logic: RuleLogic


class TableSaveResponse(BaseModel):
    table: TableResponse
    rules: List[RuleSaveResponse] = Field(default_factory=list)


class RuleValidationRequest(BaseModel):
    table: TableCreate
    rules: List[RuleSaveRequest] = Field(default_factory=list)


class RuleValidationIssue(BaseModel):
    row: int
    local_id: str | None = None
    field: str | None = None
    message: str


class RuleValidationResponse(BaseModel):
    total_rules: int
    error_count: int
    errors: List[RuleValidationIssue] = Field(default_factory=list)


class AttributeMetadataResponse(BaseModel):
    target_object: str
    attribute_name: str
    resolution_strategy: str
    path_logic: Dict[str, Any]
