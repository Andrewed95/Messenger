"""
File-based lock for sync process.

Uses file locking to prevent concurrent syncs.
"""

import fcntl
import logging
from pathlib import Path
from contextlib import contextmanager

logger = logging.getLogger(__name__)

LOCK_FILE = Path('/var/lib/synapse-li/sync.lock')


class SyncLock:
    """File-based lock for sync process."""

    def __init__(self):
        self.lock_file = LOCK_FILE
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        self.lock_fd = None

    def acquire(self, timeout: int = 0) -> bool:
        """
        Acquire lock for sync process.

        Returns True if lock acquired, False if already locked.
        """
        try:
            self.lock_fd = open(self.lock_file, 'w')
            fcntl.flock(self.lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            logger.info("LI: Sync lock acquired")
            return True
        except IOError:
            logger.warning("LI: Sync already in progress (lock held)")
            return False

    def release(self):
        """Release lock."""
        if self.lock_fd:
            fcntl.flock(self.lock_fd.fileno(), fcntl.LOCK_UN)
            self.lock_fd.close()
            self.lock_fd = None
            logger.info("LI: Sync lock released")

    def is_locked(self) -> bool:
        """Check if lock is currently held."""
        try:
            fd = open(self.lock_file, 'w')
            fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
            fd.close()
            return False
        except IOError:
            return True

    @contextmanager
    def lock(self):
        """Context manager for lock acquisition."""
        if not self.acquire():
            raise RuntimeError("Sync already in progress")
        try:
            yield
        finally:
            self.release()
