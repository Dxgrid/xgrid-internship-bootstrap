import asyncio
from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

from activities import (
    CHARGE_CUSTOMER_RETRY_POLICY,
    charge_customer,
    check_fraud,
    prepare_shipment,
    send_notification,
    revert_inventory,
    refund_customer,
)
from models import ORDER_STATUS_KEY, OrderInput, OrderOutput, OrderStatus, UpdateAddressInput
from workflows.shipping_workflow import ShippingWorkflow


@workflow.defn(name="OrderWorkflow")
class OrderWorkflow:
    def __init__(self) -> None:
        self.order: OrderInput | None = None
        self.current_step = "created"
        self.shipped_items: list[str] = []
        self.updated_address: str | None = None
        self._cancelled: bool = False
        self._proceed: bool = False
        self._cancel_reason: str | None = None
        self._compensations: list[dict] = []

    @workflow.run
    async def run(self, order: OrderInput) -> OrderOutput:
        try:
            self.order = OrderInput(order_id=order.order_id, address=order.address, items=list(order.items))
            workflow.logger.info(
                "OrderWorkflow started for order_id=%s item_count=%s address=%s",
                self.order.order_id,
                len(self.order.items),
                self.order.address,
            )
            workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("PENDING")])

            # Step 1: Fraud Check
            await self._advance("fraud_check")
            workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("FRAUD_CHECKING")])
            await workflow.execute_activity(
                check_fraud,
                self.order,
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=RetryPolicy(
                    maximum_attempts=3,
                    initial_interval=timedelta(seconds=1),
                    backoff_coefficient=2.0,
                    maximum_interval=timedelta(seconds=10),
                    non_retryable_error_types=["FraudDetected"],
                ),
            )
            if self._cancelled: return await self._early_exit()

            # Step 2: Prepare Shipment (Reserve Inventory)
            await self._advance("prepare_shipment")
            workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("PREPARING_SHIPMENT")])
            await workflow.execute_activity(
                prepare_shipment,
                self.order,
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=RetryPolicy(
                    maximum_attempts=5,
                    initial_interval=timedelta(seconds=2),
                    backoff_coefficient=2.0,
                    maximum_interval=timedelta(seconds=30),
                ),
            )
            # Register compensation to revert inventory if we fail later
            self._compensations.append({"activity": revert_inventory, "input": self.order})
            if self._cancelled: return await self._early_exit()

            # Step 3: Event-Driven Validation Wait
            await self._advance("awaiting_validation")
            workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("AWAITING_VALIDATION")])
            
            try:
                await workflow.wait_condition(
                    lambda: self._proceed or self._cancelled,
                    timeout=timedelta(hours=1),
                )
            except asyncio.TimeoutError:
                self._cancelled = True
                self._cancel_reason = "Manual validation timeout"

            if self._cancelled: return await self._early_exit()

            # Step 4: Charge Customer (with retries)
            await self._advance("charge_customer")
            workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("CHARGING")])
            await workflow.execute_activity(
                charge_customer,
                self.order,
                start_to_close_timeout=timedelta(seconds=20),
                retry_policy=CHARGE_CUSTOMER_RETRY_POLICY,
            )
            # Register compensation AFTER charge succeeds — only refund what was actually charged
            self._compensations.append({"activity": refund_customer, "input": self.order})
            if self._cancelled: return await self._early_exit()

            # Step 5: Ship Items (Parallel Child Workflows)
            await self._advance("shipping")
            workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("SHIPPING")])
            
            ship_tasks = []
            for item in self.order.items:
                task = workflow.execute_child_workflow(
                    ShippingWorkflow.run,
                    args=[self.order, item],
                    id=f"ship-{self.order.order_id}-{item.item_id}",
                )
                ship_tasks.append(task)
            
            shipped_results = await asyncio.gather(*ship_tasks, return_exceptions=True)
            errors = [r for r in shipped_results if isinstance(r, BaseException)]
            if errors:
                workflow.logger.error("Shipping failed: %s", errors[0])
                raise errors[0]
            self.shipped_items = [r for r in shipped_results if isinstance(r, str)]
            if self._cancelled: return await self._early_exit()

            # Step 6: Notify
            await self._advance("notifying")
            workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("NOTIFYING")])
            await workflow.execute_activity(
                send_notification,
                args=[self.order, self.shipped_items],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=RetryPolicy(
                    maximum_attempts=3,
                    initial_interval=timedelta(seconds=2),
                    backoff_coefficient=2.0,
                    maximum_interval=timedelta(seconds=30),
                    non_retryable_error_types=["InvalidEmailAddress"],
                ),
            )
            if self._cancelled: return await self._early_exit()

            # Step 7: Complete
            await self._advance("completed")
            workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("COMPLETED")])
            
            # Ensure all signal/update handlers complete before workflow exits
            await workflow.wait_condition(workflow.all_handlers_finished)
            
            return OrderOutput(
                tracking_id=f"TRK-{workflow.uuid4()}",
                address=self.order.address,
                shipped_items=self.shipped_items,
            )

        except Exception as e:
            workflow.logger.error("Workflow failed with error: %s", str(e))
            await self._run_compensations()
            raise e

    async def _early_exit(self) -> OrderOutput:
        """Helper to run compensations and return a cancelled output."""
        workflow.logger.info("OrderWorkflow stopping due to cancellation: %s", self._cancel_reason)
        workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("CANCELLED")])
        await self._run_compensations()
        return OrderOutput(
            tracking_id=f"CANCELLED-{workflow.uuid4()}",
            address=self.order.address if self.order else "N/A",
            shipped_items=[],
        )

    async def _run_compensations(self) -> None:
        workflow.logger.info("Running saga compensations (%d actions)", len(self._compensations))
        while self._compensations:
            comp = self._compensations.pop()  # LIFO — last registered runs first
            try:
                workflow.logger.info("Running compensation: %s", comp["activity"].__name__)
                await workflow.execute_activity(
                    comp["activity"],
                    comp["input"],
                    start_to_close_timeout=timedelta(seconds=30),
                    retry_policy=RetryPolicy(
                        backoff_coefficient=2.0,
                        maximum_interval=timedelta(seconds=60),
                        # No maximum_attempts — compensations must keep retrying.
                        # Giving up on a refund/revert leaves the system inconsistent.
                    ),
                )
                workflow.logger.info("Compensation succeeded: %s", comp["activity"].__name__)
            except Exception as e:
                workflow.logger.error(
                    "Compensation failed for %s: %s — continuing",
                    comp["activity"].__name__, str(e)
                )

    async def _advance(self, step: str) -> None:
        """Helper to update internal state and log progress."""
        self.current_step = step
        workflow.logger.info("Advancing to step: %s", step)

    @workflow.query
    def status(self) -> OrderStatus:
        order_id = self.order.order_id if self.order else "unknown"
        address = self.order.address if self.order else "unknown"
        return OrderStatus(
            order_id=order_id,
            step=self.current_step,
            address=address,
            shipped_items=list(self.shipped_items),
        )

    @workflow.signal(name="cancel_order")
    def cancel_order(self, reason: str) -> None:
        workflow.logger.info("Received cancel_order signal: %s", reason)
        self._cancelled = True
        self._cancel_reason = reason
        # Upsert CANCELLED immediately for filtering
        workflow.upsert_search_attributes([ORDER_STATUS_KEY.value_set("CANCELLED")])

    @workflow.signal(name="proceed_to_payment")
    def proceed_to_payment(self) -> None:
        workflow.logger.info("Received proceed_to_payment signal")
        self._proceed = True

    @workflow.signal(name="update_address_signal")
    def update_address_signal(self, update: UpdateAddressInput) -> None:
        workflow.logger.info(
            "Received update_address signal for order_id=%s new_address=%s",
            self.order.order_id if self.order else "unknown",
            update.address,
        )
        self.updated_address = update.address
        if self.order is not None:
            self.order.address = update.address

    @workflow.update(name="update_address")
    async def update_address(self, update: UpdateAddressInput) -> str:
        """Synchronous update handler that returns the new address."""
        workflow.logger.info("Received update_address update: %s", update.address)
        if self.order is None:
            raise ValueError("Workflow not initialized")
        self.order.address = update.address
        self.updated_address = update.address
        return update.address
