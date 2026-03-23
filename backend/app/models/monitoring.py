import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, Boolean, Integer
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class MonitoringConfig(Base):
    __tablename__ = "monitoring_config"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    cluster_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    monitoring_host_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    deployed: Mapped[bool] = mapped_column(Boolean, default=False)
    prometheus_installed: Mapped[bool] = mapped_column(Boolean, default=False)
    grafana_installed: Mapped[bool] = mapped_column(Boolean, default=False)
    prometheus_port: Mapped[int] = mapped_column(Integer, default=9090)
    grafana_port: Mapped[int] = mapped_column(Integer, default=3000)
    grafana_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    prometheus_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )
