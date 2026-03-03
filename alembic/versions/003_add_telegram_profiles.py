"""Add telegram_profiles table for bot MVP.

Revision ID: 003
Revises: 002
Create Date: 2026-03-03

"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "003"
down_revision: Union[str, None] = "002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "telegram_profiles",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("telegram_id", sa.BigInteger(), nullable=False),
        sa.Column("chat_id", sa.BigInteger(), nullable=False),
        sa.Column("telegram_username", sa.String(length=255), nullable=True),
        sa.Column("first_name", sa.String(length=255), nullable=True),
        sa.Column("last_name", sa.String(length=255), nullable=True),
        sa.Column("fsm_state", sa.String(length=64), nullable=False),
        sa.Column("fsm_payload", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("telegram_id"),
        sa.UniqueConstraint("user_id"),
    )
    op.create_index(
        "ix_telegram_profiles_telegram_id", "telegram_profiles", ["telegram_id"], unique=True
    )
    op.create_index("ix_telegram_profiles_chat_id", "telegram_profiles", ["chat_id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_telegram_profiles_chat_id", table_name="telegram_profiles")
    op.drop_index("ix_telegram_profiles_telegram_id", table_name="telegram_profiles")
    op.drop_table("telegram_profiles")
