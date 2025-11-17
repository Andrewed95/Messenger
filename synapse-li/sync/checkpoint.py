"""
File-based sync checkpoint tracking.

Uses JSON file to avoid modifying Synapse database schema.
"""

import json
import logging
from pathlib import Path
from datetime import datetime
from typing import Optional

logger = logging.getLogger(__name__)

CHECKPOINT_FILE = Path('/var/lib/synapse-li/sync_checkpoint.json')


class SyncCheckpoint:
    """Tracks last successful sync position using JSON file."""

    def __init__(self):
        self.file_path = CHECKPOINT_FILE
        self.file_path.parent.mkdir(parents=True, exist_ok=True)

        if not self.file_path.exists():
            self._initialize()

    def _initialize(self):
        """Create initial checkpoint file."""
        initial_data = {
            'pg_lsn': '0/0',
            'last_media_sync_ts': datetime.now().isoformat(),
            'last_sync_at': None,
            'total_syncs': 0,
            'failed_syncs': 0
        }
        self._write(initial_data)
        logger.info("LI: Initialized sync checkpoint file")

    def _read(self) -> dict:
        """Read checkpoint from file."""
        try:
            with open(self.file_path, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"LI: Failed to read checkpoint file: {e}")
            raise

    def _write(self, data: dict):
        """Write checkpoint to file."""
        try:
            # Write to temp file first, then atomic rename
            temp_file = self.file_path.with_suffix('.tmp')
            with open(temp_file, 'w') as f:
                json.dump(data, f, indent=2)
            temp_file.replace(self.file_path)

            logger.debug(f"LI: Updated checkpoint file")
        except Exception as e:
            logger.error(f"LI: Failed to write checkpoint file: {e}")
            raise

    def get_checkpoint(self) -> dict:
        """Get current checkpoint data."""
        return self._read()

    def update_checkpoint(self, pg_lsn: str, media_ts: str):
        """Update checkpoint after successful sync."""
        data = self._read()
        data['pg_lsn'] = pg_lsn
        data['last_media_sync_ts'] = media_ts
        data['last_sync_at'] = datetime.now().isoformat()
        data['total_syncs'] += 1
        self._write(data)

        logger.info(
            f"LI: Sync checkpoint updated - LSN: {pg_lsn}, "
            f"total syncs: {data['total_syncs']}"
        )

    def mark_failed(self):
        """Mark sync as failed."""
        data = self._read()
        data['failed_syncs'] += 1
        self._write(data)

        logger.warning(f"LI: Sync marked as failed - total failures: {data['failed_syncs']}")
