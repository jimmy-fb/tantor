from pydantic import BaseModel


class KafkaVersionInfo(BaseModel):
    version: str
    scala_version: str
    filename: str
    size_mb: float
    available: bool
    release_date: str | None = None
    features: list[str] | None = None
    security_fixes: list[str] | None = None
    upgrade_notes: str | None = None


class ConnectPlugin(BaseModel):
    name: str
    filename: str
    size_mb: float
