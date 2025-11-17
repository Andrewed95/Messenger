#!/usr/bin/env python3
"""
LI: Monitor PostgreSQL logical replication lag and health.

This script checks the status of PostgreSQL logical replication from the main
instance to the hidden instance. It queries the replication slot to check lag
and active status.

Run as a standalone script or via Celery task.
"""

import logging
import os
import subprocess
from typing import Optional, Tuple

logger = logging.getLogger(__name__)


def monitor_postgresql_replication(from_lsn: str = "0/0") -> str:
    """
    Monitor PostgreSQL logical replication status.

    Returns current LSN position.

    Note: Logical replication runs continuously via PostgreSQL subscription.
    This function just monitors the status.
    """
    logger.info(f"LI: Monitoring PostgreSQL replication from LSN {from_lsn}")

    try:
        # Query replication lag from the hidden instance database
        cmd = [
            'psql',
            '-h', os.environ.get('SYNAPSE_DB_HOST', 'synapse-postgres-li-rw.matrix-li.svc.cluster.local'),
            '-U', os.environ.get('SYNAPSE_DB_USER', 'synapse'),
            '-d', os.environ.get('SYNAPSE_DB_NAME', 'synapse'),
            '-t',  # Tuples only (no headers)
            '-c', "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='hidden_instance_sub'"
        ]

        # Set password via environment variable
        env = os.environ.copy()
        if 'SYNAPSE_DB_PASSWORD' in env:
            env['PGPASSWORD'] = env['SYNAPSE_DB_PASSWORD']

        result = subprocess.run(cmd, capture_output=True, text=True, check=True, env=env)

        # Extract LSN from output
        current_lsn = result.stdout.strip()

        if current_lsn:
            logger.info(f"LI: PostgreSQL replication at LSN {current_lsn}")
            return current_lsn
        else:
            logger.warning(f"LI: Could not get current LSN, using previous: {from_lsn}")
            return from_lsn

    except subprocess.CalledProcessError as e:
        logger.error(f"LI: Failed to query replication status: {e.stderr}")
        return from_lsn
    except Exception as e:
        logger.error(f"LI: Error monitoring replication: {e}")
        return from_lsn


def check_replication_health() -> Tuple[bool, Optional[dict]]:
    """
    Check overall replication health and return status.

    Returns:
        Tuple of (healthy: bool, stats: dict)
    """
    logger.info("LI: Checking replication health")

    try:
        # Check replication lag in bytes
        cmd = [
            'psql',
            '-h', os.environ.get('SYNAPSE_DB_HOST', 'synapse-postgres-li-rw.matrix-li.svc.cluster.local'),
            '-U', os.environ.get('SYNAPSE_DB_USER', 'synapse'),
            '-d', os.environ.get('SYNAPSE_DB_NAME', 'synapse'),
            '-t',
            '-c', """
                SELECT
                    slot_name,
                    active,
                    restart_lsn,
                    confirmed_flush_lsn,
                    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes
                FROM pg_replication_slots
                WHERE slot_name = 'hidden_instance_sub';
            """
        ]

        env = os.environ.copy()
        if 'SYNAPSE_DB_PASSWORD' in env:
            env['PGPASSWORD'] = env['SYNAPSE_DB_PASSWORD']

        result = subprocess.run(cmd, capture_output=True, text=True, check=True, env=env)

        if not result.stdout.strip():
            logger.error("LI: Replication slot not found!")
            return False, None

        # Parse output
        parts = result.stdout.strip().split('|')
        if len(parts) >= 5:
            slot_name = parts[0].strip()
            active = parts[1].strip() == 't'
            restart_lsn = parts[2].strip()
            confirmed_flush_lsn = parts[3].strip()
            lag_bytes = int(parts[4].strip()) if parts[4].strip() else 0

            stats = {
                'slot_name': slot_name,
                'active': active,
                'restart_lsn': restart_lsn,
                'confirmed_flush_lsn': confirmed_flush_lsn,
                'lag_bytes': lag_bytes,
                'lag_mb': lag_bytes / (1024 * 1024) if lag_bytes else 0
            }

            if not active:
                logger.error("LI: Replication slot is inactive!")
                return False, stats

            if stats['lag_mb'] > 100:
                logger.warning(f"LI: High replication lag detected: {stats['lag_mb']:.2f} MB")
                # In production, send alert here (email, Slack, etc.)

            logger.info(f"LI: Replication healthy - lag: {stats['lag_mb']:.2f} MB")
            return True, stats
        else:
            logger.error("LI: Unexpected query output format")
            return False, None

    except subprocess.CalledProcessError as e:
        logger.error(f"LI: Failed to check replication health: {e.stderr}")
        return False, None
    except Exception as e:
        logger.error(f"LI: Error checking replication health: {e}")
        return False, None


if __name__ == "__main__":
    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )

    # Check replication health
    healthy, stats = check_replication_health()

    if healthy and stats:
        print(f"✓ Replication healthy")
        print(f"  Lag: {stats['lag_mb']:.2f} MB")
        print(f"  LSN: {stats['confirmed_flush_lsn']}")
    else:
        print("✗ Replication unhealthy or unavailable")
        exit(1)
