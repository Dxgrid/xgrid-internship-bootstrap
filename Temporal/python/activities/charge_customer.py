import os
from datetime import timedelta

import httpx
from temporalio import activity
from temporalio.common import RetryPolicy
from temporalio.exceptions import ApplicationError

from models import OrderInput

PAYMENT_SERVICE_URL = os.getenv("PAYMENT_SERVICE_URL", "http://localhost:8003")

CHARGE_CUSTOMER_RETRY_POLICY = RetryPolicy(
    initial_interval=timedelta(seconds=1),
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=8),
    maximum_attempts=4,
)


@activity.defn
async def charge_customer(order: OrderInput) -> str:
    info = activity.info()
    idempotency_key = f"charge-{order.order_id}-{info.workflow_run_id}"
    activity.logger.info(
        "charge_customer started for order_id=%s attempt=%s idempotency_key=%s",
        order.order_id,
        info.attempt,
        idempotency_key,
    )
    async with httpx.AsyncClient(timeout=15.0) as client:
        try:
            response = await client.post(
                f"{PAYMENT_SERVICE_URL}/charge",
                json={
                    "order_id": order.order_id,
                    "idempotency_key": idempotency_key,
                    "amount": len(order.items) * 9.99,
                },
            )
            response.raise_for_status()
            result = response.json()
        except httpx.HTTPStatusError as e:
            if e.response.status_code in (400, 401, 403, 422):
                raise ApplicationError(
                    f"Payment rejected for order {order.order_id}: {e.response.text}",
                    non_retryable=True,
                    type="PaymentRejected",
                )
            raise  # 5xx, 429, 503 → retryable

    activity.logger.info(
        "charge_customer succeeded for order_id=%s txn_id=%s",
        order.order_id,
        result["transaction_id"],
    )
    return result["transaction_id"]
