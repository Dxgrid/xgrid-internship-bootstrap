import asyncio

from temporalio import activity

from models import OrderInput


@activity.defn
async def refund_customer(order: OrderInput) -> None:
    activity.logger.info(
        "refund_customer started for order_id=%s",
        order.order_id,
    )
    # Simulate refund processing
    await asyncio.sleep(1)
    activity.logger.info("refund_customer completed for order_id=%s", order.order_id)
