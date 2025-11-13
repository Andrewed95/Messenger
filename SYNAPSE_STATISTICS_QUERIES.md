# Synapse Database - Statistics Extraction Queries

This document provides practical SQL queries to extract various statistics from a Synapse Matrix server database.

---

## BASIC MESSAGE STATISTICS

### Total Message Count
```sql
SELECT COUNT(*) as total_messages
FROM events
WHERE type = 'm.room.message';
```

### Messages by Room (Top 20)
```sql
SELECT 
    room_id,
    COUNT(*) as message_count,
    MIN(origin_server_ts) as first_message,
    MAX(origin_server_ts) as last_message,
    COUNT(DISTINCT sender) as unique_senders
FROM events
WHERE type = 'm.room.message'
GROUP BY room_id
ORDER BY message_count DESC
LIMIT 20;
```

### Messages by User (Top 20)
```sql
SELECT 
    sender,
    COUNT(*) as message_count,
    COUNT(DISTINCT room_id) as rooms_active,
    MIN(origin_server_ts) as first_message,
    MAX(origin_server_ts) as last_message
FROM events
WHERE type = 'm.room.message'
GROUP BY sender
ORDER BY message_count DESC
LIMIT 20;
```

### Daily Message Volume (Last 30 Days)
```sql
SELECT 
    DATE(to_timestamp(origin_server_ts / 1000.0)) as message_date,
    COUNT(*) as message_count,
    COUNT(DISTINCT sender) as active_users,
    COUNT(DISTINCT room_id) as active_rooms
FROM events
WHERE type = 'm.room.message'
  AND origin_server_ts > (EXTRACT(EPOCH FROM NOW()) * 1000 - 30 * 24 * 3600 * 1000)
GROUP BY DATE(to_timestamp(origin_server_ts / 1000.0))
ORDER BY message_date DESC;
```

### Messages with Media (URLs)
```sql
SELECT 
    COUNT(*) as messages_with_media,
    COUNT(DISTINCT sender) as users_sharing_media,
    COUNT(DISTINCT room_id) as rooms_with_media
FROM events
WHERE type = 'm.room.message'
  AND contains_url = TRUE;
```

---

## ROOM STATISTICS

### Basic Room Statistics
```sql
SELECT 
    r.room_id,
    r.is_public,
    r.creator,
    rsc.current_state_events,
    rsc.joined_members,
    rsc.invited_members,
    rsc.left_members,
    rsc.banned_members,
    rss.name,
    rss.room_type,
    rss.encryption,
    rss.is_federatable
FROM rooms r
LEFT JOIN room_stats_current rsc ON r.room_id = rsc.room_id
LEFT JOIN room_stats_state rss ON r.room_id = rss.room_id
ORDER BY rsc.joined_members DESC NULLS LAST
LIMIT 50;
```

### Most Active Rooms
```sql
SELECT 
    e.room_id,
    r.is_public,
    rss.name,
    COUNT(*) as total_events,
    COUNT(DISTINCT e.sender) as unique_senders,
    COUNT(CASE WHEN e.type = 'm.room.message' THEN 1 END) as message_count,
    MIN(e.origin_server_ts) as first_event,
    MAX(e.origin_server_ts) as last_event,
    rsc.joined_members
FROM events e
LEFT JOIN rooms r ON e.room_id = r.room_id
LEFT JOIN room_stats_state rss ON e.room_id = rss.room_id
LEFT JOIN room_stats_current rsc ON e.room_id = rsc.room_id
GROUP BY e.room_id, r.is_public, rss.name, rsc.joined_members
ORDER BY message_count DESC
LIMIT 50;
```

### Room Creation Timeline
```sql
SELECT 
    DATE(to_timestamp(e.origin_server_ts / 1000.0)) as creation_date,
    COUNT(DISTINCT e.room_id) as rooms_created,
    COUNT(DISTINCT e.sender) as creators
FROM events e
WHERE e.type = 'm.room.create'
GROUP BY DATE(to_timestamp(e.origin_server_ts / 1000.0))
ORDER BY creation_date DESC;
```

### Public vs Private Rooms
```sql
SELECT 
    r.is_public,
    COUNT(*) as room_count,
    AVG(rsc.joined_members) as avg_members,
    SUM(rsc.joined_members) as total_members,
    SUM(COALESCE((
        SELECT COUNT(*) FROM events e 
        WHERE e.room_id = r.room_id AND e.type = 'm.room.message'
    ), 0)) as total_messages
FROM rooms r
LEFT JOIN room_stats_current rsc ON r.room_id = rsc.room_id
GROUP BY r.is_public;
```

### Rooms by Type (if available)
```sql
SELECT 
    rss.room_type,
    COUNT(*) as room_count,
    AVG(rsc.joined_members) as avg_members,
    COUNT(DISTINCT rsc.room_id) as rooms_with_stats
FROM room_stats_state rss
LEFT JOIN room_stats_current rsc ON rss.room_id = rsc.room_id
GROUP BY rss.room_type
ORDER BY room_count DESC;
```

### Encrypted vs Unencrypted Rooms
```sql
SELECT 
    CASE WHEN rss.encryption IS NOT NULL THEN 'Encrypted' ELSE 'Unencrypted' END as encryption_status,
    COUNT(*) as room_count,
    AVG(rsc.joined_members) as avg_members,
    SUM(rsc.joined_members) as total_members
FROM room_stats_state rss
LEFT JOIN room_stats_current rsc ON rss.room_id = rsc.room_id
GROUP BY CASE WHEN rss.encryption IS NOT NULL THEN 'Encrypted' ELSE 'Unencrypted' END;
```

---

## USER STATISTICS

### Total User Count
```sql
SELECT 
    COUNT(*) as total_users,
    SUM(CASE WHEN is_guest = 1 THEN 1 ELSE 0 END) as guest_users,
    SUM(CASE WHEN is_guest = 0 THEN 1 ELSE 0 END) as registered_users,
    SUM(CASE WHEN deactivated = 1 THEN 1 ELSE 0 END) as deactivated_users,
    SUM(CASE WHEN admin = 1 THEN 1 ELSE 0 END) as admin_users
FROM users;
```

### User Registration Timeline (Last 30 Days)
```sql
SELECT 
    DATE(to_timestamp(creation_ts / 1000.0)) as registration_date,
    COUNT(*) as new_users,
    SUM(CASE WHEN is_guest = 1 THEN 1 ELSE 0 END) as guest_registrations
FROM users
WHERE creation_ts > (EXTRACT(EPOCH FROM NOW()) * 1000 - 30 * 24 * 3600 * 1000)
GROUP BY DATE(to_timestamp(creation_ts / 1000.0))
ORDER BY registration_date DESC;
```

### Daily Active Users (DAU) - Last 30 Days
```sql
SELECT 
    DATE(to_timestamp(timestamp / 1000.0)) as activity_date,
    COUNT(DISTINCT user_id) as daily_active_users,
    COUNT(DISTINCT device_id) as active_devices
FROM user_daily_visits
WHERE timestamp > (EXTRACT(EPOCH FROM NOW()) * 1000 - 30 * 24 * 3600 * 1000)
GROUP BY DATE(to_timestamp(timestamp / 1000.0))
ORDER BY activity_date DESC;
```

### Monthly Active Users
```sql
SELECT 
    COUNT(*) as monthly_active_users,
    MIN(to_timestamp(timestamp / 1000.0)) as earliest_activity,
    MAX(to_timestamp(timestamp / 1000.0)) as latest_activity
FROM monthly_active_users;
```

### User Activity Summary
```sql
SELECT 
    u.name,
    u.creation_ts,
    u.is_guest,
    u.deactivated,
    u.admin,
    usc.joined_rooms,
    (SELECT COUNT(*) FROM events WHERE sender = u.name) as total_events,
    (SELECT COUNT(*) FROM events WHERE sender = u.name AND type = 'm.room.message') as message_count,
    (SELECT MAX(origin_server_ts) FROM events WHERE sender = u.name) as last_activity
FROM users u
LEFT JOIN user_stats_current usc ON u.name = usc.user_id
ORDER BY message_count DESC NULLS LAST
LIMIT 50;
```

### Most Active Users (by Message Count)
```sql
SELECT 
    sender,
    COUNT(*) as message_count,
    COUNT(DISTINCT room_id) as rooms_active,
    COUNT(DISTINCT DATE(to_timestamp(origin_server_ts / 1000.0))) as active_days,
    MIN(origin_server_ts) as first_message,
    MAX(origin_server_ts) as last_message
FROM events
WHERE type = 'm.room.message'
GROUP BY sender
ORDER BY message_count DESC
LIMIT 50;
```

### User Retention (Active in Last 7, 30, 90 Days)
```sql
SELECT 
    COUNT(DISTINCT CASE WHEN timestamp > (EXTRACT(EPOCH FROM NOW()) * 1000 - 7 * 24 * 3600 * 1000) THEN user_id END) as active_7d,
    COUNT(DISTINCT CASE WHEN timestamp > (EXTRACT(EPOCH FROM NOW()) * 1000 - 30 * 24 * 3600 * 1000) THEN user_id END) as active_30d,
    COUNT(DISTINCT CASE WHEN timestamp > (EXTRACT(EPOCH FROM NOW()) * 1000 - 90 * 24 * 3600 * 1000) THEN user_id END) as active_90d
FROM user_daily_visits;
```

---

## MEDIA/FILE STATISTICS

### Media Upload Statistics
```sql
SELECT 
    COUNT(*) as total_uploads,
    COUNT(DISTINCT user_id) as uploaders,
    SUM(media_length) as total_storage_bytes,
    ROUND(SUM(media_length) / 1024 / 1024 / 1024, 2) as total_storage_gb,
    AVG(media_length) as avg_file_size,
    MAX(media_length) as largest_file
FROM local_media_repository;
```

### Media by Type
```sql
SELECT 
    media_type,
    COUNT(*) as file_count,
    SUM(media_length) as total_bytes,
    ROUND(SUM(media_length) / 1024 / 1024, 2) as total_mb,
    AVG(media_length) as avg_size,
    MAX(media_length) as max_size
FROM local_media_repository
GROUP BY media_type
ORDER BY total_bytes DESC;
```

### Media Upload Timeline (Last 30 Days)
```sql
SELECT 
    DATE(to_timestamp(created_ts / 1000.0)) as upload_date,
    COUNT(*) as files_uploaded,
    COUNT(DISTINCT user_id) as unique_uploaders,
    SUM(media_length) as bytes_uploaded,
    ROUND(SUM(media_length) / 1024 / 1024, 2) as mb_uploaded
FROM local_media_repository
WHERE created_ts > (EXTRACT(EPOCH FROM NOW()) * 1000 - 30 * 24 * 3600 * 1000)
GROUP BY DATE(to_timestamp(created_ts / 1000.0))
ORDER BY upload_date DESC;
```

### Top Media Uploaders
```sql
SELECT 
    user_id,
    COUNT(*) as upload_count,
    SUM(media_length) as total_bytes,
    ROUND(SUM(media_length) / 1024 / 1024, 2) as total_mb,
    MIN(created_ts) as first_upload,
    MAX(created_ts) as last_upload
FROM local_media_repository
WHERE user_id IS NOT NULL
GROUP BY user_id
ORDER BY total_bytes DESC
LIMIT 50;
```

### Unused/Stale Media
```sql
SELECT 
    COUNT(*) as stale_media_count,
    SUM(media_length) as stale_storage_bytes,
    ROUND(SUM(media_length) / 1024 / 1024, 2) as stale_storage_mb,
    MIN(last_access_ts) as earliest_access,
    MAX(last_access_ts) as latest_access
FROM local_media_repository
WHERE last_access_ts < (EXTRACT(EPOCH FROM NOW()) * 1000 - 90 * 24 * 3600 * 1000)
   OR last_access_ts IS NULL;
```

---

## MEMBERSHIP STATISTICS

### Current Room Membership
```sql
SELECT 
    room_id,
    SUM(CASE WHEN membership = 'join' THEN 1 ELSE 0 END) as joined,
    SUM(CASE WHEN membership = 'invite' THEN 1 ELSE 0 END) as invited,
    SUM(CASE WHEN membership = 'leave' THEN 1 ELSE 0 END) as left,
    SUM(CASE WHEN membership = 'ban' THEN 1 ELSE 0 END) as banned
FROM room_memberships
GROUP BY room_id
ORDER BY joined DESC
LIMIT 50;
```

### User's Room Count
```sql
SELECT 
    user_id,
    COUNT(DISTINCT room_id) as joined_rooms
FROM local_current_membership
GROUP BY user_id
ORDER BY joined_rooms DESC
LIMIT 50;
```

### Membership Changes Over Time
```sql
SELECT 
    DATE(to_timestamp(e.origin_server_ts / 1000.0)) as event_date,
    COUNT(CASE WHEN rm.membership = 'join' THEN 1 END) as joins,
    COUNT(CASE WHEN rm.membership = 'leave' THEN 1 END) as leaves,
    COUNT(CASE WHEN rm.membership = 'invite' THEN 1 END) as invites,
    COUNT(CASE WHEN rm.membership = 'ban' THEN 1 END) as bans
FROM events e
JOIN room_memberships rm ON e.event_id = rm.event_id
WHERE e.type = 'm.room.member'
GROUP BY DATE(to_timestamp(e.origin_server_ts / 1000.0))
ORDER BY event_date DESC;
```

---

## CALL/VOIP STATISTICS

### Call Events Count
```sql
SELECT 
    type,
    COUNT(*) as event_count,
    COUNT(DISTINCT room_id) as rooms_with_calls,
    COUNT(DISTINCT sender) as unique_participants,
    MIN(origin_server_ts) as first_call,
    MAX(origin_server_ts) as last_call
FROM events
WHERE type LIKE 'm.call%'
GROUP BY type
ORDER BY event_count DESC;
```

### Call Participation
```sql
SELECT 
    room_id,
    COUNT(DISTINCT sender) as unique_participants,
    COUNT(*) as total_call_events,
    MIN(origin_server_ts) as first_call,
    MAX(origin_server_ts) as last_call
FROM events
WHERE type LIKE 'm.call%'
GROUP BY room_id
ORDER BY unique_participants DESC;
```

### Daily Call Activity
```sql
SELECT 
    DATE(to_timestamp(origin_server_ts / 1000.0)) as call_date,
    COUNT(*) as call_events,
    COUNT(DISTINCT room_id) as rooms_with_calls,
    COUNT(DISTINCT sender) as participants
FROM events
WHERE type LIKE 'm.call%'
GROUP BY DATE(to_timestamp(origin_server_ts / 1000.0))
ORDER BY call_date DESC;
```

---

## OVERALL PLATFORM STATISTICS

### Comprehensive Platform Overview
```sql
WITH message_stats AS (
    SELECT COUNT(*) as total_messages FROM events WHERE type = 'm.room.message'
),
user_stats AS (
    SELECT COUNT(*) as total_users FROM users WHERE deactivated = 0
),
room_stats AS (
    SELECT COUNT(*) as total_rooms FROM rooms
),
media_stats AS (
    SELECT 
        COUNT(*) as total_media,
        SUM(media_length) as total_storage
    FROM local_media_repository
),
active_stats AS (
    SELECT 
        COUNT(DISTINCT user_id) as mau
    FROM monthly_active_users
)
SELECT 
    (SELECT total_messages FROM message_stats) as total_messages,
    (SELECT total_users FROM user_stats) as total_users,
    (SELECT total_rooms FROM room_stats) as total_rooms,
    (SELECT total_media FROM media_stats) as total_media_files,
    ROUND((SELECT total_storage FROM media_stats)::numeric / 1024 / 1024 / 1024, 2) as storage_gb,
    (SELECT mau FROM active_stats) as monthly_active_users;
```

---

## PERFORMANCE TIPS

1. **Add time window conditions** to events queries to avoid scanning entire table:
   ```sql
   WHERE origin_server_ts > (EXTRACT(EPOCH FROM NOW()) * 1000 - 30 * 24 * 3600 * 1000)
   ```

2. **Use appropriate indexes** - ensure these exist:
   - `events_room_stream` - for room-based queries
   - `events_ts` - for time-based queries
   - `user_daily_visits_ts_idx` - for activity queries

3. **Consider pagination** for large result sets:
   ```sql
   LIMIT 50 OFFSET page * 50
   ```

4. **Materialize complex stats** - consider creating views or tables for frequently-used statistics

5. **Batch processing** - for large exports, use streaming rather than loading all at once

---

## NOTES

- All timestamps in Synapse are in **milliseconds since epoch** (not seconds)
- User IDs are stored with their server domain (e.g., `@user:server.com`)
- Room IDs also include domain (e.g., `!abc123:server.com`)
- The `sender` field in events contains the full user ID
- Queries may need adjustment based on PostgreSQL or SQLite syntax differences

