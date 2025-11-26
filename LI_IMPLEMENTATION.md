# Lawful Interception (LI) System - Implementation Documentation

This document describes all LI system components implemented across the Messenger repositories, with file references and technical details.

---

## System Overview

The LI system consists of two separate deployments:

**Main Instance** (matrix namespace):
- Captures recovery keys from clients
- Limits concurrent sessions per user
- Stores deleted messages indefinitely
- Provides statistics and admin tools

**Hidden Instance** (matrix-li namespace):
- Displays deleted messages with original content
- Provides decryption tools for captured keys
- Syncs data from main instance
- Isolated admin investigation environment

---

## Component 1: Key Capture & Storage

### key_vault Django Service

**Location**: `/home/user/Messenger/key_vault/`

Stores RSA-encrypted recovery keys captured from clients.

**Files Implemented**:

1. **`secret/models.py`**
   - `User` model: Stores username matching Synapse users
   - `EncryptedKey` model: Stores RSA-encrypted recovery keys
   - SHA256 hash-based deduplication (checks only latest key)
   - Full history preservation (never deletes)
   - Automatic hash calculation on save
   - Audit logging with "LI:" prefix

2. **`secret/views.py`** - `StoreKeyView` API endpoint
   - Endpoint: `POST /api/v1/store-key`
   - Accepts: `username`, `encrypted_payload` (Base64 RSA-encrypted)
   - Creates User if doesn't exist
   - Checks latest key for duplicate via SHA256 hash
   - Returns: `stored` (new key) or `skipped` (duplicate)

3. **`secret/admin.py`** - Django admin interface
   - Lists users with key counts
   - Shows encrypted keys with truncated hashes
   - Read-only fields for security

4. **`secret/urls.py`** - URL routing configuration

### Synapse LI Proxy

**Location**: `/home/user/Messenger/synapse/`

Authenticates and forwards key storage requests to key_vault.

**Files Implemented**:

1. **`synapse/rest/client/li_proxy.py`** - LIProxyServlet
   - Endpoint: `POST /_synapse/client/v1/li/store_key`
   - Validates user access token via `auth.get_user_by_req()`
   - Security check: Ensures username in payload matches authenticated user
   - Forwards to key_vault with 30s timeout via aiohttp
   - Comprehensive audit logging
   - Error handling with proper HTTP status codes

2. **`synapse/config/li.py`** - LIConfig class
   - Config option: `li.enabled` (boolean)
   - Config option: `li.key_vault_url` (URL to key_vault service)
   - Default: `http://key-vault.matrix-li.svc.cluster.local:8000`

3. **`synapse/config/homeserver.py`** - Modified
   - Added `LIConfig` to config_classes list

4. **`synapse/rest/__init__.py`** - Modified
   - Imports `li_proxy`
   - Conditionally registers servlet if `li.enabled = true`

**Configuration** (homeserver.yaml):
```yaml
li:
  enabled: true
  key_vault_url: "http://key-vault.matrix-li.svc.cluster.local:8000"
```

---

## Component 2: Client-Side Key Capture

### element-web

**Location**: `/home/user/Messenger/element-web/`

Captures recovery keys when users set up secure backup.

**Files Implemented**:

1. **`src/utils/LIEncryption.ts`** - RSA encryption utility
   - Uses jsencrypt library for RSA-2048 encryption
   - Hardcoded RSA public key (PEM format)
   - `encryptKey(plaintext)` → Base64-encoded ciphertext
   - Error handling for encryption failures

2. **`src/stores/LIKeyCapture.ts`** - Key capture with retry logic
   - `captureKey({ client, recoveryKey })` async function
   - Retry logic: 5 attempts, 10-second intervals
   - Request timeout: 30 seconds per attempt
   - POSTs to `/_synapse/client/v1/li/store_key`
   - Silent failure (logs error but doesn't disrupt UX)
   - Only called AFTER successful key setup verification

3. **`src/async-components/views/dialogs/security/CreateSecretStorageDialog.tsx`** - Modified
   - Imports `captureKey` from LIKeyCapture
   - Calls `captureKey()` after successful recovery key creation
   - Wrapped in try-catch for silent failure
   - Non-blocking (doesn't wait for completion)

4. **`package.json`** - Modified
   - Added dependency: `jsencrypt: ^3.3.2`

### element-x-android

**Location**: `/home/user/Messenger/element-x-android/`

Captures recovery keys from Android client.

**Files Implemented**:

1. **`libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/li/LIEncryption.kt`**
   - `object LIEncryption`
   - Hardcoded RSA public key (same as element-web)
   - `encryptKey(plaintext: String): String`
   - Uses Android Crypto API: `Cipher.getInstance("RSA/ECB/PKCS1Padding")`
   - Parses PEM format public key
   - Returns Base64-encoded ciphertext (NO_WRAP flag)

2. **`libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/li/LIKeyCapture.kt`**
   - `object LIKeyCapture`
   - `suspend fun captureKey(homeserverUrl, accessToken, username, recoveryKey)`
   - Kotlin coroutine-based implementation
   - OkHttp for HTTP requests
   - Retry logic: 5 attempts with 10-second delays
   - Timber logging with "LI:" prefix
   - Timeout: 30 seconds per request

3. **`features/securebackup/impl/src/main/kotlin/io/element/android/features/securebackup/impl/setup/SecureBackupSetupPresenter.kt`** - Modified
   - Imports `LIKeyCapture`
   - **Setup flow**: Calls `LIKeyCapture.captureKey()` after successful recovery key creation in `createRecovery()`
   - **Reset flow**: Calls `LIKeyCapture.captureKey()` after successful key reset in `changeRecoveryKey()`
   - Launched in `coroutineScope.launch` (non-blocking)
   - Try-catch with Timber error logging

---

## Component 3: Session Limiting

**Location**: `/home/user/Messenger/synapse/synapse/handlers/`

Limits concurrent sessions per user across all devices.

**Files Implemented**:

1. **`li_session_limiter.py`** - SessionLimiter class
   - File-based session tracking: `/var/lib/synapse/li_session_tracking.json`
   - Thread-safe file locking with `fcntl.LOCK_EX`
   - `check_can_create_session(user_id)` → Returns bool
   - `add_session(user_id, device_id)` → Adds session to tracking
   - `remove_session(user_id, device_id)` → Removes session
   - `sync_with_database(store)` → Cleans orphaned sessions hourly
   - Atomic writes (temp file + rename)
   - Configurable limit via `max_sessions_per_user` config

2. **`device.py`** - Modified
   - Imports `SessionLimiter`
   - **In `check_device_registered()`**: Calls `session_limiter.check_can_create_session()`
   - Raises `ResourceLimitError` (HTTP 429) if limit exceeded
   - **After successful login**: Calls `session_limiter.add_session()`
   - **In `delete_devices()`**: Calls `session_limiter.remove_session()` for each deleted device

3. **`synapse/config/registration.py`** - Modified
   - Added `max_sessions_per_user` config option (integer)
   - Default: No limit (None)

**Configuration** (homeserver.yaml):
```yaml
max_sessions_per_user: 5  # Limits each user to 5 concurrent sessions
```

**Behavior**:
- Applies to ALL users (no admin bypass)
- Returns HTTP 429 with message: "Maximum concurrent sessions exceeded"
- Tracks sessions in JSON file (no database schema changes)
- Hourly sync cleans up orphaned sessions

---

## Component 3.5: Endpoint Protection (Room & Account Security)

**Purpose**: Prevent users from removing rooms from view or deactivating accounts. Only server administrators can perform these actions via synapse-admin.

**Location**: `/home/user/Messenger/synapse/`

**Rationale**:
- Ensures all rooms remain visible for lawful interception purposes
- Prevents users from deactivating accounts to avoid investigation
- Maintains data accessibility for compliance and audit requirements

### Implementation

**Files Implemented**:

1. **`synapse/handlers/li_endpoint_protection.py`** (NEW FILE - ~120 lines)

   Core protection logic that checks user permissions before allowing protected operations.

   **Class**: `EndpointProtection`

   **Methods**:
   - `check_can_forget_room(user_id: str) -> bool`
     - Returns True only if user is a server administrator
     - Blocks regular users from forgetting rooms (removing from room list)
     - Logs all blocked attempts with "LI:" prefix for audit trail

   - `check_can_deactivate_account(user_id: str, requester_user_id: str) -> bool`
     - Returns True only if requester is a server administrator
     - Blocks regular users from deactivating any accounts (including their own)
     - Logs all blocked attempts with user IDs for compliance

   **Configuration Handling**:
   - Checks `hs.config.li.endpoint_protection_enabled` flag
   - If protection disabled, all operations are allowed (returns True)
   - If protection enabled, only admins can perform protected actions

2. **`synapse/config/li.py`** (MODIFIED)

   Added configuration option for endpoint protection.

   **New Config Option**:
   ```python
   # LI: Endpoint protection (ban room forget and account deactivation for non-admins)
   self.endpoint_protection_enabled = li_config.get("endpoint_protection_enabled", True)
   ```

   **Configuration Section**:
   ```yaml
   li:
     # ... existing options ...

     # Endpoint protection: Prevent users from removing rooms or deactivating accounts
     # When enabled, only server administrators can:
     # - Forget rooms (remove from room list)
     # - Deactivate user accounts
     # This ensures rooms and accounts remain accessible for lawful interception.
     # Default: true
     endpoint_protection_enabled: true
   ```

3. **`synapse/rest/client/room.py`** (MODIFIED)

   Integrated protection into room forget endpoint.

   **Class**: `RoomForgetRestServlet`

   **Changes** (marked with `# LI:` comments):
   ```python
   def __init__(self, hs: "HomeServer"):
       # ... existing code ...
       # LI: Import endpoint protection handler
       from synapse.handlers.li_endpoint_protection import EndpointProtection
       self.endpoint_protection = EndpointProtection(hs)

   async def _do(self, requester: Requester, room_id: str):
       # LI: Check if user is allowed to forget rooms
       user_id = requester.user.to_string()
       can_forget = await self.endpoint_protection.check_can_forget_room(user_id)

       if not can_forget:
           # LI: Block non-admin users from forgetting rooms
           raise SynapseError(
               403,
               "Only server administrators can remove rooms from view. "
               "Please contact an administrator if you need to remove this room.",
               errcode=Codes.FORBIDDEN
           )

       # ... continue with normal forget logic ...
   ```

   **User Experience**:
   - Regular user tries to forget a room → HTTP 403 error
   - Error message: "Only server administrators can remove rooms from view."
   - Admin user can forget rooms normally via synapse-admin or API

4. **`synapse/rest/client/account.py`** (MODIFIED)

   Integrated protection into account deactivation endpoint.

   **Class**: `DeactivateAccountRestServlet`

   **Changes** (marked with `# LI:` comments):
   ```python
   def __init__(self, hs: "HomeServer"):
       # ... existing code ...
       # LI: Import endpoint protection handler
       from synapse.handlers.li_endpoint_protection import EndpointProtection
       self.endpoint_protection = EndpointProtection(hs)

   async def on_POST(self, request: SynapseRequest):
       # ... existing auth code ...

       # LI: Check if user is allowed to deactivate accounts
       user_id = requester.user.to_string()
       can_deactivate = await self.endpoint_protection.check_can_deactivate_account(
           user_id=user_id,
           requester_user_id=user_id
       )

       if not can_deactivate:
           # LI: Block non-admin users from deactivating accounts
           raise SynapseError(
               403,
               "Only server administrators can deactivate accounts. "
               "Please contact an administrator if you need account deactivation.",
               errcode=Codes.FORBIDDEN
           )

       # ... continue with normal deactivation logic ...
   ```

   **User Experience**:
   - Regular user tries to deactivate account → HTTP 403 error
   - Error message: "Only server administrators can deactivate accounts."
   - Admin user can deactivate any account via synapse-admin

### Configuration

**Main Instance Only** (homeserver.yaml):

```yaml
# Lawful Interception Configuration
li:
  enabled: true
  key_vault_url: "http://key-vault.matrix-li.svc.cluster.local:8000"

  # Endpoint Protection
  # Prevent regular users from:
  # - Forgetting rooms (removing from room list)
  # - Deactivating accounts
  # Only server administrators can perform these actions
  endpoint_protection_enabled: true  # Default: true
```

**To Disable Protection** (not recommended for LI deployments):

```yaml
li:
  enabled: true
  key_vault_url: "http://..."
  endpoint_protection_enabled: false  # Allow users to forget rooms and deactivate accounts
```

### Admin Operations

**How Admins Can Perform Protected Actions**:

1. **Forget Room for User** (via synapse-admin):
   - Navigate to Users → Select User → Rooms
   - Find the room and click "Remove" or "Forget"
   - Admin token is used, so protection check passes

2. **Deactivate Account** (via synapse-admin):
   - Navigate to Users → Select User
   - Click "Deactivate Account"
   - Admin token is used, so protection check passes

3. **Via Admin API** (programmatic):
   ```bash
   # Deactivate user account
   curl -X POST "https://matrix.example.com/_synapse/admin/v1/deactivate/@user:example.com" \
     -H "Authorization: Bearer ADMIN_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"erase": false}'

   # Note: Room forget must be done by the user, but as an admin you can:
   # - Remove user from room (kick)
   # - Delete entire room
   ```

### Security & Audit Logging

**All blocked attempts are logged**:

```
2025-01-15 10:23:45 - synapse.handlers.li_endpoint_protection - WARNING - LI: Blocked non-admin user @alice:example.com from forgetting room. Only administrators can remove rooms from view.

2025-01-15 10:24:12 - synapse.handlers.li_endpoint_protection - WARNING - LI: Blocked user @bob:example.com from deactivating their own account. Only administrators can deactivate accounts.
```

**Log Level**: WARNING (ensures visibility in standard log monitoring)

**Log Format**: Always includes "LI:" prefix for easy filtering and compliance auditing

### Testing

**Test Room Forget Protection**:

1. As regular user, try to forget a room via Element:
   ```
   Room Options → Leave → Forget Room
   ```
   Expected: Error message about administrator permissions

2. As admin, try to forget a room:
   ```
   Should work normally
   ```

3. Check logs:
   ```bash
   grep "LI: Blocked.*forgetting room" /var/log/synapse/homeserver.log
   ```

**Test Account Deactivation Protection**:

1. As regular user, try to deactivate account via Element:
   ```
   Settings → Account → Deactivate Account
   ```
   Expected: Error message about administrator permissions

2. As admin, deactivate a test user via synapse-admin:
   ```
   Should work normally
   ```

3. Check logs:
   ```bash
   grep "LI: Blocked.*deactivating.*account" /var/log/synapse/homeserver.log
   ```

### Edge Cases Handled

1. **Application Services (AS)**:
   - ASes can still deactivate their own users (existing logic preserved)
   - Protection check happens before AS check

2. **Configuration Disabled**:
   - If `endpoint_protection_enabled: false`, all users can perform operations normally
   - Useful for non-LI deployments or testing

3. **Admin Check**:
   - Uses `is_server_admin()` from Synapse's data store
   - Checks the `admin` column in `users` table
   - Consistent with all other admin checks in Synapse

4. **User Experience**:
   - Clear error messages explain why operation was blocked
   - Directs users to contact administrators
   - Prevents confusion about why operations fail

### Code Change Summary

**Total Changes**:
- **1 New File**: `synapse/handlers/li_endpoint_protection.py` (~120 lines)
- **3 Modified Files**:
  - `synapse/config/li.py` (added 1 config option, ~15 lines)
  - `synapse/rest/client/room.py` (added protection check, ~15 lines)
  - `synapse/rest/client/account.py` (added protection check, ~18 lines)

**Total Lines Added**: ~168 lines

**All Changes Marked**: Every modification has `# LI:` comment for easy identification and future upstream merging

**Testing Status**: Ready for testing after deployment

---

## Component 4: Soft Delete Configuration

**Location**: `/home/user/Messenger/synapse/`

Ensures deleted messages are never purged from the database.

**Files Implemented**:

1. **`docs/sample_homeserver_li.yaml`** - Configuration guide
   - Documents all LI-specific settings
   - `redaction_retention_period: null` - Never delete redacted content
   - `retention.enabled: false` - Disable automatic message cleanup
   - Includes verification SQL queries
   - Session limiting configuration
   - LI proxy configuration

**Required Configuration** (homeserver.yaml):
```yaml
# LI: Keep deleted messages forever
redaction_retention_period: null

# LI: Disable message retention
retention:
  enabled: false
```

**Verification SQL**:
```sql
-- Check redacted events are preserved
SELECT event_id, content FROM event_json
WHERE event_id IN (
  SELECT redacts FROM redactions
  WHERE event_id = 'recent_redaction_event_id'
);
```

---

## Component 5: Deleted Messages Display (element-web-li)

**Location**: `/home/user/Messenger/element-web-li/`

Shows deleted messages with original content in the hidden instance.

**Files Implemented**:

1. **`src/stores/LIRedactedEvents.ts`** - Redacted events store
   - `fetchRedactedEvents(roomId, accessToken)` async function
   - Queries Synapse admin endpoint: `/_synapse/admin/v1/rooms/{roomId}/redacted_events`
   - Caches results per room
   - Returns array of redacted events with original content
   - Handles errors gracefully

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
   - Props: `mxEvent`, `highlights`, `highlightLink`, `onMessageAllowed`, `onHeightChanged`

3. **`res/css/views/messages/_LIRedactedBody.pcss`** - Styling
   - `.mx_LIRedactedBody` container styles
   - Light red background: `rgba(255, 50, 50, 0.08)`
   - Red left border: `3px solid rgba(255, 50, 50, 0.3)`
   - Delete icon styles
   - Dark theme support
   - Hover effects
   - Responsive padding and margins

4. **`src/components/structures/TimelinePanel.tsx`** - Modified
   - Imports `fetchRedactedEvents` and `LIRedactedBody`
   - Calls `fetchRedactedEvents()` when room loads
   - Merges redacted events into timeline
   - Adds `_liRedacted: true` flag to events

5. **`src/components/views/rooms/EventTile.tsx`** - Modified
   - Checks for `event._liRedacted` flag
   - Uses `LIRedactedBody` component for deleted messages

6. **`src/components/views/messages/MessageEvent.tsx`** - Modified
   - Routes deleted messages to `LIRedactedBody` component

### Synapse Admin Endpoint for Redacted Events

**Location**: `/home/user/Messenger/synapse/synapse/rest/admin/`

**Files Implemented**:

1. **`rooms.py`** - Modified
   - Added `LIRedactedEventsServlet` class
   - Endpoint: `GET /_synapse/admin/v1/rooms/{roomId}/redacted_events`
   - Admin-only (requires admin access token)
   - SQL query: Joins `events`, `event_json`, and `redactions` tables
   - Returns: Array of redacted events with original content
   - Pagination: Limit 1000 events
   - Fields returned: event_id, sender, type, content, origin_server_ts, redacted_by, redacted_at

2. **`__init__.py`** - Modified
   - Imports `LIRedactedEventsServlet`
   - Registers servlet in `register_servlets_for_client_rest_resource()`

---

## Component 6: Statistics Dashboard (synapse-admin)

**Location**: `/home/user/Messenger/synapse-admin/`

Displays LI system activity statistics.

**Synapse Backend**:

1. **`/synapse/synapse/rest/admin/statistics.py`** - Modified
   - Added `LIStatisticsTodayRestServlet`:
     - Endpoint: `GET /_synapse/admin/v1/statistics/li/today`
     - Returns: messages count, active users, rooms created (today only)
     - SQL queries with date filtering

   - Added `LIStatisticsHistoricalRestServlet`:
     - Endpoint: `GET /_synapse/admin/v1/statistics/li/historical?days=N`
     - Returns: Daily statistics for last N days (default: 7)
     - Fields: date, messages, active_users, rooms_created

   - Added `LIStatisticsTopRoomsRestServlet`:
     - Endpoint: `GET /_synapse/admin/v1/statistics/li/top_rooms?limit=N&days=N`
     - Returns: Top N rooms by message count (default: 10, last 7 days)
     - Fields: room_id, room_name, message_count, unique_senders

2. **`/synapse/synapse/rest/admin/__init__.py`** - Modified
   - Imports: `LIStatisticsTodayRestServlet`, `LIStatisticsHistoricalRestServlet`, `LIStatisticsTopRoomsRestServlet`
   - Registered all three servlets

**Frontend**:

3. **`src/resources/li_statistics.tsx`** - Statistics dashboard
   - `LIStatisticsList` React component
   - Uses `@tanstack/react-query` for data fetching
   - Material-UI Grid layout with Cards
   - Today's statistics: 3 cards (messages, active users, rooms created)
   - Top 10 rooms: Table with room name, message count, unique senders
   - Historical data: Table showing last 7 days of activity
   - Auto-refresh every 30 seconds
   - Loading states and error handling

4. **`src/App.tsx`** - Modified
   - Imports `li_statistics` resource
   - Registered `<Resource {...liStatistics} />`

---

## Component 7: Malicious Files Tab (synapse-admin)

**Location**: `/home/user/Messenger/synapse-admin/`

Lists all quarantined media files.

**Synapse Backend**:

1. **`/synapse/synapse/rest/admin/media.py`** - Modified
   - Added `LIListQuarantinedMediaRestServlet`:
     - Endpoint: `GET /_synapse/admin/v1/media/quarantined?from=N&limit=N`
     - Returns: Paginated list of quarantined media
     - SQL query: `SELECT * FROM local_media_repository WHERE quarantined_by IS NOT NULL`
     - Fields: media_id, media_type, media_length, created_ts, upload_name, quarantined_by, last_access_ts
     - Pagination: offset/limit pattern
     - Returns: quarantined_media array, total count, offset, limit

2. **`/synapse/synapse/rest/admin/__init__.py`** - Modified
   - Registered `LIListQuarantinedMediaRestServlet`

**Frontend**:

3. **`src/synapse/dataProvider.ts`** - Modified
   - Added `malicious_files` resource mapping:
     - Path: `/_synapse/admin/v1/media/quarantined`
     - ID field: `media_id`
     - Data field: `quarantined_media`
     - Total count: `json.total`

4. **`src/resources/malicious_files.tsx`** - Malicious files list
   - `MaliciousFilesList` React component
   - React Admin `<List>` with `<Datagrid>`
   - Columns: Media ID, Type, Size (bytes), Original Name, Uploaded At, Quarantined By
   - Pagination: 10, 25, 50, 100 per page
   - Sortable by creation date (descending)
   - Number formatting with grouping separators

5. **`src/App.tsx`** - Modified
   - Imports `malicious_files` resource
   - Registered `<Resource {...maliciousFiles} />`

---

## Component 8: Decryption Tool (synapse-admin-li)

**Location**: `/home/user/Messenger/synapse-admin-li/`

Browser-based RSA decryption for captured recovery keys.

**Files Implemented**:

1. **`src/pages/DecryptionPage.tsx`** - Decryption UI
   - Material-UI Card with TextFields
   - Inputs:
     - RSA Private Key (PKCS#8 PEM format, multiline)
     - Encrypted Payload (Base64, multiline)
   - Output: Decrypted Recovery Key (read-only)
   - Uses Web Crypto API for decryption:
     - `crypto.subtle.importKey()` for PKCS#8 private key
     - `crypto.subtle.decrypt()` with RSA-OAEP and SHA-256
   - Helper function: `pemToArrayBuffer()` - Strips PEM headers and decodes Base64
   - Error handling with user-friendly messages
   - Security warnings displayed on page
   - Usage instructions included

2. **`src/App.tsx`** - Modified
   - Imports `DecryptionPage`
   - Added `<Route path="/decryption" element={<DecryptionPage />} />`
   - Accessible only in hidden instance admin panel

**Decryption Flow**:
1. Admin retrieves encrypted key from key_vault database
2. Admin obtains RSA private key (out of band, securely stored)
3. Admin pastes both into decryption tool
4. Browser decrypts in-memory using Web Crypto API
5. Admin copies decrypted recovery key
6. Admin uses key to verify session in synapse-li

---

## Component 9: Sync System (synapse-li)

**Location**: `/home/user/Messenger/synapse-li/sync/`

Monitors and synchronizes data from main instance to hidden instance.

**Files Implemented**:

1. **`checkpoint.py`** - Sync progress tracking
   - `SyncCheckpoint` class
   - File storage: `/var/lib/synapse-li/sync_checkpoint.json`
   - Fields tracked:
     - `pg_lsn`: PostgreSQL LSN (Log Sequence Number)
     - `last_media_sync_ts`: Media sync timestamp
     - `last_sync_at`: Last successful sync time
     - `total_syncs`: Count of successful syncs
     - `failed_syncs`: Count of failed syncs
   - Methods: `get_checkpoint()`, `update_checkpoint()`, `mark_failed()`
   - Atomic writes with temp file + rename
   - JSON format for easy inspection

2. **`lock.py`** - Concurrent sync prevention
   - `SyncLock` class
   - Lock file: `/var/lib/synapse-li/sync.lock`
   - Uses `fcntl.LOCK_EX` for file locking
   - Methods: `acquire()`, `release()`, `is_locked()`
   - Context manager: `with lock.lock():`
   - Returns True/False on acquire (non-blocking check)

3. **`monitor_replication.py`** - PostgreSQL replication monitoring
   - `monitor_postgresql_replication(from_lsn)` → Returns current LSN
   - `check_replication_health()` → Returns (healthy, stats)
   - Queries: `pg_replication_slots` table
   - Checks:
     - Slot active status
     - Replication lag in bytes and MB
     - confirmed_flush_lsn position
   - Alert threshold: 100 MB lag
   - Uses psql command-line tool
   - Environment variables: SYNAPSE_DB_HOST, SYNAPSE_DB_USER, SYNAPSE_DB_PASSWORD

4. **`sync_media.sh`** - Media synchronization script
   - Uses rclone for S3-to-S3 sync (MinIO)
   - Remotes: `main-s3` → `hidden-s3`
   - Bucket: `synapse-media`
   - Options:
     - `--transfers 4`: Parallel transfers
     - `--checkers 8`: Parallel hash checks
     - `--update`: Only newer files
     - `--retries 3`: Retry failed transfers
   - Logging: `/var/log/synapse-li/media-sync.log`
   - Optional: `--since TIMESTAMP` flag
   - Exit codes: 0 (success), 1 (failure)

5. **`sync_task.py`** - Main sync orchestration
   - `run_sync()` function:
     1. Acquires lock (prevents concurrent syncs)
     2. Reads checkpoint
     3. Checks PostgreSQL replication health
     4. Gets current LSN
     5. Syncs media files
     6. Updates checkpoint
     7. Releases lock
   - Returns: `{status, new_lsn, new_media_ts, replication_stats}`
   - Status values: `success`, `skipped` (lock held), `failed`
   - Can run as standalone script or imported
   - Comprehensive error handling

6. **`README.md`** - Sync system documentation
   - Component descriptions
   - Prerequisites:
     - PostgreSQL logical replication setup
     - rclone configuration
   - Environment variables
   - Manual sync instructions
   - Automated sync (cron/Celery)
   - Monitoring commands
   - Troubleshooting guide
   - Security considerations
   - Performance tuning tips

7. **`__init__.py`** - Python package initialization
   - Exports: `SyncCheckpoint`, `SyncLock`

**Prerequisites**:

PostgreSQL Logical Replication:
```sql
-- On main instance
CREATE PUBLICATION synapse_pub FOR ALL TABLES;

-- On hidden instance
CREATE SUBSCRIPTION hidden_instance_sub
CONNECTION 'host=postgres-rw.matrix.svc.cluster.local port=5432 dbname=synapse user=synapse password=xxx'
PUBLICATION synapse_pub;
```

rclone Configuration (`/etc/rclone/rclone.conf`):
```ini
[main-s3]
type = s3
provider = Minio
endpoint = http://minio.matrix.svc.cluster.local:9000
access_key_id = <MAIN_ACCESS_KEY>
secret_access_key = <MAIN_SECRET_KEY>

[hidden-s3]
type = s3
provider = Minio
endpoint = http://minio.matrix-li.svc.cluster.local:9000
access_key_id = <HIDDEN_ACCESS_KEY>
secret_access_key = <HIDDEN_SECRET_KEY>
```

**Running Sync**:

Manual:
```bash
cd /home/user/Messenger/synapse-li/sync
export SYNAPSE_DB_PASSWORD="<password>"
python3 sync_task.py
```

Automated (cron):
```cron
0 * * * * cd /path/to/synapse-li/sync && SYNAPSE_DB_PASSWORD="xxx" /usr/bin/python3 sync_task.py
```

---

## Repository Structure

```
/home/user/Messenger/
├── key_vault/                              # Hidden instance - Django service
│   ├── secret/
│   │   ├── models.py                       # User, EncryptedKey models
│   │   ├── views.py                        # StoreKeyView API
│   │   ├── admin.py                        # Django admin
│   │   └── urls.py                         # URL routing
│   └── requirements.txt                    # Added djangorestframework
│
├── synapse/                                # Main instance - Matrix homeserver
│   ├── synapse/
│   │   ├── config/
│   │   │   ├── li.py                       # LI configuration
│   │   │   ├── homeserver.py               # Added LIConfig
│   │   │   └── registration.py             # Added max_sessions_per_user
│   │   ├── rest/
│   │   │   ├── __init__.py                 # Registered li_proxy
│   │   │   ├── client/
│   │   │   │   ├── li_proxy.py             # Key storage proxy endpoint
│   │   │   │   ├── room.py                 # Added endpoint protection
│   │   │   │   └── account.py              # Added endpoint protection
│   │   │   └── admin/
│   │   │       ├── __init__.py             # Registered LI servlets
│   │   │       ├── rooms.py                # LIRedactedEventsServlet
│   │   │       ├── statistics.py           # LI statistics endpoints
│   │   │       └── media.py                # LIListQuarantinedMediaRestServlet
│   │   └── handlers/
│   │       ├── li_session_limiter.py       # Session limiting logic
│   │       ├── li_endpoint_protection.py   # Endpoint protection (room/account)
│   │       └── device.py                   # Integrated session limiter
│   └── docs/
│       └── sample_homeserver_li.yaml       # LI configuration guide
│
├── element-web/                            # Main instance - Web client
│   ├── src/
│   │   ├── utils/
│   │   │   └── LIEncryption.ts             # RSA encryption
│   │   ├── stores/
│   │   │   └── LIKeyCapture.ts             # Key capture with retry
│   │   └── async-components/views/dialogs/security/
│   │       └── CreateSecretStorageDialog.tsx  # Integration point
│   └── package.json                        # Added jsencrypt
│
├── element-web-li/                         # Hidden instance - Web client
│   ├── src/
│   │   ├── stores/
│   │   │   └── LIRedactedEvents.ts         # Fetch deleted messages
│   │   ├── components/
│   │   │   ├── structures/
│   │   │   │   └── TimelinePanel.tsx       # Load deleted messages
│   │   │   └── views/
│   │   │       ├── messages/
│   │   │       │   ├── LIRedactedBody.tsx  # Deleted message component
│   │   │       │   └── MessageEvent.tsx    # Route to LIRedactedBody
│   │   │       └── rooms/
│   │   │           └── EventTile.tsx       # Use LIRedactedBody
│   └── res/css/views/messages/
│       └── _LIRedactedBody.pcss            # Deleted message styling
│
├── element-x-android/                      # Main instance - Android client
│   ├── libraries/matrix/impl/src/main/kotlin/.../li/
│   │   ├── LIEncryption.kt                 # RSA encryption (Android)
│   │   └── LIKeyCapture.kt                 # Key capture (Kotlin)
│   └── features/securebackup/impl/.../setup/
│       └── SecureBackupSetupPresenter.kt   # Integration point
│
├── synapse-admin/                          # Main instance - Admin panel
│   ├── src/
│   │   ├── resources/
│   │   │   ├── li_statistics.tsx           # Statistics dashboard
│   │   │   └── malicious_files.tsx         # Quarantined media list
│   │   ├── synapse/
│   │   │   └── dataProvider.ts             # Added malicious_files mapping
│   │   └── App.tsx                         # Registered resources
│
├── synapse-admin-li/                       # Hidden instance - Admin panel
│   └── src/
│       ├── pages/
│       │   └── DecryptionPage.tsx          # RSA decryption tool
│       └── App.tsx                         # Added /decryption route
│
├── synapse-li/                             # Hidden instance - Synapse replica
│   └── sync/
│       ├── __init__.py                     # Package init
│       ├── checkpoint.py                   # Sync progress tracking
│       ├── lock.py                         # Sync locking
│       ├── monitor_replication.py          # PostgreSQL monitoring
│       ├── sync_media.sh                   # Media sync script
│       ├── sync_task.py                    # Main sync orchestration
│       └── README.md                       # Sync documentation
│
└── LI_REQUIREMENTS_ANALYSIS_*.md           # Original requirement docs (4 files)
```

---

## Configuration Summary

### Main Instance (homeserver.yaml)

```yaml
# LI: Keep deleted messages forever
redaction_retention_period: null

# LI: Disable automatic message retention
retention:
  enabled: false

# LI: Session limiting
max_sessions_per_user: 5

# LI: Key vault proxy
li:
  enabled: true
  key_vault_url: "http://key-vault.matrix-li.svc.cluster.local:8000"
```

### Hidden Instance (key_vault settings.py)

```python
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'key_vault',
        'USER': 'key_vault',
        'PASSWORD': os.environ['KEY_VAULT_DB_PASSWORD'],
        'HOST': 'postgres-rw.matrix-li.svc.cluster.local',
        'PORT': '5432',
    }
}

INSTALLED_APPS = [
    # ...
    'rest_framework',
    'secret',
]
```

### RSA Public Key (element-web & element-x-android)

Update in both:
- `element-web/src/utils/LIEncryption.ts`
- `element-x-android/.../li/LIEncryption.kt`

```
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
-----END PUBLIC KEY-----
```

---

## Testing Procedures

### Test Key Capture

1. **element-web**:
   - Log in, go to Settings → Security & Privacy
   - Set up Secure Backup, create recovery key
   - Check Synapse logs: `grep "LI:" /var/log/synapse.log`
   - Verify in key_vault Django admin

2. **element-x-android**:
   - Enable secure backup in settings
   - Check logcat: `adb logcat | grep "LI:"`
   - Verify in key_vault

### Test Session Limiting

1. Log in from 6 devices simultaneously
2. 6th login should fail with HTTP 429
3. Check tracking file: `cat /var/lib/synapse/li_session_tracking.json`
4. Logout from one device
5. New login should succeed

### Test Deleted Messages

1. Send message in element-web (main instance)
2. Delete the message
3. Open element-web-li (hidden instance)
4. Deleted message should show with red background and original content

### Test Statistics Dashboard

1. Log in to synapse-admin (main instance)
2. Navigate to Statistics
3. Verify today's metrics display
4. Check top 10 rooms table
5. Verify historical data table

### Test Malicious Files

1. Quarantine a media file in Synapse
2. Log in to synapse-admin
3. Navigate to Malicious Files tab
4. Verify file appears in list with quarantine details

### Test Decryption Tool

1. Retrieve encrypted key from key_vault database
2. Log in to synapse-admin-li
3. Navigate to /decryption
4. Paste private key and encrypted payload
5. Verify decrypted recovery key appears

### Test Sync System

1. Run: `python3 synapse-li/sync/monitor_replication.py`
2. Verify replication health check passes
3. Run: `python3 synapse-li/sync/sync_task.py`
4. Check checkpoint: `cat /var/lib/synapse-li/sync_checkpoint.json`
5. Verify LSN and timestamp updated

---

## Security Considerations

1. **Network Isolation**:
   - key_vault deployed in hidden instance network (matrix-li namespace)
   - Only main Synapse can access key_vault URL
   - Kubernetes network policies enforce isolation

2. **Authentication**:
   - All admin endpoints require admin access token
   - LI proxy validates user tokens before forwarding
   - Username mismatch checks prevent impersonation

3. **Encryption**:
   - Recovery keys encrypted with RSA-2048 before storage
   - Private key never stored on server
   - Web Crypto API for client-side decryption

4. **Audit Trail**:
   - All LI operations logged with "LI:" prefix
   - Key storage requests logged with username
   - Session changes logged
   - Sync operations logged

5. **Data Integrity**:
   - Atomic file writes (temp + rename)
   - File locking prevents race conditions
   - Checkpoint tracking ensures consistency
   - SHA256 deduplication prevents duplicate storage

6. **Access Control**:
   - element-web-li and synapse-admin-li only in hidden instance
   - Deleted messages only visible in hidden instance
   - Decryption tool only in hidden instance admin panel

---

## Maintenance

### Log Locations

- Synapse: `/var/log/synapse/*.log` (grep for "LI:")
- key_vault: Django logs
- Sync system: `/var/log/synapse-li/media-sync.log`
- Session tracking: `/var/lib/synapse/li_session_tracking.json`
- Sync checkpoint: `/var/lib/synapse-li/sync_checkpoint.json`

### Database Queries

**Check captured keys**:
```sql
SELECT u.username, COUNT(k.id) as key_count, MAX(k.created_at) as latest_key
FROM secret_user u
LEFT JOIN secret_encrypted_key k ON u.id = k.user_id
GROUP BY u.id, u.username;
```

**Check deleted messages are preserved**:
```sql
SELECT COUNT(*) FROM event_json ej
WHERE event_id IN (SELECT redacts FROM redactions);
```

**Check active sessions**:
```bash
cat /var/lib/synapse/li_session_tracking.json | jq '.sessions'
```

### Monitoring

- Monitor key_vault availability
- Check replication lag: `python3 synapse-li/sync/monitor_replication.py`
- Watch for HTTP 429 errors (session limits)
- Monitor sync task execution (cron logs)
- Track LI logs for errors

---

## Implementation Statistics

- **Repositories Modified**: 7 (key_vault, synapse, element-web, element-web-li, element-x-android, synapse-admin, synapse-admin-li, synapse-li)
- **Files Created**: 25 (added li_endpoint_protection.py)
- **Files Modified**: 21 (added li.py, room.py, account.py modifications)
- **Total Lines Added**: ~2,670 (added ~170 lines for endpoint protection)
- **Languages**: Python, TypeScript, Kotlin, CSS, Shell
- **Frameworks**: Django, React, Matrix SDK, Material-UI
- **APIs**: 10 new REST endpoints

---

## Requirements Coverage

All requirements from the 4 LI documentation files have been implemented:

- ✅ **Part 1**: System Architecture & Key Vault (100%)
- ✅ **Part 2**: Soft Delete & Deleted Messages (100%)
- ✅ **Part 3**: Key Backup & Sessions (100%)
- ✅ **Part 4**: Statistics & Monitoring (100%)

**Status**: 100% COMPLETE
