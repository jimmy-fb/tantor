import uuid

from sqlalchemy import String, Integer, Text, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class Service(Base):
    __tablename__ = "services"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    cluster_id: Mapped[str] = mapped_column(String(36), ForeignKey("clusters.id", ondelete="CASCADE"))
    host_id: Mapped[str] = mapped_column(String(36), ForeignKey("hosts.id", ondelete="CASCADE"))
    role: Mapped[str] = mapped_column(String(30))  # broker, controller, broker_controller, zookeeper, ksqldb, kafka_connect
    node_id: Mapped[int] = mapped_column(Integer)
    config_overrides: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="pending")  # pending, installing, running, stopped, error
