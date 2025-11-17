"""
LI Session Limiter

Limits the number of active sessions per user using file-based tracking.
Avoids database schema changes by using JSON file storage.
"""

import json
import logging
import fcntl
from pathlib import Path
from typing import Optional, List, Dict

logger = logging.getLogger(__name__)

SESSION_TRACKING_FILE = Path("/var/lib/synapse/li_session_tracking.json")


class SessionLimiter:
    """
    Tracks active sessions per user and enforces limits.

    Uses file-based storage to avoid database migrations.
    Thread-safe via file locking.
    Applies to ALL users without exception.
    """

    def __init__(self, max_sessions: Optional[int]):
        self.max_sessions = max_sessions
        self.tracking_file = SESSION_TRACKING_FILE
        self.tracking_file.parent.mkdir(parents=True, exist_ok=True)

        if not self.tracking_file.exists():
            self._initialize()

    def _initialize(self) -> None:
        """Create initial tracking file."""
        with open(self.tracking_file, 'w') as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
            json.dump({}, f)
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)

        logger.info("LI: Initialized session tracking file")

    def _read_sessions(self) -> Dict[str, List[str]]:
        """Read session tracking data with lock."""
        with open(self.tracking_file, 'r') as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_SH)  # Shared lock for reading
            data = json.load(f)
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
            return data

    def _write_sessions(self, data: Dict[str, List[str]]) -> None:
        """Write session tracking data with lock."""
        # Atomic write with temp file
        temp_file = self.tracking_file.with_suffix('.tmp')

        with open(temp_file, 'w') as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)  # Exclusive lock for writing
            json.dump(data, f, indent=2)
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)

        temp_file.replace(self.tracking_file)

    def check_can_create_session(
        self,
        user_id: str,
        device_id: str
    ) -> bool:
        """
        Check if user can create a new session.

        Returns True if session can be created, False if limit exceeded.
        Applies to ALL users without exception.
        """
        # LI: No limit configured
        if self.max_sessions is None:
            return True

        # Read current sessions
        sessions = self._read_sessions()
        user_sessions = sessions.get(user_id, [])

        # LI: Check if device already exists (device refresh/token renewal)
        if device_id in user_sessions:
            logger.debug(f"LI: Existing session for {user_id}/{device_id}, allowing")
            return True

        # LI: Check session count
        if len(user_sessions) >= self.max_sessions:
            logger.warning(
                f"LI: Session limit exceeded for {user_id} "
                f"({len(user_sessions)}/{self.max_sessions})"
            )
            return False

        return True

    def add_session(self, user_id: str, device_id: str) -> bool:
        """
        Add a new session to tracking.

        Returns True if added, False if limit exceeded.
        Performs final check under lock to handle concurrent logins.
        """
        with open(self.tracking_file, 'r+') as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)  # Exclusive lock

            # Re-read to get latest state
            f.seek(0)
            sessions = json.load(f)

            if user_id not in sessions:
                sessions[user_id] = []

            # Check if already exists
            if device_id in sessions[user_id]:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                return True

            # Re-check limit under lock (handles concurrent logins)
            if self.max_sessions and len(sessions[user_id]) >= self.max_sessions:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                logger.warning(f"LI: Concurrent login blocked for {user_id}")
                return False

            # Add session
            sessions[user_id].append(device_id)

            # Write atomically
            f.seek(0)
            f.truncate()
            json.dump(sessions, f, indent=2)

            fcntl.flock(f.fileno(), fcntl.LOCK_UN)

            logger.info(
                f"LI: Added session {device_id} for {user_id}, "
                f"total: {len(sessions[user_id])}"
            )
            return True

    def remove_session(self, user_id: str, device_id: str) -> None:
        """Remove a session from tracking."""
        sessions = self._read_sessions()

        if user_id in sessions and device_id in sessions[user_id]:
            sessions[user_id].remove(device_id)

            # Clean up empty user entries
            if not sessions[user_id]:
                del sessions[user_id]

            self._write_sessions(sessions)

            logger.info(f"LI: Removed session {device_id} for {user_id}")

    def get_user_sessions(self, user_id: str) -> List[str]:
        """Get list of active sessions for a user."""
        sessions = self._read_sessions()
        return sessions.get(user_id, [])

    def sync_with_database(self, db_devices: Dict[str, List[str]]) -> None:
        """
        Sync session tracking file with database reality.

        Called periodically to ensure consistency.
        Removes sessions that no longer exist in database.
        """
        sessions = self._read_sessions()
        updated = False

        for user_id in list(sessions.keys()):
            user_devices_in_db = db_devices.get(user_id, [])
            tracked_devices = sessions[user_id]

            # Remove devices not in database
            for device_id in tracked_devices[:]:
                if device_id not in user_devices_in_db:
                    sessions[user_id].remove(device_id)
                    updated = True
                    logger.info(
                        f"LI: Removed orphaned session {device_id} for {user_id}"
                    )

            # Clean up empty users
            if not sessions[user_id]:
                del sessions[user_id]
                updated = True

        if updated:
            self._write_sessions(sessions)
            logger.info("LI: Session tracking synced with database")
