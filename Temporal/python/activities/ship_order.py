import os

import httpx
from temporalio import activity

from models import OrderInput, OrderItem

SHIPPING_SERVICE_URL = os.getenv("SHIPPING_SERVICE_URL", "http://localhost:8004")


@activity.defn
async def ship_order(order: OrderInput, item: OrderItem) -> str:
    activity.logger.info(
        "ship_order started for order_id=%s item_id=%s description=%s quantity=%s",
        order.order_id,
        item.item_id,
        item.description,
        item.quantity,
    )
    idempotency_key = f"ship-{order.order_id}-{item.item_id}-{activity.info().workflow_run_id}"
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            f"{SHIPPING_SERVICE_URL}/ship",
            json={
                "order_id": order.order_id,
                "item_id": item.item_id,
                "description": item.description,
                "address": order.address,
                "idempotency_key": idempotency_key,
            },
        )
        response.raise_for_status()
        result = response.json()

    activity.logger.info(
        "ship_order completed for order_id=%s item_id=%s tracking_id=%s",
        order.order_id,
        item.item_id,
        result["tracking_id"],
    )
    return result["tracking_id"]
