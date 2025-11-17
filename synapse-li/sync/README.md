# LI Sync System

This directory contains the synchronization system for keeping the hidden LI instance in sync with the main production instance.

## Overview

The sync system maintains data consistency between:
- **Main Instance**: Production Synapse server with PostgreSQL and MinIO
- **Hidden Instance**: LI-enabled Synapse server (synapse-li) with replicated PostgreSQL and MinIO

## Components

### 1. `checkpoint.py`
File-based checkpoint tracking to record the last successful sync position.

**Storage**: `/var/lib/synapse-li/sync_checkpoint.json`

**Fields**:
- `pg_lsn`: PostgreSQL LSN (Log Sequence Number) of last sync
- `last_media_sync_ts`: Timestamp of last media sync
- `last_sync_at`: When sync last completed
- `total_syncs`: Total successful syncs
- `failed_syncs`: Total failed syncs

### 2. `lock.py`
File-based locking mechanism to prevent concurrent sync operations.

**Lock File**: `/var/lib/synapse-li/sync.lock`

Uses `fcntl` for atomic file locking.

### 3. `monitor_replication.py`
Monitors PostgreSQL logical replication status and health.

**Functions**:
- `monitor_postgresql_replication(from_lsn)`: Get current replication LSN
- `check_replication_health()`: Check replication lag and status

**Usage**:
```bash
python3 monitor_replication.py
```

### 4. `sync_media.sh`
Shell script for syncing media files using rclone.

**Requirements**:
- rclone installed and configured
- `/etc/rclone/rclone.conf` with `main-s3` and `hidden-s3` remotes

**Usage**:
```bash
./sync_media.sh [--since TIMESTAMP]
```

### 5. `sync_task.py`
Main orchestration script that:
1. Acquires sync lock
2. Checks PostgreSQL replication health
3. Syncs media files
4. Updates checkpoint

**Usage**:
```bash
python3 sync_task.py
```

## Prerequisites

### PostgreSQL Logical Replication

The main PostgreSQL instance must have logical replication enabled:

```sql
-- On main instance
CREATE PUBLICATION synapse_pub FOR ALL TABLES;

-- On hidden instance
CREATE SUBSCRIPTION hidden_instance_sub
CONNECTION 'host=postgres-rw.matrix.svc.cluster.local port=5432 dbname=synapse user=synapse password=xxx'
PUBLICATION synapse_pub;
```

### rclone Configuration

Create `/etc/rclone/rclone.conf`:

```ini
[main-s3]
type = s3
provider = Minio
env_auth = false
access_key_id = <MAIN_ACCESS_KEY>
secret_access_key = <MAIN_SECRET_KEY>
endpoint = http://minio.matrix.svc.cluster.local:9000

[hidden-s3]
type = s3
provider = Minio
env_auth = false
access_key_id = <HIDDEN_ACCESS_KEY>
secret_access_key = <HIDDEN_SECRET_KEY>
endpoint = http://minio.matrix-li.svc.cluster.local:9000
```

### Environment Variables

The sync scripts use these environment variables:

- `SYNAPSE_DB_HOST`: PostgreSQL host (default: `synapse-postgres-li-rw.matrix-li.svc.cluster.local`)
- `SYNAPSE_DB_USER`: PostgreSQL user (default: `synapse`)
- `SYNAPSE_DB_NAME`: PostgreSQL database (default: `synapse`)
- `SYNAPSE_DB_PASSWORD`: PostgreSQL password (required)

## Running the Sync

### Manual Sync

```bash
cd /home/user/Messenger/synapse-li/sync
export SYNAPSE_DB_PASSWORD="<password>"
python3 sync_task.py
```

### Automated Sync (Cron)

Add to crontab:

```cron
# Sync every hour
0 * * * * cd /path/to/synapse-li/sync && SYNAPSE_DB_PASSWORD="xxx" /usr/bin/python3 sync_task.py >> /var/log/synapse-li/sync-cron.log 2>&1
```

### Celery-Based Sync (Optional)

For more sophisticated scheduling, use Celery:

1. Create `celeryconfig.py`:

```python
from celery import Celery
from celery.schedules import crontab

app = Celery('synapse_li_sync')

app.conf.beat_schedule = {
    'sync-every-hour': {
        'task': 'sync_task.run_sync',
        'schedule': crontab(minute=0),  # Every hour
    },
}

app.conf.timezone = 'UTC'
```

2. Run Celery:

```bash
celery -A celeryconfig beat --loglevel=info &
celery -A celeryconfig worker --loglevel=info &
```

## Monitoring

### Check Sync Status

```bash
cat /var/lib/synapse-li/sync_checkpoint.json
```

### Check Replication Health

```bash
python3 monitor_replication.py
```

### View Sync Logs

```bash
tail -f /var/log/synapse-li/media-sync.log
```

## Troubleshooting

### Replication Lag Too High

If replication lag exceeds 100 MB:

1. Check network connectivity between main and hidden instances
2. Check PostgreSQL replication slot is active:
   ```sql
   SELECT * FROM pg_replication_slots WHERE slot_name = 'hidden_instance_sub';
   ```
3. Restart PostgreSQL subscription if needed:
   ```sql
   ALTER SUBSCRIPTION hidden_instance_sub DISABLE;
   ALTER SUBSCRIPTION hidden_instance_sub ENABLE;
   ```

### Media Sync Failures

If media sync fails:

1. Check rclone configuration: `rclone lsd main-s3:` and `rclone lsd hidden-s3:`
2. Verify network access to both MinIO instances
3. Check MinIO credentials and bucket permissions
4. Review logs: `/var/log/synapse-li/media-sync.log`

### Lock File Issues

If sync is stuck with lock held:

1. Check if sync process is actually running: `ps aux | grep sync_task`
2. If not running, manually remove lock: `rm /var/lib/synapse-li/sync.lock`
3. Restart sync

## Security Considerations

1. **Network Isolation**: Only the hidden instance should be able to access main instance's PostgreSQL and MinIO
2. **Credentials**: Store database and MinIO credentials securely (Kubernetes secrets, vault, etc.)
3. **Audit Logs**: All sync operations are logged with `LI:` prefix for audit trail
4. **One-Way Sync**: Sync is always main → hidden, never the reverse

## Performance Tuning

### Replication

Adjust PostgreSQL settings:

```sql
ALTER SUBSCRIPTION hidden_instance_sub SET (streaming = on);
```

### Media Sync

Adjust rclone parameters in `sync_media.sh`:

- `--transfers`: Number of parallel file transfers (default: 4)
- `--checkers`: Number of parallel file checkers (default: 8)
- `--bwlimit`: Bandwidth limit (e.g., `10M` for 10 MB/s)

## Integration with synapse-admin-li

The sync system can be triggered from synapse-admin-li via a sync button. See the main LI requirements documentation for details on the admin interface integration.
