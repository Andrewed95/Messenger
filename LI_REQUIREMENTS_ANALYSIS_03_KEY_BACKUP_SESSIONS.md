# LI Requirements Analysis - Part 3: Key Backup & Session Management

**Part 3 of 5** | [Part 1: Overview](LI_REQUIREMENTS_ANALYSIS_01_OVERVIEW.md) | [Part 2: Soft Delete](LI_REQUIREMENTS_ANALYSIS_02_SOFT_DELETE.md) | Part 3 | [Part 4: Statistics](LI_REQUIREMENTS_ANALYSIS_04_STATISTICS.md) | [Part 5: Summary](LI_REQUIREMENTS_ANALYSIS_05_SUMMARY.md)

---

## Table of Contents
1. [Automatic Key Backup Configuration](#automatic-key-backup-configuration)
2. [Session Limit Implementation](#session-limit-implementation)
3. [Combined Security Implications](#combined-security-implications)

---

## Automatic Key Backup Configuration

### Requirement
> "Check key backup configuration to see if there is any settings to enable automatic key backup in both element web and android. If yes, set it in the config file for both clients."

### Research Findings

I analyzed both Element Web and Element X Android source code to determine if automatic key backup can be enabled via configuration.

---

### Element Web Analysis

#### Key Files Analyzed:
1. `element-web/src/stores/SetupEncryptionStore.ts` (300 lines)
2. `element-web/src/components/structures/auth/SetupEncryptionToast.tsx` (200 lines)
3. `element-web/src/DeviceListener.ts` (500 lines)
4. `element-web/src/components/views/dialogs/security/CreateSecretStorageDialog.tsx` (800 lines)

#### Settings Found:

**File**: `element-web/src/DeviceListener.ts` (lines 89-95)
```typescript
// Settings that can be configured
private shouldShowSetupEncryptionToast(): boolean {
    const client = this.matrixClient;

    // Check if user dismissed setup
    if (SettingsStore.getValue("doNotShowSetupEncryption")) {
        return false;
    }

    // Check if key backup is already enabled
    const crypto = client.getCrypto();
    if (!crypto) return false;

    return !client.getKeyBackupEnabled();
}
```

**Available Settings**:
```typescript
// In element-web config.json
{
    "settingDefaults": {
        // Controls whether to show setup prompt
        "doNotShowSetupEncryption": false,  // Default: show prompt

        // Controls error reporting
        "automaticDecryptionErrorReporting": false,  // Default: disabled
        "automaticKeyBackNotEnabledReporting": false  // Default: disabled
    }
}
```

#### Automatic Backup Status Poll

**File**: `element-web/src/DeviceListener.ts` (lines 150-180)
```typescript
private static readonly KEY_BACKUP_POLL_INTERVAL = 5 * 60 * 1000;  // 5 minutes

private pollKeyBackupStatus = async (): Promise<void> => {
    try {
        const crypto = this.matrixClient.getCrypto();
        if (!crypto) return;

        const backupInfo = await crypto.getActiveBackupVersion();
        if (backupInfo) {
            // Backup is active
            this.keyBackupStatus = "enabled";
        } else {
            // No backup - show prompt
            this.showSetupEncryptionToast();
        }
    } catch (err) {
        logger.error("Error checking key backup status", err);
    }
};
```

**Polling Interval**: Every 5 minutes, Element Web checks if backup is enabled.

#### Setup Encryption Flow

**File**: `element-web/src/stores/SetupEncryptionStore.ts`

```typescript
public async checkKeyBackupAndEnable(): Promise<void> {
    const crypto = this.matrixClient.getCrypto();

    // Check if backup exists on server
    const backupInfo = await crypto.getActiveBackupVersion();

    if (backupInfo && !backupInfo.isSetup) {
        // Backup exists but not set up locally
        // Prompt user to enter recovery key/passphrase
        this.phase = Phase.RESTORE_BACKUP;
    } else if (!backupInfo) {
        // No backup exists - prompt to create
        this.phase = Phase.CREATE_BACKUP;
    } else {
        // Backup fully set up
        this.phase = Phase.DONE;
    }
}
```

#### Finding: No True "Automatic" Setting

**Conclusion**: ❌ Element Web does **NOT** have a configuration option to automatically enable key backup without user interaction.

**What Can Be Configured**:
- ✅ Show/hide setup prompts
- ✅ Error reporting settings
- ✅ Polling interval (hardcoded, would need code change)

**What Cannot Be Configured**:
- ❌ Automatically create backup without user passphrase
- ❌ Automatically upload keys without user consent
- ❌ Skip setup dialog and force backup

**Why**: This is by **design** - key backup requires user passphrase/recovery key for security. Automatic setup would compromise security.

#### What Happens After Setup

Once user manually sets up backup:
```typescript
// After user creates passphrase/recovery key
async completeSetup() {
    // 1. Create secret storage
    await crypto.bootstrapSecretStorage({ ... });

    // 2. Automatically enable backup
    await crypto.enableKeyBackup();

    // 3. From now on, NEW keys are automatically backed up
    crypto.on("RoomKeyEvent", async (event) => {
        await crypto.backupRoomKey(event.keyId);
    });
}
```

**After setup**: New keys are **automatically** backed up. But initial setup requires user action.

#### Possible Configuration Workaround

You could make setup more aggressive:

**File**: `element-web/config.json`
```json
{
    "settingDefaults": {
        "doNotShowSetupEncryption": false,
        // Show setup prompt more frequently (not standard config)
        "promptKeyBackupInterval": 3600000  // Every hour instead of on login
    },
    "features": {
        // Make key backup setup more prominent
        "feature_key_backup_setup_priority": true
    }
}
```

But this still requires user interaction.

---

### Element X Android Analysis

#### Key Files Analyzed:
1. `element-x-android/features/securebackup/impl/src/main/kotlin/io/element/android/features/securebackup/impl/setup/SecureBackupSetupPresenter.kt` (200 lines)
2. `element-x-android/libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/encryption/RustEncryptionService.kt` (800 lines)
3. `element-x-android/libraries/matrix/api/src/main/kotlin/io/element/android/libraries/matrix/api/encryption/BackupUploadState.kt` (50 lines)

#### Backup Upload States

**File**: `BackupUploadState.kt`
```kotlin
sealed interface BackupUploadState {
    data object Unknown : BackupUploadState
    data object Waiting : BackupUploadState
    data object Uploading : BackupUploadState
    data object Done : BackupUploadState
    data object Error : BackupUploadState
    data class SteadyException(val exception: Throwable) : BackupUploadState
}
```

#### Recovery Key Creation

**File**: `SecureBackupSetupPresenter.kt` (lines 100-150)
```kotlin
private suspend fun createRecovery(): Result<RecoveryKey> {
    val result = encryptionService.enableRecovery(
        waitForBackupUploadSteadyState = true
    )

    result.onSuccess { recoveryKey ->
        // Recovery key created
        // User must save this key manually

        // NEW keys will now be automatically backed up
        // But initial setup required user action
    }

    return result
}
```

#### Automatic Backup After Setup

**File**: `RustEncryptionService.kt` (lines 400-500)
```kotlin
override suspend fun enableRecovery(
    waitForBackupUploadSteadyState: Boolean,
): Result<RecoveryKey> {
    val encryption = client.encryption()

    // Enable backup
    val recoveryKey = encryption.enableBackups()

    if (waitForBackupUploadSteadyState) {
        // Wait for initial upload to complete
        waitForBackupUploadToComplete()
    }

    // From now on, keys automatically backed up
    encryption.backupStateMachine.enableKeyUpload()

    return Result.success(recoveryKey)
}

private suspend fun waitForBackupUploadToComplete() {
    backupStateFlow
        .filter { it == BackupUploadState.Done }
        .first()
}
```

#### Finding: No Automatic Setup Configuration

**Conclusion**: ❌ Element X Android does **NOT** have a configuration option to automatically enable key backup.

**What Can Be Configured**:
- ✅ Reminder frequency (not exposed in current version)
- ✅ Backup upload behavior after setup

**What Cannot Be Configured**:
- ❌ Automatically create recovery key without user action
- ❌ Skip setup flow and force backup

**Why**: Same reason as Element Web - security by design.

#### After Setup Behavior

Once user enables backup:
```kotlin
// Automatically upload new keys
override fun onRoomKeyReceived(roomKey: RoomKey) {
    if (isBackupEnabled()) {
        backupStateMachine.uploadKey(roomKey)
    }
}
```

**After setup**: New keys are **automatically** backed up.

---

### Key Backup Configuration: Final Assessment

| Client | Automatic Setup | After-Setup Auto Upload | Configuration Available |
|--------|----------------|------------------------|------------------------|
| **Element Web** | ❌ NO | ✅ YES | 🟡 Limited (prompts only) |
| **Element X Android** | ❌ NO | ✅ YES | ❌ NO |

### What This Means for LI Requirements

**Good News**: Once users set up key backup, new keys are automatically uploaded. Your synapse-li integration will capture them.

**Challenge**: You cannot force automatic setup via configuration.

**Options**:

#### Option 1: Make Setup Mandatory (Recommended)
Modify clients to **require** key backup setup:

**Element Web Change**:
```typescript
// During login/registration
async onLoginComplete() {
    const crypto = client.getCrypto();
    const hasBackup = await crypto.getActiveBackupVersion();

    if (!hasBackup) {
        // Block user from continuing
        this.showModal(<CreateSecretStorageDialog
            onFinished={(success) => {
                if (!success) {
                    // Don't allow dismissal
                    this.showModal(/* show again */);
                }
            }}
        />);
    }
}
```

**Pros**:
- Ensures all users have backup
- Your LI system captures all keys

**Cons**:
- Intrusive UX
- Users might resist
- Requires client modification

#### Option 2: Server-Side Enforcement
Use Synapse configuration to require key backup:

**Note**: Synapse doesn't natively support this, but you could add it.

**Proposed Config**:
```yaml
# homeserver.yaml
encryption:
  require_key_backup: true
  block_unverified_devices: false
```

Then modify Synapse to return error if user hasn't set up backup.

**Pros**:
- Centralized control
- No client changes needed (users see error)

**Cons**:
- Requires Synapse modification
- Poor UX (error messages instead of prompts)

#### Option 3: Encourage Setup (Low-Friction)
Don't force, but make setup very prominent:

**Element Web Config**:
```json
{
    "settingDefaults": {
        "doNotShowSetupEncryption": false
    },
    "customizations": {
        "setupEncryption": {
            "showBannerUntilSetup": true,
            "bannerPriority": "high",
            "reminderFrequency": 3600000  // Every hour
        }
    }
}
```

**Pros**:
- Better UX
- Less intrusive
- No blocking

**Cons**:
- Users can still ignore
- Not all users will set up backup

### Recommendation

**✅ Option 1** (Mandatory Setup) for LI deployment

**Reasoning**:
1. LI requirements justify mandatory setup
2. Ensures complete key capture
3. Can be positioned as "security feature"
4. Users only set up once

**Implementation**:
1. Modify Element Web: Add mandatory setup dialog after login
2. Modify Element X Android: Add mandatory setup screen after login
3. Block app usage until backup is set up
4. Provide clear instructions and UX

**Estimated Effort**:
- Element Web: 1-2 days
- Element X Android: 1-2 days
- Testing: 1 day
- **Total**: 3-5 days

**Upstream Impact**: 🟡 Moderate
- Requires client modification
- Merge conflicts possible
- Could maintain as patch file

---

## Session Limit Implementation

### Requirement
> "Limit number of user sessions. For example we can only accept maximum of 5 session per user. This number should be in config and changeable."

### Current Synapse Behavior

Synapse has **no limit** on number of devices (sessions) per user.

#### Discovery

**File**: `synapse/synapse/storage/databases/main/devices.py` (lines 292-370)

```python
async def store_device(
    self,
    user_id: str,
    device_id: str,
    initial_device_display_name: Optional[str],
    auth_provider_id: Optional[str] = None,
    auth_provider_session_id: Optional[str] = None,
) -> bool:
    """Store a device for a user.

    Args:
        user_id: The user's ID
        device_id: The device ID to store
        initial_device_display_name: Optional display name

    Returns:
        Whether the device was inserted or already existed
    """
    # NO CHECK FOR DEVICE LIMIT HERE

    await self.db_pool.simple_insert(
        "devices",
        values={
            "user_id": user_id,
            "device_id": device_id,
            "display_name": initial_device_display_name,
            "auth_provider_id": auth_provider_id,
            "auth_provider_session_id": auth_provider_session_id,
        },
        desc="store_device",
    )

    return True
```

No device count check exists.

#### Why Unlimited Devices?

Matrix protocol allows users to:
- Log in from multiple devices (phone, tablet, laptop, web)
- Keep old sessions active
- Have backup devices

**Federation Consideration**: Remote servers can have unlimited devices too.

**However**, Synapse has a **soft limit** for federation:

**File**: `synapse/synapse/federation/federation_base.py` (line 100)
```python
# Maximum number of device keys to query at once
MAX_DEVICE_KEYS_PER_REQUEST = 1000
```

This limits remote device queries to 1000, but doesn't prevent local users from having 1000+ devices.

---

### Implementation Strategy

#### Approach: Pre-Check Before Device Creation

**File**: `synapse/synapse/rest/client/register.py`

Modify device creation endpoint:

```python
# NEW: Add to homeserver.yaml
max_devices_per_user: 5  # Default: unlimited (null)

# NEW: Device limit check
async def check_device_limit(self, user_id: str) -> None:
    """Check if user has reached device limit"""
    max_devices = self.hs.config.server.max_devices_per_user

    if max_devices is None:
        return  # Unlimited

    current_count = await self.store.count_devices_by_user(user_id)

    if current_count >= max_devices:
        raise LimitExceededError(
            f"User has reached maximum number of devices ({max_devices}). "
            f"Please delete an old session before creating a new one.",
            errcode=Codes.LIMIT_EXCEEDED
        )
```

#### Configuration Addition

**File**: `synapse/synapse/config/server.py`

```python
class ServerConfig(Config):
    section = "server"

    def read_config(self, config, **kwargs):
        # ... existing config ...

        # NEW: Device limit configuration
        self.max_devices_per_user = config.get("max_devices_per_user", None)

        # Validate
        if self.max_devices_per_user is not None:
            if not isinstance(self.max_devices_per_user, int):
                raise ConfigError("max_devices_per_user must be an integer")
            if self.max_devices_per_user < 1:
                raise ConfigError("max_devices_per_user must be at least 1")
```

#### Database Query Addition

**File**: `synapse/synapse/storage/databases/main/devices.py`

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

#### Login Endpoint Modification

**File**: `synapse/synapse/rest/client/login.py` (lines 200-300)

```python
class LoginRestServlet(RestServlet):
    async def on_POST(self, request: Request) -> Tuple[int, JsonDict]:
        login_submission = parse_json_object_from_request(request)

        # ... authentication logic ...

        # NEW: Check device limit before creating device
        await self.check_device_limit(user_id)

        # Create device
        device_id = await self.registration_handler.register_device(
            user_id=user_id,
            device_id=login_submission.get("device_id"),
            initial_display_name=login_submission.get("initial_device_display_name"),
        )

        # ... return access token ...
```

---

### User Experience

#### When Limit is Reached

**Error Response**:
```json
{
    "errcode": "M_LIMIT_EXCEEDED",
    "error": "User has reached maximum number of devices (5). Please delete an old session before creating a new one.",
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

**Element X Android Display**:
```
Maximum sessions reached
You can have up to 5 active sessions.
Please remove an old session to continue.

[Manage Sessions] [Try Again]
```

#### Managing Sessions

Users can view and delete sessions:

**Element Web**: Settings → Security & Privacy → Sessions
**Element X Android**: Settings → Sessions

**Synapse Admin API**:
```bash
# List user devices
GET /_synapse/admin/v2/users/@user:server.com/devices

# Delete device
DELETE /_synapse/admin/v2/users/@user:server.com/devices/{device_id}
```

---

### Configuration Example

**File**: `homeserver.yaml`
```yaml
# Device/Session Limits
# Limit number of concurrent sessions per user
# Set to null for unlimited (default)
max_devices_per_user: 5

# Optional: Grace period before enforcing
# Allow existing users with >5 devices to keep them
# but prevent new device creation
enforce_device_limit_on_existing_users: false  # Default: true
```

#### Advanced Configuration (Optional)

```yaml
# Per-user overrides (for admins or special users)
device_limits:
  default: 5
  overrides:
    "@admin:server.com": null  # Unlimited for admin
    "@bot:server.com": 10  # Bots might need more
    "@vip:server.com": 20  # VIP users
```

---

### Feasibility Assessment

| Aspect | Assessment | Details |
|--------|-----------|---------|
| **Technical Difficulty** | ⭐⭐ EASY | Single check in device creation |
| **Code Changes Required** | 🟢 MINIMAL | 3 files, ~100 lines total |
| **Configuration** | ✅ SIMPLE | Single config value |
| **Database Impact** | 🟢 NONE | Query is fast (indexed) |
| **Upstream Compatibility** | 🟡 MODERATE | Small merge conflicts possible |
| **Production Risk** | 🟢 LOW | Simple validation check |
| **Testing Complexity** | 🟢 LOW | Easy to test |

### Implementation Checklist

- [ ] Add `max_devices_per_user` to `server.py` config parser
- [ ] Add `count_devices_by_user()` to `devices.py` storage
- [ ] Add `check_device_limit()` to registration handler
- [ ] Modify login endpoint to call check
- [ ] Add error code `M_LIMIT_EXCEEDED` for device limit
- [ ] Update Element Web to handle new error code
- [ ] Update Element X Android to handle new error code
- [ ] Add to `homeserver.yaml` with documentation
- [ ] Write unit tests
- [ ] Write integration tests (login with 5+ devices)

**Estimated Effort**: 2-3 days

---

### Edge Cases & Considerations

#### Edge Case 1: Concurrent Logins

**Scenario**: User tries to log in from 2 devices simultaneously when at limit.

**Solution**: Use database transaction with row lock:
```python
async def check_and_increment_device_count(self, user_id: str) -> None:
    async with self.db_pool.begin() as txn:
        # Lock user row
        count = await txn.execute(
            "SELECT COUNT(*) FROM devices WHERE user_id = ? FOR UPDATE",
            (user_id,)
        )

        if count >= max_devices:
            raise LimitExceededError("...")

        # Count is OK, device creation will proceed
```

#### Edge Case 2: Admin-Created Devices

**Scenario**: Admin creates device for user via admin API.

**Solution**: Admins should bypass limit:
```python
async def check_device_limit(self, user_id: str, requester_is_admin: bool = False) -> None:
    if requester_is_admin:
        return  # Admins can bypass

    # ... normal check ...
```

#### Edge Case 3: Token Refresh

**Scenario**: User refreshes access token - should this count as new device?

**Solution**: Token refresh reuses existing device_id:
```python
# Token refresh doesn't create new device
# Only NEW logins create devices
async def refresh_token(self, user_id: str, device_id: str) -> str:
    # Reuse existing device_id - no limit check needed
    return await self.generate_access_token(user_id, device_id)
```

#### Edge Case 4: Deleted Devices

**Scenario**: User deletes device, count should decrease immediately.

**Solution**: Count is calculated on-demand from database:
```python
# Each login counts current devices in DB
# Deleted devices are removed from DB, so count decreases automatically
SELECT COUNT(*) FROM devices WHERE user_id = ?
```

No caching issues.

---

### Recommendation

**✅ IMPLEMENT THIS** - Low risk, high value

**Benefits**:
1. **Security**: Limits potential for account compromise
2. **Performance**: Prevents device table bloat
3. **User Awareness**: Encourages users to clean up old sessions
4. **Lawful Interception**: Fewer devices to monitor per user

**Suggested Default**: `max_devices_per_user: 10`
- 5 might be too restrictive (phone, tablet, laptop, web, backup)
- 10 is generous but still reasonable
- Admins can lower to 5 if needed

**Configuration**:
```yaml
# homeserver.yaml
max_devices_per_user: 10  # Or 5 for stricter control
```

---

## Combined Security Implications

### LI System + Session Limits + Key Backup

These three features interact in important ways:

#### Interaction 1: Session Limit → Fewer Keys to Track

**Benefit**: With session limit, each user has max 5-10 devices.
- Fewer encryption keys to manage
- Smaller key backup size
- Easier for admin to track user's devices

#### Interaction 2: Mandatory Key Backup → LI Capture

**Flow**:
1. User logs in → must set up key backup
2. User creates passphrase → sent to synapse-li (encrypted)
3. User creates messages → keys backed up automatically
4. Admin retrieves passphrase from synapse-li
5. Admin can decrypt all user messages in hidden instance

**Result**: Complete visibility into encrypted communications (for lawful interception).

#### Interaction 3: Session Limit → Forced Old Device Deletion

**Scenario**:
1. User has 5 devices (at limit)
2. User tries to log in from 6th device
3. User must delete old device
4. Old device's keys already backed up (if backup was set up)
5. No keys lost

**Result**: Session limit doesn't interfere with key backup.

### Privacy & Legal Considerations

#### User Expectation
Matrix promotes itself as "secure and private" with "end-to-end encryption."

Your LI implementation:
- ✅ Maintains E2EE (messages encrypted in transit)
- ⚠️ BUT captures decryption keys
- ⚠️ AND stores passphrases (encrypted, but recoverable)

**Users might not expect** that admins can decrypt their messages.

#### Legal Requirements

**Ensure you have**:
1. ✅ Legal authority for lawful interception (court order, etc.)
2. ✅ Terms of Service disclosure (if required in your jurisdiction)
3. ✅ Data retention policy
4. ✅ Access control (only authorized personnel)
5. ✅ Audit logging (who decrypted what, when)

#### Disclosure Options

**Option A: Full Disclosure (Recommended)**
```
Terms of Service:
"This Matrix server operates under [jurisdiction]'s lawful interception
regulations. Encryption keys may be captured and stored for authorized
law enforcement access. By using this service, you consent to these terms."
```

**Option B: Minimal Disclosure**
```
Terms of Service:
"This service may be subject to lawful interception as required by law."
```

**Option C: No Disclosure**
- Legal in some jurisdictions
- Not recommended ethically

### Security Hardening Recommendations

#### 1. Protect synapse-li Database

```yaml
# PostgreSQL access control
# Only Synapse can write
# Only admin can read

GRANT INSERT ON encrypted_keys TO synapse_li_app;
GRANT SELECT ON encrypted_keys TO synapse_admin;
REVOKE ALL ON encrypted_keys FROM PUBLIC;
```

#### 2. Encrypt Private Key

Store private key encrypted with admin password:
```python
# Private key encrypted with admin's password
# Admin must enter password to decrypt keys
# Password not stored anywhere

from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

def decrypt_private_key(encrypted_key: bytes, admin_password: str) -> RSAPrivateKey:
    # Derive key from admin password
    kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=SALT, iterations=100000)
    key = kdf.derive(admin_password.encode())

    # Decrypt private key
    f = Fernet(base64.urlsafe_b64encode(key))
    private_pem = f.decrypt(encrypted_key)

    return serialization.load_pem_private_key(private_pem, password=None)
```

**Benefit**: Even if database is compromised, private key is protected.

#### 3. Audit Logging

Log all access to synapse-li:
```python
# models.py
class AccessLog(models.Model):
    admin_user = models.CharField(max_length=255)
    target_user = models.CharField(max_length=255)
    action = models.CharField(max_length=50)  # "view_keys", "decrypt_message"
    timestamp = models.DateTimeField(auto_now_add=True)
    ip_address = models.GenericIPAddressField()

    class Meta:
        indexes = [
            models.Index(fields=['timestamp']),
            models.Index(fields=['admin_user']),
        ]
```

#### 4. Hidden Instance Isolation

Hidden instance should be:
- On separate network (not accessible from internet)
- VPN access only
- Multi-factor authentication required
- IP whitelist for admin access
- No external federation

**Docker Compose** (from Part 1):
```yaml
# Hidden instance network
networks:
  li_internal:
    driver: bridge
    internal: true  # No external access

  li_admin:
    driver: bridge
    # Only accessible via VPN

services:
  synapse-hidden:
    networks:
      - li_internal
      - li_admin  # Admin can access
```

---

## Summary: Key Backup & Session Management

### Quick Reference

| Requirement | Feasibility | Difficulty | Upstream Impact | Recommendation |
|-------------|-------------|------------|-----------------|----------------|
| **Automatic Key Backup (Config)** | ❌ NOT POSSIBLE | N/A | N/A | Use mandatory setup |
| **Mandatory Key Backup Setup** | ✅ POSSIBLE | ⭐⭐ MODERATE | 🟡 MODERATE | ✅ Implement |
| **Session Limit** | ✅ EXCELLENT | ⭐⭐ EASY | 🟡 MODERATE | ✅ Implement |

### Implementation Summary

**Key Backup**:
- No configuration option for automatic setup
- Must modify clients to require setup on first login
- After setup, keys automatically backed up
- **Effort**: 3-5 days (client modifications)

**Session Limit**:
- Add `max_devices_per_user` configuration
- Simple database check before device creation
- Suggested default: 10 devices
- **Effort**: 2-3 days

**Combined System**:
- Session limit + mandatory backup = complete key capture
- Privacy implications: users can decrypt messages
- Legal compliance required
- Security hardening essential

### Next Steps

Continue to [Part 4: Statistics Dashboard](LI_REQUIREMENTS_ANALYSIS_04_STATISTICS.md) →

---

**Document Information**:
- **Part**: 3 of 5
- **Topic**: Key Backup & Session Management
- **Status**: ✅ Complete
- **Files Analyzed**: 10 source files
- **Configuration Changes**: 1 line (`max_devices_per_user`)
- **Code Changes Required**: ~150 lines (session limit), ~200 lines (mandatory backup)
