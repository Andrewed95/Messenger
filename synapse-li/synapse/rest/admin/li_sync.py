#
# LI: Database Sync REST API
#
# This file provides REST endpoints for triggering and monitoring
# LI database synchronization from synapse-admin-li.
#
# Endpoints:
#   GET  /_synapse/admin/v1/li/sync/status  - Get sync status
#   POST /_synapse/admin/v1/li/sync/trigger - Trigger new sync
#
# Per CLAUDE.md section 3.3:
# - Manual sync trigger available from synapse-admin-li
# - At most one sync process runs at any time (file lock)
#

import logging
import os
import subprocess
import threading
import traceback
from http import HTTPStatus
from pathlib import Path
from typing import TYPE_CHECKING

from synapse.http.servlet import RestServlet
from synapse.http.site import SynapseRequest
from synapse.rest.admin._base import admin_patterns, assert_requester_is_admin
from synapse.types import JsonDict

if TYPE_CHECKING:
    from synapse.server import HomeServer

logger = logging.getLogger(__name__)

# Sync configuration from environment
SYNC_DIR = Path(os.environ.get('LI_SYNC_DIR', '/var/lib/synapse-li/sync'))
LOCK_FILE = SYNC_DIR / 'sync.lock'
CHECKPOINT_FILE = SYNC_DIR / 'sync_checkpoint.json'

# Database configuration
MAIN_DB_HOST = os.environ.get('MAIN_DB_HOST', 'matrix-postgresql-rw.matrix.svc.cluster.local')
MAIN_DB_PORT = os.environ.get('MAIN_DB_PORT', '5432')
MAIN_DB_NAME = os.environ.get('MAIN_DB_NAME', 'matrix')
MAIN_DB_USER = os.environ.get('MAIN_DB_USER', 'synapse')
MAIN_DB_PASSWORD = os.environ.get('MAIN_DB_PASSWORD', '')

LI_DB_HOST = os.environ.get('LI_DB_HOST', 'matrix-postgresql-li-rw.matrix.svc.cluster.local')
LI_DB_PORT = os.environ.get('LI_DB_PORT', '5432')
LI_DB_NAME = os.environ.get('LI_DB_NAME', 'matrix_li')
LI_DB_USER = os.environ.get('LI_DB_USER', 'synapse_li')
LI_DB_PASSWORD = os.environ.get('LI_DB_PASSWORD', '')

DUMP_FILE = SYNC_DIR / 'main_db_dump.sql'


def _is_sync_running() -> bool:
    """Check if sync is currently running by testing the lock file."""
    import fcntl
    fd = None
    try:
        SYNC_DIR.mkdir(parents=True, exist_ok=True)
        fd = open(LOCK_FILE, 'w')
        fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
        return False
    except IOError:
        return True
    finally:
        if fd is not None:
            fd.close()


def _get_checkpoint() -> dict:
    """Read checkpoint file."""
    import json
    try:
        if CHECKPOINT_FILE.exists():
            return json.loads(CHECKPOINT_FILE.read_text())
    except Exception:
        pass
    return {
        'last_sync_at': None,
        'last_sync_status': 'never',
        'total_syncs': 0,
        'failed_syncs': 0,
    }


def _update_checkpoint(status: str, dump_size_mb: float = None,
                       duration_seconds: float = None, error: str = None) -> None:
    """Update checkpoint file."""
    import json
    from datetime import datetime

    checkpoint = _get_checkpoint()
    checkpoint['last_sync_at'] = datetime.now().isoformat()
    checkpoint['last_sync_status'] = status

    if status == 'success':
        checkpoint['total_syncs'] = checkpoint.get('total_syncs', 0) + 1
        checkpoint['last_dump_size_mb'] = dump_size_mb
        checkpoint['last_duration_seconds'] = duration_seconds
        checkpoint['last_error'] = None
    elif status == 'failed':
        checkpoint['failed_syncs'] = checkpoint.get('failed_syncs', 0) + 1
        checkpoint['last_error'] = error

    SYNC_DIR.mkdir(parents=True, exist_ok=True)
    CHECKPOINT_FILE.write_text(json.dumps(checkpoint, indent=2))


def _run_sync_task() -> None:
    """
    Execute the sync process in background thread.
    Uses pg_dump/pg_restore for full database synchronization.
    """
    import fcntl
    from datetime import datetime

    lock_fd = None
    start_time = datetime.now()

    try:
        # Acquire lock
        SYNC_DIR.mkdir(parents=True, exist_ok=True)
        lock_fd = open(LOCK_FILE, 'w')
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        logger.info("LI: Sync lock acquired, starting database sync")

        # Step 1: pg_dump from main database
        logger.info(f"LI: Starting pg_dump from {MAIN_DB_HOST}:{MAIN_DB_PORT}/{MAIN_DB_NAME}")
        env = os.environ.copy()
        env['PGPASSWORD'] = MAIN_DB_PASSWORD

        dump_cmd = [
            'pg_dump',
            '-h', MAIN_DB_HOST,
            '-p', MAIN_DB_PORT,
            '-U', MAIN_DB_USER,
            '-d', MAIN_DB_NAME,
            '--clean', '--if-exists', '--no-owner', '--no-privileges',
            '-f', str(DUMP_FILE)
        ]

        result = subprocess.run(dump_cmd, env=env, capture_output=True, text=True, timeout=3600)
        if result.returncode != 0:
            raise RuntimeError(f"pg_dump failed: {result.stderr}")

        if not DUMP_FILE.exists() or DUMP_FILE.stat().st_size == 0:
            raise RuntimeError("pg_dump created empty dump file")

        dump_size_mb = DUMP_FILE.stat().st_size / 1024 / 1024
        logger.info(f"LI: pg_dump completed ({dump_size_mb:.2f} MB)")

        # Step 2: pg_restore to LI database
        logger.info(f"LI: Starting pg_restore to {LI_DB_HOST}:{LI_DB_PORT}/{LI_DB_NAME}")
        env['PGPASSWORD'] = LI_DB_PASSWORD

        restore_cmd = [
            'psql',
            '-h', LI_DB_HOST,
            '-p', LI_DB_PORT,
            '-U', LI_DB_USER,
            '-d', LI_DB_NAME,
            '-f', str(DUMP_FILE),
            '--quiet', '--single-transaction'
        ]

        result = subprocess.run(restore_cmd, env=env, capture_output=True, text=True, timeout=7200)
        # psql may return non-zero for non-critical warnings
        if result.returncode != 0 and ("FATAL" in result.stderr or "PANIC" in result.stderr):
            raise RuntimeError(f"pg_restore failed: {result.stderr}")

        logger.info("LI: pg_restore completed")

        # Step 3: Cleanup and update checkpoint
        if DUMP_FILE.exists():
            DUMP_FILE.unlink()

        duration = (datetime.now() - start_time).total_seconds()
        _update_checkpoint('success', dump_size_mb, duration)

        logger.info(f"LI: Database sync completed successfully in {duration:.1f}s")

    except Exception as e:
        error_msg = str(e)
        logger.error(f"LI: Database sync failed: {error_msg}", exc_info=True)
        _update_checkpoint('failed', error=error_msg)

        # Cleanup on failure
        try:
            if DUMP_FILE.exists():
                DUMP_FILE.unlink()
        except Exception:
            pass

    finally:
        # Release lock
        if lock_fd:
            try:
                import fcntl
                fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
                lock_fd.close()
                logger.info("LI: Sync lock released")
            except Exception:
                pass


class LISyncStatusRestServlet(RestServlet):
    """
    LI: Get current sync status.

    GET /_synapse/admin/v1/li/sync/status

    Returns:
        {
            "is_running": bool,
            "last_sync_at": string | null,
            "last_sync_status": "success" | "failed" | "never",
            "last_dump_size_mb": float | null,
            "last_duration_seconds": float | null,
            "last_error": string | null,
            "total_syncs": int,
            "failed_syncs": int
        }
    """

    PATTERNS = admin_patterns("/li/sync/status$")

    def __init__(self, hs: "HomeServer"):
        self.auth = hs.get_auth()

    async def on_GET(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        await assert_requester_is_admin(self.auth, request)

        checkpoint = _get_checkpoint()

        return HTTPStatus.OK, {
            'is_running': _is_sync_running(),
            'last_sync_at': checkpoint.get('last_sync_at'),
            'last_sync_status': checkpoint.get('last_sync_status', 'never'),
            'last_dump_size_mb': checkpoint.get('last_dump_size_mb'),
            'last_duration_seconds': checkpoint.get('last_duration_seconds'),
            'last_error': checkpoint.get('last_error'),
            'total_syncs': checkpoint.get('total_syncs', 0),
            'failed_syncs': checkpoint.get('failed_syncs', 0),
        }


class LISyncTriggerRestServlet(RestServlet):
    """
    LI: Trigger database sync from main to LI instance.

    POST /_synapse/admin/v1/li/sync/trigger

    Returns:
        - 202 Accepted: Sync started successfully
          {"started": true, "message": "Sync started"}

        - 409 Conflict: Sync already in progress
          {"started": false, "is_running": true, "message": "Sync already in progress"}

        - 500 Error: Failed to start sync
          {"started": false, "error": "...", "stack_trace": "..."}
    """

    PATTERNS = admin_patterns("/li/sync/trigger$")

    def __init__(self, hs: "HomeServer"):
        self.auth = hs.get_auth()

    async def on_POST(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        await assert_requester_is_admin(self.auth, request)

        # Check if sync is already running
        if _is_sync_running():
            logger.info("LI: Sync trigger rejected - sync already in progress")
            return HTTPStatus.CONFLICT, {
                'started': False,
                'is_running': True,
                'message': 'Sync already in progress',
            }

        # Start sync in background thread
        try:
            logger.info("LI: Starting sync via admin API")
            thread = threading.Thread(target=_run_sync_task, daemon=True)
            thread.start()

            return HTTPStatus.ACCEPTED, {
                'started': True,
                'message': 'Sync started',
            }

        except Exception as e:
            error_msg = str(e)
            stack_trace = traceback.format_exc()
            logger.error(f"LI: Failed to start sync: {error_msg}", exc_info=True)

            return HTTPStatus.INTERNAL_SERVER_ERROR, {
                'started': False,
                'error': error_msg,
                'stack_trace': stack_trace,
            }
