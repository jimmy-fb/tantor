import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Text, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class KafkaUser(Base):
    __tablename__ = "kafka_users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    cluster_id: Mapped[str] = mapped_column(String(36), ForeignKey("clusters.id", ondelete="CASCADE"))
    username: Mapped[str] = mapped_column(String(255))
    mechanism: Mapped[str] = mapped_column(String(20))  # "SCRAM-SHA-256" or "SCRAM-SHA-512"
    encrypted_password: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
