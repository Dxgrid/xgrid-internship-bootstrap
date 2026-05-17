from dataclasses import dataclass, field

from temporalio.common import SearchAttributeKey

# Search Attribute keys for workflow filtering and observability
ORDER_STATUS_KEY = SearchAttributeKey.for_keyword("OrderStatus")


@dataclass
class OrderItem:
    item_id: int
    description: str
    quantity: int


@dataclass
class OrderInput:
    order_id: str
    address: str
    items: list[OrderItem] = field(default_factory=list)


@dataclass
class UpdateAddressInput:
    address: str


@dataclass
class OrderOutput:
    tracking_id: str
    address: str
    shipped_items: list[str] = field(default_factory=list)


@dataclass
class OrderStatus:
    order_id: str
    step: str
    address: str
    shipped_items: list[str] = field(default_factory=list)
