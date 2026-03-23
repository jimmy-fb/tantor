import uuid

from sqlalchemy import String, Boolean, Integer
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class LdapConfig(Base):
    __tablename__ = "ldap_configs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    server_url: Mapped[str] = mapped_column(String(500), nullable=True)  # ldap://ad.company.com:389
    use_ssl: Mapped[bool] = mapped_column(Boolean, default=False)
    bind_dn: Mapped[str] = mapped_column(String(500), nullable=True)  # cn=admin,dc=example,dc=com
    encrypted_bind_password: Mapped[str] = mapped_column(String(1000), nullable=True)
    user_search_base: Mapped[str] = mapped_column(String(500), nullable=True)  # ou=users,dc=example,dc=com
    user_search_filter: Mapped[str] = mapped_column(String(500), default="(sAMAccountName={username})")
    group_search_base: Mapped[str | None] = mapped_column(String(500), nullable=True)
    admin_group_dn: Mapped[str | None] = mapped_column(String(500), nullable=True)  # members get admin role
    monitor_group_dn: Mapped[str | None] = mapped_column(String(500), nullable=True)  # members get monitor role
    default_role: Mapped[str] = mapped_column(String(20), default="monitor")
    connection_timeout: Mapped[int] = mapped_column(Integer, default=10)
