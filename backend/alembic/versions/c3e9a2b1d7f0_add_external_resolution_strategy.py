"""add external resolution strategy

Revision ID: c3e9a2b1d7f0
Revises: b2c7d9e1f4a3
Create Date: 2026-02-09 00:00:00.000000
"""

from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = "c3e9a2b1d7f0"
down_revision: Union[str, None] = "b2c7d9e1f4a3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "ALTER TYPE resolution_strategy_enum "
        "ADD VALUE IF NOT EXISTS 'EXTERNAL'"
    )


def downgrade() -> None:
    # PostgreSQL enums cannot drop values safely; no-op downgrade.
    pass
