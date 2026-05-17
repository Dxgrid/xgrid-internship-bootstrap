import asyncio
import logging
import os

from temporalio.client import Client
from temporalio.worker import Worker

from activities import (
    charge_customer,
    check_fraud,
    prepare_shipment,
    send_notification,
    ship_order,
    revert_inventory,
    refund_customer,
)
from workflows import OrderWorkflow, ShippingWorkflow


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s - %(message)s")

TASK_QUEUE = os.getenv("TEMPORAL_TASK_QUEUE", "order-task-queue")
TEMPORAL_ADDRESS = os.getenv("TEMPORAL_ADDRESS", "localhost:7233")


async def main():
    client = await Client.connect(TEMPORAL_ADDRESS, namespace=os.getenv("TEMPORAL_NAMESPACE", "default"))
    print(f"Client connected to {client.service_client.config.target_host} in namespace '{client.namespace}'")

    worker = Worker(
        client,
        task_queue=TASK_QUEUE,
        workflows=[OrderWorkflow, ShippingWorkflow],
        activities=[
            check_fraud,
            prepare_shipment,
            charge_customer,
            ship_order,
            send_notification,
            revert_inventory,
            refund_customer,
        ],
    )
    print("Python order management worker starting...")
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
