import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Text, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    cluster_id: Mapped[str] = mapped_column(String(36), ForeignKey("clusters.id", ondelete="CASCADE"))
    action: Mapped[str] = mapped_column(String(50))  # user_created, user_deleted, user_password_rotated, acl_created, acl_deleted
    resource_type: Mapped[str] = mapped_column(String(30))  # "user" or "acl"
    resource_name: Mapped[str] = mapped_column(String(255))
    details: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON details
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
