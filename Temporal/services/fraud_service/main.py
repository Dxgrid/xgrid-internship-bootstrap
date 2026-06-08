import random

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()


class FraudCheckRequest(BaseModel):
    order_id: str
    item_count: int


class FraudCheckResponse(BaseModel):
    order_id: str
    approved: bool
    reason: str


@app.post("/check", response_model=FraudCheckResponse)
async def check_fraud(request: FraudCheckRequest):
    # 10% transient failure — Temporal will retry automatically
    if random.random() < 0.1:
        raise HTTPException(status_code=503, detail="Fraud service temporarily unavailable")

    # Business rule: orders with >10 items are flagged — non-retryable failure
    if request.item_count > 10:
        return FraudCheckResponse(
            order_id=request.order_id,
            approved=False,
            reason="Order quantity exceeds fraud threshold",
        )

    return FraudCheckResponse(
        order_id=request.order_id,
        approved=True,
        reason="Order passed fraud checks",
    )


@app.get("/health")
async def health():
    return {"status": "ok"}
