"""Tests for the capability-agnostic MCP authorization transaction."""

from __future__ import annotations

from typing import Any

import pytest

from debug_control_plane.mcp_plane.authorization import (
    AuthorizationCoordinator,
    AuthorizationFlowError,
)


class _AuthClient:
    def __init__(self, statuses: list[str], *, claim: dict[str, Any] | None = None) -> None:
        self.statuses = iter(statuses)
        self.claim = claim or {"ok": True, "token": "opaque-token"}
        self.calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []

    def auth_request(self, *args, **kwargs):
        self.calls.append(("request", args, kwargs))
        return {"ok": True, "requestId": "request-1", "status": "pending"}

    def auth_status(self, *args, **kwargs):
        self.calls.append(("status", args, kwargs))
        return {"ok": True, "status": next(self.statuses)}

    def auth_claim(self, *args, **kwargs):
        self.calls.append(("claim", args, kwargs))
        return self.claim


def test_authorization_coordinator_requests_polls_claims_with_original_intent() -> None:
    client = _AuthClient(["pending", "approved"])
    coordinator = AuthorizationCoordinator(  # type: ignore[arg-type]
        client, poll_interval_s=0.001
    )

    result = coordinator.authorize(
        "phone-1", requested_method="POST", requested_path="/ai-voice/open"
    )

    assert result["token"] == "opaque-token"
    assert [name for name, _, _ in client.calls] == ["request", "status", "status", "claim"]
    name, args, kwargs = client.calls[0]
    assert name == "request"
    assert args[0] == "phone-1"
    assert kwargs == {
        "client_label": "MCP Debug Control Plane",
        "requested_method": "POST",
        "requested_path": "/ai-voice/open",
    }
    nonce = args[1]
    assert isinstance(nonce, str) and len(nonce) >= 32
    assert client.calls[-1][1] == ("phone-1", "request-1", nonce)


@pytest.mark.parametrize(
    ("status", "reason"),
    [("denied", "authorization_denied"), ("expired", "authorization_expired")],
)
def test_authorization_coordinator_stops_without_claim_when_not_approved(
    status: str, reason: str
) -> None:
    client = _AuthClient([status])
    coordinator = AuthorizationCoordinator(client, poll_interval_s=0.001)  # type: ignore[arg-type]

    with pytest.raises(AuthorizationFlowError) as exc_info:
        coordinator.authorize("phone-1", requested_method="GET", requested_path="/state")

    assert exc_info.value.reason == reason
    assert [name for name, _, _ in client.calls] == ["request", "status"]


def test_authorization_coordinator_rejects_approved_claim_without_token() -> None:
    client = _AuthClient(["approved"], claim={"ok": True})
    coordinator = AuthorizationCoordinator(client, poll_interval_s=0.001)  # type: ignore[arg-type]

    with pytest.raises(AuthorizationFlowError, match="did not issue a token"):
        coordinator.authorize("phone-1", requested_method="GET", requested_path="/state")
