# Synapse Database Schema for Statistics Extraction

## Overview
Synapse uses a comprehensive database schema to track messages, rooms, users, media, and various statistics. The current schema version is 72 (based on /main/full_schemas/72/).

---

## 1. CORE TABLES FOR MESSAGE COUNTS

### EVENTS TABLE (Critical for Message Statistics)
**Location:** Lines 409-427 in full.sql.postgres

```sql
CREATE TABLE events (
    topological_ordering bigint NOT NULL,
    event_id text NOT NULL,
    type text NOT NULL,                    -- Event type (e.g., 'm.room.message')
    room_id text NOT NULL,
    content text,                          -- Event content (JSON)
    unrecognized_keys text,
    processed boolean NOT NULL,
    outlier boolean NOT NULL,
    depth bigint DEFAULT 0 NOT NULL,
    origin_server_ts bigint,               -- Timestamp when event was created
    received_ts bigint,                    -- Timestamp when server received it
    sender text,                           -- User who sent the event
    contains_url boolean,
    instance_name text,
    stream_ordering bigint,                -- Stream ID (important for ordering)
    state_key text,                        -- For state events
    rejection_reason text
);
```

**Key Fields for Statistics:**
- `type`: Event type identifier ('m.room.message' for regular messages)
- `room_id`: Which room the event is in
- `sender`: Who sent it
- `origin_server_ts`: When it was created (milliseconds since epoch)
- `stream_ordering`: Global ordering of events (useful for time-series queries)
- `contains_url`: Boolean flag for media-containing messages

**Indexes:**
- `events_stream_ordering` (UNIQUE on stream_ordering)
- `events_room_stream` (room_id, stream_ordering)
- `events_order_room` (room_id, topological_ordering, stream_ordering)
- `events_ts` (origin_server_ts, stream_ordering)
- `event_contains_url_index` (room_id, topological_ordering, stream_ordering)

---

## 2. ROOM STATISTICS TABLES

### ROOM_STATS_CURRENT (Current Room Statistics)
**Location:** Full schema v72

```sql
CREATE TABLE room_stats_current (
    room_id text NOT NULL PRIMARY KEY,
    
    -- Absolute counts
    current_state_events integer NOT NULL,
    joined_members integer NOT NULL,
    invited_members integer NOT NULL,
    left_members integer NOT NULL,
    banned_members integer NOT NULL,
    local_users_in_room integer NOT NULL,
    
    -- The maximum delta stream position this row accounts for
    completed_delta_stream_id bigint NOT NULL
);
```

**What it tracks:**
- Current state event count in room
- Member counts by status (joined, invited, left, banned)
- Local users only (not federation)

### ROOM_STATS_STATE (Room State Information)
**Location:** Full schema v72

```sql
CREATE TABLE room_stats_state (
    room_id text NOT NULL,
    name text,
    canonical_alias text,
    join_rules text,
    history_visibility text,
    encryption text,
    avatar text,
    guest_access text,
    is_federatable boolean,
    topic text,
    room_type text                         -- NEW: Added in delta 72
);

CREATE UNIQUE INDEX room_stats_state_room ON room_stats_state(room_id);
```

**What it tracks:**
- Room metadata and settings
- Room type (useful for identifying call rooms, spaces, etc.)
- Encryption status

### ROOM_STATS_EARLIEST_TOKEN
```sql
CREATE TABLE room_stats_earliest_token (
    room_id text NOT NULL,
    token bigint NOT NULL
);
```

**Tracks:** The earliest available statistics token for a room

---

## 3. USER STATISTICS TABLES

### USER_STATS_CURRENT (Current User Statistics)
**Location:** Full schema v72

```sql
CREATE TABLE user_stats_current (
    user_id text NOT NULL PRIMARY KEY,
    joined_rooms bigint NOT NULL,
    completed_delta_stream_id bigint NOT NULL
);
```

**What it tracks:**
- Number of rooms each user is currently in (joined)

---

## 4. ROOM CREATION & METADATA

### ROOMS TABLE
**Location:** Lines 784-790 in full.sql.postgres

```sql
CREATE TABLE rooms (
    room_id text NOT NULL PRIMARY KEY,
    is_public boolean,                     -- Public vs private
    creator text,                          -- User who created room
    room_version text,                     -- Matrix spec version
    has_auth_chain_index boolean
);
```

**What it tracks:**
- Room creation info and visibility settings
- Can JOIN with events table to find room creation time via m.room.create events

---

## 5. USER TRACKING TABLES

### USERS TABLE (User Registrations)
**Location:** Lines 942-956 in full.sql.postgres

```sql
CREATE TABLE users (
    name text,
    password_hash text,
    creation_ts bigint,                    -- User registration timestamp (ms)
    admin smallint DEFAULT 0 NOT NULL,
    upgrade_ts bigint,
    is_guest smallint DEFAULT 0 NOT NULL,
    appservice_id text,
    consent_version text,
    consent_server_notice_sent text,
    user_type text,
    deactivated smallint DEFAULT 0 NOT NULL,
    shadow_banned boolean,
    consent_ts bigint
);

CREATE UNIQUE INDEX users_creation_ts ON users USING btree (creation_ts);
```

**What it tracks:**
- User creation time
- User status (admin, guest, deactivated)
- User types

### USER_DAILY_VISITS
**Location:** Added in delta 49, modified in delta 58

```sql
CREATE TABLE user_daily_visits (
    user_id text NOT NULL,
    device_id text,
    timestamp bigint NOT NULL,             -- Date of visit (ms)
    user_agent text                        -- Added in delta 58
);

CREATE INDEX user_daily_visits_uts_idx ON user_daily_visits(user_id, timestamp);
CREATE INDEX user_daily_visits_ts_idx ON user_daily_visits(timestamp);
```

**What it tracks:**
- Daily user activity (one row per user per day)
- Device information
- User agent/client info
- USED FOR: Daily active users (DAU) statistics

### MONTHLY_ACTIVE_USERS
**Location:** Added in delta 51

```sql
CREATE TABLE monthly_active_users (
    user_id text NOT NULL,
    timestamp bigint NOT NULL              -- Last seen timestamp (ms)
);

CREATE UNIQUE INDEX monthly_active_users_users ON monthly_active_users(user_id);
CREATE INDEX monthly_active_users_time_stamp ON monthly_active_users(timestamp);
```

**What it tracks:**
- Users active in the past month (for rate limiting and quota purposes)
- Last activity timestamp
- Note: Updates are rate-limited for performance
- USED FOR: Monthly active users (MAU) statistics

---

## 6. MEDIA & FILE UPLOADS

### LOCAL_MEDIA_REPOSITORY (Uploaded Media Tracking)
**Location:** Lines 495-506 in full.sql.postgres

```sql
CREATE TABLE local_media_repository (
    media_id text,
    media_type text,                       -- MIME type
    media_length integer,                  -- File size in bytes
    created_ts bigint,                     -- Upload timestamp (ms)
    upload_name text,                      -- Original filename
    user_id text,                          -- Who uploaded it
    quarantined_by text,
    url_cache text,
    last_access_ts bigint,
    safe_from_quarantine boolean DEFAULT false NOT NULL
);

CREATE UNIQUE INDEX local_media_repository_media_id_key ON local_media_repository(media_id);
CREATE INDEX users_have_local_media ON local_media_repository(user_id, created_ts);
```

**What it tracks:**
- All media files uploaded to the server
- File size and type
- Upload time and user
- Last accessed time

### LOCAL_MEDIA_REPOSITORY_THUMBNAILS
```sql
CREATE TABLE local_media_repository_thumbnails (
    media_id text,
    thumbnail_width integer,
    thumbnail_height integer,
    thumbnail_type text,
    thumbnail_method text,
    thumbnail_length integer
);
```

**What it tracks:**
- Generated thumbnails for media files

---

## 7. EVENT TYPES FOR STATISTICS

From synapse/api/constants.py, key event types for statistics:

**State Events:**
- `m.room.create` - Room creation
- `m.room.member` - Membership changes
- `m.room.message` - Regular text messages
- `m.room.name` - Room name changes
- `m.room.topic` - Room topic
- `m.room.avatar` - Room avatar
- `m.room.join_rules` - Join rules
- `m.room.history_visibility` - History settings
- `m.room.encryption` - E2E encryption
- `m.room.power_levels` - Permission changes
- `m.room.server_acl` - Server ACL

**Call-Related Events:**
- `m.call.*` events (in Matrix spec, though not dedicated table)
- Can be tracked via event type field in events table

---

## 8. CURRENT STATE TRACKING

### CURRENT_STATE_EVENTS
**Location:** Full schema v72

```sql
CREATE TABLE current_state_events (
    event_id text NOT NULL,
    room_id text NOT NULL,
    type text NOT NULL,                    -- Event type
    state_key text NOT NULL,               -- For state events
    membership text                        -- For membership events
);

CREATE UNIQUE INDEX current_state_events_room_id_type_state_key_key 
    ON current_state_events(room_id, type, state_key);
```

**What it tracks:**
- Current state in each room (de-duplicated)
- Useful for fast queries on room settings

### ROOM_MEMBERSHIPS (Historical Membership)
**Location:** Full schema v72

```sql
CREATE TABLE room_memberships (
    event_id text NOT NULL,
    user_id text NOT NULL,
    sender text NOT NULL,                  -- Who changed the membership
    room_id text NOT NULL,
    membership text NOT NULL,              -- join/leave/invite/ban/knock
    forgotten integer DEFAULT 0,
    display_name text,
    avatar_url text
);

CREATE INDEX room_memberships_room_id ON room_memberships(room_id);
CREATE INDEX room_memberships_user_id ON room_memberships(user_id);
```

**What it tracks:**
- All membership changes (join/leave/etc)
- Useful for tracking user activity in rooms

---

## 9. OPTIONAL/ADVANCED STATISTICS TABLES

### STATS_INCREMENTAL_POSITION
```sql
CREATE TABLE stats_incremental_position (
    Lock CHAR(1) NOT NULL DEFAULT 'X' UNIQUE,
    stream_id bigint NOT NULL
);
```
**Tracks:** Position in event stream for incremental stats updates

### EVENT_SEARCH
```sql
CREATE TABLE event_search (
    event_id text,
    room_id text,
    sender text,
    key text,
    vector tsvector,                       -- Full-text search vector
    origin_server_ts bigint,
    stream_ordering bigint
);
```
**Tracks:** Full-text searchable event content

### LOCAL_CURRENT_MEMBERSHIP
```sql
CREATE TABLE local_current_membership (
    room_id text NOT NULL,
    user_id text NOT NULL,
    event_id text NOT NULL,
    membership text NOT NULL               -- Current membership state
);
```
**Tracks:** Fast lookup of who's in each room

---

## AVAILABLE STATISTICS TO EXTRACT

### Message Statistics
1. **Total message count** - `SELECT COUNT(*) FROM events WHERE type = 'm.room.message'`
2. **Messages by room** - GROUP BY room_id
3. **Messages by user** - GROUP BY sender
4. **Messages by date** - GROUP BY DATE(from_timestamp_ms(origin_server_ts))
5. **Avg messages per room** - Calculate mean
6. **Messages with media** - WHERE contains_url = TRUE

### Room Statistics
1. **Total rooms** - `SELECT COUNT(DISTINCT room_id) FROM events`
2. **Public vs private rooms** - `SELECT is_public, COUNT(*) FROM rooms GROUP BY is_public`
3. **Room membership breakdown** - Use room_stats_current
4. **Most active rooms** - Join events with rooms, count by room_id
5. **Rooms by type** - From room_stats_state.room_type
6. **Room creation rate** - Use room creation event timestamps

### User Statistics
1. **Total users** - `SELECT COUNT(*) FROM users`
2. **Daily active users (DAU)** - `SELECT COUNT(DISTINCT user_id) FROM user_daily_visits WHERE DATE(timestamp/1000) = TODAY()`
3. **Monthly active users (MAU)** - `SELECT COUNT(*) FROM monthly_active_users`
4. **User registration rate** - `SELECT creation_ts FROM users ORDER BY creation_ts`
5. **Active users** - Users with events in events table
6. **User retention** - Compare current users with historical snapshots

### Media Statistics
1. **Total media uploaded** - `SELECT COUNT(*) FROM local_media_repository`
2. **Total storage used** - `SELECT SUM(media_length) FROM local_media_repository`
3. **Media by type** - `SELECT media_type, COUNT(*), SUM(media_length) FROM local_media_repository GROUP BY media_type`
4. **Media upload rate** - Group by date using created_ts
5. **Popular media** - Sort by last_access_ts

### Call Statistics (Via Events Table)
1. **Call events** - `SELECT * FROM events WHERE type LIKE 'm.call%'`
2. **Call participation** - Count distinct users in m.call.* events
3. **Call duration** - Parse from m.call.answer vs m.call.hangup events
4. **Call success rate** - Compare answer vs hangup events

---

## KEY INDEXES FOR EFFICIENT QUERIES

For statistics queries, these indexes are critical:

- **events_stream_ordering** - Fast time-based queries
- **events_room_stream** - Queries by room and time
- **events_ts** - Queries on origin_server_ts
- **users_creation_ts** - User registration queries
- **user_daily_visits_ts_idx** - Daily active user queries
- **monthly_active_users_time_stamp** - MAU queries
- **users_have_local_media** - Media queries
- **room_memberships_room_id** - Membership by room

---

## SCHEMA VERSION & LOCATION

- **Current Schema Version:** 72
- **Full Schema File:** `/synapse/synapse/storage/schema/main/full_schemas/72/full.sql.postgres`
- **SQLite Version:** `/synapse/synapse/storage/schema/main/full_schemas/72/full.sql.sqlite`
- **Delta Files:** `/synapse/synapse/storage/schema/main/delta/[version]/`
- **Common Schema:** `/synapse/synapse/storage/schema/common/`

---

## STATISTICS MAINTENANCE

Synapse maintains incremental statistics via background updates:
- Events are processed as they arrive
- Room stats updated when membership changes
- User stats updated on login/activity
- Stats position tracked in `stats_incremental_position` table

---
