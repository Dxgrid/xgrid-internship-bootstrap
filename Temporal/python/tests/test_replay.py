from pathlib import Path

import pytest
from temporalio.testing import Replayer
from temporalio.worker import WorkflowHistory

from workflows.order_workflow import OrderWorkflow
from workflows.shipping_workflow import ShippingWorkflow


@pytest.mark.asyncio
async def test_order_workflow_replay():
    """
    Replay a known-good event history to catch non-determinism before deploy.

    To generate the history file:
      temporal workflow show -w <workflow_id> --output json \
        > Temporal/python/tests/testdata/order_history.json
    Or: Temporal UI → workflow → Download History → save as JSON.
    """
    history_path = Path(__file__).parent / "testdata" / "order_history.json"
    replayer = Replayer(workflows=[OrderWorkflow, ShippingWorkflow])
    await replayer.replay_workflow(WorkflowHistory.from_json(history_path.read_text()))


@pytest.mark.asyncio
async def test_shipping_workflow_replay():
    history_path = Path(__file__).parent / "testdata" / "shipping_history.json"
    replayer = Replayer(workflows=[ShippingWorkflow])
    await replayer.replay_workflow(WorkflowHistory.from_json(history_path.read_text()))
