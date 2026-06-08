import argparse
import asyncio
import logging
import os
from uuid import uuid4

from temporalio.client import Client

from models import OrderInput, OrderItem, UpdateAddressInput
from workflows import OrderWorkflow


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s - %(message)s")

TASK_QUEUE = os.getenv("TEMPORAL_TASK_QUEUE", "order-task-queue")
TEMPORAL_ADDRESS = os.getenv("TEMPORAL_ADDRESS", "localhost:7233")


def build_default_order(order_id: str, address: str) -> OrderInput:
    return OrderInput(
        order_id=order_id,
        address=address,
        items=[
            OrderItem(item_id=1001, description="Keyboard", quantity=1),
            OrderItem(item_id=1002, description="Mouse", quantity=1),
            OrderItem(item_id=1003, description="Monitor", quantity=2),
        ],
    )


async def main() -> None:
    parser = argparse.ArgumentParser(description="Start the Temporal order workflow")
    parser.add_argument("--workflow-id", default=f"order-{uuid4()}")
    parser.add_argument("--order-id", default="ORD-1001")
    parser.add_argument("--address", default="1 Main Street, Austin, TX")
    parser.add_argument("--signal-address", default="")
    parser.add_argument("--signal-delay-seconds", type=int, default=5)
    args = parser.parse_args()

    client = await Client.connect(TEMPORAL_ADDRESS, namespace=os.getenv("TEMPORAL_NAMESPACE", "default"))
    order = build_default_order(args.order_id, args.address)

    handle = await client.start_workflow(
        OrderWorkflow.run,
        order,
        id=args.workflow_id,
        task_queue=TASK_QUEUE,
    )
    print(f"Started workflow_id={handle.id} run_id={handle.run_id}")

    if args.signal_address:
        print(f"Waiting {args.signal_delay_seconds} seconds before sending update_address signal")
        await asyncio.sleep(args.signal_delay_seconds)
        await handle.signal("update_address", UpdateAddressInput(address=args.signal_address))
        print(f"Sent update_address signal with address={args.signal_address}")

    result = await handle.result()
    print(result)


if __name__ == "__main__":
    asyncio.run(main())
