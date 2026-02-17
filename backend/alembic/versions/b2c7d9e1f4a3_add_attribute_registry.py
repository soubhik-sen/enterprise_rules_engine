"""add attribute registry table

Revision ID: b2c7d9e1f4a3
Revises: 9f1b2c3d4e5f
Create Date: 2026-02-08 00:00:01.000000
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


# revision identifiers, used by Alembic.
revision: str = "b2c7d9e1f4a3"
down_revision: Union[str, None] = "9f1b2c3d4e5f"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                FROM pg_type
                WHERE typname = 'resolution_strategy_enum'
            ) THEN
                CREATE TYPE resolution_strategy_enum AS ENUM ('DIRECT', 'ASSOCIATION');
            END IF;
        END$$;
        """
    )

    op.create_table(
        "attribute_registry",
        sa.Column("id", sa.UUID(), server_default=sa.text("uuidv7()"), nullable=False),
        sa.Column("target_object", sa.String(), nullable=False),
        sa.Column("attribute_name", sa.String(), nullable=False),
        sa.Column(
            "resolution_strategy",
            postgresql.ENUM(
                "DIRECT",
                "ASSOCIATION",
                name="resolution_strategy_enum",
                create_type=False,
            ),
            nullable=False,
        ),
        sa.Column(
            "path_logic",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "target_object",
            "attribute_name",
            name="uq_attribute_registry_target_attr",
        ),
    )
    op.create_index(
        "ix_attribute_registry_target_object",
        "attribute_registry",
        ["target_object"],
        unique=False,
    )
    op.create_index(
        "ix_attribute_registry_target_attr",
        "attribute_registry",
        ["target_object", "attribute_name"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_attribute_registry_target_attr", table_name="attribute_registry")
    op.drop_index("ix_attribute_registry_target_object", table_name="attribute_registry")
    op.drop_table("attribute_registry")
    sa.Enum(name="resolution_strategy_enum").drop(op.get_bind(), checkfirst=True)
