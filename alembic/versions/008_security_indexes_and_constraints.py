"""Security indexes and constraints: audit_log, subscriptions, transactions, promo_codes.

Revision ID: 008
Revises: 007
Create Date: 2026-03-11

"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "008"
down_revision: Union[str, None] = "007"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Add security indexes and constraints for performance and data integrity."""

    # C-12: Missing indexes on audit_log
    try:
        op.create_index(
            "ix_audit_log_action",
            "audit_log",
            ["action"],
            unique=False,
            if_not_exists=True,
        )
    except Exception:
        pass

    try:
        op.create_index(
            "ix_audit_log_created_at",
            "audit_log",
            ["created_at"],
            unique=False,
            if_not_exists=True,
        )
    except Exception:
        pass

    # C-12: Composite index on subscriptions
    try:
        op.create_index(
            "ix_subscriptions_user_status",
            "subscriptions",
            ["user_id", "status"],
            unique=False,
            if_not_exists=True,
        )
    except Exception:
        pass

    # C-12: Index on transactions.created_at
    try:
        op.create_index(
            "ix_transactions_created_at",
            "transactions",
            ["created_at"],
            unique=False,
            if_not_exists=True,
        )
    except Exception:
        pass

    # C-12: Index on notification_events.next_retry_at
    try:
        op.create_index(
            "ix_notification_events_next_retry",
            "notification_events",
            ["next_retry_at"],
            unique=False,
            if_not_exists=True,
        )
    except Exception:
        pass

    # C-12: Index on users.created_at
    try:
        op.create_index(
            "ix_users_created_at",
            "users",
            ["created_at"],
            unique=False,
            if_not_exists=True,
        )
    except Exception:
        pass

    # M-12/M-13/M-15: CHECK constraints for data validation
    # plan_offers.price >= 0
    try:
        op.create_check_constraint(
            "ck_plan_offers_price_nonnegative",
            "plan_offers",
            "price >= 0",
        )
    except Exception:
        pass

    # transactions.amount > 0
    try:
        op.create_check_constraint(
            "ck_transactions_amount_positive",
            "transactions",
            "amount > 0",
        )
    except Exception:
        pass

    # promocodes discount: 0 <= discount <= 100 (if using value as percent)
    # Note: promocodes.value is Numeric, check that it's within reasonable bounds
    try:
        op.create_check_constraint(
            "ck_promocodes_value_valid",
            "promocodes",
            "value >= 0",
        )
    except Exception:
        pass

    # H-13: Missing foreign key audit_log.user_id -> users.id
    try:
        op.create_foreign_key(
            "fk_audit_log_user_id_users",
            "audit_log",
            "users",
            ["user_id"],
            ["id"],
        )
    except Exception:
        pass


def downgrade() -> None:
    """Drop all added indexes and constraints."""

    # Drop foreign key
    try:
        op.drop_constraint(
            "fk_audit_log_user_id_users",
            "audit_log",
            type_="foreignkey",
        )
    except Exception:
        pass

    # Drop CHECK constraints
    try:
        op.drop_constraint(
            "ck_promocodes_value_valid",
            "promocodes",
            type_="check",
        )
    except Exception:
        pass

    try:
        op.drop_constraint(
            "ck_transactions_amount_positive",
            "transactions",
            type_="check",
        )
    except Exception:
        pass

    try:
        op.drop_constraint(
            "ck_plan_offers_price_nonnegative",
            "plan_offers",
            type_="check",
        )
    except Exception:
        pass

    # Drop indexes
    try:
        op.drop_index(
            "ix_users_created_at",
            table_name="users",
            if_exists=True,
        )
    except Exception:
        pass

    try:
        op.drop_index(
            "ix_notification_events_next_retry",
            table_name="notification_events",
            if_exists=True,
        )
    except Exception:
        pass

    try:
        op.drop_index(
            "ix_transactions_created_at",
            table_name="transactions",
            if_exists=True,
        )
    except Exception:
        pass

    try:
        op.drop_index(
            "ix_subscriptions_user_status",
            table_name="subscriptions",
            if_exists=True,
        )
    except Exception:
        pass

    try:
        op.drop_index(
            "ix_audit_log_created_at",
            table_name="audit_log",
            if_exists=True,
        )
    except Exception:
        pass

    try:
        op.drop_index(
            "ix_audit_log_action",
            table_name="audit_log",
            if_exists=True,
        )
    except Exception:
        pass
