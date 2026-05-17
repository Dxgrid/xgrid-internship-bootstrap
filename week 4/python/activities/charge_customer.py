import asyncio
from datetime import timedelta

from temporalio import activity
from temporalio.common import RetryPolicy
from temporalio.exceptions import ApplicationError

from models import OrderInput


CHARGE_CUSTOMER_RETRY_POLICY = RetryPolicy(
    initial_interval=timedelta(seconds=1),
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=8),
    maximum_attempts=4,
)


@activity.defn
async def charge_customer(order: OrderInput) -> None:
    attempt = activity.info().attempt
    activity.logger.info(
        "charge_customer started for order_id=%s attempt=%s",
        order.order_id,
        attempt,
    )
    await asyncio.sleep(1)

    if attempt <= 3:
        activity.logger.warning(
            "charge_customer failing on attempt=%s for order_id=%s",
            attempt,
            order.order_id,
        )
        raise ApplicationError(
            f"Charge customer failed on attempt {attempt}",
            type="transient-charge-failure",
        )

    activity.logger.info(
        "charge_customer succeeded on attempt=%s for order_id=%s",
        attempt,
        order.order_id,
    )
