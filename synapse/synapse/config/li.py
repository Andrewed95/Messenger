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

    def generate_config_section(self, **kwargs: Any) -> str:
        return """\
        # Lawful Interception Configuration
        li:
          # Enable LI proxy endpoints
          enabled: false

          # key_vault Django service URL (hidden instance network)
          # Only main Synapse can access this URL
          key_vault_url: "http://key-vault.matrix-li.svc.cluster.local:8000"
        """
