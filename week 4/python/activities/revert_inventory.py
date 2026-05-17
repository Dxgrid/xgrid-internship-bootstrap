import asyncio

from temporalio import activity

from models import OrderInput


@activity.defn
async def revert_inventory(order: OrderInput) -> None:
    activity.logger.info(
        "revert_inventory started for order_id=%s",
        order.order_id,
    )
    # Simulate compensating work (e.g., un-reserve inventory)
    await asyncio.sleep(1)
    activity.logger.info("revert_inventory completed for order_id=%s", order.order_id)
