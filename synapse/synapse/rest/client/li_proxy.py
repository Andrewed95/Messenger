"""
LI Proxy Endpoint for Key Vault

Proxies encrypted key storage requests to key_vault Django service.
Authentication handled by Synapse (access token validation).
"""

import logging
import aiohttp
from typing import TYPE_CHECKING, Tuple

from synapse.http.server import DirectServeJsonResource
from synapse.http.servlet import parse_json_object_from_request, RestServlet
from synapse.types import JsonDict

if TYPE_CHECKING:
    from synapse.server import HomeServer

logger = logging.getLogger(__name__)


class LIProxyServlet(RestServlet):
    """
    Proxy endpoint: POST /_synapse/client/v1/li/store_key

    Validates user auth, then forwards to key_vault.
    """

    PATTERNS = ["/li/store_key$"]

    def __init__(self, hs: "HomeServer"):
        super().__init__()
        self.hs = hs
        self.auth = hs.get_auth()
        self.key_vault_url = hs.config.li.key_vault_url  # From homeserver.yaml

    async def on_POST(self, request) -> Tuple[int, JsonDict]:
        # LI: Validate user authentication
        requester = await self.auth.get_user_by_req(request)
        user_id = requester.user.to_string()

        # LI: Log for audit trail
        logger.info(f"LI: Key storage request from user {user_id}")

        # Parse request body
        body = parse_json_object_from_request(request)

        # Ensure username matches authenticated user (security check)
        if body.get('username') != user_id:
            logger.warning(
                f"LI: Username mismatch - authenticated: {user_id}, "
                f"provided: {body.get('username')}"
            )
            return 403, {"error": "Username mismatch"}

        # LI: Forward to key_vault
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.key_vault_url}/api/v1/store-key",
                    json=body,
                    timeout=aiohttp.ClientTimeout(total=30)
                ) as resp:
                    response_data = await resp.json()

                    # LI: Log result
                    if resp.status in [200, 201]:
                        logger.info(
                            f"LI: Key successfully stored for {user_id}, "
                            f"status={response_data.get('status')}"
                        )
                    else:
                        logger.error(
                            f"LI: Key storage failed for {user_id}, "
                            f"status={resp.status}"
                        )

                    return resp.status, response_data
        except Exception as e:
            logger.error(f"LI: Failed to forward to key_vault for {user_id}: {e}")
            return 500, {"error": "Failed to store key"}


def register_servlets(hs: "HomeServer", http_server: DirectServeJsonResource) -> None:
    """Register LI proxy servlet."""
    LIProxyServlet(hs).register(http_server)
