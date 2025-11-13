# Synapse Database Schema Analysis - Complete Documentation

This directory contains comprehensive documentation of the Synapse Matrix server database schema, focusing on statistics extraction capabilities.

## Documents Included

### 1. SYNAPSE_SCHEMA_ANALYSIS.md
**Complete database schema reference guide**

Contains:
- Overview of all major tables
- Detailed schema definitions for:
  - Events table (critical for message statistics)
  - Room statistics tables (current and historical)
  - User statistics tables
  - Media/file upload tracking
  - User tracking and activity tables
  - Current state tables
- Event types available for tracking
- All indexes used for efficient queries
- List of extractable statistics

### 2. SYNAPSE_STATISTICS_QUERIES.md
**Ready-to-use SQL queries for extracting statistics**

Contains practical SQL examples for:
- Message statistics (counts, by room, by user, daily trends)
- Room statistics (basic info, activity, creation timeline, encryption status)
- User statistics (total counts, registrations, DAU, MAU, retention)
- Media statistics (uploads, storage usage, by type, upload timeline)
- Membership statistics (room membership, membership changes)
- Call/VoIP statistics (call events, participation, daily activity)
- Platform overview statistics
- Performance tips and best practices

## Key Findings

### Critical Tables for Statistics

1. **events** - Contains ALL events in the system
   - 27 columns tracking type, room, user, timestamp, content
   - 5+ indexes for efficient querying
   - Includes message content and metadata

2. **room_stats_current** - Pre-calculated room statistics
   - Member counts (joined, invited, left, banned)
   - State event count
   - Local user count

3. **user_stats_current** - Pre-calculated user statistics
   - Joined room count per user
   - Update position tracking

4. **local_media_repository** - All uploaded files
   - File size, type, upload date
   - User who uploaded it
   - Last access tracking

5. **users** - User registration tracking
   - Creation timestamp
   - User type (admin, guest)
   - Deactivation status

6. **monthly_active_users** - Monthly activity tracking
   - Last activity timestamp
   - Used for quota/rate limiting

7. **user_daily_visits** - Daily activity tracking
   - Date of visit
   - Device and user agent info
   - Useful for DAU calculations

### Available Statistics Categories

Message Statistics:
- Total message count
- Messages by room
- Messages by user
- Daily message volume
- Messages with media

Room Statistics:
- Total rooms
- Public vs private breakdown
- Room membership counts
- Most active rooms
- Room creation rate
- Rooms by type
- Encrypted vs unencrypted

User Statistics:
- Total users (registered, guests, deactivated, admin)
- User registration rate
- Daily active users (DAU)
- Monthly active users (MAU)
- User retention
- Most active users

Media Statistics:
- Total uploads and storage used
- Storage by file type
- Upload rate over time
- Top uploaders
- Stale/unused media

Call Statistics:
- Call event count
- Call participation
- Daily call activity
- Call duration (via m.call.answer/hangup events)

## Database Schema Location

Current Schema Version: 72

Files:
- Full schema (PostgreSQL): `/synapse/synapse/storage/schema/main/full_schemas/72/full.sql.postgres`
- Full schema (SQLite): `/synapse/synapse/storage/schema/main/full_schemas/72/full.sql.sqlite`
- Delta migration files: `/synapse/synapse/storage/schema/main/delta/[version]/`
- Common schema files: `/synapse/synapse/storage/schema/common/`

## Important Notes

1. **Timestamps**: All Synapse timestamps are in MILLISECONDS since epoch (not seconds)
   - Conversion: `to_timestamp(column_name / 1000.0)` in PostgreSQL

2. **User/Room IDs**: Include server domain
   - User: `@user:server.com`
   - Room: `!abc123:server.com`

3. **Event Types**: Use Matrix spec types
   - Messages: `m.room.message`
   - Membership: `m.room.member`
   - Room creation: `m.room.create`
   - Calls: `m.call.*` (various)

4. **Statistics Tables**: Pre-calculated and maintained by Synapse
   - Updated incrementally as events occur
   - Position tracked in `stats_incremental_position`

5. **Indexes**: Critical for performance
   - `events_stream_ordering` - time-based queries
   - `events_room_stream` - room and time queries
   - `users_creation_ts` - registration queries
   - `user_daily_visits_ts_idx` - activity queries
   - `monthly_active_users_time_stamp` - MAU queries

## Usage Examples

### Quick Query for Total Messages
```sql
SELECT COUNT(*) as total_messages
FROM events
WHERE type = 'm.room.message';
```

### Messages Over Last 30 Days
```sql
SELECT 
    DATE(to_timestamp(origin_server_ts / 1000.0)) as message_date,
    COUNT(*) as message_count
FROM events
WHERE type = 'm.room.message'
  AND origin_server_ts > (EXTRACT(EPOCH FROM NOW()) * 1000 - 30 * 24 * 3600 * 1000)
GROUP BY DATE(to_timestamp(origin_server_ts / 1000.0))
ORDER BY message_date DESC;
```

### Monthly Active Users
```sql
SELECT COUNT(*) as monthly_active_users
FROM monthly_active_users;
```

### Room with Members
```sql
SELECT 
    room_id,
    joined_members,
    invited_members,
    current_state_events
FROM room_stats_current
ORDER BY joined_members DESC
LIMIT 20;
```

See SYNAPSE_STATISTICS_QUERIES.md for many more examples.

## Next Steps

1. Use SYNAPSE_SCHEMA_ANALYSIS.md as a reference for understanding available data
2. Use SYNAPSE_STATISTICS_QUERIES.md to extract specific statistics
3. Adapt queries as needed for your use case
4. Consider materializing frequently-used statistics as views for performance
5. Add time-window conditions to large queries to improve performance

## Database Access

These statistics can be accessed from:
- PostgreSQL Synapse database
- SQLite Synapse database (if using SQLite backend)
- Both use similar schema (with minor syntax differences in queries)

Ensure proper access permissions and credentials to the Synapse database.

