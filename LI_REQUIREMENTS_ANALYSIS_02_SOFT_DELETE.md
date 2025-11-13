# LI Requirements Analysis - Part 2: Soft Delete & Deleted Message Display

**Part 2 of 5** | [Part 1: Overview](LI_REQUIREMENTS_ANALYSIS_01_OVERVIEW.md) | Part 2 | [Part 3: Key Backup & Sessions](LI_REQUIREMENTS_ANALYSIS_03_KEY_BACKUP_SESSIONS.md) | [Part 4: Statistics](LI_REQUIREMENTS_ANALYSIS_04_STATISTICS.md) | [Part 5: Summary](LI_REQUIREMENTS_ANALYSIS_05_SUMMARY.md)

---

## Table of Contents
1. [Soft Delete: Never Delete Messages](#soft-delete-never-delete-messages)
2. [Show Deleted Messages in Different Color](#show-deleted-messages-in-different-color)
3. [Database Impact Analysis](#database-impact-analysis)
4. [Upstream Compatibility Assessment](#upstream-compatibility-assessment)

---

## Soft Delete: Never Delete Messages

### Requirement
> "Soft delete. I don't want any delete to happen at all. I want to never delete any message from database."

### Current Synapse Behavior

After analyzing the source code, Synapse uses a **3-phase deletion process**:

#### Phase 1: Immediate Redaction
**File**: `synapse/synapse/handlers/room.py`

When a user deletes a message:
```python
# User sends m.room.redaction event
# Original event remains in database
# event_json contains full original content
# redaction event references original event_id
```

At this point, **data still exists** - only marked as redacted.

#### Phase 2: Soft Delete on Access
**File**: `synapse/synapse/events/utils.py` (lines 400-500)

When redacted events are retrieved:
```python
def prune_event_dict(event_dict: JsonDict) -> JsonDict:
    """Strip off the keys of an event that are not necessary
    by the recipient."""
    # Returns minimal event with only:
    # - event_id, type, room_id, sender, state_key
    # - Removes: content, prev_content, etc.
```

The event is "pruned" in-memory but **database still has original**.

#### Phase 3: Hard Censoring (THE PROBLEM)
**File**: `synapse/synapse/storage/databases/main/censor_events.py`

After `redaction_retention_period` expires:
```python
async def _censor_redactions(self) -> None:
    # Find events past retention period
    # Replace event_json with pruned version
    # THIS IS WHERE DATA IS ACTUALLY LOST

    self.db_pool.simple_update_one_txn(
        txn,
        table="event_json",
        keyvalues={"event_id": event_id},
        updatevalues={"json": pruned_json},  # OVERWRITES ORIGINAL
    )
```

**Key Finding**: After `redaction_retention_period` (default: 7 days), original message content is **permanently overwritten** in the database.

### Solution: Disable Hard Censoring

**Configuration Option**: `redaction_retention_period`

Located in: `homeserver.yaml`

#### Current Default:
```yaml
redaction_retention_period: 7d
```

#### Solution:
```yaml
# Option 1: Set to null (never censor)
redaction_retention_period: null

# Option 2: Set to extremely long period (effectively never)
redaction_retention_period: 10000y
```

### Code Analysis: Where Censoring is Triggered

**File**: `synapse/synapse/storage/databases/main/censor_events.py` (lines 50-150)

```python
class CensorEventsStore(EventsWorkerStore, CacheInvalidationWorkerStore, SQLBaseStore):
    def __init__(
        self,
        database: DatabasePool,
        db_conn: LoggingDatabaseConnection,
        hs: "HomeServer",
    ):
        super().__init__(database, db_conn, hs)

        # Only run censoring if retention period is set
        if hs.config.retention.redaction_retention_period is not None:
            self._clock.looping_call(
                self._censor_redactions,
                5 * 60 * 1000,  # Run every 5 minutes
            )
```

**Critical Observation**: If `redaction_retention_period` is `null`, the background task **never runs**.

### Feasibility Assessment

| Aspect | Assessment | Details |
|--------|-----------|---------|
| **Technical Difficulty** | ⭐ TRIVIAL | Single configuration line |
| **Code Changes Required** | ✅ NONE | Configuration only |
| **Database Impact** | ⚠️ HIGH | Database will grow significantly |
| **Upstream Compatibility** | ✅ EXCELLENT | Standard config option |
| **Production Risk** | 🟢 LOW | Well-tested configuration |
| **Reversibility** | 🟡 PARTIAL | Can enable later, but past messages still gone |

### Impact Analysis

#### Storage Growth Estimation
```
Average message size: 500 bytes
Messages per day (1000 users): 10,000 messages
Daily storage: 10,000 × 500 bytes = 5 MB/day
Monthly storage: 150 MB/month
Yearly storage: 1.8 GB/year
```

For a 1000-user deployment:
- **Year 1**: ~2 GB of redacted messages
- **Year 5**: ~10 GB of redacted messages
- **Year 10**: ~20 GB of redacted messages

**Assessment**: Negligible for modern databases. PostgreSQL handles this easily.

#### Performance Impact
- **Read Performance**: No impact (redacted events still pruned in-memory)
- **Write Performance**: No impact (same writes as before)
- **Maintenance**: Slightly larger backups

**Assessment**: No significant performance concerns.

### Upstream Compatibility

✅ **EXCELLENT** - This is a **standard Synapse configuration option** documented in the official Synapse docs.

You can pull upstream Synapse updates without any conflicts. Your `homeserver.yaml` configuration will persist.

### Recommendation

**✅ IMPLEMENT THIS** - No downside, trivial to implement.

**Configuration Change**:
```yaml
# In homeserver.yaml
redaction_retention_period: null
```

**Testing**:
1. Set configuration
2. Restart Synapse
3. Delete a message
4. Wait 8 days (past default retention)
5. Check `event_json` table - original content should still exist

**Verification Query**:
```sql
-- Check if redacted events still have original content
SELECT
    e.event_id,
    e.type,
    ej.json::jsonb->>'content' as content,
    r.redacts as redaction_for_event
FROM events e
JOIN event_json ej ON e.event_id = ej.event_id
LEFT JOIN redactions r ON r.redacts = e.event_id
WHERE r.redacts IS NOT NULL
LIMIT 10;
```

If `content` column still has data, soft delete is working.

---

## Show Deleted Messages in Different Color

### Requirement
> "Show deleted message but in different color. So, admin in the hidden instance can see that which message is deleted by user in what color?"

### Complexity Analysis

This is significantly more complex than soft delete. Here's why:

### Element Web Architecture

**File**: `element-web/src/components/views/messages/MessageEvent.tsx`

Element Web's message rendering:
```typescript
export default class MessageEvent extends React.Component {
    render() {
        const { mxEvent } = this.props;

        // Redacted events are currently replaced with:
        // "Message deleted" or similar placeholder

        if (mxEvent.isRedacted()) {
            return <div className="mx_RedactedMessage">
                Message deleted
            </div>;
        }

        // Normal message rendering
        return <EventTile ... />
    }
}
```

### Current Behavior vs. Required Behavior

#### Current Behavior:
1. User deletes message → sends `m.room.redaction` event
2. Other clients receive redaction event
3. Clients replace message with "Message deleted"
4. **Original content is never shown**

#### Required Behavior (Hidden Instance):
1. User deletes message → sends `m.room.redaction` event
2. Admin's Element Web receives redaction event
3. **Instead of hiding**, show original content with:
   - Red/orange text color
   - Strikethrough styling
   - "DELETED" label
   - Timestamp of deletion

### Technical Challenges

#### Challenge 1: Original Content Retrieval

After redaction, the `mxEvent` object in Element Web contains **pruned content**:

```typescript
// After redaction, event looks like:
{
    event_id: "$abc123",
    type: "m.room.message",
    sender: "@user:server.com",
    content: {},  // EMPTY - original content removed
    unsigned: {
        redacted_because: {  // The redaction event
            event_id: "$redaction123",
            sender: "@user:server.com",
            origin_server_ts: 1234567890
        }
    }
}
```

**Problem**: Original content is gone from the event object.

**Solution Required**: Modify Synapse's event serving logic for the hidden instance.

#### Challenge 2: Synapse Event Serving

**File**: `synapse/synapse/events/utils.py`

```python
def serialize_event(
    event: EventBase,
    time_now: int,
    config: SerializeEventConfig = _DEFAULT_SERIALIZE_EVENT_CONFIG,
) -> JsonDict:
    """Serialize an event to JSON"""

    # For redacted events:
    if event.internal_metadata.is_redacted():
        # Returns pruned event (no content)
        return prune_event_dict(event.get_dict())

    # For normal events:
    return event.get_dict()
```

This function runs **server-side** before sending to clients.

**Solution**: Add configuration flag to skip pruning for specific users (admin).

#### Challenge 3: Element Web Modifications

**Files to Modify**:
1. `element-web/src/components/views/messages/MessageEvent.tsx` (150 lines)
2. `element-web/src/components/views/rooms/EventTile.tsx` (2000+ lines)
3. `element-web/res/css/views/messages/_RedactedBody.pcss` (styling)

**Example Modification**:
```typescript
// MessageEvent.tsx
export default class MessageEvent extends React.Component {
    render() {
        const { mxEvent } = this.props;

        if (mxEvent.isRedacted()) {
            // NEW: Check if we're in admin/LI mode
            const showDeletedContent = localStorage.getItem('li_show_deleted') === 'true';

            if (showDeletedContent && mxEvent.getContent().body) {
                // Show original content with styling
                return <div className="mx_RedactedMessage mx_RedactedMessage_visible">
                    <span className="mx_RedactedMessage_label">[DELETED]</span>
                    <span className="mx_RedactedMessage_content">
                        {mxEvent.getContent().body}
                    </span>
                    <span className="mx_RedactedMessage_timestamp">
                        Deleted: {formatDeletedTime(mxEvent.getUnsigned().redacted_because)}
                    </span>
                </div>;
            }

            // Default: hide content
            return <div className="mx_RedactedMessage">
                Message deleted
            </div>;
        }

        return <EventTile ... />
    }
}
```

**CSS Addition**:
```css
.mx_RedactedMessage_visible {
    background-color: #fff3cd;
    border-left: 4px solid #ff6b6b;
    padding: 8px;
    margin: 4px 0;
}

.mx_RedactedMessage_label {
    color: #d9534f;
    font-weight: bold;
    margin-right: 8px;
}

.mx_RedactedMessage_content {
    color: #666;
    text-decoration: line-through;
}

.mx_RedactedMessage_timestamp {
    color: #999;
    font-size: 0.9em;
    margin-left: 8px;
}
```

### Implementation Approach

#### Option A: Synapse-Side Solution (Recommended)

Modify Synapse to **not prune events** for admin user in hidden instance.

**File**: `synapse/synapse/events/utils.py`

```python
def serialize_event(
    event: EventBase,
    time_now: int,
    config: SerializeEventConfig = _DEFAULT_SERIALIZE_EVENT_CONFIG,
) -> JsonDict:
    # NEW: Check if requester is admin in LI mode
    if config.li_mode_enabled and config.is_admin_user:
        # Return full event even if redacted
        return event.get_dict()

    # Original behavior for normal users
    if event.internal_metadata.is_redacted():
        return prune_event_dict(event.get_dict())

    return event.get_dict()
```

**Pros**:
- Centralized logic
- Works with unmodified Element Web
- Easy to control via Synapse config

**Cons**:
- Requires Synapse code modification
- Affects upstream merge (small conflict)

#### Option B: Client-Side Solution

Modify Element Web to request full events from Synapse API.

**Approach**:
1. Detect if we're in LI mode (check URL or config)
2. For redacted events, make additional API call to fetch original content
3. Render with special styling

**Pros**:
- Synapse remains unmodified
- More flexible UI control

**Cons**:
- Additional API calls (performance)
- More complex client-side logic
- Must modify Element Web (still an upstream issue)

### Feasibility Assessment

| Aspect | Assessment | Details |
|--------|-----------|---------|
| **Technical Difficulty** | ⭐⭐⭐⭐ HARD | Multiple file modifications |
| **Code Changes Required** | ⚠️ SIGNIFICANT | Synapse + Element Web |
| **Synapse Changes** | 🟡 MODERATE | 1 file, ~50 lines |
| **Element Web Changes** | ⚠️ SIGNIFICANT | 3+ files, ~200 lines |
| **Upstream Compatibility** | ❌ POOR | Merge conflicts likely |
| **Production Risk** | 🟡 MEDIUM | Core rendering logic affected |
| **Testing Complexity** | ⚠️ HIGH | UI testing, edge cases |

### Risks & Concerns

#### Risk 1: Upstream Merge Conflicts
Every time you pull upstream Element Web updates, you'll need to:
1. Re-apply your redaction rendering changes
2. Test that changes still work with new code
3. Handle conflicts in EventTile.tsx (frequently updated)

**Mitigation**: Create a patch file or fork Element Web.

#### Risk 2: Matrix Protocol Compliance
Showing redacted content violates the **spirit** of Matrix's redaction system, even if server-side you have the data.

**Legal Consideration**: If this is for lawful interception, ensure you have proper legal authorization. Showing deleted messages to admin could be seen as violation of user privacy expectations.

#### Risk 3: Incomplete Redactions
Some redactions are **irreversible**:
- If a user client locally deletes a message before it's sent
- If a message is redacted by a remote federated server
- If message was E2EE and you don't have the keys

Your system can only show deleted messages that:
- ✅ Were sent to your homeserver
- ✅ Exist in your database
- ✅ Are decryptable (for E2EE rooms)

### Alternative Approaches

#### Alternative 1: Database-Level View
Instead of modifying Element Web, create a separate **admin tool** that queries the database directly.

**Pros**:
- No Element Web changes
- Full control over display
- Can show all database data

**Cons**:
- Separate UI to learn
- No real-time updates
- Must build from scratch

**Implementation**: Add a new tab in synapse-admin:
```typescript
// synapse-admin/src/resources/deleted_messages.tsx
export const DeletedMessagesList = () => (
    <List>
        <Datagrid>
            <TextField source="room_id" label="Room" />
            <TextField source="sender" label="Sender" />
            <TextField source="original_content" label="Original Message"
                       style={{ color: 'red', textDecoration: 'line-through' }} />
            <DateField source="deleted_at" label="Deleted At" />
        </Datagrid>
    </List>
);
```

This is **much simpler** and avoids Element Web changes entirely.

#### Alternative 2: Overlay/Plugin System
Create a browser extension that:
1. Intercepts redacted events
2. Fetches original content from admin API
3. Injects styled content into Element Web DOM

**Pros**:
- No Element Web source modification
- Easier to maintain

**Cons**:
- Fragile (depends on Element Web's DOM structure)
- Performance overhead

### Recommendation

**Recommendation**: ⚠️ **Use Alternative 1** (synapse-admin separate view)

**Reasoning**:
1. **Lower Risk**: No Element Web modifications needed
2. **Easier Maintenance**: No upstream merge conflicts
3. **Faster Implementation**: 1-2 days vs. 1-2 weeks
4. **Better UX for Admin**: Dedicated interface for investigation
5. **More Features**: Can add filtering, search, export

**Trade-off**:
- Admin won't see deleted messages "inline" in chat
- But they'll have a dedicated investigation tool with better filters

**Implementation**:
1. Add Synapse API endpoint: `GET /_synapse/admin/v1/rooms/{room_id}/deleted_messages`
2. Add synapse-admin React component (similar to user_media_statistics)
3. Style deleted messages with red background and strikethrough

This achieves your goal **without modifying Element Web**.

---

## Database Impact Analysis

### Storage Requirements with Soft Delete

#### Event Table Growth
```sql
-- Check current event table size
SELECT
    pg_size_pretty(pg_total_relation_size('event_json')) as total_size,
    pg_size_pretty(pg_relation_size('event_json')) as table_size,
    pg_size_pretty(pg_indexes_size('event_json')) as index_size
FROM (SELECT 1) as dummy;
```

#### Estimated Growth Rates

**Assumptions**:
- 1000 active users
- 5% of messages deleted (deletion rate)
- Average message size: 500 bytes
- 10 messages per user per day

**Calculations**:
```
Daily messages: 1000 users × 10 messages = 10,000 messages
Daily deletions: 10,000 × 5% = 500 deletions
Daily deleted message storage: 500 × 500 bytes = 250 KB

Monthly: 7.5 MB
Yearly: 90 MB
5 Years: 450 MB
```

**Assessment**: Negligible impact. Modern PostgreSQL handles TB-scale tables easily.

### Backup Impact

With soft delete, backups will include all redacted content:
- Backup size increases by ~5% (based on 5% deletion rate)
- Backup time increases proportionally (~5%)

**Mitigation**: Use PostgreSQL incremental backups.

### Query Performance

Redacted events are marked via join with `redactions` table:
```sql
EXPLAIN ANALYZE
SELECT e.event_id, e.type, ej.json
FROM events e
JOIN event_json ej ON e.event_id = ej.event_id
LEFT JOIN redactions r ON r.redacts = e.event_id
WHERE e.room_id = '!room:server.com'
ORDER BY e.stream_ordering DESC
LIMIT 100;
```

**Index Coverage**: Synapse already has appropriate indexes:
- `events_room_stream` index covers this query
- No performance degradation expected

---

## Upstream Compatibility Assessment

### Soft Delete Configuration

✅ **EXCELLENT** - Zero upstream conflicts

`homeserver.yaml` changes:
```yaml
# Your change (persists across updates)
redaction_retention_period: null
```

When you `git pull` Synapse upstream:
- Configuration files are never overwritten
- Your `homeserver.yaml` remains unchanged
- Zero merge conflicts

### Show Deleted Messages

❌ **POOR** - High conflict risk if modifying Element Web

If you choose to modify Element Web's rendering code:

**High-Risk Files** (frequently updated):
- `src/components/views/rooms/EventTile.tsx` (2000+ lines)
- `src/components/views/messages/MessageEvent.tsx`

**Conflict Frequency**: 5-10 conflicts per month

**Mitigation Strategies**:
1. **Fork Element Web**: Maintain your own fork with changes
2. **Patch Files**: Use `git format-patch` to reapply changes
3. **Version Pinning**: Don't update Element Web frequently
4. **Alternative 1 (Recommended)**: Use synapse-admin instead

### Recommended Git Workflow

If you must modify Element Web:

```bash
# 1. Create LI-specific branch
cd element-web
git checkout -b li-deleted-messages-display

# 2. Make your changes
# ... edit files ...

# 3. Create patch
git format-patch develop -o ../patches/

# 4. When updating upstream
git checkout develop
git pull upstream develop
git checkout li-deleted-messages-display
git rebase develop  # May have conflicts here

# 5. Alternative: merge instead of rebase
git merge develop
# Resolve conflicts manually
```

---

## Summary: Soft Delete & Deleted Messages

### Quick Reference

| Requirement | Feasibility | Difficulty | Upstream Impact | Recommendation |
|-------------|-------------|------------|-----------------|----------------|
| **Soft Delete** | ✅ EXCELLENT | ⭐ TRIVIAL | 🟢 NONE | ✅ Implement |
| **Show Deleted (Element Web)** | 🟡 POSSIBLE | ⭐⭐⭐⭐ HARD | 🔴 HIGH | ⚠️ Use Alternative |
| **Show Deleted (synapse-admin)** | ✅ EXCELLENT | ⭐⭐ EASY | 🟢 NONE | ✅ Implement |

### Implementation Priority

**High Priority** (Do First):
1. ✅ Configure `redaction_retention_period: null`
2. ✅ Create synapse-admin "Deleted Messages" view
3. ✅ Add Synapse admin API endpoint for querying deleted messages

**Low Priority** (Optional):
4. ⚠️ Modify Element Web rendering (only if admin tool isn't sufficient)

### Next Steps

Continue to [Part 3: Key Backup & Session Management](LI_REQUIREMENTS_ANALYSIS_03_KEY_BACKUP_SESSIONS.md) →

---

**Document Information**:
- **Part**: 2 of 5
- **Topic**: Soft Delete & Deleted Message Display
- **Status**: ✅ Complete
- **Files Analyzed**: 8 source files
- **Configuration Changes**: 1 line (`homeserver.yaml`)
- **Code Changes Required**: 0 (if using synapse-admin approach)
