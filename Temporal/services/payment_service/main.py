from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()

# In-memory idempotency store: key → transaction_id
processed_charges: dict[str, str] = {}
processed_refunds: set[str] = set()
# Attempt counter per idempotency key — fail first 2 attempts to give a cancel window
_attempt_counts: dict[str, int] = {}


class ChargeRequest(BaseModel):
    order_id: str
    idempotency_key: str
    amount: float


class ChargeResponse(BaseModel):
    order_id: str
    transaction_id: str
    status: str


class RefundRequest(BaseModel):
    order_id: str
    idempotency_key: str


@app.post("/charge", response_model=ChargeResponse)
async def charge(request: ChargeRequest):
    # Idempotency: same key returns the same result — no double-charge on retry
    if request.idempotency_key in processed_charges:
        return ChargeResponse(
            order_id=request.order_id,
            transaction_id=processed_charges[request.idempotency_key],
            status="already_charged",
        )

    # Fail first 2 attempts per charge — gives ~3s window (1s + 2s backoff) to cancel
    _attempt_counts[request.idempotency_key] = _attempt_counts.get(request.idempotency_key, 0) + 1
    if _attempt_counts[request.idempotency_key] < 3:
        raise HTTPException(status_code=500, detail="Payment gateway timeout")

    txn_id = f"TXN-{request.order_id}-{len(processed_charges) + 1:04d}"
    processed_charges[request.idempotency_key] = txn_id

    return ChargeResponse(
        order_id=request.order_id,
        transaction_id=txn_id,
        status="charged",
    )


@app.post("/refund")
async def refund(request: RefundRequest):
    # Idempotent: refunding the same key twice is safe
    if request.idempotency_key in processed_refunds:
        return {"order_id": request.order_id, "status": "already_refunded"}

    processed_refunds.add(request.idempotency_key)
    return {"order_id": request.order_id, "status": "refunded"}


@app.get("/health")
async def health():
    return {"status": "ok"}
