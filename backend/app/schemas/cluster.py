from datetime import datetime
from pydantic import BaseModel


class ServiceAssignment(BaseModel):
    host_id: str
    role: str  # broker, controller, broker_controller, zookeeper, ksqldb, kafka_connect
    node_id: int


class ClusterConfig(BaseModel):
    replication_factor: int = 3
    num_partitions: int = 3
    log_dirs: str = "/var/lib/kafka/data"
    listener_port: int = 9092
    controller_port: int = 9093
    heap_size: str = "1G"
    ksqldb_port: int = 8088
    connect_port: int = 8083
    connect_rest_port: int = 8083


class ClusterCreate(BaseModel):
    name: str
    kafka_version: str = "3.7.0"
    mode: str = "kraft"  # "kraft" or "zookeeper"
    services: list[ServiceAssignment]
    config: ClusterConfig = ClusterConfig()


class ClusterResponse(BaseModel):
    id: str
    name: str
    kafka_version: str
    mode: str
    state: str
    config_json: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


class ServiceResponse(BaseModel):
    id: str
    cluster_id: str
    host_id: str
    role: str
    node_id: int
    config_overrides: str | None
    status: str

    model_config = {"from_attributes": True}


class ClusterDetailResponse(BaseModel):
    cluster: ClusterResponse
    services: list[ServiceResponse]


class DeploymentTaskResponse(BaseModel):
    task_id: str
    cluster_id: str
    status: str
