import uuid
from typing import Optional

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()

_idempotency_store: dict[str, dict] = {}


class ShipRequest(BaseModel):
    order_id: str
    item_id: int
    description: str
    address: str
    idempotency_key: Optional[str] = None


@app.post("/ship")
async def ship(request: ShipRequest):
    if request.idempotency_key and request.idempotency_key in _idempotency_store:
        return _idempotency_store[request.idempotency_key]

    tracking_id = f"TRACK-{request.order_id}-{request.item_id}-{uuid.uuid4().hex[:8].upper()}"
    result = {
        "order_id": request.order_id,
        "item_id": request.item_id,
        "tracking_id": tracking_id,
        "status": "shipped",
        "address": request.address,
    }

    if request.idempotency_key:
        _idempotency_store[request.idempotency_key] = result

    return result


@app.get("/health")
async def health():
    return {"status": "ok"}
