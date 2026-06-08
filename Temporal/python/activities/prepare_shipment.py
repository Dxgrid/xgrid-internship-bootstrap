import os

import httpx
from temporalio import activity
from temporalio.exceptions import ApplicationError

from models import OrderInput

INVENTORY_SERVICE_URL = os.getenv("INVENTORY_SERVICE_URL", "http://localhost:8002")


@activity.defn
async def prepare_shipment(order: OrderInput) -> None:
    activity.logger.info(
        "prepare_shipment started for order_id=%s address=%s",
        order.order_id,
        order.address,
    )
    items_payload = [{"item_id": item.item_id, "quantity": item.quantity} for item in order.items]

    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            response = await client.post(
                f"{INVENTORY_SERVICE_URL}/reserve",
                json={"order_id": order.order_id, "items": items_payload},
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 409:
                raise ApplicationError(
                    f"Insufficient stock for order {order.order_id}: {e.response.text}",
                    non_retryable=True,
                    type="InsufficientStock",
                )
            raise  # 5xx → retryable

    activity.logger.info("prepare_shipment completed for order_id=%s", order.order_id)
