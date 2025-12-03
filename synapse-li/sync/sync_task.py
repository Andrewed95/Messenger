#!/usr/bin/env python3
"""
LI: Main sync task that performs full database synchronization using pg_dump/pg_restore.

This script:
1. Acquires a lock to prevent concurrent syncs
2. Performs pg_dump from main PostgreSQL database
3. Performs pg_restore to LI PostgreSQL database (full replacement)
4. Updates checkpoint after successful sync

IMPORTANT: Each sync completely overwrites the LI database with a fresh copy from main.
Any changes made in LI (such as password resets) are lost after the next sync.

Per CLAUDE.md section 3.3:
- Uses pg_dump/pg_restore for full database synchronization
- Sync interval is configurable via Kubernetes CronJob
- Manual sync trigger available from synapse-admin-li
- File lock prevents concurrent syncs
- LI uses shared MinIO for media (no media sync needed)

Can be run manually, via Kubernetes CronJob, or triggered from synapse-admin-li.
"""

import logging
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent))

from checkpoint import SyncCheckpoint
from lock import SyncLock

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

logger = logging.getLogger(__name__)

# Environment variables for database connections
# Main PostgreSQL (source)
MAIN_DB_HOST = os.environ.get('MAIN_DB_HOST', 'matrix-postgresql-rw.matrix.svc.cluster.local')
MAIN_DB_PORT = os.environ.get('MAIN_DB_PORT', '5432')
MAIN_DB_NAME = os.environ.get('MAIN_DB_NAME', 'matrix')
MAIN_DB_USER = os.environ.get('MAIN_DB_USER', 'synapse')
MAIN_DB_PASSWORD = os.environ.get('MAIN_DB_PASSWORD', '')

# LI PostgreSQL (destination)
LI_DB_HOST = os.environ.get('LI_DB_HOST', 'matrix-postgresql-li-rw.matrix.svc.cluster.local')
LI_DB_PORT = os.environ.get('LI_DB_PORT', '5432')
LI_DB_NAME = os.environ.get('LI_DB_NAME', 'matrix_li')
LI_DB_USER = os.environ.get('LI_DB_USER', 'synapse_li')
LI_DB_PASSWORD = os.environ.get('LI_DB_PASSWORD', '')

# Dump file location
DUMP_DIR = Path('/var/lib/synapse-li/sync')
DUMP_FILE = DUMP_DIR / 'main_db_dump.sql'


def pg_dump_main() -> bool:
    """
    Perform pg_dump from main PostgreSQL database.

    Returns:
        True if successful, raises exception on failure
    """
    logger.info(f"LI: Starting pg_dump from main database ({MAIN_DB_HOST}:{MAIN_DB_PORT}/{MAIN_DB_NAME})")

    # Ensure dump directory exists
    DUMP_DIR.mkdir(parents=True, exist_ok=True)

    # Set password via environment
    env = os.environ.copy()
    env['PGPASSWORD'] = MAIN_DB_PASSWORD

    # pg_dump command
    # Using --clean to include DROP statements
    # Using --if-exists to avoid errors on first sync
    # Using --no-owner to avoid ownership issues
    # Using --no-privileges to avoid permission issues
    cmd = [
        'pg_dump',
        '-h', MAIN_DB_HOST,
        '-p', MAIN_DB_PORT,
        '-U', MAIN_DB_USER,
        '-d', MAIN_DB_NAME,
        '--clean',
        '--if-exists',
        '--no-owner',
        '--no-privileges',
        '-f', str(DUMP_FILE)
    ]

    try:
        result = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True,
            check=True,
            timeout=3600  # 1 hour timeout for large databases
        )

        # Check dump file was created and has content
        if not DUMP_FILE.exists():
            raise RuntimeError("pg_dump did not create dump file")

        dump_size = DUMP_FILE.stat().st_size
        if dump_size == 0:
            raise RuntimeError("pg_dump created empty dump file")

        logger.info(f"LI: pg_dump completed successfully ({dump_size / 1024 / 1024:.2f} MB)")
        return True

    except subprocess.TimeoutExpired:
        logger.error("LI: pg_dump timed out after 1 hour")
        raise RuntimeError("pg_dump timed out")
    except subprocess.CalledProcessError as e:
        logger.error(f"LI: pg_dump failed: {e.stderr}")
        raise RuntimeError(f"pg_dump failed: {e.stderr}")


def pg_restore_li() -> bool:
    """
    Perform pg_restore to LI PostgreSQL database.

    This completely replaces the LI database with the dump from main.

    Returns:
        True if successful, raises exception on failure
    """
    logger.info(f"LI: Starting pg_restore to LI database ({LI_DB_HOST}:{LI_DB_PORT}/{LI_DB_NAME})")

    if not DUMP_FILE.exists():
        raise RuntimeError("Dump file not found - run pg_dump first")

    # Set password via environment
    env = os.environ.copy()
    env['PGPASSWORD'] = LI_DB_PASSWORD

    # psql command to execute the dump file
    # Using psql instead of pg_restore because we have a SQL dump
    cmd = [
        'psql',
        '-h', LI_DB_HOST,
        '-p', LI_DB_PORT,
        '-U', LI_DB_USER,
        '-d', LI_DB_NAME,
        '-f', str(DUMP_FILE),
        '--quiet',
        '--single-transaction'  # All or nothing
    ]

    try:
        result = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True,
            check=True,
            timeout=7200  # 2 hour timeout for large restores
        )

        logger.info("LI: pg_restore (psql) completed successfully")
        return True

    except subprocess.TimeoutExpired:
        logger.error("LI: pg_restore timed out after 2 hours")
        raise RuntimeError("pg_restore timed out")
    except subprocess.CalledProcessError as e:
        # psql may return errors for non-critical issues
        # Check if the error is significant
        stderr = e.stderr or ""
        if "FATAL" in stderr or "PANIC" in stderr:
            logger.error(f"LI: pg_restore failed with critical error: {stderr}")
            raise RuntimeError(f"pg_restore failed: {stderr}")
        else:
            # Non-critical warnings (like "table does not exist" during DROP)
            logger.warning(f"LI: pg_restore completed with warnings: {stderr}")
            return True


def cleanup_dump_file():
    """Remove dump file after successful sync."""
    try:
        if DUMP_FILE.exists():
            DUMP_FILE.unlink()
            logger.info("LI: Cleaned up dump file")
    except Exception as e:
        logger.warning(f"LI: Failed to clean up dump file: {e}")


def run_sync() -> dict:
    """
    Execute full sync process using pg_dump/pg_restore.

    Returns:
        Dictionary with sync results:
        - status: 'success', 'skipped', or 'failed'
        - dump_size_mb: Size of dump file in MB (on success)
        - duration_seconds: Total sync duration (on success)
        - error: Error message (on failure)
        - reason: Skip reason (on skipped)
    """
    logger.info("LI: Starting database sync task (pg_dump/pg_restore)")

    lock = SyncLock()
    checkpoint_mgr = SyncCheckpoint()
    start_time = datetime.now()

    try:
        # Acquire lock (non-blocking)
        with lock.lock():
            logger.info("LI: Sync lock acquired")

            # Get current checkpoint for logging
            checkpoint = checkpoint_mgr.get_checkpoint()
            logger.info(f"LI: Previous sync: {checkpoint.get('last_sync_at', 'never')}, "
                       f"total syncs: {checkpoint.get('total_syncs', 0)}")

            # Step 1: pg_dump from main database
            pg_dump_main()
            dump_size = DUMP_FILE.stat().st_size / 1024 / 1024  # MB

            # Step 2: pg_restore to LI database
            pg_restore_li()

            # Step 3: Cleanup dump file
            cleanup_dump_file()

            # Step 4: Update checkpoint
            duration = (datetime.now() - start_time).total_seconds()
            checkpoint_mgr.update_checkpoint(
                dump_size_mb=dump_size,
                duration_seconds=duration
            )

            logger.info(f"LI: Sync completed successfully in {duration:.1f} seconds")

            return {
                'status': 'success',
                'dump_size_mb': dump_size,
                'duration_seconds': duration
            }

    except RuntimeError as e:
        error_msg = str(e)
        if "Sync already in progress" in error_msg:
            # Lock already held
            logger.warning(f"LI: Sync task skipped: {error_msg}")
            return {
                'status': 'skipped',
                'reason': error_msg
            }
        else:
            # Other runtime error
            logger.error(f"LI: Sync task failed: {error_msg}", exc_info=True)
            checkpoint_mgr.mark_failed(error_msg)
            cleanup_dump_file()
            return {
                'status': 'failed',
                'error': error_msg
            }

    except Exception as e:
        # Unexpected error
        error_msg = str(e)
        logger.error(f"LI: Sync task failed unexpectedly: {error_msg}", exc_info=True)
        checkpoint_mgr.mark_failed(error_msg)
        cleanup_dump_file()
        return {
            'status': 'failed',
            'error': error_msg
        }


def get_sync_status() -> dict:
    """
    Get current sync status.

    Returns:
        Dictionary with:
        - is_running: Whether sync is currently in progress
        - last_sync_at: Timestamp of last successful sync
        - last_sync_status: 'success' or 'failed'
        - last_error: Error message from last failed sync (if any)
        - total_syncs: Total number of successful syncs
        - failed_syncs: Total number of failed syncs
    """
    lock = SyncLock()
    checkpoint_mgr = SyncCheckpoint()

    checkpoint = checkpoint_mgr.get_checkpoint()

    return {
        'is_running': lock.is_locked(),
        'last_sync_at': checkpoint.get('last_sync_at'),
        'last_sync_status': checkpoint.get('last_sync_status', 'unknown'),
        'last_error': checkpoint.get('last_error'),
        'total_syncs': checkpoint.get('total_syncs', 0),
        'failed_syncs': checkpoint.get('failed_syncs', 0),
        'last_dump_size_mb': checkpoint.get('last_dump_size_mb'),
        'last_duration_seconds': checkpoint.get('last_duration_seconds')
    }


if __name__ == "__main__":
    # Check for status flag
    if len(sys.argv) > 1 and sys.argv[1] == '--status':
        import json
        status = get_sync_status()
        print(json.dumps(status, indent=2, default=str))
        sys.exit(0)

    # Run sync
    result = run_sync()

    if result['status'] == 'success':
        print(f"✓ Database sync completed successfully")
        print(f"  Dump size: {result['dump_size_mb']:.2f} MB")
        print(f"  Duration: {result['duration_seconds']:.1f} seconds")
        sys.exit(0)
    elif result['status'] == 'skipped':
        print(f"⚠ Sync skipped: {result['reason']}")
        sys.exit(0)
    else:
        print(f"✗ Sync failed: {result.get('error', 'Unknown error')}")
        sys.exit(1)
