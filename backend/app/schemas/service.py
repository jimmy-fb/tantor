from pydantic import BaseModel


class ServiceStatusUpdate(BaseModel):
    status: str


class ServiceActionResponse(BaseModel):
    service_id: str
    action: str
    success: bool
    message: str
