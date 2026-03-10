from pathlib import Path

from pydantic_settings import BaseSettings
from cryptography.fernet import Fernet

_BASE_DIR = Path(__file__).parent.parent


class Settings(BaseSettings):
    DATABASE_URL: str = "sqlite:///./tantor.db"
    FERNET_KEY: str = Fernet.generate_key().decode()
    CORS_ORIGINS: list[str] = ["http://localhost:5173", "http://localhost", "http://localhost:80"]

    # JWT Auth
    JWT_SECRET_KEY: str = Fernet.generate_key().decode()
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    REFRESH_TOKEN_EXPIRE_DAYS: int = 7

    # Logging
    LOGGING_LEVEL: str = "INFO"

    # Kafka defaults
    KAFKA_SCALA_VERSION: str = "2.13"
    KAFKA_INSTALL_DIR: str = "/opt/kafka"
    KAFKA_DATA_DIR: str = "/var/lib/kafka/data"
    KAFKA_LOG_DIR: str = "/var/log/kafka"

    # Airgapped repo paths
    REPO_BASE_DIR: str = str(_BASE_DIR / "repo")
    KAFKA_REPO_DIR: str = str(_BASE_DIR / "repo" / "kafka")
    KSQLDB_REPO_DIR: str = str(_BASE_DIR / "repo" / "ksqldb")
    KSQLDB_INSTALL_DIR: str = "/opt/ksqldb"
    CONNECT_PLUGINS_DIR: str = str(_BASE_DIR / "repo" / "connect-plugins")
    VERSION_CATALOG_PATH: str = str(_BASE_DIR / "repo" / "version_catalog.json")

    # Monitoring
    PROMETHEUS_PORT: int = 9090
    GRAFANA_PORT: int = 3000
    MONITORING_REPO_DIR: str = str(_BASE_DIR / "repo" / "monitoring")
    PROMETHEUS_VERSION: str = "2.51.0"
    NODE_EXPORTER_VERSION: str = "1.7.0"
    JMX_EXPORTER_VERSION: str = "0.20.0"

    # Ansible
    ANSIBLE_WORKING_DIR: str = str(_BASE_DIR / "ansible_work")

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()
