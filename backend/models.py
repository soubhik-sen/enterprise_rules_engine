import enum
import uuid
from sqlalchemy import (
    String,
    Integer,
    ForeignKey,
    Enum as SQAEnum,
    Index,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

class Base(DeclarativeBase):
    pass

class HitPolicy(str, enum.Enum):
    FIRST_HIT = "FIRST_HIT"
    COLLECT_ALL = "COLLECT_ALL"
    UNIQUE = "UNIQUE"


class ResolutionStrategy(str, enum.Enum):
    DIRECT = "DIRECT"
    ASSOCIATION = "ASSOCIATION"
    EXTERNAL = "EXTERNAL"


class DecisionTable(Base):
    __tablename__ = "decision_tables"

    # UUIDv7 as primary key, using Postgres 18+ server-side generation
    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), 
        primary_key=True, 
        server_default=text("uuidv7()")
    )
    slug: Mapped[str] = mapped_column(String, unique=True, index=True, nullable=False)
    object_type: Mapped[str] = mapped_column(
        String,
        nullable=False,
        server_default=text("''"),
        index=True,
    )
    description: Mapped[str] = mapped_column(String, nullable=False, server_default=text("''"))
    hit_policy: Mapped[HitPolicy] = mapped_column(
        SQAEnum(HitPolicy, name="hit_policy_enum"), 
        nullable=False, 
        default=HitPolicy.FIRST_HIT
    )
    
    rules: Mapped[list["DecisionRule"]] = relationship(
        "DecisionRule", 
        back_populates="table", 
        order_by="DecisionRule.priority", 
        cascade="all, delete-orphan"
    )

    # Schema Registry for Flutter UI generation and validation
    # Format: {"age": "number", "region": "string"}
    input_schema: Mapped[dict] = mapped_column(JSONB, nullable=False, server_default=text("'{}'::jsonb"))
    # Format: {"discount": "number"}
    output_schema: Mapped[dict] = mapped_column(JSONB, nullable=False, server_default=text("'{}'::jsonb"))

    def __repr__(self):
        return f"<DecisionTable(slug={self.slug})>"

class DecisionRule(Base):
    __tablename__ = "decision_rules"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), 
        primary_key=True, 
        server_default=text("uuidv7()")
    )
    table_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), 
        ForeignKey("decision_tables.id"), 
        nullable=False
    )
    priority: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    
    # logic block: {"inputs": {"age": "18..65"}, "outputs": {"status": "eligible"}}
    logic: Mapped[dict] = mapped_column(JSONB, nullable=False)

    table: Mapped["DecisionTable"] = relationship("DecisionTable", back_populates="rules")

    # GIN Index for logic JSONB using jsonb_path_ops
    __table_args__ = (
        Index(
            'ix_decision_rules_logic', 
            'logic', 
            postgresql_using='gin', 
            postgresql_ops={'logic': 'jsonb_path_ops'}
        ),
    )

    def __repr__(self):
        return f"<DecisionRule(id={self.id}, priority={self.priority})>"


class AttributeRegistry(Base):
    __tablename__ = "attribute_registry"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        server_default=text("uuidv7()"),
    )
    target_object: Mapped[str] = mapped_column(String, nullable=False, index=True)
    attribute_name: Mapped[str] = mapped_column(String, nullable=False)
    resolution_strategy: Mapped[ResolutionStrategy] = mapped_column(
        SQAEnum(ResolutionStrategy, name="resolution_strategy_enum"),
        nullable=False,
        default=ResolutionStrategy.DIRECT,
    )
    path_logic: Mapped[dict] = mapped_column(
        JSONB,
        nullable=False,
        server_default=text("'{}'::jsonb"),
    )

    __table_args__ = (
        UniqueConstraint(
            "target_object",
            "attribute_name",
            name="uq_attribute_registry_target_attr",
        ),
        Index(
            "ix_attribute_registry_target_attr",
            "target_object",
            "attribute_name",
        ),
    )

    def __repr__(self):
        return (
            "<AttributeRegistry("
            f"target_object={self.target_object}, "
            f"attribute_name={self.attribute_name}, "
            f"strategy={self.resolution_strategy}"
            ")>"
        )
