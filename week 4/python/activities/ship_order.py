import asyncio

from temporalio import activity

from models import OrderInput, OrderItem


@activity.defn
async def ship_order(order: OrderInput, item: OrderItem) -> str:
    activity.logger.info(
        "ship_order started for order_id=%s item_id=%s description=%s quantity=%s",
        order.order_id,
        item.item_id,
        item.description,
        item.quantity,
    )
    await asyncio.sleep(1)
    shipped_item = f"{item.item_id}:{item.description}"
    activity.logger.info(
        "ship_order completed for order_id=%s shipped_item=%s",
        order.order_id,
        shipped_item,
    )
    return shipped_item
