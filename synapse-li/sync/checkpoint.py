"""
File-based sync checkpoint tracking for pg_dump/pg_restore synchronization.

Uses JSON file to track sync progress and statistics.
"""

import json
import logging
from pathlib import Path
from datetime import datetime
from typing import Optional

logger = logging.getLogger(__name__)

CHECKPOINT_FILE = Path('/var/lib/synapse-li/sync_checkpoint.json')


class SyncCheckpoint:
    """Tracks sync progress and statistics using JSON file."""

    def __init__(self):
        self.file_path = CHECKPOINT_FILE
        self.file_path.parent.mkdir(parents=True, exist_ok=True)

        if not self.file_path.exists():
            self._initialize()

    def _initialize(self):
        """Create initial checkpoint file."""
        initial_data = {
            'last_sync_at': None,
            'last_sync_status': 'never',
            'last_dump_size_mb': None,
            'last_duration_seconds': None,
            'last_error': None,
            'total_syncs': 0,
            'failed_syncs': 0,
            'created_at': datetime.now().isoformat()
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
        """Write checkpoint to file atomically."""
        try:
            # Write to temp file first, then atomic rename
            temp_file = self.file_path.with_suffix('.tmp')
            with open(temp_file, 'w') as f:
                json.dump(data, f, indent=2)
            temp_file.replace(self.file_path)

            logger.debug("LI: Updated checkpoint file")
        except Exception as e:
            logger.error(f"LI: Failed to write checkpoint file: {e}")
            raise

    def get_checkpoint(self) -> dict:
        """Get current checkpoint data."""
        return self._read()

    def update_checkpoint(self, dump_size_mb: float, duration_seconds: float):
        """
        Update checkpoint after successful sync.

        Args:
            dump_size_mb: Size of the database dump in MB
            duration_seconds: Total sync duration in seconds
        """
        data = self._read()
        data['last_sync_at'] = datetime.now().isoformat()
        data['last_sync_status'] = 'success'
        data['last_dump_size_mb'] = dump_size_mb
        data['last_duration_seconds'] = duration_seconds
        data['last_error'] = None
        data['total_syncs'] += 1
        self._write(data)

        logger.info(
            f"LI: Sync checkpoint updated - "
            f"dump size: {dump_size_mb:.2f} MB, "
            f"duration: {duration_seconds:.1f}s, "
            f"total syncs: {data['total_syncs']}"
        )

    def mark_failed(self, error_message: str = None):
        """
        Mark sync as failed.

        Args:
            error_message: Optional error message to record
        """
        data = self._read()
        data['last_sync_status'] = 'failed'
        data['last_error'] = error_message
        data['failed_syncs'] += 1
        self._write(data)

        logger.warning(
            f"LI: Sync marked as failed - "
            f"error: {error_message}, "
            f"total failures: {data['failed_syncs']}"
        )

    def get_last_sync_info(self) -> dict:
        """
        Get information about the last sync.

        Returns:
            Dictionary with last sync details
        """
        data = self._read()
        return {
            'last_sync_at': data.get('last_sync_at'),
            'status': data.get('last_sync_status', 'unknown'),
            'dump_size_mb': data.get('last_dump_size_mb'),
            'duration_seconds': data.get('last_duration_seconds'),
            'error': data.get('last_error')
        }

    def get_statistics(self) -> dict:
        """
        Get sync statistics.

        Returns:
            Dictionary with sync statistics
        """
        data = self._read()
        return {
            'total_syncs': data.get('total_syncs', 0),
            'failed_syncs': data.get('failed_syncs', 0),
            'success_rate': (
                data.get('total_syncs', 0) /
                (data.get('total_syncs', 0) + data.get('failed_syncs', 0))
                if (data.get('total_syncs', 0) + data.get('failed_syncs', 0)) > 0
                else 0
            ),
            'created_at': data.get('created_at')
        }
