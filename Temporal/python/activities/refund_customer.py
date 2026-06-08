import os

import httpx
from temporalio import activity

from models import OrderInput

PAYMENT_SERVICE_URL = os.getenv("PAYMENT_SERVICE_URL", "http://localhost:8003")


@activity.defn
async def refund_customer(order: OrderInput) -> None:
    idempotency_key = f"refund-{order.order_id}-{activity.info().workflow_run_id}"
    activity.logger.info(
        "refund_customer started for order_id=%s idempotency_key=%s",
        order.order_id,
        idempotency_key,
    )
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.post(
            f"{PAYMENT_SERVICE_URL}/refund",
            json={"order_id": order.order_id, "idempotency_key": idempotency_key},
        )
        response.raise_for_status()

    activity.logger.info("refund_customer completed for order_id=%s", order.order_id)
