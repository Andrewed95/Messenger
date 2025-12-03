"""
LI Sync System

This package provides synchronization functionality for keeping the LI instance
database in sync with the main production instance using pg_dump/pg_restore.

Components:
- checkpoint: Track sync progress and statistics
- lock: Prevent concurrent sync operations
- sync_task: Main orchestration for database synchronization

Per CLAUDE.md:
- Uses pg_dump/pg_restore for full database synchronization
- Each sync completely overwrites the LI database
- LI uses shared MinIO for media (no media sync needed)
- Sync interval configurable via Kubernetes CronJob
- Manual sync trigger available from synapse-admin-li
"""

from .checkpoint import SyncCheckpoint
from .lock import SyncLock

__all__ = ['SyncCheckpoint', 'SyncLock']
