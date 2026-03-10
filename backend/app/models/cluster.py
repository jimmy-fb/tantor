import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class Cluster(Base):
    __tablename__ = "clusters"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    name: Mapped[str] = mapped_column(String(255))
    kafka_version: Mapped[str] = mapped_column(String(20))
    mode: Mapped[str] = mapped_column(String(20))  # "kraft" or "zookeeper"
    state: Mapped[str] = mapped_column(String(20), default="configured")  # configured, deploying, running, stopped, error
    config_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    cluster_uuid: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
