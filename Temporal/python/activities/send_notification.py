import os

import httpx
from temporalio import activity

from models import OrderInput

NOTIFICATION_SERVICE_URL = os.getenv("NOTIFICATION_SERVICE_URL", "http://localhost:8005")


@activity.defn
async def send_notification(order: OrderInput, shipped_items: list[str]) -> None:
    activity.logger.info(
        "send_notification started for order_id=%s shipped_items=%s final_address=%s",
        order.order_id,
        shipped_items,
        order.address,
    )
    idempotency_key = f"notify-{order.order_id}-{activity.info().workflow_run_id}"
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.post(
            f"{NOTIFICATION_SERVICE_URL}/notify",
            json={
                "order_id": order.order_id,
                "address": order.address,
                "tracking_ids": shipped_items,
                "idempotency_key": idempotency_key,
            },
        )
        response.raise_for_status()

    activity.logger.info("send_notification completed for order_id=%s", order.order_id)
