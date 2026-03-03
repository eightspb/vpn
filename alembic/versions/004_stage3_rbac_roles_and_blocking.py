"""Stage 3 RBAC update: roles + users.is_blocked.

Revision ID: 004
Revises: 003
Create Date: 2026-03-03
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "004"
down_revision: Union[str, None] = "003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    if bind.dialect.name == "postgresql":
        for role_value in ("owner", "operator", "readonly"):
            op.execute(sa.text(f"ALTER TYPE roleenum ADD VALUE IF NOT EXISTS '{role_value}'"))

    op.add_column(
        "users",
        sa.Column("is_blocked", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.alter_column("users", "is_blocked", server_default=None)


def downgrade() -> None:
    op.drop_column("users", "is_blocked")
