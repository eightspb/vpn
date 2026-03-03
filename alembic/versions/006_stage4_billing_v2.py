"""Stage 4 billing v2: transaction state machine, webhook idempotency, promo/trial.

Revision ID: 006
Revises: 005
Create Date: 2026-03-03
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "006"
down_revision: Union[str, None] = "005"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE TYPE promocodekind AS ENUM ('fixed', 'percent')")
    op.execute("CREATE TYPE transactionstatus AS ENUM ('pending', 'completed', 'canceled', 'failed', 'refunded')")

    op.create_table(
        "promocodes",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("code", sa.String(length=64), nullable=False),
        sa.Column("kind", sa.Enum("fixed", "percent", name="promocodekind"), nullable=False),
        sa.Column("value", sa.Numeric(12, 2), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("usage_limit", sa.Integer(), nullable=True),
        sa.Column("used_count", sa.Integer(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("code"),
    )

    op.add_column("transactions", sa.Column("original_amount", sa.Numeric(12, 2), nullable=True))
    op.add_column("transactions", sa.Column("discount_amount", sa.Numeric(12, 2), nullable=True))
    op.add_column("transactions", sa.Column("idempotency_key", sa.String(length=128), nullable=True))
    op.add_column("transactions", sa.Column("is_trial", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column("transactions", sa.Column("promocode_id", sa.Integer(), nullable=True))
    op.create_foreign_key(
        "fk_transactions_promocode_id_promocodes",
        "transactions",
        "promocodes",
        ["promocode_id"],
        ["id"],
    )
    op.create_index("ix_transactions_idempotency_key", "transactions", ["idempotency_key"], unique=True)
    op.create_index(
        "uq_transactions_provider_external_id",
        "transactions",
        ["provider", "external_id"],
        unique=True,
        postgresql_where=sa.text("external_id IS NOT NULL"),
    )

    op.execute(
        """
        UPDATE transactions
        SET status = 'pending'
        WHERE status NOT IN ('pending', 'completed', 'canceled', 'failed', 'refunded')
        """
    )
    op.execute(
        """
        ALTER TABLE transactions
        ALTER COLUMN status TYPE transactionstatus
        USING status::transactionstatus
        """
    )
    op.alter_column("transactions", "status", server_default="pending")
    op.alter_column("transactions", "is_trial", server_default=None)

    op.create_table(
        "trial_activations",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("period_key", sa.String(length=16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ip_address", sa.String(length=64), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "period_key", name="uq_trial_user_period"),
    )

    op.create_table(
        "payment_webhook_events",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("provider", sa.String(length=64), nullable=False),
        sa.Column("event_id", sa.String(length=128), nullable=False),
        sa.Column("external_id", sa.String(length=255), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("transaction_id", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["transaction_id"], ["transactions.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("provider", "event_id", name="uq_payment_webhook_provider_event"),
    )


def downgrade() -> None:
    op.drop_table("payment_webhook_events")
    op.drop_table("trial_activations")
    op.drop_table("promocodes")

    op.alter_column("transactions", "status", type_=sa.String(length=32), postgresql_using="status::text")
    op.drop_index("uq_transactions_provider_external_id", table_name="transactions")
    op.drop_index("ix_transactions_idempotency_key", table_name="transactions")
    op.drop_constraint("fk_transactions_promocode_id_promocodes", "transactions", type_="foreignkey")
    op.drop_column("transactions", "promocode_id")
    op.drop_column("transactions", "is_trial")
    op.drop_column("transactions", "idempotency_key")
    op.drop_column("transactions", "discount_amount")
    op.drop_column("transactions", "original_amount")

    op.execute("DROP TYPE IF EXISTS transactionstatus")
    op.execute("DROP TYPE IF EXISTS promocodekind")
