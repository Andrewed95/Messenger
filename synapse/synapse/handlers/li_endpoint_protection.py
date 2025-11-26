"""
LI Endpoint Protection

Provides protection for sensitive user endpoints to prevent unauthorized actions.
Only administrators can perform protected actions.

Protected endpoints:
- Room forget: Users cannot forget rooms (remove from room list)
- Account deactivation: Users cannot deactivate their own accounts

This ensures:
- Rooms remain visible for lawful interception purposes
- User accounts cannot be self-deactivated to avoid investigation
"""

import logging
from typing import TYPE_CHECKING, Optional

if TYPE_CHECKING:
    from synapse.server import HomeServer
    from synapse.types import UserID

logger = logging.getLogger(__name__)


class EndpointProtection:
    """
    LI: Endpoint protection handler.

    Checks if a user is authorized to perform protected actions.
    Only server administrators are allowed to:
    - Forget rooms (remove from room list)
    - Deactivate accounts

    Regular users are blocked from these operations.
    """

    def __init__(self, hs: "HomeServer"):
        self._store = hs.get_datastores().main
        self._auth = hs.get_auth()
        self._enabled = hs.config.li.endpoint_protection_enabled

    async def check_can_forget_room(self, user_id: str) -> bool:
        """
        LI: Check if user can forget a room.

        Args:
            user_id: The user attempting to forget the room

        Returns:
            True if user can forget the room, False otherwise

        Notes:
            - If endpoint protection is disabled, always returns True
            - If user is a server admin, returns True
            - Otherwise, returns False (user is blocked from forgetting rooms)
        """
        # LI: If protection is disabled, allow all operations
        if not self._enabled:
            return True

        # LI: Check if user is a server admin
        is_admin = await self._store.is_server_admin(user_id)

        if is_admin:
            logger.debug(f"LI: Admin {user_id} allowed to forget room")
            return True

        # LI: Regular user - block operation
        logger.warning(
            f"LI: Blocked non-admin user {user_id} from forgetting room. "
            f"Only administrators can remove rooms from view."
        )
        return False

    async def check_can_deactivate_account(
        self,
        user_id: str,
        requester_user_id: Optional[str] = None
    ) -> bool:
        """
        LI: Check if user can deactivate an account.

        Args:
            user_id: The account being deactivated
            requester_user_id: The user requesting the deactivation (if different from user_id)

        Returns:
            True if deactivation is allowed, False otherwise

        Notes:
            - If endpoint protection is disabled, always returns True
            - If requester is a server admin, returns True (admin deactivating any account)
            - If user is deactivating their own account and they're an admin, returns True
            - Otherwise, returns False (user cannot deactivate accounts)
        """
        # LI: If protection is disabled, allow all operations
        if not self._enabled:
            return True

        # LI: Determine who is making the request
        if requester_user_id is None:
            requester_user_id = user_id

        # LI: Check if requester is a server admin
        is_admin = await self._store.is_server_admin(requester_user_id)

        if is_admin:
            logger.debug(
                f"LI: Admin {requester_user_id} allowed to deactivate account {user_id}"
            )
            return True

        # LI: Regular user trying to deactivate account (self or other) - block operation
        if requester_user_id == user_id:
            logger.warning(
                f"LI: Blocked user {user_id} from deactivating their own account. "
                f"Only administrators can deactivate accounts."
            )
        else:
            logger.warning(
                f"LI: Blocked user {requester_user_id} from deactivating account {user_id}. "
                f"Only administrators can deactivate accounts."
            )

        return False
