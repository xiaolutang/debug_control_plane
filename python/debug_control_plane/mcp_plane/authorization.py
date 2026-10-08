"""Generic App-authorization transaction used by the MCP adapter.

The App remains the authority that displays the prompt and issues tokens.
This module only drives the protocol-defined bootstrap sequence after a
protected MCP operation returns ``authorization_required``:

``request -> poll status -> claim -> retry original operation``.

It deliberately has no knowledge of product capabilities or endpoint bodies.
"""

from __future__ import annotations

import secrets
import time
from typing import Any

from .bridge_client import BridgeClient, BridgeError

DEFAULT_AUTHORIZATION_TIMEOUT_S = 30.0
DEFAULT_AUTHORIZATION_POLL_INTERVAL_S = 0.25
DEFAULT_MCP_CLIENT_LABEL = "MCP Debug Control Plane"


class AuthorizationFlowError(BridgeError):
    """A local failure while completing the standard App authorization flow."""

    def __init__(self, reason: str, message: str) -> None:
        self.reason = reason
        super().__init__(message)


class AuthorizationCoordinator:
    """Drive one capability-agnostic authorization transaction for a device."""

    def __init__(
        self,
        client: BridgeClient,
        *,
        client_label: str = DEFAULT_MCP_CLIENT_LABEL,
        timeout_s: float = DEFAULT_AUTHORIZATION_TIMEOUT_S,
        poll_interval_s: float = DEFAULT_AUTHORIZATION_POLL_INTERVAL_S,
    ) -> None:
        if timeout_s <= 0:
            raise ValueError("timeout_s must be positive")
        if poll_interval_s <= 0:
            raise ValueError("poll_interval_s must be positive")
        self._client = client
        self._client_label = client_label
        self._timeout_s = timeout_s
        self._poll_interval_s = poll_interval_s

    def authorize(
        self,
        device_id: str,
        *,
        requested_method: str,
        requested_path: str,
    ) -> dict[str, Any]:
        """Wait for App approval and persist the claimed token through the client.

        The return value is the successful ``/auth/claim`` body.  It never
        exposes the token in logs or error messages; token persistence remains
        the responsibility of the injected token provider.
        """
        nonce = secrets.token_urlsafe(32)
        request = self._client.auth_request(
            device_id,
            nonce,
            client_label=self._client_label,
            requested_method=requested_method,
            requested_path=requested_path,
        )
        request_id = request.get("requestId") if isinstance(request, dict) else None
        if not isinstance(request_id, str) or not request_id:
            raise AuthorizationFlowError(
                "invalid_request_response",
                "App returned an invalid authorization request response",
            )

        deadline = time.monotonic() + self._timeout_s
        while time.monotonic() < deadline:
            status_body = self._client.auth_status(device_id, request_id, nonce)
            status = status_body.get("status") if isinstance(status_body, dict) else None
            if status == "approved":
                claim = self._client.auth_claim(device_id, request_id, nonce)
                token = claim.get("token") if isinstance(claim, dict) else None
                if not isinstance(token, str) or not token:
                    raise AuthorizationFlowError(
                        "invalid_claim_response",
                        "App approved authorization but did not issue a token",
                    )
                return claim
            if status == "denied":
                raise AuthorizationFlowError(
                    "authorization_denied", "authorization was denied in the App"
                )
            if status == "expired":
                raise AuthorizationFlowError(
                    "authorization_expired", "authorization request expired in the App"
                )
            if status != "pending":
                raise AuthorizationFlowError(
                    "invalid_status_response",
                    "App returned an invalid authorization status response",
                )
            time.sleep(self._poll_interval_s)

        raise AuthorizationFlowError(
            "authorization_timeout",
            "authorization was not approved in the App before the timeout",
        )
