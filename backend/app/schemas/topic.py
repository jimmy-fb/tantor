from pydantic import BaseModel


class TopicCreate(BaseModel):
    name: str
    partitions: int = 3
    replication_factor: int = 1
    config: dict[str, str] | None = None


class TopicInfo(BaseModel):
    name: str
    partitions: int
    replication_factor: int
    configs: dict[str, str] | None = None


class TopicDetail(TopicInfo):
    partition_details: list[dict]


class ConsumerGroupInfo(BaseModel):
    group_id: str
    state: str
    members: int
    topics: list[str]


class ConsumerGroupDetail(ConsumerGroupInfo):
    offsets: list[dict]


class ProduceRequest(BaseModel):
    topic: str
    key: str | None = None
    value: str
    headers: dict[str, str] | None = None


class ProduceResponse(BaseModel):
    success: bool
    message: str


class ConsumeRequest(BaseModel):
    topic: str
    from_beginning: bool = False
    max_messages: int = 10
    group_id: str | None = None
    timeout_ms: int = 10000


class ConsumedMessage(BaseModel):
    timestamp: int | str | None = None
    partition: int | None = None
    offset: int | None = None
    key: str | None = None
    value: str
    headers: str | None = None


class ConsumeResponse(BaseModel):
    messages: list[ConsumedMessage]
    count: int


class ValidationStep(BaseModel):
    step: str
    success: bool
    message: str
    data: list | None = None


class ValidationResult(BaseModel):
    steps: list[ValidationStep]
    success: bool
