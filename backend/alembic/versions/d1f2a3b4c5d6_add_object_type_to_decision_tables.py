"""add object_type to decision_tables

Revision ID: d1f2a3b4c5d6
Revises: c3e9a2b1d7f0
Create Date: 2026-02-11 00:00:00.000000
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = "d1f2a3b4c5d6"
down_revision = "c3e9a2b1d7f0"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "decision_tables",
        sa.Column("object_type", sa.String(), nullable=False, server_default=""),
    )
    op.create_index(
        "ix_decision_tables_object_type",
        "decision_tables",
        ["object_type"],
        unique=False,
    )
    op.execute(
        "UPDATE decision_tables SET object_type = 'PURCHASE_ORDER' "
        "WHERE slug = 'purchase_order_default_profile_v1' AND (object_type = '' OR object_type IS NULL)"
    )
    op.execute(
        "UPDATE decision_tables SET object_type = 'SHIPMENT' "
        "WHERE slug = 'shipment_default_profile_v1' AND (object_type = '' OR object_type IS NULL)"
    )


def downgrade() -> None:
    op.drop_index("ix_decision_tables_object_type", table_name="decision_tables")
    op.drop_column("decision_tables", "object_type")
