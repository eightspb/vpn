"""Seed default plans — UNLIMITED, TRAFFIC, DEVICES с offers 30/90/365.

Revision ID: 002
Revises: 001
Create Date: 2025-03-03

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "002"
down_revision: Union[str, None] = "001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        sa.text(
            """
            INSERT INTO plans (name, kind, description, created_at)
            VALUES
                ('Безлимит', 'UNLIMITED', 'Без ограничений по трафику и устройствам', NOW()),
                ('По трафику', 'TRAFFIC', 'Ограничение по трафику (ГБ)', NOW()),
                ('По устройствам', 'DEVICES', 'Ограничение по количеству устройств', NOW())
            """
        )
    )

    # plan_id: 1=UNLIMITED, 2=TRAFFIC, 3=DEVICES
    op.execute(
        sa.text(
            """
            INSERT INTO plan_offers (plan_id, duration_days, price, currency, created_at)
            VALUES
                (1, 30, 199, 'RUB', NOW()),
                (1, 90, 499, 'RUB', NOW()),
                (1, 365, 1499, 'RUB', NOW()),
                (2, 30, 99, 'RUB', NOW()),
                (2, 90, 249, 'RUB', NOW()),
                (2, 365, 799, 'RUB', NOW()),
                (3, 30, 149, 'RUB', NOW()),
                (3, 90, 349, 'RUB', NOW()),
                (3, 365, 999, 'RUB', NOW())
            """
        )
    )


def downgrade() -> None:
    op.execute(sa.text("DELETE FROM plan_offers"))
    op.execute(sa.text("DELETE FROM plans"))
