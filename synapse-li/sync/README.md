# LI Sync System

This directory contains the synchronization system for keeping the LI instance database in sync with the main production instance using **pg_dump/pg_restore**.

## Overview

The sync system maintains database consistency between:
- **Main Instance**: Production Synapse server with PostgreSQL and MinIO
- **LI Instance**: Lawful Intercept Synapse server (synapse-li) with its own PostgreSQL

Per CLAUDE.md section 3.3 and 7.2:
- Uses **pg_dump/pg_restore** for full database synchronization
- Each sync **completely overwrites** the LI database with a fresh copy from main
- Any changes made in LI (such as password resets) are **lost after the next sync**
- LI uses **shared MinIO** for media (no media sync needed)
- Sync interval is configurable via Kubernetes CronJob
- Manual sync trigger available from synapse-admin-li

## Components

### 1. `checkpoint.py`
File-based checkpoint tracking to record sync progress and statistics.

**Storage**: `/var/lib/synapse-li/sync_checkpoint.json`

**Fields**:
- `last_sync_at`: When sync last completed
- `last_sync_status`: 'success', 'failed', or 'never'
- `last_dump_size_mb`: Size of database dump in MB
- `last_duration_seconds`: Total sync duration
- `last_error`: Error message from last failed sync
- `total_syncs`: Total successful syncs
- `failed_syncs`: Total failed syncs

### 2. `lock.py`
File-based locking mechanism to prevent concurrent sync operations.

**Lock File**: `/var/lib/synapse-li/sync.lock`

Uses `fcntl` for atomic file locking. At any time, there must be **at most one sync process** in progress.

### 3. `sync_task.py`
Main orchestration script that:
1. Acquires sync lock (prevents concurrent syncs)
2. Performs pg_dump from main PostgreSQL
3. Performs pg_restore to LI PostgreSQL (full replacement)
4. Updates checkpoint

**Usage**:
```bash
# Run sync
python3 sync_task.py

# Check sync status
python3 sync_task.py --status
```

## Prerequisites

### PostgreSQL Access

The sync system requires access to both databases:

1. **Main PostgreSQL** (read access for pg_dump)
2. **LI PostgreSQL** (write access for pg_restore)

### Required Tools

The synapse-li container must have these tools installed:
- `pg_dump` (PostgreSQL client tools)
- `psql` (PostgreSQL client)

### Environment Variables

Required environment variables:

```bash
# Main PostgreSQL (source)
MAIN_DB_HOST=matrix-postgresql-rw.matrix.svc.cluster.local
MAIN_DB_PORT=5432
MAIN_DB_NAME=matrix
MAIN_DB_USER=synapse
MAIN_DB_PASSWORD=<password>

# LI PostgreSQL (destination)
LI_DB_HOST=matrix-postgresql-li-rw.matrix.svc.cluster.local
LI_DB_PORT=5432
LI_DB_NAME=matrix_li
LI_DB_USER=synapse_li
LI_DB_PASSWORD=<password>
```

## Running the Sync

### Manual Sync

```bash
cd /home/user/Messenger/synapse-li/sync
export MAIN_DB_PASSWORD="<main_password>"
export LI_DB_PASSWORD="<li_password>"
python3 sync_task.py
```

### Kubernetes CronJob

In production, sync is triggered by a Kubernetes CronJob defined in the deployment manifests.

Default schedule: Every 6 hours (configurable)

### Manual Trigger from synapse-admin-li

The sync can be triggered manually from the synapse-admin-li interface via a "Sync Now" button.

## Monitoring

### Check Sync Status

```bash
# View checkpoint file
cat /var/lib/synapse-li/sync_checkpoint.json

# Get status via sync_task.py
python3 sync_task.py --status
```

### Check Lock Status

```bash
# Check if sync is currently running
ls -la /var/lib/synapse-li/sync.lock
```

## Troubleshooting

### pg_dump Fails

If pg_dump fails:

1. Check network connectivity to main PostgreSQL
2. Verify credentials and permissions:
   ```bash
   psql -h $MAIN_DB_HOST -U $MAIN_DB_USER -d $MAIN_DB_NAME -c "SELECT 1"
   ```
3. Check available disk space for dump file
4. Review error message in checkpoint file

### pg_restore Fails

If pg_restore fails:

1. Check network connectivity to LI PostgreSQL
2. Verify credentials and permissions
3. Check if LI database exists
4. Review error message in checkpoint file

### Lock File Issues

If sync is stuck with lock held:

1. Check if sync process is actually running: `ps aux | grep sync_task`
2. If not running, manually remove lock: `rm /var/lib/synapse-li/sync.lock`
3. Investigate why previous sync didn't release lock (check logs)

### Sync Takes Too Long

For large databases, sync may take significant time:

1. Monitor progress via logs
2. Consider increasing timeout values in `sync_task.py`
3. Ensure adequate network bandwidth between database servers
4. Consider running sync during low-usage periods

## Security Considerations

1. **Credentials**: Store database credentials securely (Kubernetes secrets)
2. **Audit Logs**: All sync operations are logged with `LI:` prefix for audit trail
3. **One-Way Sync**: Sync is always main → LI, never the reverse
4. **Full Replacement**: Each sync completely replaces LI database - any local changes are lost

## Media Storage

Per CLAUDE.md section 7.5, the LI instance uses **shared MinIO** for media:

- LI Synapse connects directly to main MinIO
- No media sync is needed
- Media is read-only for LI in practice
- LI admins must NOT delete or modify media files (affects main instance)

## Integration with synapse-admin-li

The sync system can be triggered from synapse-admin-li via a "Sync Now" button.

The synapse-admin-li interface:
1. Calls the sync API endpoint
2. Displays sync status (running, last sync time, errors)
3. Shows progress during sync operation

See the synapse-admin-li documentation for details on the admin interface integration.
