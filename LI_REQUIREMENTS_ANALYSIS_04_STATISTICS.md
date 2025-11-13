# LI Requirements Analysis - Part 4: Statistics Dashboard

**Part 4 of 5** | [Part 1: Overview](LI_REQUIREMENTS_ANALYSIS_01_OVERVIEW.md) | [Part 2: Soft Delete](LI_REQUIREMENTS_ANALYSIS_02_SOFT_DELETE.md) | [Part 3: Key Backup & Sessions](LI_REQUIREMENTS_ANALYSIS_03_KEY_BACKUP_SESSIONS.md) | Part 4 | [Part 5: Summary](LI_REQUIREMENTS_ANALYSIS_05_SUMMARY.md)

---

## Table of Contents
1. [Statistics Requirements Overview](#statistics-requirements-overview)
2. [Synapse Database Schema Analysis](#synapse-database-schema-analysis)
3. [Statistics Implementation Details](#statistics-implementation-details)
4. [synapse-admin Integration](#synapse-admin-integration)
5. [Performance Considerations](#performance-considerations)
6. [Visualization Strategy](#visualization-strategy)

---

## Statistics Requirements Overview

### User's Requirements
> "Also I need statistics. Add more and more statistics to synapse-admin. For example:
> - How many message send per day
> - How many file uploaded per day and what is the volume of it
> - How many room created per day
> - Call statistics (how many calls per day and what is type of call, is that P2P call or it is a group calls?)
> - How many users register per day
> - Which rooms are most active? (Top 10)
> - Which users are most active? (Top 10)
> - Keep historical data to show previous time data. For example last 30 days, last 6 months
> - Antivirus. Show how many malicious file detected by av per day. Also show in which room the malicious file uploaded and by which user."

### Categorization

I'll categorize these into **4 groups**:

#### Group 1: Time-Series Statistics (Daily Aggregates)
- Messages per day
- Files uploaded per day + volume
- Rooms created per day
- Calls per day (by type)
- New user registrations per day
- Malicious files detected per day

#### Group 2: Ranking Statistics (Top N)
- Top 10 most active rooms
- Top 10 most active users

#### Group 3: Historical Data
- Last 30 days view
- Last 6 months view
- Exportable data

#### Group 4: Contextual Details
- Malicious file details (room, user, timestamp)

---

## Synapse Database Schema Analysis

### Key Tables for Statistics

I analyzed Synapse's database schema to determine what data is available.

#### Table 1: `events` (Main Event Storage)

**File**: `synapse/synapse/storage/schema/main/full_schemas/72/full.sql` (lines 500-600)

```sql
CREATE TABLE events (
    stream_ordering BIGINT PRIMARY KEY,
    topological_ordering BIGINT NOT NULL,
    event_id TEXT NOT NULL UNIQUE,
    type TEXT NOT NULL,
    room_id TEXT NOT NULL,
    sender TEXT NOT NULL,
    content TEXT,
    origin_server_ts BIGINT NOT NULL,
    -- ... more columns ...

    CONSTRAINT event_id_not_null CHECK (event_id IS NOT NULL)
);

CREATE INDEX events_room_stream ON events (room_id, stream_ordering);
CREATE INDEX events_order_room ON events (room_id, topological_ordering, stream_ordering);
CREATE INDEX events_ts ON events (origin_server_ts);
```

**Key Event Types for Statistics**:
- `m.room.message` - Messages
- `m.room.create` - Room creation
- `m.call.invite` - Call initiation
- `m.call.answer` - Call answer
- `m.room.member` - User joins/leaves

#### Table 2: `local_media_repository` (File Uploads)

```sql
CREATE TABLE local_media_repository (
    media_id TEXT PRIMARY KEY,
    media_type TEXT NOT NULL,
    media_length INTEGER NOT NULL,  -- File size in bytes
    created_ts BIGINT NOT NULL,
    upload_name TEXT,
    user_id TEXT NOT NULL,
    quarantined_by TEXT,  -- If quarantined by admin
    -- ... more columns ...
);

CREATE INDEX local_media_repository_created_ts ON local_media_repository (created_ts);
CREATE INDEX local_media_repository_user_id_created_ts ON local_media_repository (user_id, created_ts);
```

#### Table 3: `room_stats_current` (Pre-Aggregated Room Stats)

**File**: `synapse/synapse/storage/schema/main/delta/54/stats.sql`

```sql
CREATE TABLE room_stats_current (
    room_id TEXT PRIMARY KEY,
    current_state_events INT NOT NULL,  -- Number of state events
    joined_members INT NOT NULL,  -- Current member count
    invited_members INT NOT NULL,
    left_members INT NOT NULL,
    banned_members INT NOT NULL,
    local_users_in_room INT NOT NULL,
    completed_delta_stream_id BIGINT NOT NULL
);
```

**Note**: This table has **current** stats, not historical.

#### Table 4: `user_stats_current` (Pre-Aggregated User Stats)

```sql
CREATE TABLE user_stats_current (
    user_id TEXT PRIMARY KEY,
    joined_rooms INT NOT NULL,  -- Number of rooms user is in
    public_rooms INT NOT NULL,
    private_rooms INT NOT NULL
);
```

**Note**: Again, current stats only, no message counts.

#### Table 5: `users` (User Registration)

```sql
CREATE TABLE users (
    name TEXT PRIMARY KEY,
    password_hash TEXT,
    creation_ts BIGINT,  -- Registration timestamp
    admin SMALLINT DEFAULT 0 NOT NULL,
    -- ... more columns ...
);

CREATE INDEX users_creation_ts ON users (creation_ts);
```

#### Table 6: `room_memberships` (Join/Leave Events)

```sql
CREATE TABLE room_memberships (
    event_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    sender TEXT NOT NULL,
    room_id TEXT NOT NULL,
    membership TEXT NOT NULL,  -- 'join', 'leave', 'invite', 'ban'
    -- ... more columns ...
);
```

### Key Finding: No Pre-Aggregated Message Counts

**Important**: Synapse does **NOT** have a table like `daily_message_counts`.

All statistics must be **calculated from the `events` table**.

---

## Statistics Implementation Details

### Statistic 1: Messages Per Day

#### SQL Query

```sql
-- Messages sent per day (last 30 days)
SELECT
    DATE(to_timestamp(origin_server_ts / 1000)) AS date,
    COUNT(*) AS message_count
FROM events
WHERE
    type = 'm.room.message'
    AND origin_server_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY DATE(to_timestamp(origin_server_ts / 1000))
ORDER BY date DESC;
```

#### Synapse Admin API Endpoint (New)

**File**: `synapse/synapse/rest/admin/statistics.py` (NEW FILE)

```python
class MessagesPerDayRestServlet(RestServlet):
    PATTERNS = admin_patterns("/statistics/messages_per_day$")

    def __init__(self, hs: "HomeServer"):
        self.store = hs.get_datastores().main
        self.auth = hs.get_auth()

    async def on_GET(self, request: Request) -> Tuple[int, JsonDict]:
        await assert_requester_is_admin(self.auth, request)

        # Parse query params
        days = int(request.args.get(b"days", [b"30"])[0])

        # Query database
        rows = await self.store.db_pool.execute(
            "get_messages_per_day",
            """
            SELECT
                DATE(to_timestamp(origin_server_ts / 1000)) AS date,
                COUNT(*) AS message_count
            FROM events
            WHERE
                type = 'm.room.message'
                AND origin_server_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '%s days') * 1000
            GROUP BY DATE(to_timestamp(origin_server_ts / 1000))
            ORDER BY date DESC
            """,
            days,
        )

        return 200, {
            "days": days,
            "data": [
                {"date": str(row[0]), "count": row[1]}
                for row in rows
            ]
        }
```

#### Expected Response

```json
{
    "days": 30,
    "data": [
        {"date": "2025-11-13", "count": 1247},
        {"date": "2025-11-12", "count": 1189},
        {"date": "2025-11-11", "count": 1302},
        ...
    ]
}
```

#### Performance

**Index Used**: `events_ts` (on `origin_server_ts`)

**Query Time** (estimated):
- 100K events: ~50ms
- 1M events: ~200ms
- 10M events: ~1s

**Mitigation**: Add query result caching (refresh every hour).

---

### Statistic 2: Files Uploaded Per Day + Volume

#### SQL Query

```sql
-- Files uploaded per day with total volume (last 30 days)
SELECT
    DATE(to_timestamp(created_ts / 1000)) AS date,
    COUNT(*) AS file_count,
    SUM(media_length) AS total_bytes,
    pg_size_pretty(SUM(media_length)::bigint) AS total_size_human
FROM local_media_repository
WHERE
    created_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY DATE(to_timestamp(created_ts / 1000))
ORDER BY date DESC;
```

#### Synapse Admin API Endpoint

```python
class FilesPerDayRestServlet(RestServlet):
    PATTERNS = admin_patterns("/statistics/files_per_day$")

    async def on_GET(self, request: Request) -> Tuple[int, JsonDict]:
        await assert_requester_is_admin(self.auth, request)

        days = int(request.args.get(b"days", [b"30"])[0])

        rows = await self.store.db_pool.execute(
            "get_files_per_day",
            """
            SELECT
                DATE(to_timestamp(created_ts / 1000)) AS date,
                COUNT(*) AS file_count,
                SUM(media_length) AS total_bytes
            FROM local_media_repository
            WHERE
                created_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '%s days') * 1000
            GROUP BY DATE(to_timestamp(created_ts / 1000))
            ORDER BY date DESC
            """,
            days,
        )

        return 200, {
            "days": days,
            "data": [
                {
                    "date": str(row[0]),
                    "file_count": row[1],
                    "total_bytes": row[2],
                    "total_size_human": self._human_size(row[2])
                }
                for row in rows
            ]
        }

    @staticmethod
    def _human_size(bytes: int) -> str:
        """Convert bytes to human readable format"""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes < 1024.0:
                return f"{bytes:.2f} {unit}"
            bytes /= 1024.0
        return f"{bytes:.2f} PB"
```

#### Expected Response

```json
{
    "days": 30,
    "data": [
        {
            "date": "2025-11-13",
            "file_count": 47,
            "total_bytes": 125829120,
            "total_size_human": "120.00 MB"
        },
        ...
    ]
}
```

---

### Statistic 3: Rooms Created Per Day

#### SQL Query

```sql
-- Rooms created per day (last 30 days)
SELECT
    DATE(to_timestamp(origin_server_ts / 1000)) AS date,
    COUNT(*) AS room_count
FROM events
WHERE
    type = 'm.room.create'
    AND origin_server_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY DATE(to_timestamp(origin_server_ts / 1000))
ORDER BY date DESC;
```

#### Synapse Admin API Endpoint

```python
class RoomsCreatedPerDayRestServlet(RestServlet):
    PATTERNS = admin_patterns("/statistics/rooms_per_day$")

    async def on_GET(self, request: Request) -> Tuple[int, JsonDict]:
        # Similar to messages_per_day
        # Query for type = 'm.room.create'
        # ...
```

---

### Statistic 4: Call Statistics (P2P vs Group)

#### Background: Matrix Call Events

**Call Flow**:
1. Caller sends `m.call.invite` event
2. Callee sends `m.call.answer` event
3. Call established

**Call Types**:
- **P2P Call**: Direct call between 2 users (in a DM room)
- **Group Call**: Conference call (3+ participants)

**Determining Call Type**:
- Check room member count at time of call
- If 2 members → P2P
- If 3+ members → Group

#### SQL Query

```sql
-- Calls per day with type classification (last 30 days)
SELECT
    DATE(to_timestamp(e.origin_server_ts / 1000)) AS date,
    COUNT(*) AS total_calls,
    SUM(CASE WHEN rsc.joined_members = 2 THEN 1 ELSE 0 END) AS p2p_calls,
    SUM(CASE WHEN rsc.joined_members > 2 THEN 1 ELSE 0 END) AS group_calls
FROM events e
JOIN room_stats_current rsc ON e.room_id = rsc.room_id
WHERE
    e.type = 'm.call.invite'
    AND e.origin_server_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY DATE(to_timestamp(e.origin_server_ts / 1000))
ORDER BY date DESC;
```

**Note**: This uses current room member count, not historical. For precise stats, would need historical tracking.

#### Alternative: Use State Events

More accurate approach:
```sql
-- Count members at time of call by querying state events
WITH call_events AS (
    SELECT
        event_id,
        room_id,
        origin_server_ts,
        DATE(to_timestamp(origin_server_ts / 1000)) AS date
    FROM events
    WHERE
        type = 'm.call.invite'
        AND origin_server_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
),
member_counts AS (
    SELECT
        ce.date,
        ce.room_id,
        COUNT(DISTINCT rm.user_id) AS member_count
    FROM call_events ce
    JOIN room_memberships rm ON ce.room_id = rm.room_id
    WHERE rm.membership = 'join'
    GROUP BY ce.date, ce.room_id
)
SELECT
    date,
    COUNT(*) AS total_calls,
    SUM(CASE WHEN member_count = 2 THEN 1 ELSE 0 END) AS p2p_calls,
    SUM(CASE WHEN member_count > 2 THEN 1 ELSE 0 END) AS group_calls
FROM member_counts
GROUP BY date
ORDER BY date DESC;
```

#### Expected Response

```json
{
    "days": 30,
    "data": [
        {
            "date": "2025-11-13",
            "total_calls": 23,
            "p2p_calls": 18,
            "group_calls": 5
        },
        ...
    ]
}
```

---

### Statistic 5: User Registrations Per Day

#### SQL Query

```sql
-- User registrations per day (last 30 days)
SELECT
    DATE(to_timestamp(creation_ts / 1000)) AS date,
    COUNT(*) AS registration_count
FROM users
WHERE
    creation_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY DATE(to_timestamp(creation_ts / 1000))
ORDER BY date DESC;
```

**Note**: Excludes deactivated users if needed:
```sql
WHERE
    creation_ts >= ...
    AND deactivated = 0
```

#### Expected Response

```json
{
    "days": 30,
    "data": [
        {"date": "2025-11-13", "count": 12},
        {"date": "2025-11-12", "count": 8},
        ...
    ]
}
```

---

### Statistic 6: Top 10 Most Active Rooms

#### Definition of "Active"
- Option A: Most messages sent (recommended)
- Option B: Most unique participants
- Option C: Most recent activity

I'll use **Option A** (most messages).

#### SQL Query

```sql
-- Top 10 most active rooms (last 30 days)
SELECT
    e.room_id,
    r.name AS room_name,
    COUNT(*) AS message_count,
    COUNT(DISTINCT e.sender) AS unique_senders
FROM events e
LEFT JOIN room_stats_state rs ON e.room_id = rs.room_id AND rs.name = 'm.room.name'
LEFT JOIN rooms r ON e.room_id = r.room_id
WHERE
    e.type = 'm.room.message'
    AND e.origin_server_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY e.room_id, r.name
ORDER BY message_count DESC
LIMIT 10;
```

#### Expected Response

```json
{
    "period": "30 days",
    "data": [
        {
            "room_id": "!abc123:server.com",
            "room_name": "General Chat",
            "message_count": 3847,
            "unique_senders": 45
        },
        {
            "room_id": "!def456:server.com",
            "room_name": "Tech Discussion",
            "message_count": 2931,
            "unique_senders": 32
        },
        ...
    ]
}
```

---

### Statistic 7: Top 10 Most Active Users

#### SQL Query

```sql
-- Top 10 most active users (last 30 days)
SELECT
    sender AS user_id,
    COUNT(*) AS message_count,
    COUNT(DISTINCT room_id) AS room_count
FROM events
WHERE
    type = 'm.room.message'
    AND origin_server_ts >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY sender
ORDER BY message_count DESC
LIMIT 10;
```

#### Expected Response

```json
{
    "period": "30 days",
    "data": [
        {
            "user_id": "@alice:server.com",
            "message_count": 1247,
            "room_count": 15
        },
        {
            "user_id": "@bob:server.com",
            "message_count": 1089,
            "room_count": 22
        },
        ...
    ]
}
```

---

### Statistic 8: Malicious Files Detected (Antivirus)

#### Background: Antivirus Integration

Synapse doesn't have built-in antivirus, but you can integrate one.

**Common Approaches**:
1. **ClamAV Integration**: Scan files on upload
2. **External Scanner**: Async scanning service
3. **Cloud AV**: Use cloud-based API (VirusTotal, etc.)

#### Proposed Integration

**File**: `synapse/synapse/rest/media/v1/upload_resource.py`

After file upload, scan with ClamAV:
```python
async def _async_render_POST(self, request: Request) -> None:
    # ... existing upload logic ...

    # NEW: Scan with ClamAV
    is_malicious = await self._scan_file(file_path)

    if is_malicious:
        # Mark as quarantined
        await self.store.quarantine_media(media_id)

        # Log to malicious_files table
        await self.store.log_malicious_file(
            media_id=media_id,
            user_id=requester.user.to_string(),
            room_id=room_id,  # If uploaded to room
            detected_at=self.clock.time_msec(),
            threat_name="ClamAV.Threat.Detected"
        )

        raise SynapseError(400, "File contains malware", Codes.FORBIDDEN)

    # ... continue with upload ...
```

#### New Database Table: `malicious_files`

```sql
CREATE TABLE malicious_files (
    id SERIAL PRIMARY KEY,
    media_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    room_id TEXT,  -- NULL if not uploaded to room
    detected_at BIGINT NOT NULL,
    threat_name TEXT,
    file_name TEXT,
    file_size INTEGER,
    FOREIGN KEY (media_id) REFERENCES local_media_repository(media_id)
);

CREATE INDEX malicious_files_detected_at ON malicious_files (detected_at);
CREATE INDEX malicious_files_user_id ON malicious_files (user_id);
CREATE INDEX malicious_files_room_id ON malicious_files (room_id);
```

#### SQL Query: Malicious Files Per Day

```sql
-- Malicious files detected per day (last 30 days)
SELECT
    DATE(to_timestamp(detected_at / 1000)) AS date,
    COUNT(*) AS malicious_count
FROM malicious_files
WHERE
    detected_at >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY DATE(to_timestamp(detected_at / 1000))
ORDER BY date DESC;
```

#### SQL Query: Malicious File Details

```sql
-- Detailed list of malicious files
SELECT
    mf.media_id,
    mf.user_id,
    mf.room_id,
    r.name AS room_name,
    mf.threat_name,
    mf.file_name,
    mf.file_size,
    to_timestamp(mf.detected_at / 1000) AS detected_at
FROM malicious_files mf
LEFT JOIN rooms r ON mf.room_id = r.room_id
ORDER BY mf.detected_at DESC
LIMIT 100;
```

#### Expected Response

```json
{
    "summary": {
        "period": "30 days",
        "total_malicious": 7
    },
    "daily_counts": [
        {"date": "2025-11-13", "count": 2},
        {"date": "2025-11-10", "count": 1},
        ...
    ],
    "details": [
        {
            "media_id": "abc123",
            "user_id": "@attacker:server.com",
            "room_id": "!room123:server.com",
            "room_name": "General Chat",
            "threat_name": "Trojan.Generic.123456",
            "file_name": "invoice.pdf.exe",
            "file_size": 524288,
            "detected_at": "2025-11-13T14:23:45Z"
        },
        ...
    ]
}
```

---

## synapse-admin Integration

### Architecture

**File**: `synapse-admin/src/synapse/dataProvider.ts` (lines 228-478)

synapse-admin uses **React Admin** framework with custom data provider.

#### Existing Pattern

```typescript
// Current implementation
const resourceMap = {
    users: {
        path: "v2/users",
        map: u => ({ ...u, id: u.name }),
        data: "users",
        total: (json) => json.total,
    },
    rooms: {
        path: "rooms",
        map: r => ({ ...r, id: r.room_id }),
        data: "rooms",
        total: (json) => json.total_rooms,
    },
    // ... more resources ...
};
```

#### New Statistics Resources

```typescript
// NEW: Statistics resources
const resourceMap = {
    // ... existing resources ...

    // NEW: Statistics
    statistics_messages: {
        path: "statistics/messages_per_day",
        map: s => ({ ...s, id: s.date }),
        data: "data",
        total: (json) => json.data.length,
    },
    statistics_files: {
        path: "statistics/files_per_day",
        map: s => ({ ...s, id: s.date }),
        data: "data",
    },
    statistics_rooms: {
        path: "statistics/rooms_per_day",
        map: s => ({ ...s, id: s.date }),
        data: "data",
    },
    statistics_calls: {
        path: "statistics/calls_per_day",
        map: s => ({ ...s, id: s.date }),
        data: "data",
    },
    statistics_registrations: {
        path: "statistics/registrations_per_day",
        map: s => ({ ...s, id: s.date }),
        data: "data",
    },
    top_rooms: {
        path: "statistics/top_rooms",
        map: r => ({ ...r, id: r.room_id }),
        data: "data",
    },
    top_users: {
        path: "statistics/top_users",
        map: u => ({ ...u, id: u.user_id }),
        data: "data",
    },
    malicious_files: {
        path: "statistics/malicious_files",
        map: f => ({ ...f, id: f.media_id }),
        data: "details",
        total: (json) => json.summary.total_malicious,
    },
};
```

### UI Components

#### Component 1: Statistics Dashboard (Overview)

**File**: `synapse-admin/src/resources/statistics/Dashboard.tsx` (NEW)

```typescript
import React from "react";
import { Card, CardContent, Typography, Grid } from "@mui/material";
import { useGetList } from "react-admin";
import { Line } from "react-chartjs-2";

export const StatisticsDashboard = () => {
    // Fetch data for last 30 days
    const { data: messages } = useGetList("statistics_messages", {
        pagination: { page: 1, perPage: 30 },
        sort: { field: "date", order: "DESC" },
        filter: { days: 30 },
    });

    const { data: files } = useGetList("statistics_files", {
        pagination: { page: 1, perPage: 30 },
        filter: { days: 30 },
    });

    // Prepare chart data
    const chartData = {
        labels: messages?.map(m => m.date).reverse(),
        datasets: [
            {
                label: "Messages",
                data: messages?.map(m => m.count).reverse(),
                borderColor: "rgb(75, 192, 192)",
                backgroundColor: "rgba(75, 192, 192, 0.2)",
            },
        ],
    };

    return (
        <Grid container spacing={3}>
            <Grid item xs={12}>
                <Typography variant="h4">Statistics Dashboard</Typography>
            </Grid>

            {/* Summary Cards */}
            <Grid item xs={12} md={3}>
                <Card>
                    <CardContent>
                        <Typography color="textSecondary" gutterBottom>
                            Messages Today
                        </Typography>
                        <Typography variant="h5">
                            {messages?.[0]?.count || 0}
                        </Typography>
                    </CardContent>
                </Card>
            </Grid>

            <Grid item xs={12} md={3}>
                <Card>
                    <CardContent>
                        <Typography color="textSecondary" gutterBottom>
                            Files Uploaded Today
                        </Typography>
                        <Typography variant="h5">
                            {files?.[0]?.file_count || 0}
                        </Typography>
                    </CardContent>
                </Card>
            </Grid>

            {/* Chart */}
            <Grid item xs={12}>
                <Card>
                    <CardContent>
                        <Typography variant="h6" gutterBottom>
                            Messages per Day (Last 30 Days)
                        </Typography>
                        <Line data={chartData} options={{ responsive: true }} />
                    </CardContent>
                </Card>
            </Grid>

            {/* More charts for files, calls, etc. */}
        </Grid>
    );
};
```

#### Component 2: Top Rooms

**File**: `synapse-admin/src/resources/statistics/TopRooms.tsx` (NEW)

```typescript
import React from "react";
import { List, Datagrid, TextField, NumberField } from "react-admin";

export const TopRoomsList = () => (
    <List
        resource="top_rooms"
        basePath="/top_rooms"
        perPage={10}
        pagination={false}
    >
        <Datagrid>
            <TextField source="room_id" label="Room ID" />
            <TextField source="room_name" label="Room Name" />
            <NumberField source="message_count" label="Messages" />
            <NumberField source="unique_senders" label="Participants" />
        </Datagrid>
    </List>
);
```

#### Component 3: Top Users

**File**: `synapse-admin/src/resources/statistics/TopUsers.tsx` (NEW)

```typescript
import React from "react";
import { List, Datagrid, TextField, NumberField } from "react-admin";

export const TopUsersList = () => (
    <List
        resource="top_users"
        basePath="/top_users"
        perPage={10}
        pagination={false}
    >
        <Datagrid>
            <TextField source="user_id" label="User ID" />
            <NumberField source="message_count" label="Messages Sent" />
            <NumberField source="room_count" label="Active Rooms" />
        </Datagrid>
    </List>
);
```

#### Component 4: Malicious Files

**File**: `synapse-admin/src/resources/statistics/MaliciousFiles.tsx` (NEW)

```typescript
import React from "react";
import { List, Datagrid, TextField, DateField, NumberField } from "react-admin";

export const MaliciousFilesList = () => (
    <List
        resource="malicious_files"
        basePath="/malicious_files"
        perPage={25}
    >
        <Datagrid>
            <DateField source="detected_at" label="Detected At" showTime />
            <TextField source="user_id" label="Uploaded By" />
            <TextField source="room_id" label="Room ID" />
            <TextField source="room_name" label="Room Name" />
            <TextField source="file_name" label="File Name" />
            <NumberField source="file_size" label="Size (bytes)" />
            <TextField source="threat_name" label="Threat" />
        </Datagrid>
    </List>
);
```

### Navigation Menu Addition

**File**: `synapse-admin/src/App.tsx`

```typescript
import { Admin, Resource } from "react-admin";
import {
    StatisticsDashboard,
    TopRoomsList,
    TopUsersList,
    MaliciousFilesList,
} from "./resources/statistics";

// Icons
import TimelineIcon from "@mui/icons-material/Timeline";
import TrendingUpIcon from "@mui/icons-material/TrendingUp";
import WarningIcon from "@mui/icons-material/Warning";

const App = () => (
    <Admin dataProvider={dataProvider}>
        {/* Existing resources */}
        <Resource name="users" ... />
        <Resource name="rooms" ... />

        {/* NEW: Statistics Resources */}
        <Resource
            name="statistics"
            list={StatisticsDashboard}
            icon={TimelineIcon}
            options={{ label: "Statistics" }}
        />
        <Resource
            name="top_rooms"
            list={TopRoomsList}
            icon={TrendingUpIcon}
            options={{ label: "Top Rooms" }}
        />
        <Resource
            name="top_users"
            list={TopUsersList}
            icon={TrendingUpIcon}
            options={{ label: "Top Users" }}
        />
        <Resource
            name="malicious_files"
            list={MaliciousFilesList}
            icon={WarningIcon}
            options={{ label: "Malicious Files" }}
        />
    </Admin>
);
```

---

## Performance Considerations

### Query Performance Analysis

#### Concern: Large `events` Table

**Typical Sizes**:
- 1000 users, 6 months: ~5M events
- 10K users, 6 months: ~50M events
- 100K users, 6 months: ~500M events

**Query Time** (without optimization):
```sql
-- Full table scan: SLOW (30+ seconds on 50M rows)
SELECT COUNT(*) FROM events WHERE type = 'm.room.message';
```

### Optimization Strategy 1: Materialized Views

**Create Daily Aggregate Tables**:

```sql
-- Pre-aggregated daily statistics
CREATE TABLE statistics_daily (
    date DATE PRIMARY KEY,
    message_count INTEGER DEFAULT 0,
    file_count INTEGER DEFAULT 0,
    file_bytes BIGINT DEFAULT 0,
    room_count INTEGER DEFAULT 0,
    call_count INTEGER DEFAULT 0,
    p2p_call_count INTEGER DEFAULT 0,
    group_call_count INTEGER DEFAULT 0,
    registration_count INTEGER DEFAULT 0,
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX statistics_daily_date ON statistics_daily (date);
```

**Background Job to Update**:

**File**: `synapse/synapse/app/statistics_updater.py` (NEW)

```python
class StatisticsUpdater:
    """Background job to update daily statistics"""

    def __init__(self, hs: "HomeServer"):
        self.store = hs.get_datastores().main
        self.clock = hs.get_clock()

        # Run every hour
        self.clock.looping_call(self._update_statistics, 60 * 60 * 1000)

    async def _update_statistics(self) -> None:
        """Update statistics for today"""
        today = datetime.now().date()

        # Count messages
        message_count = await self.store.db_pool.simple_select_one_onecol(
            table="events",
            keyvalues={"type": "m.room.message"},
            retcol="COUNT(*)",
            desc="count_messages_today",
        )

        # ... similar for other stats ...

        # Upsert into statistics_daily
        await self.store.db_pool.simple_upsert(
            table="statistics_daily",
            keyvalues={"date": today},
            values={
                "message_count": message_count,
                "file_count": file_count,
                # ... other fields ...
                "updated_at": self.clock.time(),
            },
            desc="upsert_daily_statistics",
        )
```

**Benefit**: Queries against `statistics_daily` are **instant** (O(1) lookups).

### Optimization Strategy 2: Database Partitioning

Partition `events` table by date:

```sql
-- Partition by month
CREATE TABLE events (
    -- ... columns ...
) PARTITION BY RANGE (origin_server_ts);

CREATE TABLE events_2025_01 PARTITION OF events
    FOR VALUES FROM (1704067200000) TO (1706745600000);  -- Jan 2025

CREATE TABLE events_2025_02 PARTITION OF events
    FOR VALUES FROM (1706745600000) TO (1709251200000);  -- Feb 2025

-- ... create partitions for each month ...
```

**Benefit**: Queries for recent data only scan relevant partitions.

**Query Time Improvement**:
- Before: 30s (full table scan of 50M rows)
- After: 2s (scan only current month partition, ~4M rows)

### Optimization Strategy 3: Read Replicas

For large deployments:
- Statistics queries run on **read replica**
- Main database handles writes only
- No performance impact on production

**PostgreSQL Replication**:
```yaml
# docker-compose.yml
services:
  postgres-primary:
    image: postgres:15
    environment:
      POSTGRES_PRIMARY: "true"
    volumes:
      - postgres-data:/var/lib/postgresql/data

  postgres-replica:
    image: postgres:15
    environment:
      POSTGRES_REPLICA_OF: postgres-primary
    volumes:
      - postgres-replica-data:/var/lib/postgresql/data
```

**Synapse Configuration**:
```yaml
# homeserver.yaml
statistics:
  database: postgres-replica  # Use replica for stats queries
```

### Performance Summary

| Optimization | Query Time (50M events) | Implementation Effort | Recommended |
|--------------|------------------------|----------------------|-------------|
| **No Optimization** | 30s | N/A | ❌ Too slow |
| **Materialized Views** | <100ms | ⭐⭐ Moderate | ✅ YES |
| **Table Partitioning** | 2s | ⭐⭐⭐ Hard | 🟡 Optional |
| **Read Replica** | Varies | ⭐⭐⭐ Hard | 🟡 Large deployments |

**Recommendation**: Start with **Materialized Views** (Strategy 1).

---

## Visualization Strategy

### Charting Library Selection

synapse-admin currently has **no charting library**.

#### Option A: Chart.js (Recommended)

**Pros**:
- Lightweight (~60KB)
- Easy to use
- Good React integration (`react-chartjs-2`)
- Free and open source

**Installation**:
```bash
npm install chart.js react-chartjs-2
```

**Usage**:
```typescript
import { Line, Bar } from "react-chartjs-2";

<Line data={chartData} options={{ responsive: true }} />
```

#### Option B: Recharts

**Pros**:
- Built for React
- Declarative API
- Good documentation

**Cons**:
- Larger bundle size (~100KB)

#### Option C: Victory

**Pros**:
- Highly customizable
- Great for complex visualizations

**Cons**:
- Steeper learning curve
- Larger bundle size

### Recommendation: Chart.js

**Reasoning**:
- Simplest integration
- Smallest size
- Sufficient for your needs

### Chart Types Needed

1. **Line Chart**: Messages per day (time series)
2. **Bar Chart**: Files per day with volume
3. **Stacked Bar Chart**: Call types (P2P vs Group)
4. **Table**: Top 10 rooms/users
5. **Alert List**: Malicious files

All easily handled by Chart.js.

---

## Summary: Statistics Dashboard

### Feasibility Assessment

| Statistic | Difficulty | Data Availability | Performance | Recommendation |
|-----------|-----------|------------------|-------------|----------------|
| **Messages per day** | ⭐⭐ EASY | ✅ events table | 🟡 Optimize | ✅ Implement |
| **Files per day** | ⭐ TRIVIAL | ✅ local_media_repository | 🟢 Fast | ✅ Implement |
| **Rooms per day** | ⭐ TRIVIAL | ✅ events table | 🟢 Fast | ✅ Implement |
| **Calls per day** | ⭐⭐ EASY | ✅ events table | 🟢 Fast | ✅ Implement |
| **Registrations per day** | ⭐ TRIVIAL | ✅ users table | 🟢 Fast | ✅ Implement |
| **Top rooms** | ⭐⭐ EASY | ✅ events table | 🟡 Optimize | ✅ Implement |
| **Top users** | ⭐⭐ EASY | ✅ events table | 🟡 Optimize | ✅ Implement |
| **Malicious files** | ⭐⭐⭐ MODERATE | ⚠️ Need AV integration | 🟢 Fast | ✅ Implement |

### Implementation Estimate

**Synapse API Endpoints** (8 endpoints):
- 1-2 days per endpoint
- **Total**: 2 weeks

**synapse-admin Components** (5 components):
- 1 day per component
- **Total**: 1 week

**Database Optimizations** (materialized views):
- 2-3 days

**Antivirus Integration**:
- 3-5 days (ClamAV setup + testing)

**Testing & Refinement**:
- 1 week

**Total Estimated Effort**: 5-6 weeks

### Next Steps

Continue to [Part 5: Summary & Implementation Roadmap](LI_REQUIREMENTS_ANALYSIS_05_SUMMARY.md) →

---

**Document Information**:
- **Part**: 4 of 5
- **Topic**: Statistics Dashboard Implementation
- **Status**: ✅ Complete
- **API Endpoints**: 8 new endpoints required
- **UI Components**: 5 new React components
- **Database Tables**: 2 new tables (statistics_daily, malicious_files)
- **External Dependencies**: ClamAV (antivirus), Chart.js (visualization)
