from typing import Optional

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()

sent_notifications: list[dict] = []
_idempotency_store: dict[str, dict] = {}


class NotifyRequest(BaseModel):
    order_id: str
    address: str
    tracking_ids: list[str]
    idempotency_key: Optional[str] = None


@app.post("/notify")
async def notify(request: NotifyRequest):
    if request.idempotency_key and request.idempotency_key in _idempotency_store:
        return _idempotency_store[request.idempotency_key]

    message = (
        f"Your order {request.order_id} has shipped to {request.address}! "
        f"Tracking: {', '.join(request.tracking_ids)}"
    )
    record = {
        "order_id": request.order_id,
        "address": request.address,
        "tracking_ids": request.tracking_ids,
        "message": message,
    }
    sent_notifications.append(record)
    print(f"[NOTIFICATION] {message}")

    result = {"status": "sent", "message": message}
    if request.idempotency_key:
        _idempotency_store[request.idempotency_key] = result

    return result


@app.get("/notifications")
async def list_notifications():
    return sent_notifications


@app.get("/health")
async def health():
    return {"status": "ok"}
