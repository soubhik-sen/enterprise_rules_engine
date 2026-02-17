"""add description column to decision_tables

Revision ID: 9f1b2c3d4e5f
Revises: 498dcfeac13b
Create Date: 2026-02-08 00:00:00.000000
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "9f1b2c3d4e5f"
down_revision: Union[str, None] = "498dcfeac13b"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "decision_tables",
        sa.Column("description", sa.String(), server_default="", nullable=False),
    )
    op.alter_column("decision_tables", "description", server_default=None)


def downgrade() -> None:
    op.drop_column("decision_tables", "description")

