import os

import httpx
from temporalio import activity
from temporalio.exceptions import ApplicationError

from models import OrderInput

FRAUD_SERVICE_URL = os.getenv("FRAUD_SERVICE_URL", "http://localhost:8001")


@activity.defn
async def check_fraud(order: OrderInput) -> None:
    activity.logger.info(
        "check_fraud started for order_id=%s address=%s item_count=%s",
        order.order_id,
        order.address,
        len(order.items),
    )
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            response = await client.post(
                f"{FRAUD_SERVICE_URL}/check",
                json={"order_id": order.order_id, "item_count": len(order.items)},
            )
            response.raise_for_status()
            result = response.json()
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 400:
                raise ApplicationError(
                    f"Fraud check bad request: {e.response.text}",
                    non_retryable=True,
                    type="FraudCheckBadRequest",
                )
            raise  # 5xx → retryable, Temporal retries automatically

    if not result["approved"]:
        raise ApplicationError(
            f"Fraud detected for order {order.order_id}: {result['reason']}",
            non_retryable=True,
            type="FraudDetected",
        )

    activity.logger.info("check_fraud passed for order_id=%s", order.order_id)
