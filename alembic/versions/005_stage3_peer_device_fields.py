"""Stage 3 peer-management columns for peers_devices.

Revision ID: 005
Revises: 004
Create Date: 2026-03-03
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "005"
down_revision: Union[str, None] = "004"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("peers_devices", sa.Column("mode", sa.String(length=16), nullable=False, server_default="full"))
    op.add_column("peers_devices", sa.Column("group_name", sa.String(length=128), nullable=True))
    op.add_column("peers_devices", sa.Column("expiry_date", sa.Date(), nullable=True))
    op.add_column("peers_devices", sa.Column("traffic_limit_mb", sa.Integer(), nullable=True))
    op.add_column("peers_devices", sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("peers_devices", sa.Column("config_version", sa.Integer(), nullable=False, server_default="1"))
    op.add_column("peers_devices", sa.Column("config_download_count", sa.Integer(), nullable=False, server_default="0"))
    op.add_column("peers_devices", sa.Column("last_config_downloaded_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("peers_devices", sa.Column("last_downloaded_config_version", sa.Integer(), nullable=True))

    op.execute(sa.text("UPDATE peers_devices SET mode = 'full' WHERE mode IS NULL"))
    op.execute(sa.text("UPDATE peers_devices SET config_version = 1 WHERE config_version IS NULL"))
    op.execute(sa.text("UPDATE peers_devices SET config_download_count = 0 WHERE config_download_count IS NULL"))
    op.execute(sa.text("UPDATE peers_devices SET updated_at = created_at WHERE updated_at IS NULL"))

    op.alter_column("peers_devices", "mode", server_default=None)
    op.alter_column("peers_devices", "config_version", server_default=None)
    op.alter_column("peers_devices", "config_download_count", server_default=None)


def downgrade() -> None:
    op.drop_column("peers_devices", "last_downloaded_config_version")
    op.drop_column("peers_devices", "last_config_downloaded_at")
    op.drop_column("peers_devices", "config_download_count")
    op.drop_column("peers_devices", "config_version")
    op.drop_column("peers_devices", "updated_at")
    op.drop_column("peers_devices", "traffic_limit_mb")
    op.drop_column("peers_devices", "expiry_date")
    op.drop_column("peers_devices", "group_name")
    op.drop_column("peers_devices", "mode")
