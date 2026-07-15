"""
DevFlow ticket-source adapters — repo-agnostic ingestion.

The seam is a normalized envelope (EIP Canonical Data Model), so the router and
research stage never know or care whether a ticket came from GitHub, Jira, or a
flat file:

    {"id": "123", "title": "...", "body": "...", "labels": ["hitl"], "url": "..."}

An adapter is just a module exposing two callables:

    list_open_tickets(label: str | None) -> list[Ticket]
    set_label(ticket_id: str, label: str) -> None     # for the auto-downgrade

`get(name)` resolves an adapter by name. Add a new source by dropping a
`<name>.py` in this package with those two functions — no core changes.
GitHub ships first (it wraps calls the agent-orchestration watcher already makes).
"""
from __future__ import annotations

import importlib
from typing import Callable, Optional, Protocol, TypedDict


class Ticket(TypedDict):
    id: str
    title: str
    body: str
    labels: list[str]
    url: str


class Adapter(Protocol):
    def list_open_tickets(self, label: Optional[str]) -> list[Ticket]: ...
    def set_label(self, ticket_id: str, label: str) -> None: ...


def get(name: str) -> Adapter:
    """Resolve an adapter module by name (e.g. 'github'). Raises a clear error
    naming the available adapters if the source isn't wired up."""
    try:
        return importlib.import_module(f"{__name__}.{name}")  # type: ignore[return-value]
    except ModuleNotFoundError as e:
        # Only swallow a missing-adapter error, not an import error inside the adapter.
        if e.name and e.name.endswith(name):
            import pkgutil
            avail = [m.name for m in pkgutil.iter_modules(__path__) if m.name != "selfcheck"]
            raise ValueError(f"unknown ticket adapter {name!r}; available: {avail}") from None
        raise


def normalize(raw: dict, *, id_key: str, title_key: str, body_key: str,
              labels: list[str], url: str) -> Ticket:
    """Helper for adapters: coerce a source-specific record into the envelope.
    Keeps every adapter's mapping in one obvious place."""
    return Ticket(
        id=str(raw[id_key]),
        title=raw.get(title_key) or "",
        body=raw.get(body_key) or "",
        labels=labels,
        url=url,
    )
