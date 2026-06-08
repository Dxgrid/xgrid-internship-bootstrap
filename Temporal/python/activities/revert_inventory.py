import os

import httpx
from temporalio import activity

from models import OrderInput

INVENTORY_SERVICE_URL = os.getenv("INVENTORY_SERVICE_URL", "http://localhost:8002")


@activity.defn
async def revert_inventory(order: OrderInput) -> None:
    idempotency_key = f"revert-inventory-{order.order_id}-{activity.info().workflow_run_id}"
    activity.logger.info(
        "revert_inventory started for order_id=%s idempotency_key=%s",
        order.order_id,
        idempotency_key,
    )
    items_payload = [{"item_id": item.item_id, "quantity": item.quantity} for item in order.items]

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.post(
            f"{INVENTORY_SERVICE_URL}/revert",
            json={"order_id": order.order_id, "items": items_payload},
        )
        response.raise_for_status()

    activity.logger.info("revert_inventory completed for order_id=%s", order.order_id)
