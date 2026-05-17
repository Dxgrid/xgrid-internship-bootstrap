import asyncio

from temporalio import activity

from models import OrderInput


@activity.defn
async def prepare_shipment(order: OrderInput) -> None:
    activity.logger.info(
        "prepare_shipment started for order_id=%s address=%s",
        order.order_id,
        order.address,
    )
    await asyncio.sleep(1)
    activity.logger.info("prepare_shipment completed for order_id=%s", order.order_id)
