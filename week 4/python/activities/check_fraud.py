import asyncio

from temporalio import activity

from models import OrderInput


@activity.defn
async def check_fraud(order: OrderInput) -> None:
    activity.logger.info(
        "check_fraud started for order_id=%s address=%s item_count=%s",
        order.order_id,
        order.address,
        len(order.items),
    )
    await asyncio.sleep(1)
    activity.logger.info("check_fraud completed for order_id=%s", order.order_id)
