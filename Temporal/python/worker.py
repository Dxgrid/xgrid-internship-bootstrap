import asyncio
import logging
import os
import signal
from datetime import timedelta

from aiohttp import web
from temporalio.client import Client
from temporalio.runtime import PrometheusConfig, Runtime, TelemetryConfig
from temporalio.worker import Worker
from temporalio.worker.workflow_sandbox import SandboxedWorkflowRunner, SandboxRestrictions

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

async def _start_health_server() -> None:
    async def handle(_: web.Request) -> web.Response:
        return web.Response(text="OK")

    app = web.Application()
    app.router.add_get("/health", handle)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", 8081).start()


async def main():
    runtime = Runtime(
        telemetry=TelemetryConfig(
            metrics=PrometheusConfig(bind_address="0.0.0.0:9090")
        )
    )
    client = await Client.connect(
        TEMPORAL_ADDRESS,
        namespace=os.getenv("TEMPORAL_NAMESPACE", "default"),
        runtime=runtime,
    )
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
        workflow_runner=SandboxedWorkflowRunner(
            restrictions=SandboxRestrictions.default.with_passthrough_modules("httpx")
        ),
        max_concurrent_workflow_tasks=50,
        max_concurrent_activities=20,
        graceful_shutdown_timeout=timedelta(seconds=30),
    )

    # Health endpoint for ECS container-level health checks (separate from Prometheus :9090)
    asyncio.create_task(_start_health_server())

    # Graceful shutdown: drain in-flight activities before ECS SIGKILL
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda: asyncio.create_task(worker.shutdown()))

    print("Python order management worker starting (metrics on :9090, health on :8081)...")
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
