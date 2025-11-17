# LI Requirements Analysis - Part 2: Soft Delete & Deleted Messages

**Part 2 of 4** | [Part 1: Overview](LI_REQUIREMENTS_ANALYSIS_01_OVERVIEW.md) | Part 2 | [Part 3: Key Backup & Sessions](LI_REQUIREMENTS_ANALYSIS_03_KEY_BACKUP_SESSIONS.md) | [Part 4: Statistics](LI_REQUIREMENTS_ANALYSIS_04_STATISTICS.md)

---

## Table of Contents
1. [Soft Delete Configuration](#1-soft-delete-configuration)
2. [Showing Deleted Messages in element-web-li](#2-showing-deleted-messages-in-element-web-li)
3. [synapse-li Modifications](#3-synapse-li-modifications)

---

## 1. Soft Delete Configuration

### 1.1 Requirement

> "Soft delete. I don't want any delete to happen at all. I want to never delete any message from database."

### 1.2 Synapse's Deletion Mechanism

Synapse has a 3-phase deletion process:

1. **Immediate Redaction**: User sends `m.room.redaction` event, original event marked as redacted
2. **Soft Delete on Access**: Redacted events returned as "pruned" (minimal data) to clients
3. **Hard Censoring**: After `redaction_retention_period`, original content **permanently deleted** from database

**The Problem**: Phase 3 destroys the original message content.

**File**: `synapse/synapse/storage/databases/main/censor_events.py`

```python
async def _censor_redactions(self) -> None:
    # After redaction_retention_period expires
    # Replaces event_json with pruned version (PERMANENT DELETION)
    self.db_pool.simple_update_one_txn(
        txn,
        table="event_json",
        keyvalues={"event_id": event_id},
        updatevalues={"json": pruned_json},  # Original content lost
    )
```

### 1.3 Solution: Deployment Configuration

**Configuration**: Set `redaction_retention_period: null` in Synapse deployment

**Location**: Include in your deployment manifests/Helm values

#### For Kubernetes Deployment

**File**: `deployment/manifests/05-synapse-main.yaml` (MODIFICATION)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-config
  namespace: matrix
data:
  homeserver.yaml: |
    server_name: "{{ MATRIX_DOMAIN }}"

    # ... other Synapse configs ...

    # LI: Soft Delete - Never remove deleted messages from database
    # Setting to null disables hard censoring entirely
    # Messages remain in database permanently for lawful interception
    redaction_retention_period: null
```

#### For Docker Compose Deployment

**File**: `docker-compose.yml` or `homeserver.yaml`

```yaml
# LI: Soft Delete Configuration
#
# Purpose: Preserve all deleted messages in database for lawful interception
#
# How it works:
# - When users delete messages, Synapse marks them as "redacted"
# - Normally after 7 days, Synapse permanently deletes the content
# - Setting to 'null' disables permanent deletion
# - Messages stay in database forever (soft delete)
#
# Default: 7d (7 days before permanent deletion)
# LI Setting: null (never delete)
redaction_retention_period: null
```

### 1.4 How It Works

**When `redaction_retention_period: null`**:

```python
# File: synapse/synapse/storage/databases/main/censor_events.py

def __init__(self, ...):
    # Only run censoring if retention period is set
    if hs.config.retention.redaction_retention_period is not None:
        self._clock.looping_call(
            self._censor_redactions,
            5 * 60 * 1000,  # Run every 5 minutes
        )
    # If null, background task never runs → no censoring
```

**Result**: Original message content remains in `event_json` table forever.

### 1.5 Deployment Guide Addition

Add this to your deployment documentation:

**File**: `deployment/README.md` (ADD SECTION)

```markdown
### Soft Delete Configuration (Lawful Interception)

**Purpose**: Preserve deleted messages in database for investigations.

**Configuration**:
```yaml
# In homeserver.yaml
redaction_retention_period: null
```

**What this does**:
- Users can still "delete" messages (sends redaction event)
- Other users see "Message deleted" in their clients
- **BUT** original content remains in database permanently
- Admin can access original content via hidden instance

**Important**: This is a one-line configuration change. No code modifications needed.

**Default**: `7d` (messages deleted after 7 days)
**LI Setting**: `null` (never delete)
```

### 1.6 Verification

After deployment, verify soft delete is working:

```sql
-- Connect to Synapse PostgreSQL database
-- Check if redacted events still have original content

SELECT
    e.event_id,
    e.type,
    ej.json::jsonb->>'content' as original_content,
    r.redacts as redaction_event_id,
    to_timestamp(e.origin_server_ts / 1000) as deleted_at
FROM events e
JOIN event_json ej ON e.event_id = ej.event_id
LEFT JOIN redactions r ON r.redacts = e.event_id
WHERE r.redacts IS NOT NULL
ORDER BY e.origin_server_ts DESC
LIMIT 10;
```

**Expected**: `original_content` column shows the actual message text, not null/empty.

---

## 2. Showing Deleted Messages in element-web-li

### 2.1 Requirement

> "Show deleted message but in different color. So, admin in the hidden instance can see that which message is deleted by user in what color?"

### 2.2 Key Clarifications

**Important**:
- Only modify **element-web-li** (hidden instance client)
- Do NOT touch main instance element-web
- Admin logs in AS a user (not as admin user) - synapse-li only sees the user
- Admin must see deleted messages with visual distinction

### 2.3 Approach: CSS-Based Styling

**Strategy**: Modify element-web-li to NOT hide redacted message content, and apply visual styling.

**Advantages**:
- Minimal code changes
- No complex logic needed
- Easy to maintain
- Visually clear

### 2.4 Implementation

#### Step 1: Modify Redacted Message Rendering

**File**: `element-web-li/src/components/views/messages/RedactedBody.tsx` (NEW FILE)

```typescript
/**
 * LI: Custom redacted message renderer for hidden instance
 *
 * Shows original content of deleted messages with visual styling
 * instead of hiding the content.
 */

import React from 'react';
import { MatrixEvent } from 'matrix-js-sdk';

interface RedactedBodyProps {
    mxEvent: MatrixEvent;
}

export const RedactedBody: React.FC<RedactedBodyProps> = ({ mxEvent }) => {
    // Get original content from event
    const content = mxEvent.getContent();
    const originalBody = content.body || '';

    // Get redaction info
    const unsignedData = mxEvent.getUnsignedData();
    const redactedBecause = unsignedData?.redacted_because;
    const redactedAt = redactedBecause?.origin_server_ts;
    const redactedBy = redactedBecause?.sender;

    return (
        <div className="mx_RedactedBody_LI">
            <div className="mx_RedactedBody_LI_label">
                🗑️ DELETED MESSAGE
            </div>
            <div className="mx_RedactedBody_LI_content">
                {originalBody}
            </div>
            {redactedAt && (
                <div className="mx_RedactedBody_LI_metadata">
                    Deleted {new Date(redactedAt).toLocaleString()}
                    {redactedBy && ` by ${redactedBy}`}
                </div>
            )}
        </div>
    );
};
```

**File**: `element-web-li/res/css/views/messages/_RedactedBody.pcss` (NEW FILE)

```css
/**
 * LI: Styling for deleted messages in hidden instance
 *
 * Visual design:
 * - Light red background
 * - Red left border
 * - Strikethrough text
 * - Delete icon and label
 * - Metadata about deletion
 */

.mx_RedactedBody_LI {
    background-color: #fff5f5;  /* Light red background */
    border-left: 4px solid #e53e3e;  /* Red left border */
    border-radius: 4px;
    padding: 12px;
    margin: 4px 0;
    font-family: inherit;
}

.mx_RedactedBody_LI_label {
    color: #c53030;  /* Dark red */
    font-weight: 600;
    font-size: 0.85rem;
    margin-bottom: 6px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.mx_RedactedBody_LI_content {
    color: #666;
    text-decoration: line-through;
    text-decoration-color: #e53e3e;
    text-decoration-thickness: 2px;
    line-height: 1.5;
    padding: 4px 0;
}

.mx_RedactedBody_LI_metadata {
    color: #999;
    font-size: 0.8rem;
    margin-top: 6px;
    font-style: italic;
}
```

#### Step 2: Integrate Custom Renderer

**File**: `element-web-li/src/components/views/messages/MessageEvent.tsx` (MODIFICATION)

```typescript
// LI: Import custom redacted body renderer
import { RedactedBody } from './RedactedBody';

export default class MessageEvent extends React.Component {
    render() {
        const { mxEvent } = this.props;

        // LI: For redacted events, show original content with styling
        if (mxEvent.isRedacted()) {
            return <RedactedBody mxEvent={mxEvent} />;
        }

        // Normal message rendering
        return <EventTile ... />
    }
}
```

**Comment**: Only 3 lines added to existing file, marked with `// LI:` for easy tracking.

#### Step 3: Ensure Original Content is Available

**File**: `element-web-li/src/stores/LIConfig.ts` (NEW FILE)

```typescript
/**
 * LI: Configuration flag for hidden instance
 *
 * Tells element-web-li this is the LI instance and to show
 * deleted messages differently.
 */

export const IS_LI_INSTANCE = true;
```

**File**: `element-web-li/config.json` (MODIFICATION)

```json
{
    "brand": "Element (LI)",
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://synapse-li.your-domain.com"
        }
    },

    // LI: Custom settings for hidden instance
    "features": {
        "feature_show_deleted_messages": true
    }
}
```

### 2.5 How Deleted Messages Appear

**Normal element-web** (main instance):
```
┌─────────────────────────────────┐
│ [User deleted this message]     │
└─────────────────────────────────┘
```

**element-web-li** (hidden instance):
```
┌─────────────────────────────────────────────────┐
│ 🗑️ DELETED MESSAGE                              │
│ This is the original message content           │
│ Deleted 2025-11-16 14:32:15 by @user:server.com│
└─────────────────────────────────────────────────┘
```

Visual appearance:
- Light red background (#fff5f5)
- Red left border (4px, #e53e3e)
- Strikethrough text
- Delete emoji and "DELETED MESSAGE" label
- Timestamp and deleter username

### 2.6 Alternative: Icon-Based Approach

If strikethrough is not clear enough, use icon overlay:

```css
.mx_RedactedBody_LI_content {
    position: relative;
    color: #666;
    padding: 4px 0;
}

.mx_RedactedBody_LI_content::before {
    content: "🗑️ ";
    color: #e53e3e;
    font-size: 1.2rem;
    margin-right: 4px;
}
```

This adds a trash icon before every deleted message content.

### 2.7 Testing

**Test Plan**:
1. In main instance: User deletes a message
2. Sync hidden instance
3. Admin logs into hidden instance as that user
4. Admin sees message with red background, strikethrough, "DELETED MESSAGE" label
5. Verify original content is readable

---

## 3. synapse-li Modifications

### 3.1 Requirement

synapse-li (hidden instance Synapse) must serve full event content even for redacted events.

### 3.2 Approach: Disable Event Pruning for All Requests

**Strategy**: Modify synapse-li to never prune redacted events.

**File**: `synapse-li/synapse/events/utils.py` (MODIFICATION)

```python
def serialize_event(
    event: EventBase,
    time_now: int,
    config: SerializeEventConfig = _DEFAULT_SERIALIZE_EVENT_CONFIG,
) -> JsonDict:
    """Serialize an event to JSON"""

    # LI: Never prune redacted events in hidden instance
    # Always return full content for investigation purposes
    # (Comment added for upstream merge tracking)

    # Original code would check:
    # if event.internal_metadata.is_redacted():
    #     return prune_event_dict(event.get_dict())

    # LI: Skip pruning entirely
    return event.get_dict()
```

**Alternative Approach** (cleaner for upstream):

**File**: `synapse-li/synapse/config/server.py` (MODIFICATION)

```python
class ServerConfig(Config):
    section = "server"

    def read_config(self, config, **kwargs):
        # ... existing config ...

        # LI: Disable event pruning for hidden instance
        self.li_disable_pruning = config.get("li_disable_pruning", False)
```

**File**: `synapse-li/synapse/events/utils.py` (MODIFICATION)

```python
from synapse.config.server import ServerConfig

def serialize_event(
    event: EventBase,
    time_now: int,
    config: SerializeEventConfig = _DEFAULT_SERIALIZE_EVENT_CONFIG,
    server_config: ServerConfig = None,  # LI: Added parameter
) -> JsonDict:
    """Serialize an event to JSON"""

    # LI: Check if pruning is disabled (hidden instance only)
    if server_config and server_config.li_disable_pruning:
        return event.get_dict()  # Return full content

    # Normal behavior for main instance
    if event.internal_metadata.is_redacted():
        return prune_event_dict(event.get_dict())

    return event.get_dict()
```

**Configuration** (`synapse-li homeserver.yaml`):

```yaml
# LI: Disable event pruning in hidden instance
# This ensures deleted messages are returned with full content
# for admin investigation purposes
li_disable_pruning: true
```

### 3.3 Minimal Change Strategy

**Best Approach**: Add configuration flag + 3-line modification

```python
# File: synapse-li/synapse/events/utils.py
# Line ~450 (in serialize_event function)

def serialize_event(...):
    # LI: Skip pruning if disabled in config
    if hasattr(hs.config, 'server') and getattr(hs.config.server, 'li_disable_pruning', False):
        return event.get_dict()

    # ... rest of original code unchanged ...
```

This is the **minimum viable change** - only 3 lines added, marked with `// LI:` comment.

### 3.4 Deployment Configuration

**File**: `deployment/manifests/XX-synapse-li.yaml` (NEW FILE - Hidden Instance)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-li-config
  namespace: matrix-li  # Separate namespace for hidden instance
data:
  homeserver.yaml: |
    server_name: "{{ MATRIX_DOMAIN }}"

    # ... other configs same as main instance ...

    # LI: Soft Delete - Never remove deleted messages
    redaction_retention_period: null

    # LI: Disable Event Pruning - Return full content for redacted events
    li_disable_pruning: true
```

### 3.5 Verification

Test that synapse-li returns full content:

```bash
# In hidden instance, query a redacted event via API
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://synapse-li.domain.com/_matrix/client/r0/rooms/!room:domain.com/event/$EVENT_ID"

# Expected: Full event with original content, not pruned
{
  "event_id": "$abc123",
  "type": "m.room.message",
  "content": {
    "body": "Original message that was deleted",  # <-- Should be present
    "msgtype": "m.text"
  },
  "unsigned": {
    "redacted_because": { ... }  # Redaction info
  }
}
```

If content is missing, pruning is still active.

---

## Summary

### Implementation Checklist

**Deployment Configuration**:
- [x] Add `redaction_retention_period: null` to main Synapse config
- [x] Add `li_disable_pruning: true` to synapse-li config
- [x] Document in deployment README

**synapse-li Changes**:
- [x] Modify `events/utils.py` to skip pruning when `li_disable_pruning: true`
- [x] Add configuration option to `config/server.py`
- [x] 3 lines of code changes total

**element-web-li Changes**:
- [x] Create `RedactedBody.tsx` component (new file)
- [x] Create `_RedactedBody.pcss` styles (new file)
- [x] Modify `MessageEvent.tsx` (3 lines)
- [x] Add `LIConfig.ts` flag (new file)

**Visual Design**:
- Red background (#fff5f5)
- Red left border (4px, #e53e3e)
- Strikethrough text
- "🗑️ DELETED MESSAGE" label
- Deletion metadata (timestamp, deleter)

**Testing**:
1. User deletes message in main instance
2. Sync hidden instance
3. Admin logs in as user in hidden instance
4. Deleted message shows with red styling and original content
5. Verify content is readable and visually distinct

### Key Points

✅ **Soft delete**: One-line config change (`redaction_retention_period: null`)
✅ **No database impact concerns**: User explicitly doesn't care about storage growth
✅ **Minimal code changes**: New files for main logic, 3-line edits to existing files
✅ **Only modify hidden instance**: Main instance clients unaffected
✅ **Visual clarity**: Deleted messages clearly distinguished with red styling
✅ **Upstream compatible**: All changes marked with comments for easy tracking

### Next Steps

Continue to [Part 3: Key Backup & Session Management](LI_REQUIREMENTS_ANALYSIS_03_KEY_BACKUP_SESSIONS.md)
