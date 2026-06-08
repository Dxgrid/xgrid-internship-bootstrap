import dataclasses
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from temporalio.client import Client, WorkflowUpdateFailedError
from temporalio.exceptions import WorkflowAlreadyStartedError
from temporalio.service import RPCError

from models import OrderInput as DCOrderInput, OrderItem as DCOrderItem, OrderStatus as DCOrderStatus, UpdateAddressInput as DCUpdateAddressInput, ORDER_STATUS_KEY
from workflows.order_workflow import OrderWorkflow

load_dotenv()


# Logging configuration
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger(__name__)


# Module-level Temporal client and task queue (initialized in lifespan)
temporal_client: Optional[Client] = None
TASK_QUEUE = os.getenv("TEMPORAL_TASK_QUEUE", "order-task-queue")


# Lifespan manager: connect to Temporal once at startup
@asynccontextmanager
async def lifespan(app: FastAPI):
    global temporal_client
    address = os.getenv("TEMPORAL_ADDRESS", "localhost:7233")
    namespace = os.getenv("TEMPORAL_NAMESPACE", "default")
    try:
        temporal_client = await Client.connect(address, namespace=namespace)
        logger.info(f"Connected to Temporal at {address} (namespace={namespace})")
    except Exception as e:
        logger.exception("Failed to connect to Temporal at %s: %s", address, e)
        raise
    yield
    # Close client if it exposes a close method (best-effort)
    try:
        if temporal_client is not None and hasattr(temporal_client, "close"):
            await temporal_client.close()
            logger.info("Temporal client closed")
    except Exception:
        logger.exception("Error while closing Temporal client")


app = FastAPI(
    title="Order Management System",
    description="3-tier Order Management System powered by Temporal durable workflows",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# Mount static files
static_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "static")
if not os.path.exists(static_dir):
    os.makedirs(static_dir, exist_ok=True)
app.mount("/static", StaticFiles(directory=static_dir), name="static")


# Serve the UI at root
@app.get("/", response_class=FileResponse)
async def serve_ui():
    return FileResponse(os.path.join(static_dir, "index.html"))


# --------------------
# Pydantic models
# --------------------


class OrderItemRequest(BaseModel):
    item_id: int
    description: str
    quantity: int


class CreateOrderRequest(BaseModel):
    order_id: str
    address: str
    items: list[OrderItemRequest]


class UpdateAddressRequest(BaseModel):
    address: str


class CancelOrderRequest(BaseModel):
    reason: str = "Customer requested cancellation"


class OrderResponse(BaseModel):
    workflow_id: str
    run_id: str
    message: str


class OrderStatusResponse(BaseModel):
    order_id: str
    step: str
    address: str
    shipped_items: list[str]
    workflow_id: str
    order_status: Optional[str] = None
    execution_status: Optional[str] = None


class WorkflowListItem(BaseModel):
    workflow_id: str
    status: str
    order_status: Optional[str] = None


# --------------------
# Exception handler
# --------------------


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error("Unhandled error: %s", exc, exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal server error", "error": str(exc)},
    )


# --------------------
# Helpers
# --------------------


def pydantic_to_dataclass_order(req: CreateOrderRequest) -> DCOrderInput:
    items = [DCOrderItem(item_id=i.item_id, description=i.description, quantity=i.quantity) for i in req.items]
    return DCOrderInput(order_id=req.order_id, address=req.address, items=items)


def pydantic_to_update_address(req: UpdateAddressRequest) -> DCUpdateAddressInput:
    return DCUpdateAddressInput(address=req.address)


# --------------------
# Routes
# --------------------


@app.post("/orders", response_model=OrderResponse, status_code=201)
async def create_order(request: CreateOrderRequest):
    logger.info("Create order request received: order_id=%s", request.order_id)
    if temporal_client is None:
        logger.error("Temporal client not initialized")
        raise HTTPException(status_code=503, detail="Temporal client not connected")

    workflow_id = f"order-{request.order_id}"
    dc_order = pydantic_to_dataclass_order(request)
    try:
        handle = await temporal_client.start_workflow(
            OrderWorkflow.run,
            dc_order,
            id=workflow_id,
            task_queue=TASK_QUEUE,
        )
        # Some SDK handle implementations may not expose `workflow_id`; use the known id
        run_id = getattr(handle, "run_id", None) or ""
        logger.info("Started workflow: id=%s run_id=%s", workflow_id, run_id)
        return OrderResponse(workflow_id=workflow_id, run_id=run_id, message="Order started")
    except WorkflowAlreadyStartedError:
        logger.warning("Order already exists: %s", workflow_id)
        raise HTTPException(status_code=409, detail="Order already exists")
    except Exception as e:
        logger.exception("Failed to start workflow for order_id=%s: %s", request.order_id, e)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/orders/{workflow_id}", response_model=OrderStatusResponse)
async def get_order(workflow_id: str):
    logger.info("Get order status request: workflow_id=%s", workflow_id)
    if temporal_client is None:
        raise HTTPException(status_code=503, detail="Temporal client not connected")
    try:
        handle = temporal_client.get_workflow_handle(workflow_id)
        # Query the workflow status object
        status_obj = await handle.query(OrderWorkflow.status)
        desc = await handle.describe()
        # Determine execution status
        exec_status = getattr(desc, "status", None)
        if exec_status is not None and hasattr(exec_status, "name"):
            exec_status_str = exec_status.name
        else:
            exec_status_str = str(exec_status) if exec_status is not None else "UNKNOWN"

        # Extract search attributes from describe
        search_attrs = desc.search_attributes
        order_status = None
        if search_attrs is not None:
            v = search_attrs.get("OrderStatus")
            if isinstance(v, list) and len(v) > 0:
                order_status = str(v[0])
            elif v is not None:
                order_status = str(v)

        # status_obj is expected to be a dataclass (OrderStatus)
        if dataclasses.is_dataclass(status_obj):
            os_dict = dataclasses.asdict(status_obj)
            return OrderStatusResponse(
                order_id=os_dict.get("order_id", ""),
                step=os_dict.get("step", ""),
                address=os_dict.get("address", ""),
                shipped_items=os_dict.get("shipped_items", []),
                workflow_id=workflow_id,
                order_status=order_status,
                execution_status=exec_status_str,
            )
        # Fallback if query returned dict-like
        if isinstance(status_obj, dict):
            return OrderStatusResponse(
                order_id=status_obj.get("order_id", ""),
                step=status_obj.get("step", ""),
                address=status_obj.get("address", ""),
                shipped_items=status_obj.get("shipped_items", []),
                workflow_id=workflow_id,
                order_status=order_status,
                execution_status=exec_status_str,
            )
        raise HTTPException(status_code=500, detail="Unexpected status response from workflow")
    except RPCError as rpc_e:
        # Map NOT_FOUND to 404
        if getattr(rpc_e, "status", None) is not None and getattr(rpc_e.status, "name", None) == "NOT_FOUND":
            logger.warning("Workflow not found: %s", workflow_id)
            raise HTTPException(status_code=404, detail="Workflow not found")
        logger.exception("RPCError while describing workflow %s: %s", workflow_id, rpc_e)
        raise HTTPException(status_code=500, detail=str(rpc_e))
    except Exception as e:
        logger.exception("Error querying workflow %s: %s", workflow_id, e)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/orders", response_model=list[WorkflowListItem])
async def list_orders(status: Optional[str] = Query(None)):
    logger.info("List orders request, status filter=%s", status)
    if temporal_client is None:
        raise HTTPException(status_code=503, detail="Temporal client not connected")

    query = 'WorkflowType="OrderWorkflow"'
    if status:
        query = f'{query} AND OrderStatus="{status}"'

    results: list[WorkflowListItem] = []
    try:
        # list_workflows returns an async iterator of WorkflowExecutionInfo
        i = 0
        async for wf in temporal_client.list_workflows(query=query, page_size=50):
            if i >= 50:
                break
            wf_id = wf.id
            status_str = wf.status.name if hasattr(wf.status, "name") else str(wf.status)
            status_attr = None
            # Try to glean OrderStatus from search attributes if present
            sa = getattr(wf, "search_attributes", None)
            if sa is not None:
                try:
                    v = sa.get("OrderStatus")
                    if isinstance(v, list) and len(v) > 0:
                        status_attr = str(v[0])
                    elif v is not None:
                        status_attr = str(v)
                except Exception:
                    status_attr = None

            results.append(WorkflowListItem(workflow_id=wf_id, status=status_str, order_status=status_attr))
            i += 1
        return results
    except Exception as e:
        logger.exception("Error listing workflows: %s", e)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/orders/{workflow_id}/signal/proceed")
async def signal_proceed(workflow_id: str):
    """Signal the workflow to proceed from validation to payment."""
    if temporal_client is None:
        raise HTTPException(status_code=503, detail="Temporal client not connected")
    try:
        handle = temporal_client.get_workflow_handle(workflow_id)
        desc = await handle.describe()
        exec_status = getattr(desc, "status", None)
        if exec_status is not None and getattr(exec_status, "name", None) != "RUNNING":
            raise HTTPException(status_code=400, detail="Workflow already completed or not running")
        
        await handle.signal("proceed_to_payment")
        return {"workflow_id": workflow_id, "message": "Proceed signal sent"}
    except RPCError as rpc_e:
        if getattr(rpc_e, "status", None) is not None and getattr(rpc_e.status, "name", None) == "NOT_FOUND":
            raise HTTPException(status_code=404, detail="Workflow not found")
        logger.exception("RPCError while signalling proceed on workflow %s: %s", workflow_id, rpc_e)
        raise HTTPException(status_code=500, detail=str(rpc_e))
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Unexpected error in signal_proceed for %s: %s", workflow_id, e)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/orders/{workflow_id}/signal/address")
async def signal_address(workflow_id: str, request: UpdateAddressRequest):
    logger.info("Signal address request: workflow_id=%s new_address=%s", workflow_id, request.address)
    if temporal_client is None:
        raise HTTPException(status_code=503, detail="Temporal client not connected")
    try:
        handle = temporal_client.get_workflow_handle(workflow_id)
        desc = await handle.describe()
        exec_status = getattr(desc, "status", None)
        if exec_status is not None and getattr(exec_status, "name", None) != "RUNNING":
            logger.warning("Cannot signal completed workflow: %s status=%s", workflow_id, exec_status)
            raise HTTPException(status_code=400, detail="Workflow already completed")

        await handle.signal("update_address_signal", pydantic_to_update_address(request))
        return {"detail": "Signal sent"}
    except RPCError as rpc_e:
        if getattr(rpc_e, "status", None) is not None and getattr(rpc_e.status, "name", None) == "NOT_FOUND":
            raise HTTPException(status_code=404, detail="Workflow not found")
        logger.exception("RPCError while signaling workflow %s: %s", workflow_id, rpc_e)
        raise HTTPException(status_code=500, detail=str(rpc_e))
    except Exception as e:
        logger.exception("Error signaling workflow %s: %s", workflow_id, e)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/orders/{workflow_id}/update/address")
async def update_address(workflow_id: str, request: UpdateAddressRequest):
    logger.info("Update address request: workflow_id=%s new_address=%s", workflow_id, request.address)
    if temporal_client is None:
        raise HTTPException(status_code=503, detail="Temporal client not connected")
    try:
        handle = temporal_client.get_workflow_handle(workflow_id)
        # Execute update synchronously
        try:
            res = await handle.execute_update("update_address", pydantic_to_update_address(request))
            # res expected to be the new address (string)
            return {"address": res}
        except WorkflowUpdateFailedError as ufe:
            logger.warning("Workflow update failed for %s: %s", workflow_id, ufe)
            raise HTTPException(status_code=422, detail=str(ufe))
        except Exception as e:
            # Re-raise to be caught by the outer catch-all
            raise e
    except RPCError as rpc_e:
        if getattr(rpc_e, "status", None) is not None and getattr(rpc_e.status, "name", None) == "NOT_FOUND":
            raise HTTPException(status_code=404, detail="Workflow not found")
        logger.exception("RPCError while updating workflow %s: %s", workflow_id, rpc_e)
        raise HTTPException(status_code=500, detail=str(rpc_e))
    except Exception as e:
        logger.exception("Error executing update for workflow %s: %s", workflow_id, e)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/orders/{workflow_id}/cancel")
async def cancel_order(workflow_id: str, request: Optional[CancelOrderRequest] = None):
    reason = request.reason if request and request.reason else "Customer requested cancellation"
    logger.info("Cancel order request: workflow_id=%s reason=%s", workflow_id, reason)
    if temporal_client is None:
        raise HTTPException(status_code=503, detail="Temporal client not connected")
    try:
        handle = temporal_client.get_workflow_handle(workflow_id)
        desc = await handle.describe()
        exec_status = getattr(desc, "status", None)
        if exec_status is not None and getattr(exec_status, "name", None) != "RUNNING":
            logger.warning("Cannot cancel completed workflow: %s status=%s", workflow_id, exec_status)
            raise HTTPException(status_code=400, detail="Workflow already completed or not running")

        await handle.signal("cancel_order", reason)
        return {"detail": "Cancel signal sent", "reason": reason}
    except RPCError as rpc_e:
        if getattr(rpc_e, "status", None) is not None and getattr(rpc_e.status, "name", None) == "NOT_FOUND":
            raise HTTPException(status_code=404, detail="Workflow not found")
        logger.exception("RPCError while cancelling workflow %s: %s", workflow_id, rpc_e)
        raise HTTPException(status_code=500, detail=str(rpc_e))
    except Exception as e:
        logger.exception("Error cancelling workflow %s: %s", workflow_id, e)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
async def health():
    if temporal_client is None:
        logger.warning("Health check: Temporal client not connected")
        raise HTTPException(status_code=503, detail="Temporal client not connected")
    return {"status": "ok", "temporal": "connected", "timestamp": datetime.now(timezone.utc).isoformat()}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api.main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8000")),
        reload=False,
        log_level="info",
    )
