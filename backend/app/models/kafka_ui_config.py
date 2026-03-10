import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Text, Integer, Boolean
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class KafkaUIConfig(Base):
    __tablename__ = "kafka_ui_config"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    cluster_id: Mapped[str] = mapped_column(String(36), index=True, unique=True)
    port: Mapped[int] = mapped_column(Integer, default=8080)
    config_yaml: Mapped[str] = mapped_column(Text, default="")
    is_deployed: Mapped[bool] = mapped_column(Boolean, default=False)
    is_running: Mapped[bool] = mapped_column(Boolean, default=False)
    deploy_host_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )
