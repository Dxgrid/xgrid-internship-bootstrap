import asyncio

from temporalio import activity

from models import OrderInput


@activity.defn
async def send_notification(order: OrderInput, shipped_items: list[str]) -> None:
    activity.logger.info(
        "send_notification started for order_id=%s shipped_items=%s final_address=%s",
        order.order_id,
        shipped_items,
        order.address,
    )
    await asyncio.sleep(1)
    activity.logger.info("send_notification completed for order_id=%s", order.order_id)
