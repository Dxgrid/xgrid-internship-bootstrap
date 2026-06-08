from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()

# In-memory stock — seeded with demo items
inventory: dict[int, int] = {1001: 50, 1002: 30, 1003: 10}
reservations: dict[str, list[dict]] = {}


class InventoryRequest(BaseModel):
    order_id: str
    items: list[dict]  # [{item_id: int, quantity: int}]


@app.post("/reserve")
async def reserve(request: InventoryRequest):
    for item in request.items:
        item_id = item["item_id"]
        qty = item["quantity"]
        if inventory.get(item_id, 0) < qty:
            raise HTTPException(
                status_code=409,
                detail=f"Insufficient stock for item {item_id} (available: {inventory.get(item_id, 0)}, requested: {qty})",
            )

    for item in request.items:
        inventory[item["item_id"]] -= item["quantity"]

    reservations[request.order_id] = request.items
    return {"order_id": request.order_id, "status": "reserved"}


@app.post("/revert")
async def revert(request: InventoryRequest):
    for item in request.items:
        inventory[item["item_id"]] = inventory.get(item["item_id"], 0) + item["quantity"]
    reservations.pop(request.order_id, None)
    return {"order_id": request.order_id, "status": "reverted"}


@app.get("/health")
async def health():
    return {"status": "ok", "inventory": inventory}
