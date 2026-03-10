from pydantic import BaseModel


class ConnectorCreate(BaseModel):
    name: str
    config: dict[str, str]


class ConnectorStatus(BaseModel):
    name: str
    connector: dict
    tasks: list[dict]
    type: str


class ConnectorPlugin(BaseModel):
    class_name: str
    type: str
    version: str | None = None
