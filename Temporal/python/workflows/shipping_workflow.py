from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

from activities import ship_order
from models import OrderInput, OrderItem


@workflow.defn(name="ShippingWorkflow")
class ShippingWorkflow:
    @workflow.run
    async def run(self, order: OrderInput, item: OrderItem) -> str:
        workflow.logger.info(
            "ShippingWorkflow started for order_id=%s item_id=%s description=%s",
            order.order_id,
            item.item_id,
            item.description,
        )
        shipped_item = await workflow.execute_activity(
            ship_order,
            args=[order, item],
            start_to_close_timeout=timedelta(seconds=10),
            schedule_to_close_timeout=timedelta(minutes=5),
            retry_policy=RetryPolicy(
                maximum_attempts=3,
                initial_interval=timedelta(seconds=2),
                backoff_coefficient=2.0,
                maximum_interval=timedelta(seconds=30),
            ),
        )
        workflow.logger.info(
            "ShippingWorkflow completed for order_id=%s item_id=%s shipped_item=%s",
            order.order_id,
            item.item_id,
            shipped_item,
        )
        return shipped_item
