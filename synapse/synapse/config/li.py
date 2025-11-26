"""
LI configuration for Synapse.
"""

from typing import Any
from synapse.config._base import Config


class LIConfig(Config):
    """LI-specific configuration."""

    section = "li"

    def read_config(self, config: dict, **kwargs: Any) -> None:
        li_config = config.get("li") or {}

        self.enabled = li_config.get("enabled", False)
        self.key_vault_url = li_config.get(
            "key_vault_url",
            "http://key-vault.matrix-li.svc.cluster.local:8000"
        )
        # LI: Endpoint protection (ban room forget and account deactivation for non-admins)
        self.endpoint_protection_enabled = li_config.get("endpoint_protection_enabled", True)

    def generate_config_section(self, **kwargs: Any) -> str:
        return """\
        # Lawful Interception Configuration
        li:
          # Enable LI proxy endpoints
          enabled: false

          # key_vault Django service URL (hidden instance network)
          # Only main Synapse can access this URL
          key_vault_url: "http://key-vault.matrix-li.svc.cluster.local:8000"

          # Endpoint protection: Prevent users from removing rooms or deactivating accounts
          # When enabled, only server administrators can:
          # - Forget rooms (remove from room list)
          # - Deactivate user accounts
          # This ensures rooms and accounts remain accessible for lawful interception.
          # Default: true
          endpoint_protection_enabled: true
        """
