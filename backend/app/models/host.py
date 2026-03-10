import uuid
from datetime import datetime, timezone

from sqlalchemy import String, Integer, DateTime, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class Host(Base):
    __tablename__ = "hosts"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    hostname: Mapped[str] = mapped_column(String(255))
    ip_address: Mapped[str] = mapped_column(String(255))
    ssh_port: Mapped[int] = mapped_column(Integer, default=22)
    username: Mapped[str] = mapped_column(String(255))
    auth_type: Mapped[str] = mapped_column(String(20))  # "password" or "key"
    encrypted_credential: Mapped[str] = mapped_column(Text)
    os_info: Mapped[str | None] = mapped_column(String(255), nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="unknown")  # online, offline, unknown
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
