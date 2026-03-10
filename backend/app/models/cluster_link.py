import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Text, Integer, Boolean
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class ClusterLink(Base):
    __tablename__ = "cluster_link"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    name: Mapped[str] = mapped_column(String(255))
    source_cluster_id: Mapped[str] = mapped_column(String(36), index=True)
    destination_cluster_id: Mapped[str] = mapped_column(String(36), index=True)
    topics_pattern: Mapped[str] = mapped_column(String(500), default=".*")  # Regex for topics to mirror
    sync_consumer_offsets: Mapped[bool] = mapped_column(Boolean, default=True)
    sync_topic_configs: Mapped[bool] = mapped_column(Boolean, default=True)
    state: Mapped[str] = mapped_column(String(20), default="created")  # created, running, stopped, error
    mm2_config: Mapped[str | None] = mapped_column(Text, nullable=True)  # Full MM2 properties
    deploy_host_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    mm2_port: Mapped[int] = mapped_column(Integer, default=8083)  # Connect REST port
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )
