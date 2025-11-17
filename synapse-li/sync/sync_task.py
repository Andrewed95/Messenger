#!/usr/bin/env python3
"""
LI: Main sync task that orchestrates database and media synchronization.

This script:
1. Acquires a lock to prevent concurrent syncs
2. Monitors PostgreSQL replication status
3. Syncs media files via rclone
4. Updates checkpoint after successful sync

Can be run manually or via Celery/cron.
"""

import logging
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent))

from checkpoint import SyncCheckpoint
from lock import SyncLock
from monitor_replication import monitor_postgresql_replication, check_replication_health

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

logger = logging.getLogger(__name__)


def sync_media_files(since_ts: str = None) -> str:
    """
    Sync media files from main MinIO to hidden MinIO using rclone.

    Args:
        since_ts: Optional timestamp to only sync files modified after this time

    Returns:
        New timestamp after sync
    """
    logger.info(f"LI: Syncing media files" + (f" since {since_ts}" if since_ts else ""))

    try:
        # Build command
        script_path = Path(__file__).parent / "sync_media.sh"
        cmd = [str(script_path)]

        if since_ts:
            cmd.extend(['--since', since_ts])

        # Execute sync script
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)

        logger.info(f"LI: Media sync completed: {result.stdout}")
        return datetime.now().isoformat()

    except subprocess.CalledProcessError as e:
        logger.error(f"LI: Media sync failed: {e.stderr}")
        raise
    except Exception as e:
        logger.error(f"LI: Error during media sync: {e}")
        raise


def run_sync() -> dict:
    """
    Execute full sync process.

    Returns:
        Dictionary with sync results
    """
    logger.info("LI: Starting sync task")

    lock = SyncLock()
    checkpoint_mgr = SyncCheckpoint()

    try:
        # Acquire lock
        with lock.lock():
            logger.info("LI: Sync lock acquired")

            # Get checkpoint
            checkpoint = checkpoint_mgr.get_checkpoint()
            last_lsn = checkpoint['pg_lsn']
            last_media_ts = checkpoint['last_media_sync_ts']

            logger.info(
                f"LI: Starting sync from LSN {last_lsn}, "
                f"media timestamp {last_media_ts}"
            )

            # Check PostgreSQL replication health
            healthy, repl_stats = check_replication_health()
            if not healthy:
                raise RuntimeError("PostgreSQL replication is unhealthy")

            # Get current LSN
            new_lsn = repl_stats['confirmed_flush_lsn'] if repl_stats else last_lsn

            # Sync media files
            new_media_ts = sync_media_files(last_media_ts)

            # Update checkpoint
            checkpoint_mgr.update_checkpoint(new_lsn, new_media_ts)

            logger.info("LI: Sync task completed successfully")

            return {
                'status': 'success',
                'new_lsn': new_lsn,
                'new_media_ts': new_media_ts,
                'replication_stats': repl_stats
            }

    except RuntimeError as e:
        # Lock already held
        error_msg = str(e)
        logger.warning(f"LI: Sync task skipped: {error_msg}")

        return {
            'status': 'skipped',
            'reason': error_msg
        }

    except Exception as e:
        # Sync failed
        error_msg = str(e)
        logger.error(f"LI: Sync task failed: {error_msg}", exc_info=True)

        # Mark checkpoint as failed
        checkpoint_mgr.mark_failed()

        return {
            'status': 'failed',
            'error': error_msg
        }


if __name__ == "__main__":
    result = run_sync()

    if result['status'] == 'success':
        print(f"✓ Sync completed successfully")
        print(f"  LSN: {result['new_lsn']}")
        print(f"  Media timestamp: {result['new_media_ts']}")
        if result.get('replication_stats'):
            print(f"  Replication lag: {result['replication_stats']['lag_mb']:.2f} MB")
        exit(0)
    elif result['status'] == 'skipped':
        print(f"⚠ Sync skipped: {result['reason']}")
        exit(0)
    else:
        print(f"✗ Sync failed: {result.get('error', 'Unknown error')}")
        exit(1)
