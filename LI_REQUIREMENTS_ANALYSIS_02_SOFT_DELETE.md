# Lawful Interception (LI) Requirements - Implementation Guide
## Part 2: Soft Delete & Deleted Message Display

---

## Table of Contents
1. [Soft Delete Configuration (Main Instance)](#1-soft-delete-configuration-main-instance)
2. [Deleted Message Display (Hidden Instance Only)](#2-deleted-message-display-hidden-instance-only)
3. [Implementation Strategy](#3-implementation-strategy)

---

## 1. Soft Delete Configuration (Main Instance)

### 1.1 Overview

**Requirement**: Never delete any message or file from the database or media repository.

**Solution**: Configure Synapse's `redaction_retention_period` to `null` (infinite retention).

### 1.2 How Synapse Handles Deleted Messages

When a user deletes a message in Matrix, it's called a **redaction**:

1. User clicks "Delete" on a message
2. Client sends a `m.room.redaction` event to Synapse
3. Synapse marks the original event as redacted
4. Original event content remains in database for `redaction_retention_period`
5. After retention period expires, event is "pruned" (content replaced with minimal metadata)

**With soft delete enabled**: Set retention period to `null` → events NEVER get pruned → full content preserved forever.

### 1.3 Configuration

**File**: `deployment/manifests/05-synapse-main.yaml` (for main instance)

Add to Synapse configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-config
  namespace: matrix
data:
  homeserver.yaml: |
    # ... existing config ...

    # LI: Soft Delete Configuration
    # Retain redacted message content indefinitely for lawful interception
    # Setting to null disables pruning entirely
    # WARNING: This will increase database size over time
    # Default: 7d (7 days)
    # Options:
    #   - null: Keep forever (recommended for LI)
    #   - 30d: Keep for 30 days
    #   - 1y: Keep for 1 year
    redaction_retention_period: null
```

**Deployment Guide Documentation**:

Add to `deployment/docs/CONFIGURATION-REFERENCE.md`:

```markdown
### Soft Delete / Redaction Retention

**Parameter**: `redaction_retention_period`

**Purpose**: Controls how long Synapse keeps the original content of deleted (redacted) messages before permanently removing it.

**Default**: `7d` (7 days)

**Lawful Interception Recommendation**: `null` (infinite retention)

**How it works**:
- When a user deletes a message, Synapse creates a redaction event
- The original message remains in the database for the retention period
- After the period expires, the message content is "pruned" (replaced with minimal metadata)
- Redacted messages are hidden from clients, but database retains full content during retention period

**Configuration**:

```yaml
# Keep deleted messages forever (recommended for LI compliance)
redaction_retention_period: null

# Alternative configurations:
# redaction_retention_period: 30d   # Keep for 30 days
# redaction_retention_period: 1y    # Keep for 1 year
# redaction_retention_period: 7d    # Default (7 days)
```

**Trade-offs**:
- **null (infinite)**:
  - ✅ Full LI compliance - all deleted content preserved
  - ✅ Audit trail maintained
  - ⚠️ Database size increases over time

**Database Impact**:
- Deleted messages consume space in `event_json` table
- For 20K users with 1M messages/day, estimate ~100MB/day additional storage
- Use PostgreSQL table partitioning if size becomes concern

**Verification**:

```sql
-- Check retention configuration
SELECT name, value FROM synapse_config WHERE name = 'redaction_retention_period';

-- Count redacted events still in database
SELECT COUNT(*) FROM events WHERE type = 'm.room.redaction';

-- Check for pruned events (should be 0 with null retention)
SELECT COUNT(*) FROM event_json
WHERE json::json->>'content' = '{}'
AND event_id IN (SELECT redacts FROM events WHERE type = 'm.room.redaction');
```
```

### 1.4 Media Files Retention

**Important**: Synapse's redaction retention only affects event JSON. Media files have separate retention.

**File**: Media is stored in MinIO (based on deployment architecture).

**Configuration**: Ensure media cleanup job does NOT delete quarantined or redacted media.

**File**: `deployment/manifests/10-operational-automation.yaml` (MODIFICATION)

```yaml
# LI: Modify media cleanup job to preserve all files
apiVersion: batch/v1
kind: CronJob
metadata:
  name: synapse-media-cleanup
  namespace: matrix
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cleanup
            image: matrixdotorg/synapse:latest
            command:
            - /bin/sh
            - -c
            - |
              # LI: Skip cleanup to preserve all media for LI compliance
              # Original command would be:
              # python -m synapse.app.admin_cmd purge_remote_media --before <days>

              # For LI compliance, we DON'T run purge commands
              echo "LI: Media cleanup disabled - all media preserved for compliance"
              exit 0
```

---

## 2. Deleted Message Display (Hidden Instance Only)

### 2.1 Requirements

**Objective**: In the hidden LI instance, admin can see deleted messages in element-web-li.

**Key Points**:
- Deleted messages shown ONLY in element-web-li (NOT in main instance element-web)
- Admin logs in as a regular user (after resetting password in synapse-admin-li)
- Synapse-li sees only the user, not an "admin user"
- Deleted messages visually distinguished from normal messages
- Must handle ALL message types: text, files, images, videos, audio, location, emoji reactions, etc.

### 2.2 Implementation Strategy

**Approach**: Modify element-web-li to query and display redacted events.

#### Step 1: Fetch Redacted Events

**File**: `element-web-li/src/components/structures/TimelinePanel.tsx` (MODIFICATION)

```typescript
// LI: Import redacted event fetcher
import { fetchRedactedEvents } from "../../stores/LIRedactedEvents";

// LI: In onMessageListScroll or pagination handler, add:
async function loadRedactedEventsForRoom(roomId: string) {
    try {
        const redactedEvents = await fetchRedactedEvents(roomId);

        // LI: Merge redacted events into timeline
        // Mark them with a special flag for styling
        const markedEvents = redactedEvents.map(event => ({
            ...event,
            _liRedacted: true,  // Internal flag for UI
        }));

        // Add to timeline display
        return markedEvents;
    } catch (error) {
        console.error("LI: Failed to fetch redacted events", error);
        return [];
    }
}
```

**File**: `element-web-li/src/stores/LIRedactedEvents.ts` (NEW FILE)

```typescript
/**
 * LI: Redacted Events Fetcher
 *
 * Queries Synapse for redacted events and their original content.
 */

import { MatrixClient, MatrixEvent } from "matrix-js-sdk";

export interface RedactedEventData {
    event_id: string;
    sender: string;
    origin_server_ts: number;
    content: any;  // Original content before redaction
    type: string;  // m.room.message, m.room.file, etc.
    redacted_because: {
        sender: string;
        origin_server_ts: number;
    };
}

/**
 * Fetch redacted events for a room.
 *
 * Uses Synapse admin API to get original content.
 */
export async function fetchRedactedEvents(
    roomId: string
): Promise<RedactedEventData[]> {
    const client = MatrixClientPeg.get();

    // LI: Query Synapse for redacted events in this room
    // Note: This requires admin API access or special endpoint
    const response = await client.http.authedRequest(
        "GET",
        `/_synapse/admin/v1/rooms/${encodeURIComponent(roomId)}/messages`,
        {
            dir: "b",  // Backward
            filter: JSON.stringify({
                types: ["m.room.message", "m.room.file", "m.image", "m.video", "m.audio"],
                include_redundant_members: true,
                // LI: Include redacted events (normally excluded)
                include_redacted: true,
            }),
        }
    );

    // LI: Filter to only redacted events with original content
    const redactedEvents: RedactedEventData[] = [];

    for (const event of response.chunk) {
        if (event.unsigned?.redacted_because) {
            // This event was redacted
            redactedEvents.push({
                event_id: event.event_id,
                sender: event.sender,
                origin_server_ts: event.origin_server_ts,
                content: event.content,  // Original content (preserved in DB)
                type: event.type,
                redacted_because: event.unsigned.redacted_because,
            });
        }
    }

    return redactedEvents;
}
```

#### Step 2: Display Redacted Messages with Visual Distinction

**Approach**: Use CSS styling to make deleted messages visually distinct.

**Options**:
1. **Background color** (lightest code change)
2. **Border** (moderate change)
3. **Strikethrough text** (more invasive)
4. **Opacity** (subtle)

**Recommended**: Background color + icon prefix (clear visual distinction, minimal code changes)

**File**: `element-web-li/src/components/views/rooms/EventTile.tsx` (MODIFICATION)

```typescript
// LI: Check if event is redacted
const isRedacted = mxEvent.isRedacted() || (mxEvent as any)._liRedacted;

// LI: Apply redacted styling
const tileClasses = classNames({
    // ... existing classes ...
    "mx_EventTile_redacted": isRedacted,  // LI: Add redacted class
});

// LI: In render(), add visual indicator
{isRedacted && (
    <div className="mx_EventTile_redactedBadge">
        <DeleteIcon style={{ fontSize: 14, marginRight: 4 }} />
        <span>Deleted</span>
    </div>
)}
```

**File**: `element-web-li/res/css/views/rooms/_EventTile.scss` (MODIFICATION)

```scss
// LI: Styling for redacted/deleted messages in hidden instance
.mx_EventTile_redacted {
    // Light red background to indicate deletion
    background-color: rgba(255, 0, 0, 0.08) !important;

    // Subtle border
    border-left: 3px solid rgba(255, 0, 0, 0.3);
    padding-left: 8px;

    // Slightly reduced opacity
    opacity: 0.85;
}

.mx_EventTile_redactedBadge {
    display: inline-flex;
    align-items: center;
    font-size: 11px;
    color: #d32f2f;
    margin-left: 8px;
    font-weight: 500;

    svg {
        fill: #d32f2f;
    }
}
```

#### Step 3: Handle Different Message Types

**Text Messages**:
```typescript
// Already handled by EventTile - just style differently
```

**File Attachments** (images, videos, PDFs):
```typescript
// LI: In MFileBody.tsx or similar
if (isRedacted) {
    return (
        <div className="mx_MFileBody mx_MFileBody_redacted">
            <DeleteIcon />
            <div className="mx_MFileBody_info">
                <div className="mx_MFileBody_info_filename">{content.body}</div>
                <div className="mx_MFileBody_info_metadata">
                    Deleted • {formatFileSize(content.info?.size)}
                </div>
            </div>
            {/* LI: Still show download link - file preserved in MinIO */}
            <a href={mxcUrl} download={content.body}>
                Download Deleted File
            </a>
        </div>
    );
}
```

**Images**:
```typescript
// LI: In MImageBody.tsx
if (isRedacted) {
    return (
        <div className="mx_MImageBody mx_MImageBody_redacted">
            <DeleteIcon className="mx_MImageBody_deletedIcon" />
            {/* LI: Still show thumbnail with overlay */}
            <img
                src={thumbnailUrl}
                alt={content.body}
                className="mx_MImageBody_thumbnail mx_MImageBody_thumbnail_deleted"
            />
            <div className="mx_MImageBody_deletedOverlay">
                <span>Deleted Image</span>
                <a href={fullResUrl}>View Full Size</a>
            </div>
        </div>
    );
}
```

**CSS for deleted file types**:
```scss
.mx_MFileBody_redacted,
.mx_MImageBody_redacted,
.mx_MVideoBody_redacted {
    border: 2px dashed rgba(255, 0, 0, 0.3);
    background-color: rgba(255, 0, 0, 0.05);
    padding: 8px;
    border-radius: 4px;
    position: relative;
}

.mx_MImageBody_thumbnail_deleted {
    opacity: 0.6;
    filter: grayscale(30%);
}

.mx_MImageBody_deletedOverlay {
    position: absolute;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    background: rgba(255, 255, 255, 0.95);
    padding: 12px 16px;
    border-radius: 8px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.2);
    text-align: center;

    span {
        display: block;
        color: #d32f2f;
        font-weight: 600;
        margin-bottom: 8px;
    }

    a {
        color: #1976d2;
        text-decoration: none;
        font-size: 13px;

        &:hover {
            text-decoration: underline;
        }
    }
}
```

**Location/Map Messages**:
```typescript
// LI: In MLocationBody.tsx
if (isRedacted) {
    const geoUri = content.geo_uri;  // e.g., "geo:37.786,-122.399"

    return (
        <div className="mx_MLocationBody mx_MLocationBody_redacted">
            <DeleteIcon />
            <span>Deleted Location: {geoUri}</span>
            {/* LI: Still show map link */}
            <a href={`https://www.openstreetmap.org/?mlat=${lat}&mlon=${lon}`} target="_blank">
                View on Map
            </a>
        </div>
    );
}
```

**Emoji Reactions**:
```typescript
// LI: Reactions are also events, so they can be redacted
// In ReactionsRow.tsx or similar
if (reaction.isRedacted()) {
    return (
        <div className="mx_ReactionsRow_item mx_ReactionsRow_item_redacted">
            <DeleteIcon style={{ fontSize: 12 }} />
            <span title="Deleted reaction">{reaction.getContent().key}</span>
        </div>
    );
}
```

### 2.3 Configuration Flag

**Important**: Deleted message display should ONLY be enabled in element-web-li, NOT in main instance element-web.

**File**: `element-web-li/config.json` (NEW FIELD)

```json
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://synapse-li.example.com"
    }
  },
  "brand": "Element Web LI",
  "li_features": {
    "show_deleted_messages": true
  }
}
```

**File**: `element-web-li/src/SdkConfig.ts` (MODIFICATION)

```typescript
// LI: Check if deleted messages should be shown
export function shouldShowDeletedMessages(): boolean {
    const config = SdkConfig.get();
    return config?.li_features?.show_deleted_messages === true;
}
```

**Usage in components**:
```typescript
import { shouldShowDeletedMessages } from "../../SdkConfig";

// LI: Only fetch/display if enabled
if (shouldShowDeletedMessages()) {
    const redactedEvents = await fetchRedactedEvents(roomId);
    // ... display logic ...
}
```

### 2.4 Admin Access Pattern

**Flow**:
1. Admin opens synapse-admin-li
2. Admin finds target user (e.g., `@alice:example.com`)
3. Admin resets user's password via admin panel
4. Admin opens element-web-li
5. Admin logs in with:
   - Username: `@alice:example.com`
   - Password: `<newly reset password>`
6. **From synapse-li perspective**: This is just a normal user login (not admin)
7. Admin retrieves Alice's recovery key from key_vault (via synapse-admin-li decrypt tab)
8. Admin enters recovery key in element-web-li to verify session
9. Admin now sees all of Alice's rooms and messages, including deleted ones (styled with red background)

**Important**: There is NO special "admin login" in element-web-li. Admin impersonates the user.

---

## 3. Implementation Strategy

### 3.1 Code Changes Summary

**synapse (main instance)**:
- `homeserver.yaml`: Set `redaction_retention_period: null`
- No code changes needed

**synapse-li (hidden instance)**:
- Same configuration as main instance
- Optional: Add admin API endpoint to return redacted events with original content

**element-web (main instance)**:
- No changes

**element-web-li (hidden instance)**:
- `config.json`: Add `li_features.show_deleted_messages: true`
- `src/stores/LIRedactedEvents.ts`: NEW FILE (fetch redacted events)
- `src/components/structures/TimelinePanel.tsx`: Fetch and merge redacted events
- `src/components/views/rooms/EventTile.tsx`: Add redacted styling
- `src/components/views/messages/MFileBody.tsx`: Handle deleted files
- `src/components/views/messages/MImageBody.tsx`: Handle deleted images
- `src/components/views/messages/MVideoBody.tsx`: Handle deleted videos
- `src/components/views/messages/MLocationBody.tsx`: Handle deleted locations
- `res/css/views/rooms/_EventTile.scss`: Add redacted message styles

**All changes marked with `// LI:` comments**

### 3.2 Testing Checklist

**Main Instance**:
- [ ] Verify `redaction_retention_period: null` in config
- [ ] Delete a message, verify it's hidden in timeline
- [ ] Query database: `SELECT content FROM event_json WHERE event_id = '...'`
- [ ] Confirm original content still in database

**Hidden Instance**:
- [ ] Sync from main instance
- [ ] Reset user password in synapse-admin-li
- [ ] Log in as user in element-web-li
- [ ] Verify deleted messages appear with red background
- [ ] Test different message types:
  - [ ] Text message (deleted)
  - [ ] Image (deleted)
  - [ ] File attachment (deleted)
  - [ ] Video (deleted)
  - [ ] Location (deleted)
  - [ ] Emoji reaction (deleted)
- [ ] Verify files are still downloadable from MinIO
- [ ] Verify messages are properly sorted chronologically

### 3.3 Visual Design

**Deleted Message Appearance** (in element-web-li):

```
┌────────────────────────────────────────────────────────┐
│ 🗑️ Deleted                                             │
│ ┌────────────────────────────────────────────────────┐│
│ │ Alice                               12:34 PM        ││
│ │ This message was deleted by the user               ││
│ │ (Background: light red, border-left: red)          ││
│ └────────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│ 🗑️ Deleted                                             │
│ ┌────────────────────────────────────────────────────┐│
│ │ Bob                                 12:35 PM        ││
│ │ [📎 deleted_file.pdf]                              ││
│ │ Deleted • 2.4 MB                                   ││
│ │ [Download Deleted File]                            ││
│ └────────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│ 🗑️ Deleted                                             │
│ ┌────────────────────────────────────────────────────┐│
│ │ Carol                               12:36 PM        ││
│ │ ┌──────────────────────┐                           ││
│ │ │  [Deleted Image]     │ (grayed out thumbnail)    ││
│ │ │  [View Full Size]    │                           ││
│ │ └──────────────────────┘                           ││
│ └────────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────────┘
```

**Color Scheme**:
- Background: `rgba(255, 0, 0, 0.08)` (very light red)
- Border: `3px solid rgba(255, 0, 0, 0.3)` (left border, semi-transparent red)
- Badge text: `#d32f2f` (Material Design Red 700)
- Icon: Delete/Trash icon in red

### 3.4 Alternative Approaches Considered

**Option 1: Strikethrough text** (NOT CHOSEN)
- Pros: Very clear visual indication
- Cons: Text becomes hard to read, doesn't work for images/files

**Option 2: Opacity reduction** (NOT CHOSEN)
- Pros: Subtle, non-intrusive
- Cons: Too subtle, admin might miss deleted messages

**Option 3: Separate "Deleted Messages" tab** (NOT CHOSEN)
- Pros: Clean separation
- Cons: Breaks chronological timeline flow, admin loses context

**CHOSEN: Background color + border + badge**
- ✅ Clear visual distinction
- ✅ Maintains chronological timeline
- ✅ Works for all message types
- ✅ Minimal code changes (mostly CSS)
- ✅ Admin can easily identify deleted content while maintaining context

---

## Summary

### Configuration
- **Main Instance**: `redaction_retention_period: null` (keep deleted messages forever)
- **Hidden Instance**: Same configuration + element-web-li modifications

### Visual Design
- Deleted messages shown with light red background
- Red left border (3px solid)
- Delete icon badge
- Works for: text, files, images, videos, locations, reactions

### Code Changes
- **synapse**: Configuration only (no code changes)
- **element-web-li**: ~200 lines across 8 files (all marked with `// LI:`)
- **Main element-web**: No changes

### Security
- Admin impersonates users (no special admin login in element-web-li)
- Synapse-li sees normal user authentication
- Recovery keys retrieved from key_vault for session verification

### Next Steps
See [Part 3: Key Backup & Session Limits](LI_REQUIREMENTS_ANALYSIS_03_KEY_BACKUP_SESSIONS.md)
