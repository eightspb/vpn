"""Initial schema — users, plans, plan_offers, subscriptions, transactions, settings, audit_log, peers_devices.

Revision ID: 001
Revises:
Create Date: 2025-03-03

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("username", sa.String(255), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("role", sa.Enum("admin", "user", "support", name="roleenum"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_login", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_users_username", "users", ["username"], unique=True)

    op.create_table(
        "plans",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("kind", sa.Enum("UNLIMITED", "TRAFFIC", "DEVICES", name="plankind"), nullable=False),
        sa.Column("description", sa.String(1024), nullable=True),
        sa.Column("traffic_limit_mb", sa.Integer(), nullable=True),
        sa.Column("device_limit", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "plan_offers",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("plan_id", sa.Integer(), nullable=False),
        sa.Column("duration_days", sa.Integer(), nullable=False),
        sa.Column("price", sa.Numeric(12, 2), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["plan_id"], ["plans.id"]),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "subscriptions",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("plan_offer_id", sa.Integer(), nullable=False),
        sa.Column(
            "status",
            sa.Enum("active", "expired", "cancelled", "pending", name="subscriptionstatus"),
            nullable=False,
        ),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["plan_offer_id"], ["plan_offers.id"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "transactions",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("subscription_id", sa.Integer(), nullable=True),
        sa.Column("amount", sa.Numeric(12, 2), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("provider", sa.String(64), nullable=False),
        sa.Column("external_id", sa.String(255), nullable=True),
        sa.Column("status", sa.String(32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["subscription_id"], ["subscriptions.id"]),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "settings",
        sa.Column("key", sa.String(255), nullable=False),
        sa.Column("value", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("key"),
    )

    op.create_table(
        "audit_log",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=True),
        sa.Column("action", sa.String(128), nullable=False),
        sa.Column("target", sa.String(255), nullable=True),
        sa.Column("details", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ip_address", sa.String(64), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "peers_devices",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("ip", sa.String(45), nullable=False),
        sa.Column("type", sa.String(64), nullable=False),
        sa.Column("public_key", sa.Text(), nullable=True),
        sa.Column("private_key", sa.Text(), nullable=True),
        sa.Column("config_file", sa.String(512), nullable=True),
        sa.Column("status", sa.String(32), nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=True),
        sa.Column("subscription_id", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("source_id", sa.String(128), nullable=True),
        sa.ForeignKeyConstraint(["subscription_id"], ["subscriptions.id"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_peers_devices_ip", "peers_devices", ["ip"], unique=True)
    op.create_index("ix_peers_devices_source_id", "peers_devices", ["source_id"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_peers_devices_source_id", table_name="peers_devices")
    op.drop_index("ix_peers_devices_ip", table_name="peers_devices")
    op.drop_table("peers_devices")
    op.drop_table("audit_log")
    op.drop_table("settings")
    op.drop_table("transactions")
    op.drop_table("subscriptions")
    op.drop_table("plan_offers")
    op.drop_table("plans")
    op.drop_index("ix_users_username", table_name="users")
    op.drop_table("users")

    op.execute("DROP TYPE subscriptionstatus")
    op.execute("DROP TYPE plankind")
    op.execute("DROP TYPE roleenum")
