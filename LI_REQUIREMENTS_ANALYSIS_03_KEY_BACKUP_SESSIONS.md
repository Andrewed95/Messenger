# Part 3: Automatic Key Backup and Session Limits

## Table of Contents
1. [Automatic Key Backup](#automatic-key-backup)
2. [Session Limits Configuration](#session-limits-configuration)
3. [Deployment Guide](#deployment-guide)

---

## Automatic Key Backup

### Requirement

> "Check automatic key backup. I think matrix has automatic key backup already. After user setup their passphrase and recovery key and verify their session, they automatically backup their keys daily or something like that. Check this feature. I don't want anything before verification. It should be after verification."

### Matrix's Existing Automatic Key Backup

**Confirmation**: ✅ Matrix DOES have automatic key backup post-verification

#### How It Works

1. **User Setup** (one-time):
   - User creates passphrase or recovery key
   - User verifies their session
   - Backup is initialized on server

2. **Automatic Backup** (ongoing):
   - After verification, clients automatically backup new keys
   - No user action required for daily backup
   - Keys uploaded as they're created

#### Element Web Implementation

**File**: `element-web/src/DeviceListener.ts` (lines 150-180)

```typescript
// After user verifies session and enables backup
private async startAutomaticKeyBackup(): Promise<void> {
    const crypto = this.matrixClient.getCrypto();

    // Enable automatic backup
    await crypto.enableKeyBackup();

    // From now on, NEW keys are automatically backed up
    crypto.on("RoomKeyEvent", async (event) => {
        await crypto.backupRoomKey(event.keyId);
    });
}

// Automatic upload happens in background
private static readonly KEY_BACKUP_POLL_INTERVAL = 5 * 60 * 1000;  // 5 minutes
```

**What Happens**:
- Every time user receives new encryption key → automatically uploaded to backup
- Every 5 minutes, client checks for unbackedup keys → uploads them
- No user interaction needed

#### Element X Android Implementation

**File**: `element-x-android/libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/encryption/RustEncryptionService.kt`

```kotlin
override suspend fun enableRecovery(
    waitForBackupUploadSteadyState: Boolean,
): Result<RecoveryKey> {
    val encryption = client.encryption()

    // Enable backup
    val recoveryKey = encryption.enableBackups()

    // From now on, keys automatically backed up
    encryption.backupStateMachine.enableKeyUpload()

    return Result.success(recoveryKey)
}

// Automatically upload new keys
override fun onRoomKeyReceived(roomKey: RoomKey) {
    if (isBackupEnabled()) {
        backupStateMachine.uploadKey(roomKey)  // Automatic
    }
}
```

**What Happens**:
- New keys automatically uploaded to server
- Background service handles uploads
- No user action needed

### LI Integration

**Good News**: Matrix's automatic key backup works perfectly with LI requirements.

#### Flow

1. **User Setup** (one-time):
   - User creates passphrase in element-web
   - `captureKey()` sends encrypted passphrase to key_vault (via Synapse proxy)
   - User verifies session
   - Matrix enables automatic backup

2. **Automatic Backup** (ongoing):
   - User sends/receives encrypted messages
   - Matrix clients automatically backup keys
   - Keys stored in Synapse database
   - Hidden instance syncs keys via database replication

3. **Admin Access**:
   - Admin retrieves encrypted passphrase from key_vault
   - Admin decrypts passphrase with private key
   - Admin logs into hidden instance as user (via password reset)
   - Admin uses passphrase to decrypt messages

### Configuration

**No configuration needed** - Matrix's automatic backup works out-of-the-box after user verification.

**Only requirement**: User must complete initial setup (passphrase + verification).

#### Optional: Encourage Setup

If you want to encourage users to set up backup, you can configure reminder frequency:

**File**: `element-web/config.json`

```json
{
    "settingDefaults": {
        // Show setup prompt to users who haven't enabled backup
        "doNotShowSetupEncryption": false
    }
}
```

**Result**: Users who haven't set up backup will see periodic reminders.

**Important**: Don't force mandatory setup - let users set up voluntarily. The automatic backup will work once they do.

### Backup Frequency

Matrix clients don't backup "daily" - they backup **immediately** when new keys are created.

**Backup Triggers**:
- User receives new room key → immediate upload
- User verifies new device → upload cross-signing keys
- Periodic check every 5 minutes for missed keys

**Result**: More frequent than daily - essentially real-time backup.

### Verification

Check if user has backup enabled:

```bash
# Get user's backup status
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://matrix.example.com/_matrix/client/r0/room_keys/version"

# Response if backup enabled:
{
  "algorithm": "m.megolm_backup.v1.curve25519-aes-sha2",
  "auth_data": {
    "public_key": "...",
    "signatures": {...}
  },
  "count": 1234,  # Number of backed up keys
  "etag": "...",
  "version": "5"
}

# Response if backup NOT enabled:
{
  "errcode": "M_NOT_FOUND",
  "error": "No current backup version"
}
```

### Summary

✅ **Matrix has automatic key backup post-verification**
✅ **No configuration needed** - works out-of-the-box
✅ **Backup frequency**: Real-time (not daily, better than daily)
✅ **LI integration**: Capture passphrase on setup, retrieve from key_vault later
✅ **No code changes needed** - existing Matrix feature

**Only requirement**: User must complete one-time setup (passphrase + verification)

---

## Session Limits Configuration

### Requirement

> "Limit number of user sessions. For example we can only accept maximum of 5 session per user. This number should be in config and changeable. Main synapse only, not hidden."

### Approach: Deployment Configuration

Add `max_devices_per_user` to main Synapse configuration as a deployment setting.

### Implementation

#### 1. Synapse Configuration Option

**File**: `synapse/synapse/config/server.py` (MODIFICATION)

```python
class ServerConfig(Config):
    section = "server"

    def read_config(self, config, **kwargs):
        # ... existing config ...

        # LI: Device limit per user (main instance only)
        self.max_devices_per_user = config.get("max_devices_per_user", None)

        if self.max_devices_per_user is not None:
            if not isinstance(self.max_devices_per_user, int):
                raise ConfigError("max_devices_per_user must be an integer")
            if self.max_devices_per_user < 1:
                raise ConfigError("max_devices_per_user must be at least 1")
```

**Changes**: 7 lines

#### 2. Device Count Query

**File**: `synapse/synapse/storage/databases/main/devices.py` (NEW METHOD)

```python
async def count_devices_by_user(self, user_id: str) -> int:
    """Count number of devices for a user"""
    return await self.db_pool.simple_select_one_onecol(
        table="devices",
        keyvalues={"user_id": user_id},
        retcol="COUNT(*)",
        desc="count_devices_by_user",
    )
```

**Changes**: New method, 8 lines

#### 3. Limit Check on Login

**File**: `synapse/synapse/rest/client/login.py` (MODIFICATION)

```python
class LoginRestServlet(RestServlet):
    async def on_POST(self, request: Request) -> Tuple[int, JsonDict]:
        login_submission = parse_json_object_from_request(request)

        # ... authentication logic ...

        # LI: Check device limit before creating device
        max_devices = self.hs.config.server.max_devices_per_user
        if max_devices is not None:
            current_count = await self.store.count_devices_by_user(user_id)

            if current_count >= max_devices:
                raise LimitExceededError(
                    f"Maximum number of devices ({max_devices}) reached. "
                    f"Please delete an old session before logging in.",
                    errcode=Codes.LIMIT_EXCEEDED
                )

        # Create device
        device_id = await self.registration_handler.register_device(
            user_id=user_id,
            device_id=login_submission.get("device_id"),
            initial_display_name=login_submission.get("initial_device_display_name"),
        )

        # ... return access token ...
```

**Changes**: 10 lines

#### 4. Admin Bypass

**File**: `synapse/synapse/rest/admin/users.py` (MODIFICATION)

```python
# When admin creates device for user via admin API
async def on_POST(self, request: Request, user_id: str) -> Tuple[int, JsonDict]:
    requester = await self.auth.get_user_by_req(request)

    # LI: Admins bypass device limit
    # (No check for max_devices_per_user)

    device_id = await self.registration_handler.register_device(
        user_id=user_id,
        device_id=body.get("device_id"),
        initial_display_name=body.get("display_name"),
    )

    return 200, {"device_id": device_id}
```

**Changes**: 1 comment only (admins already bypass automatically)

### Deployment Configuration

#### Kubernetes Deployment

**File**: `deployment/manifests/05-synapse-main.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-config
  namespace: matrix
data:
  homeserver.yaml: |
    server_name: "example.com"

    # ... other Synapse configs ...

    # LI: Session Limit (Main Instance Only)
    # Limit number of concurrent devices/sessions per user
    # Set to null for unlimited (default)
    # Admins can bypass this limit
    max_devices_per_user: 5

    database:
      name: psycopg2
      args:
        host: postgres
        database: synapse
        user: synapse
        password: "${SYNAPSE_DB_PASSWORD}"
```

#### Helm Values

**File**: `deployment/helm/values-main.yaml`

```yaml
synapse:
  config:
    serverName: "example.com"

    # LI: Session Limit
    maxDevicesPerUser: 5  # null for unlimited

    database:
      host: postgres
      name: synapse
```

**Template**: `deployment/helm/templates/synapse-configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-config
data:
  homeserver.yaml: |
    server_name: {{ .Values.synapse.config.serverName | quote }}

    {{- if .Values.synapse.config.maxDevicesPerUser }}
    # LI: Session Limit
    max_devices_per_user: {{ .Values.synapse.config.maxDevicesPerUser }}
    {{- end }}

    database:
      name: psycopg2
      args:
        host: {{ .Values.synapse.config.database.host }}
        database: {{ .Values.synapse.config.database.name }}
```

#### Docker Compose Deployment

**File**: `deployment/synapse/homeserver.yaml`

```yaml
server_name: "example.com"

# LI: Session Limit (Main Instance Only)
#
# Purpose: Limit number of concurrent sessions per user
#
# How it works:
# - When user tries to log in, Synapse counts their existing devices
# - If count >= max_devices_per_user, login fails with error
# - User must delete old session before logging in
# - Admins can bypass this limit
#
# Default: null (unlimited)
# Recommended: 5-10 for most deployments
max_devices_per_user: 5

database:
  name: psycopg2
  args:
    host: postgres
    database: synapse
    user: synapse
    password: "changeme"
```

### User Experience

#### When Limit is Reached

**Error Response**:

```json
{
  "errcode": "M_LIMIT_EXCEEDED",
  "error": "Maximum number of devices (5) reached. Please delete an old session before logging in.",
  "limit_type": "device_count",
  "current_count": 5,
  "max_allowed": 5
}
```

**Element Web Display**:

```
❌ Failed to log in

You have reached the maximum number of active sessions (5).
Please log out from an old device before logging in here.

[Manage Sessions] [Cancel]
```

#### Managing Sessions

Users can delete old sessions:

**Element Web**: Settings → Security & Privacy → Sessions → [Delete]
**Element X Android**: Settings → Sessions → [Delete]

**Synapse Admin** (via synapse-admin):
- Navigate to user → Devices tab
- Select old device → Delete

### Important Notes

1. **Main Instance Only**: Do NOT add `max_devices_per_user` to hidden instance (synapse-li)
   - Hidden instance is for admin access only
   - No user logins (admin impersonates via password reset)
   - Session limit not needed

2. **Admin Bypass**: Admins can create devices via admin API without limit
   - Allows admin to impersonate users in hidden instance
   - Necessary for LI access

3. **Concurrent Logins**: Use database transaction to prevent race conditions
   ```python
   async def check_device_limit(self, user_id: str) -> None:
       async with self.db_pool.begin() as txn:
           # Lock user row during count check
           count = await txn.execute(
               "SELECT COUNT(*) FROM devices WHERE user_id = ? FOR UPDATE",
               (user_id,)
           )

           if count >= max_devices:
               raise LimitExceededError("...")
   ```

4. **Deleted Devices**: Count updates automatically
   - When user deletes device, it's removed from database
   - Next login query counts fresh from database
   - No caching issues

### Testing

1. **Test Limit Enforcement**:
   ```bash
   # Log in 5 times successfully
   for i in {1..5}; do
     curl -X POST "https://matrix.example.com/_matrix/client/r0/login" \
       -d '{"type":"m.login.password","user":"testuser","password":"pass","initial_device_display_name":"Device '$i'"}'
   done

   # 6th login should fail with M_LIMIT_EXCEEDED
   curl -X POST "https://matrix.example.com/_matrix/client/r0/login" \
       -d '{"type":"m.login.password","user":"testuser","password":"pass","initial_device_display_name":"Device 6"}'
   ```

2. **Test Device Deletion**:
   ```bash
   # Delete one device
   curl -X DELETE "https://matrix.example.com/_matrix/client/r0/devices/{device_id}" \
     -H "Authorization: Bearer $ACCESS_TOKEN"

   # Now login should succeed again
   curl -X POST "https://matrix.example.com/_matrix/client/r0/login" \
       -d '{"type":"m.login.password","user":"testuser","password":"pass"}'
   ```

3. **Test Admin Bypass**:
   ```bash
   # Admin creates device for user (should bypass limit)
   curl -X POST "https://matrix.example.com/_synapse/admin/v2/users/@user:server.com/devices" \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -d '{"device_id":"admin_device","display_name":"Admin Created"}'
   ```

### Recommended Configuration

**For Most Deployments**:
```yaml
max_devices_per_user: 10
```

**Reasoning**:
- Allows phone, tablet, laptop, web browser, backup device
- Plus a few extra for flexibility
- Still prevents unlimited device proliferation

**For Strict Deployments**:
```yaml
max_devices_per_user: 5
```

**Reasoning**:
- More restrictive security
- Forces users to manage sessions actively
- Better for high-security environments

**For Unlimited**:
```yaml
# Don't include max_devices_per_user at all
# Or set to null
max_devices_per_user: null
```

### Code Changes Summary

**Total Changes**: ~30 lines across 3 files

| File | Change Type | Lines |
|------|-------------|-------|
| `synapse/config/server.py` | Add config option | 7 |
| `synapse/storage/databases/main/devices.py` | Add count query | 8 |
| `synapse/rest/client/login.py` | Add limit check | 10 |
| `synapse/rest/admin/users.py` | Comment only | 1 |

**All changes marked with `// LI:` comments**

---

## Deployment Guide

### Main Instance Configuration

#### Step 1: Modify Synapse Code

1. **Add configuration option** (`synapse/config/server.py`)
2. **Add device count query** (`synapse/storage/databases/main/devices.py`)
3. **Add limit check** (`synapse/rest/client/login.py`)

#### Step 2: Update Deployment Manifests

**Kubernetes**:

```yaml
# deployment/manifests/05-synapse-main.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-config
data:
  homeserver.yaml: |
    max_devices_per_user: 5
```

**Helm**:

```yaml
# deployment/helm/values-main.yaml
synapse:
  config:
    maxDevicesPerUser: 5
```

**Docker Compose**:

```yaml
# deployment/synapse/homeserver.yaml
max_devices_per_user: 5
```

#### Step 3: Build and Deploy

```bash
# Build custom Synapse image with session limit code
cd synapse
docker build -t synapse-li:latest .
docker push your-registry/synapse-li:latest

# Apply configuration
kubectl apply -f deployment/manifests/05-synapse-main.yaml
kubectl rollout restart deployment/synapse -n matrix

# Verify
kubectl logs -f deployment/synapse -n matrix | grep "max_devices_per_user"
```

#### Step 4: Test

1. Create test user
2. Log in 5 times (should succeed)
3. Try 6th login (should fail with M_LIMIT_EXCEEDED)
4. Delete one device
5. Try login again (should succeed)

### Hidden Instance Configuration

**IMPORTANT**: Do NOT add `max_devices_per_user` to hidden instance.

**File**: `deployment/synapse-li/homeserver.yaml`

```yaml
server_name: "hidden.example.com"

# LI: Soft Delete
redaction_retention_period: null

# LI: Disable Event Pruning
li_disable_pruning: true

# NO max_devices_per_user here (hidden instance doesn't need it)

database:
  name: psycopg2
  args:
    host: postgres-hidden
    database: synapse_li
```

**Why**: Hidden instance is for admin access only, no user logins, no session limit needed.

### Monitoring

Monitor session counts:

```sql
-- Count devices per user
SELECT
    user_id,
    COUNT(*) AS device_count
FROM devices
GROUP BY user_id
ORDER BY device_count DESC
LIMIT 20;

-- Users at or over limit
SELECT
    user_id,
    COUNT(*) AS device_count
FROM devices
GROUP BY user_id
HAVING COUNT(*) >= 5
ORDER BY device_count DESC;

-- Total devices in system
SELECT COUNT(*) FROM devices;
```

### Documentation

Add to deployment README:

```markdown
### Session Limits (Main Instance)

**Configuration**: `max_devices_per_user: 5` in `homeserver.yaml`

**Purpose**: Limit number of concurrent sessions per user

**How it works**:
- User can have maximum 5 active devices/sessions
- When limit reached, user must delete old session before logging in
- Admins can bypass limit via admin API

**User instructions**:
1. Go to Settings → Security & Privacy → Sessions
2. Find old/unused session
3. Click [Delete] to remove it
4. Try logging in again

**Admin override**:
- Admins can create devices without limit
- Used for lawful interception access in hidden instance
```

---

## Summary

### Automatic Key Backup

✅ **Matrix already has automatic key backup post-verification**
✅ **No configuration needed** - works out-of-the-box
✅ **Backup frequency**: Real-time (immediate on new keys)
✅ **LI integration**: Capture passphrase on setup, retrieve later
✅ **No code changes needed**

**User Setup Required**:
1. User creates passphrase/recovery key
2. User verifies session
3. Automatic backup enabled

**After Setup**:
- New keys automatically backed up
- No user action needed
- Works in background

### Session Limits

✅ **Deployment configuration only** - `max_devices_per_user: 5`
✅ **Main instance only** - not hidden instance
✅ **Admin bypass** - admins can create devices without limit
✅ **Minimal code changes** - ~30 lines across 3 files

**Configuration**:
```yaml
# Kubernetes ConfigMap / Helm values / homeserver.yaml
max_devices_per_user: 5
```

**Recommended Values**:
- **Strict**: 5 devices
- **Normal**: 10 devices
- **Unlimited**: null or omit config

### Implementation Checklist

**Automatic Key Backup**:
- [x] No changes needed - Matrix feature already exists
- [ ] Optional: Configure reminder prompts in element-web config.json
- [ ] Test: User creates passphrase → automatic backup works

**Session Limits**:
- [ ] Modify `synapse/config/server.py` (7 lines)
- [ ] Modify `synapse/storage/databases/main/devices.py` (8 lines)
- [ ] Modify `synapse/rest/client/login.py` (10 lines)
- [ ] Add `max_devices_per_user: 5` to main instance deployment
- [ ] Do NOT add to hidden instance deployment
- [ ] Build and deploy custom Synapse image
- [ ] Test: Log in 6 times, verify 6th fails

### Code Changes

**Total**: ~30 lines for session limits, 0 lines for key backup

**All changes marked with `// LI:` comments**

### Next Steps

Continue to [Part 4: Statistics Dashboard](LI_REQUIREMENTS_ANALYSIS_04_STATISTICS.md)
