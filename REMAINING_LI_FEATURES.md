# Remaining LI Features - Implementation Guide

## Status: Core LI System Complete (85%)

### ✅ COMPLETED FEATURES

1. **key_vault Django Service** - 100% complete
   - User and EncryptedKey models
   - REST API endpoint with deduplication
   - Admin interface

2. **Synapse LI Proxy** - 100% complete
   - `/_synapse/client/v1/li/store_key` endpoint
   - Authentication and forwarding to key_vault

3. **element-web Key Capture** - 100% complete
   - LIEncryption.ts and LIKeyCapture.ts
   - Integration in CreateSecretStorageDialog.tsx

4. **element-x-android Key Capture** - 100% complete
   - LIEncryption.kt and LIKeyCapture.kt
   - Integration in SecureBackupSetupPresenter.kt

5. **Session Limiter** - 100% complete
   - File-based SessionLimiter class
   - Integration in device.py for login/logout
   - Configuration support

6. **Soft Delete Configuration** - 100% complete
   - sample_homeserver_li.yaml with redaction_retention_period=null
   - Documented verification steps

7. **Deleted Messages Display (element-web-li)** - 100% complete
   - LIRedactedEvents.ts store
   - LIRedactedBody.tsx component
   - _LIRedactedBody.pcss styling
   - TimelinePanel.tsx integration
   - EventTile.tsx and MessageEvent.tsx updates
   - Synapse admin endpoint: `/_synapse/admin/v1/rooms/{roomId}/redacted_events`

---

## 🔧 REMAINING FEATURES (15%)

### 1. synapse-admin Statistics Dashboard

**Purpose**: Display real-time and historical statistics for LI monitoring

**Location**: `/home/user/Messenger/synapse-admin/src/resources/statistics.tsx`

**Required Components**:

```typescript
// synapse-admin/src/resources/statistics.tsx
import { Card, CardContent, Grid, Typography } from "@mui/material";
import { useQuery } from "@tanstack/react-query";
import { Title, useDataProvider } from "react-admin";
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend } from "recharts";

export const StatisticsList = () => {
  const dataProvider = useDataProvider();

  // Fetch today's statistics
  const { data: todayStats } = useQuery({
    queryKey: ["statistics", "today"],
    queryFn: async () => {
      const result = await dataProvider.getOne("statistics", {
        id: "today",
      });
      return result.data;
    },
  });

  // Fetch top rooms
  const { data: topRooms } = useQuery({
    queryKey: ["statistics", "top_rooms"],
    queryFn: async () => {
      const result = await dataProvider.getList("statistics/top_rooms", {
        pagination: { page: 1, perPage: 10 },
        sort: { field: "message_count", order: "DESC" },
        filter: {},
      });
      return result.data;
    },
  });

  // Fetch historical data
  const { data: historical } = useQuery({
    queryKey: ["statistics", "historical"],
    queryFn: async () => {
      const result = await dataProvider.getList("statistics/historical", {
        pagination: { page: 1, perPage: 30 },
        sort: { field: "date", order: "DESC" },
        filter: {},
      });
      return result.data;
    },
  });

  return (
    <>
      <Title title="Statistics" />
      <Grid container spacing={2}>
        {/* Today's Statistics */}
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="h6">Messages Today</Typography>
              <Typography variant="h3">{todayStats?.messages || 0}</Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="h6">Active Users</Typography>
              <Typography variant="h3">{todayStats?.active_users || 0}</Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="h6">Rooms Created</Typography>
              <Typography variant="h3">{todayStats?.rooms_created || 0}</Typography>
            </CardContent>
          </Card>
        </Grid>

        {/* Historical Chart */}
        <Grid item xs={12}>
          <Card>
            <CardContent>
              <Typography variant="h6">Messages - Last 30 Days</Typography>
              <LineChart width={800} height={300} data={historical}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="date" />
                <YAxis />
                <Tooltip />
                <Legend />
                <Line type="monotone" dataKey="messages" stroke="#8884d8" />
              </LineChart>
            </CardContent>
          </Card>
        </Grid>

        {/* Top Rooms Table */}
        <Grid item xs={12}>
          <Card>
            <CardContent>
              <Typography variant="h6">Top 10 Most Active Rooms</Typography>
              {/* Add table here */}
            </CardContent>
          </Card>
        </Grid>
      </Grid>
    </>
  );
};

export default {
  list: StatisticsList,
};
```

**Synapse Backend Endpoint Needed**:

Create `synapse/rest/admin/statistics.py` (already exists, extend it):

```python
# LI: Add statistics endpoints
class StatisticsTodayServlet(RestServlet):
    PATTERNS = admin_patterns("/statistics/today$")

    async def on_GET(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        requester = await self._auth.get_user_by_req(request)
        await assert_user_is_admin(self._auth, requester)

        # Get today's stats from database
        today = datetime.now().date()

        # Count messages sent today
        messages_sql = """
            SELECT COUNT(*) FROM events
            WHERE type = 'm.room.message'
            AND DATE(to_timestamp(origin_server_ts / 1000)) = ?
        """

        # Count active users today
        users_sql = """
            SELECT COUNT(DISTINCT sender) FROM events
            WHERE DATE(to_timestamp(origin_server_ts / 1000)) = ?
        """

        # Count rooms created today
        rooms_sql = """
            SELECT COUNT(*) FROM events
            WHERE type = 'm.room.create'
            AND DATE(to_timestamp(origin_server_ts / 1000)) = ?
        """

        # Execute queries and return results
        # ...
```

**Steps to Complete**:
1. Create `statistics.tsx` resource file
2. Add backend Synapse endpoints for statistics
3. Import and register in `App.tsx`:
   ```typescript
   import statistics from "./resources/statistics";
   // ...
   <Resource {...statistics} name="statistics" />
   ```
4. Add dependencies: `npm install recharts`

---

### 2. synapse-admin Malicious Files Tab

**Purpose**: Display quarantined media files with pagination

**Location**: `/home/user/Messenger/synapse-admin/src/resources/malicious_files.tsx`

**Implementation**:

```typescript
import { Datagrid, List, TextField, DateField, FunctionField } from "react-admin";

export const MaliciousFilesList = () => (
  <List>
    <Datagrid>
      <TextField source="media_id" label="Media ID" />
      <TextField source="server_name" label="Server" />
      <DateField source="quarantined_at" label="Quarantined At" />
      <TextField source="quarantined_by" label="Quarantined By" />
      <TextField source="media_type" label="Type" />
      <FunctionField
        label="Size"
        render={(record: any) => `${(record.media_length / 1024).toFixed(2)} KB`}
      />
    </Datagrid>
  </List>
);

export default {
  list: MaliciousFilesList,
};
```

**Synapse Backend**:

Synapse already has quarantine endpoints. Extend `synapse/rest/admin/media.py`:

```python
# LI: List all quarantined media
class QuarantinedMediaListServlet(RestServlet):
    PATTERNS = admin_patterns("/quarantined_media$")

    async def on_GET(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        requester = await self._auth.get_user_by_req(request)
        await assert_user_is_admin(self._auth, requester)

        sql = """
            SELECT
                media_id,
                server_name,
                quarantined_by,
                media_type,
                media_length
            FROM local_media_repository
            WHERE quarantined_by IS NOT NULL
            ORDER BY created_ts DESC
            LIMIT ? OFFSET ?
        """

        # Return paginated results
```

---

### 3. synapse-admin-li Decryption Tab

**Purpose**: Browser-based RSA decryption of captured keys

**Location**: `/home/user/Messenger/synapse-admin-li/src/resources/decryption.tsx`

**Implementation**:

```typescript
import { Card, CardContent, TextField, Button, Typography } from "@mui/material";
import { useState } from "react";
import JSEncrypt from "jsencrypt";

export const DecryptionTab = () => {
  const [privateKey, setPrivateKey] = useState("");
  const [encryptedPayload, setEncryptedPayload] = useState("");
  const [decrypted, setDecrypted] = useState("");

  const handleDecrypt = () => {
    try {
      const decrypt = new JSEncrypt();
      decrypt.setPrivateKey(privateKey);
      const result = decrypt.decrypt(encryptedPayload);
      if (result) {
        setDecrypted(result);
      } else {
        setDecrypted("Decryption failed - invalid key or payload");
      }
    } catch (error) {
      setDecrypted(`Error: ${error.message}`);
    }
  };

  return (
    <Card>
      <CardContent>
        <Typography variant="h5">RSA Decryption Tool</Typography>

        <TextField
          fullWidth
          multiline
          rows={6}
          label="RSA Private Key (PEM)"
          value={privateKey}
          onChange={(e) => setPrivateKey(e.target.value)}
          margin="normal"
        />

        <TextField
          fullWidth
          multiline
          rows={4}
          label="Encrypted Payload (Base64)"
          value={encryptedPayload}
          onChange={(e) => setEncryptedPayload(e.target.value)}
          margin="normal"
        />

        <Button
          variant="contained"
          color="primary"
          onClick={handleDecrypt}
          sx={{ mt: 2 }}
        >
          Decrypt
        </Button>

        {decrypted && (
          <TextField
            fullWidth
            multiline
            rows={4}
            label="Decrypted Recovery Key"
            value={decrypted}
            margin="normal"
            InputProps={{
              readOnly: true,
            }}
          />
        )}
      </CardContent>
    </Card>
  );
};

export default {
  list: DecryptionTab,
};
```

**Note**: This is browser-based and uses the jsencrypt library. Add to `synapse-admin-li` only.

---

### 4. Sync System for synapse-li

**Purpose**: Monitor and sync PostgreSQL replication and media files

**Location**: `/home/user/Messenger/synapse-li/sync/`

**Components Needed**:

#### A. PostgreSQL Replication Monitoring

**File**: `synapse-li/sync/monitor_replication.py`

```python
#!/usr/bin/env python3
"""
LI: Monitor PostgreSQL logical replication lag and health.
Run as a Celery beat task or cron job.
"""

import psycopg2
import logging
from datetime import datetime

logger = logging.getLogger(__name__)

def check_replication_status():
    """Check replication lag and health."""

    # Connect to hidden instance
    conn = psycopg2.connect(
        host="postgres-rw.matrix-li.svc.cluster.local",
        port=5432,
        user="synapse",
        password=os.environ["SYNAPSE_DB_PASSWORD"],
        database="synapse"
    )

    cursor = conn.cursor()

    # Check replication lag
    cursor.execute("""
        SELECT
            slot_name,
            active,
            restart_lsn,
            confirmed_flush_lsn,
            pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes
        FROM pg_replication_slots
        WHERE slot_name = 'synapse_li_slot';
    """)

    result = cursor.fetchone()

    if not result:
        logger.error("LI: Replication slot not found!")
        return False

    slot_name, active, restart_lsn, confirmed_flush_lsn, lag_bytes = result

    if not active:
        logger.error("LI: Replication slot is inactive!")
        return False

    lag_mb = lag_bytes / (1024 * 1024)
    logger.info(f"LI: Replication lag: {lag_mb:.2f} MB")

    # Alert if lag exceeds threshold
    if lag_mb > 100:
        logger.warning(f"LI: High replication lag detected: {lag_mb:.2f} MB")
        # Send alert (email, Slack, etc.)

    return True

if __name__ == "__main__":
    check_replication_status()
```

#### B. Media Sync with rclone

**File**: `synapse-li/sync/sync_media.sh`

```bash
#!/bin/bash
# LI: Sync media files from main MinIO to hidden MinIO using rclone

set -e

MAIN_ENDPOINT="https://minio.matrix.svc.cluster.local"
HIDDEN_ENDPOINT="https://minio.matrix-li.svc.cluster.local"
BUCKET="synapse-media"

# Configure rclone
rclone sync \
    main-s3:${BUCKET}/ \
    hidden-s3:${BUCKET}/ \
    --config /etc/rclone/rclone.conf \
    --log-file /var/log/synapse-li/media-sync.log \
    --log-level INFO \
    --transfers 4 \
    --checkers 8 \
    --contimeout 60s \
    --timeout 300s \
    --retries 3 \
    --low-level-retries 10 \
    --stats 1m \
    --stats-file-name-length 0

echo "LI: Media sync completed at $(date)"
```

**rclone.conf**:

```ini
[main-s3]
type = s3
provider = Minio
env_auth = false
access_key_id = MAIN_ACCESS_KEY
secret_access_key = MAIN_SECRET_KEY
endpoint = https://minio.matrix.svc.cluster.local

[hidden-s3]
type = s3
provider = Minio
env_auth = false
access_key_id = HIDDEN_ACCESS_KEY
secret_access_key = HIDDEN_SECRET_KEY
endpoint = https://minio.matrix-li.svc.cluster.local
```

#### C. Celery Configuration

**File**: `synapse-li/sync/celeryconfig.py`

```python
from celery import Celery
from celery.schedules import crontab

app = Celery('synapse_li_sync')

app.conf.beat_schedule = {
    'check-replication-every-5-minutes': {
        'task': 'sync.monitor_replication.check_replication_status',
        'schedule': crontab(minute='*/5'),
    },
    'sync-media-every-hour': {
        'task': 'sync.sync_media.sync_media_files',
        'schedule': crontab(minute=0),  # Every hour
    },
}

app.conf.timezone = 'UTC'
```

**Run with**:
```bash
celery -A sync.celeryconfig beat --loglevel=info
celery -A sync.celeryconfig worker --loglevel=info
```

---

## QUICK START GUIDE

### To Complete Remaining Features:

1. **Statistics Dashboard**:
   ```bash
   cd /home/user/Messenger/synapse-admin
   # Create statistics.tsx resource
   # Add backend endpoints to Synapse
   # Import in App.tsx
   npm install recharts
   ```

2. **Malicious Files Tab**:
   ```bash
   # Create malicious_files.tsx resource
   # Extend media.py in Synapse
   # Register in App.tsx
   ```

3. **Decryption Tab** (synapse-admin-li only):
   ```bash
   cd /home/user/Messenger/synapse-admin-li
   # Create decryption.tsx
   # Add to App.tsx with CustomRoutes
   ```

4. **Sync System**:
   ```bash
   cd /home/user/Messenger/synapse-li
   mkdir -p sync
   # Create Python scripts and Celery config
   # Set up cron or Celery beat
   ```

---

## TESTING CHECKLIST

- [ ] Statistics dashboard displays today's metrics
- [ ] Historical charts show last 30 days
- [ ] Malicious files table paginates correctly
- [ ] Decryption tool successfully decrypts test payloads
- [ ] Replication monitoring detects lag
- [ ] Media sync completes without errors
- [ ] All LI logs use `# LI:` or `// LI:` prefix

---

## DEPLOYMENT NOTES

1. **Statistics**: Requires database access for complex queries
2. **Malicious Files**: Uses existing Synapse quarantine data
3. **Decryption**: Client-side only, no backend changes needed
4. **Sync System**: Requires Celery setup in Kubernetes

---

**Total Implementation Estimate**: 8-12 hours for all remaining features
**Priority**: Medium (core LI system is functional without these)
**Complexity**: Medium-High (React, Synapse API, Celery, PostgreSQL)
