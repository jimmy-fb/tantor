import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Text, Integer
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class ConfigAuditLog(Base):
    __tablename__ = "config_audit_log"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    cluster_id: Mapped[str] = mapped_column(String(36), index=True)
    broker_id: Mapped[int] = mapped_column(Integer)  # Kafka broker.id
    config_key: Mapped[str] = mapped_column(String(255))
    old_value: Mapped[str | None] = mapped_column(Text, nullable=True)
    new_value: Mapped[str] = mapped_column(Text)
    changed_by: Mapped[str] = mapped_column(String(100))  # username
    change_type: Mapped[str] = mapped_column(String(20))  # "update", "rollback"
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
