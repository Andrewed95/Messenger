# Element Web LI CSS Injection Issue - Technical Analysis

This document explains why the current CSS-only approach in the deployment's Element Web LI will **NOT** properly display deleted messages as required by the LI (Lawful Intercept) implementation.

---

## Problem Summary

The current `deployment/li-instance/02-element-web-li/deployment.yaml` uses **CSS injection** to style deleted messages. However, CSS **cannot fetch or display the original content** of deleted messages. The CSS only modifies the visual appearance of existing DOM elements, which in Element Web's case only contain the placeholder text "This message was deleted".

---

## What LI_IMPLEMENTATION.md Describes (Component 5)

According to `/home/ali/Messenger/LI_IMPLEMENTATION.md` (lines 533-602), the deleted messages display feature requires:

### 1. Synapse Admin API Endpoint

**File**: `synapse/synapse/rest/admin/rooms.py`

```python
# LIRedactedEventsServlet
# Endpoint: GET /_synapse/admin/v1/rooms/{roomId}/redacted_events
# Returns: Array of redacted events with ORIGINAL content
```

This endpoint:
- Queries the database: Joins `events`, `event_json`, and `redactions` tables
- Returns the **original content** of deleted messages (because `redaction_retention_period: null`)
- Requires admin authentication
- Paginates results (limit 1000)

### 2. React Store to Fetch Redacted Events

**File**: `element-web-li/src/stores/LIRedactedEvents.ts`

```typescript
// fetchRedactedEvents(roomId, accessToken) async function
// Queries Synapse admin endpoint: /_synapse/admin/v1/rooms/{roomId}/redacted_events
// Caches results per room
// Returns array of redacted events with original content
```

### 3. React Component to Display Deleted Messages

**File**: `element-web-li/src/components/views/messages/LIRedactedBody.tsx`

```typescript
// Renders deleted messages with visual distinction
// Shows "Deleted Message" heading
// Displays ORIGINAL CONTENT (fetched from API)
// Supports all message types: text, images, videos, audio, files, locations
```

### 4. Timeline Integration

**Files**:
- `element-web-li/src/components/structures/TimelinePanel.tsx` - Calls `fetchRedactedEvents()` when room loads
- `element-web-li/src/components/views/rooms/EventTile.tsx` - Uses `LIRedactedBody` for deleted messages
- `element-web-li/src/components/views/messages/MessageEvent.tsx` - Routes to `LIRedactedBody`

### 5. Styling

**File**: `element-web-li/res/css/views/messages/_LIRedactedBody.pcss`

```css
/* Styling for the LIRedactedBody component */
.mx_LIRedactedBody {
    background: rgba(255, 50, 50, 0.08);
    border-left: 3px solid rgba(255, 50, 50, 0.3);
    /* ... */
}
```

---

## What the Current Deployment Does

**File**: `deployment/li-instance/02-element-web-li/deployment.yaml` (lines 80-116)

```yaml
custom.css: |
  /* Show redacted messages with strikethrough */
  .mx_EventTile_redacted {
      text-decoration: line-through !important;
      opacity: 0.7 !important;
      background-color: #fff3cd !important;
  }

  /* Add "DELETED" badge to redacted messages */
  .mx_EventTile_redacted::after {
      content: " [DELETED]";
      color: red;
      font-weight: bold;
  }

  /* Highlight message composer as read-only */
  .mx_MessageComposer {
      opacity: 0.5;
      pointer-events: none;
  }

  /* Add watermark */
  body::before {
      content: "LAWFUL INTERCEPT - RESTRICTED ACCESS";
      /* ... */
  }
```

---

## Why CSS Cannot Work

### Technical Limitation

1. **CSS operates on existing DOM elements**
   - When a message is deleted (redacted), Element Web replaces the message content with a placeholder: "This message was deleted"
   - The **original content is NOT in the DOM** - it was removed by Element Web's redaction handling
   - CSS can only style what exists - it cannot create new content or fetch data

2. **The `.mx_EventTile_redacted` element contains only placeholder text**
   ```html
   <!-- What Element Web renders for a deleted message -->
   <div class="mx_EventTile_redacted">
       Message deleted
   </div>
   ```
   - CSS cannot replace "Message deleted" with the original message
   - CSS `::after` can only append text, not replace content

3. **No API calls**
   - CSS cannot make HTTP requests to fetch data
   - The original message content is stored in the database and accessible via `/_synapse/admin/v1/rooms/{roomId}/redacted_events`
   - Only JavaScript/React code can call this API

### What the CSS Actually Does

| CSS Rule | Effect | Does it show original content? |
|----------|--------|-------------------------------|
| `.mx_EventTile_redacted { text-decoration: line-through }` | Adds strikethrough to "Message deleted" | NO |
| `.mx_EventTile_redacted::after { content: " [DELETED]" }` | Appends "[DELETED]" badge | NO |
| `background-color: #fff3cd` | Yellow background | NO |

The CSS makes deleted messages **visually distinct** but does NOT show the **original content**.

---

## What Needs to Happen

### Option A: Custom Element Web LI Build (Required)

Build a custom `element-web-li` image from `/home/ali/Messenger/element-web-li/` that includes:

1. **The React components from LI_IMPLEMENTATION.md**:
   - `LIRedactedEvents.ts` - Store to fetch redacted events
   - `LIRedactedBody.tsx` - Component to display original content
   - Timeline integration modifications

2. **Modified Synapse LI with admin endpoint**:
   - `LIRedactedEventsServlet` in `synapse/rest/admin/rooms.py`

3. **The CSS styling** (deployment's CSS can supplement, but not replace, the React components)

### Option B: Remove Misleading CSS (If Custom Build Not Available)

If no custom build is available, the CSS should be removed or modified to clarify that deleted messages are **not viewable** in this deployment:

```yaml
custom.css: |
  /* NOTICE: Full deleted message viewing requires custom element-web-li build */
  /* This deployment shows placeholder styling only */
  .mx_EventTile_redacted {
      background-color: #fff3cd !important;
      border-left: 3px solid #ffc107 !important;
  }
  .mx_EventTile_redacted::before {
      content: "⚠️ Original content requires custom build - ";
  }
```

---

## Evidence from LI_IMPLEMENTATION.md

### Lines 533-543: Component 5 Overview
```
## Component 5: Deleted Messages Display (element-web-li)

**Location**: `/home/user/Messenger/element-web-li/`

Shows deleted messages with original content in the hidden instance.

**Files Implemented**:

1. **`src/stores/LIRedactedEvents.ts`** - Redacted events store
   - `fetchRedactedEvents(roomId, accessToken)` async function
   - Queries Synapse admin endpoint: `/_synapse/admin/v1/rooms/{roomId}/redacted_events`
```

### Lines 548-560: LIRedactedBody Component
```
2. **`src/components/views/messages/LIRedactedBody.tsx`** - Deleted message component
   - Renders deleted messages with visual distinction
   - Shows "Deleted Message" heading
   - Displays original content
   - Delete icon indicator
   - Supports all message types:
     - Text messages (m.text)
     - Images (m.image)
     - Videos (m.video)
     - Audio (m.audio)
     - Files (m.file)
     - Locations (m.location)
```

### Lines 584-597: Synapse Admin Endpoint
```
### Synapse Admin Endpoint for Redacted Events

**Location**: `/home/user/Messenger/synapse/synapse/rest/admin/`

**Files Implemented**:

1. **`rooms.py`** - Modified
   - Added `LIRedactedEventsServlet` class
   - Endpoint: `GET /_synapse/admin/v1/rooms/{roomId}/redacted_events`
   - Admin-only (requires admin access token)
   - SQL query: Joins `events`, `event_json`, and `redactions` tables
   - Returns: Array of redacted events with original content
```

---

## Conclusion

The CSS injection approach in the deployment is a **placeholder** that provides visual styling but **does not fulfill the LI requirement** of displaying deleted message content.

### Required Actions

1. **Build custom images** from the modified repositories:
   - `element-web-li` with React components
   - `synapse` with admin endpoint

2. **Update deployment** to use custom images instead of stock `vectorim/element-web:v1.11.96`

3. **The CSS in the deployment** can remain for additional visual polish, but it is not a replacement for the React implementation

### Verification Test

To verify if deleted messages display correctly:

1. Send a message in main instance
2. Delete (redact) the message
3. Open Element Web LI
4. **Expected (with custom build)**: Original message content visible with red styling
5. **Current (CSS only)**: "Message deleted" placeholder with strikethrough and yellow background

---

## File References

| File | Purpose | Status in Deployment |
|------|---------|---------------------|
| `/home/ali/Messenger/LI_IMPLEMENTATION.md` | Complete LI specification | Reference document |
| `/home/ali/Messenger/element-web-li/` | Custom Element Web with LI features | Source code (needs building) |
| `/home/ali/Messenger/synapse/` | Custom Synapse with LI endpoints | Source code (needs building) |
| `deployment/li-instance/02-element-web-li/deployment.yaml` | Current deployment | Uses stock image + CSS |

---

## Summary for Reviewing Agent

The CSS-only approach in the current deployment **cannot** display deleted message content because:

1. **CSS cannot make API calls** to fetch redacted events from Synapse
2. **CSS cannot replace DOM content** - only style existing elements
3. **The original message content is not in the DOM** - it must be fetched from the database
4. **LI_IMPLEMENTATION.md specifies React components and API endpoints** that are not present in stock Element Web

The deployment requires **custom Docker images** built from the modified repositories to properly implement the LI deleted messages feature.
