# Lawful Interception (LI) Requirements - Feasibility Analysis
## Part 1: Overview and Architecture

**Document Version:** 1.0
**Analysis Date:** November 13, 2024
**Analyzed By:** Comprehensive code review of Synapse, Element Web, Element X Android, Synapse Admin
**Project Branch:** main

---

## Executive Summary

This document series provides a comprehensive feasibility analysis of implementing Lawful Interception (LI) capabilities for your Matrix/Synapse deployment. The analysis is broken into 5 parts:

1. **Overview & Architecture** (this document)
2. **Soft Delete & Message Preservation**
3. **Key Backup & Session Management**
4. **Statistics Dashboard**
5. **Summary & Implementation Roadmap**

### Overall Feasibility Assessment

| Requirement | Feasibility | Complexity | Risk Level |
|-------------|-------------|------------|------------|
| synapse-li Django project | ✅ Feasible | Medium | Low |
| Hidden instance deployment | ✅ Feasible | Low | Low |
| Soft delete (never delete from DB) | ✅ Feasible | Medium | Medium |
| Show deleted messages in hidden instance | ⚠️ Partially feasible | High | High |
| Automatic key backup config | ⚠️ Limited | Low | Low |
| Session limits per user | ✅ Feasible | Low-Medium | Low |
| Statistics dashboard | ✅ Feasible | Medium-High | Low |
| Antivirus stats integration | ✅ Feasible | Medium | Low |

**Legend:**
- ✅ Feasible - Can be implemented as requested
- ⚠️ Partially feasible - Possible with modifications/limitations
- ❌ Not feasible - Cannot be implemented or high risk

---

## Document Structure

### Part 1: Overview & Architecture (this file)
- System overview
- Core architecture
- synapse-li implementation
- Client modifications required

### Part 2: Soft Delete & Message Preservation
- Synapse's current deletion mechanism
- Implementing true soft delete
- Database schema changes
- Upstream compatibility

### Part 3: Key Backup & Session Management
- Element Web/Android key backup analysis
- Session limit implementation
- Client configuration options

### Part 4: Statistics Dashboard
- Synapse-admin integration
- Available statistics
- Database queries
- Antivirus integration

### Part 5: Summary & Recommendations
- Implementation priorities
- Risk assessment
- Timeline estimates
- Alternative approaches

---

## Part 1A: System Architecture Overview

### Current Understanding

Your requirements involve creating a dual-instance deployment:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MAIN PRODUCTION INSTANCE                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐      │
│  │   Synapse    │──────│  PostgreSQL  │──────│    MinIO     │      │
│  │   + Workers  │      │   Cluster    │      │   (Media)    │      │
│  └──────────────┘      └──────────────┘      └──────────────┘      │
│         │                                                             │
│         │ (authenticated request)                                    │
│         ▼                                                             │
│  ┌──────────────┐                                                    │
│  │ synapse-li   │◄────── Stores encrypted passphrases/recovery keys │
│  │  (Django)    │                                                    │
│  └──────────────┘                                                    │
│         ▲                                                             │
│         │                                                             │
│  ┌──────────────┐                                                    │
│  │   Clients    │                                                    │
│  │ - Element Web│──── Send passphrase/recovery key on set/reset     │
│  │ - Element X  │                                                    │
│  └──────────────┘                                                    │
│                                                                       │
│  Daily Backup ────────┐                                              │
└───────────────────────┼──────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    HIDDEN LI INSTANCE (Single Server)                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐      │
│  │   Synapse    │──────│  PostgreSQL  │──────│    MinIO     │      │
│  │   (single)   │      │   (single)   │      │   (Media)    │      │
│  └──────────────┘      └──────────────┘      └──────────────┘      │
│         │                      ▲                      ▲              │
│         │                      │                      │              │
│  ┌──────────────┐      Synced Daily           Synced Daily          │
│  │ Element Web  │      from main               from main            │
│  └──────────────┘      instance                instance              │
│         │                                                             │
│  ┌──────────────┐                                                    │
│  │Synapse Admin │                                                    │
│  └──────────────┘                                                    │
│         │                                                             │
│  ┌──────────────┐                                                    │
│  │ synapse-li   │──── Admin retrieves passphrases to decrypt keys   │
│  │  (Django)    │                                                    │
│  └──────────────┘                                                    │
│         │                                                             │
│         ▼                                                             │
│  Admin User: Impersonates any user to view encrypted messages       │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Part 1B: synapse-li Django Project - Architecture

### Overview

The synapse-li project is a Django REST Framework (DRF) application that securely stores user encryption passphrases and recovery keys for lawful interception purposes.

### Current State

**Location:** `/home/user/Messenger/synapse_li/`

**Structure:**
```
synapse_li/
├── manage.py
├── requirements.txt
├── .env.example
├── synapse_li/          # Django project
│   ├── settings.py
│   ├── urls.py
│   ├── wsgi.py
│   └── asgi.py
└── secret/              # Django app (currently empty)
    ├── models.py        # EMPTY - needs implementation
    ├── views.py         # EMPTY - needs implementation
    ├── admin.py
    ├── apps.py
    └── migrations/
```

### Required Implementation

#### 1. Database Models

**File:** `synapse_li/secret/models.py`

```python
from django.db import models
from django.utils import timezone
from cryptography.fernet import Fernet
import hashlib

class User(models.Model):
    """Matrix user identified by username (localpart@domain)"""
    username = models.CharField(max_length=255, unique=True, db_index=True)
    # Store full Matrix ID: @alice:example.com
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'li_users'
        indexes = [
            models.Index(fields=['username']),
        ]

    def __str__(self):
        return self.username


class EncryptedKey(models.Model):
    """Stores encrypted passphrases/recovery keys with full history"""

    KEY_TYPE_CHOICES = [
        ('passphrase', 'Passphrase'),
        ('recovery_key', 'Recovery Key'),
    ]

    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='keys')
    key_type = models.CharField(max_length=20, choices=KEY_TYPE_CHOICES)

    # Encrypted payload (client encrypts with server public key)
    encrypted_payload = models.TextField()

    # Hash of payload for deduplication
    payload_hash = models.CharField(max_length=64, db_index=True)

    # Metadata
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    client_ip = models.GenericIPAddressField(null=True, blank=True)
    user_agent = models.TextField(null=True, blank=True)

    # Matrix session info (from Synapse authentication)
    matrix_device_id = models.CharField(max_length=255, null=True, blank=True)
    matrix_access_token_id = models.BigIntegerField(null=True, blank=True)

    class Meta:
        db_table = 'li_encrypted_keys'
        ordering = ['-created_at']  # Latest first
        indexes = [
            models.Index(fields=['user', '-created_at']),
            models.Index(fields=['payload_hash']),
            models.Index(fields=['created_at']),
        ]

    def __str__(self):
        return f"{self.user.username} - {self.key_type} - {self.created_at}"

    @staticmethod
    def hash_payload(payload: str) -> str:
        """Generate SHA-256 hash of payload for deduplication"""
        return hashlib.sha256(payload.encode('utf-8')).hexdigest()
```

**Key Design Decisions:**

1. ✅ **Separate User model** - Clean separation, easy to filter by username
2. ✅ **Full history** - Never delete old keys (requirement #6)
3. ✅ **Deduplication via hash** - Prevent duplicate storage (requirement #5)
4. ✅ **Encrypted storage** - Payload encrypted by client before sending
5. ✅ **Metadata tracking** - IP, user agent, device for audit trail
6. ✅ **Indexed queries** - Fast retrieval by user and date

#### 2. API Endpoints

**File:** `synapse_li/secret/views.py`

```python
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from django.db import transaction
from .models import User, EncryptedKey
import logging

logger = logging.getLogger(__name__)


class StoreKeyView(APIView):
    """
    Store encrypted passphrase or recovery key

    Endpoint: POST /api/v1/store-key/

    Expected request from Synapse (after authentication):
    {
        "username": "@alice:example.com",
        "device_id": "ABCDEFGHIJ",
        "access_token_id": 12345,
        "encrypted_payload": "base64-encoded-encrypted-data",
        "key_type": "passphrase" | "recovery_key",
        "client_ip": "192.168.1.100",
        "user_agent": "Element/1.11.50"
    }
    """

    def post(self, request):
        # Extract data
        username = request.data.get('username')
        encrypted_payload = request.data.get('encrypted_payload')
        key_type = request.data.get('key_type')
        device_id = request.data.get('device_id')
        access_token_id = request.data.get('access_token_id')
        client_ip = request.data.get('client_ip')
        user_agent = request.data.get('user_agent')

        # Validation
        if not all([username, encrypted_payload, key_type]):
            return Response(
                {'error': 'Missing required fields'},
                status=status.HTTP_400_BAD_REQUEST
            )

        if key_type not in ['passphrase', 'recovery_key']:
            return Response(
                {'error': 'Invalid key_type'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # Calculate hash for deduplication
        payload_hash = EncryptedKey.hash_payload(encrypted_payload)

        try:
            with transaction.atomic():
                # Get or create user
                user, created = User.objects.get_or_create(
                    username=username
                )

                # Check if this exact payload already exists (latest only)
                latest_key = user.keys.filter(key_type=key_type).first()
                if latest_key and latest_key.payload_hash == payload_hash:
                    logger.info(f"Duplicate key for {username}, skipping")
                    return Response(
                        {'status': 'duplicate', 'message': 'Key already stored'},
                        status=status.HTTP_200_OK
                    )

                # Store new key
                key = EncryptedKey.objects.create(
                    user=user,
                    key_type=key_type,
                    encrypted_payload=encrypted_payload,
                    payload_hash=payload_hash,
                    matrix_device_id=device_id,
                    matrix_access_token_id=access_token_id,
                    client_ip=client_ip,
                    user_agent=user_agent
                )

                logger.info(f"Stored {key_type} for {username} (ID: {key.id})")

                return Response(
                    {
                        'status': 'success',
                        'message': 'Key stored successfully',
                        'key_id': key.id
                    },
                    status=status.HTTP_201_CREATED
                )

        except Exception as e:
            logger.error(f"Error storing key: {e}")
            return Response(
                {'error': 'Internal server error'},
                status=status.HTTP_500_INTERNAL_SERVER_ERROR
            )
```

**URL Configuration:**

```python
# synapse_li/secret/urls.py
from django.urls import path
from .views import StoreKeyView

urlpatterns = [
    path('store-key/', StoreKeyView.as_view(), name='store_key'),
]

# synapse_li/synapse_li/urls.py
from django.contrib import admin
from django.urls import path, include

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/v1/', include('secret.urls')),
]
```

#### 3. Admin Interface

**File:** `synapse_li/secret/admin.py`

```python
from django.contrib import admin
from .models import User, EncryptedKey


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = ['username', 'created_at', 'key_count']
    search_fields = ['username']
    readonly_fields = ['created_at', 'updated_at']

    def key_count(self, obj):
        return obj.keys.count()
    key_count.short_description = 'Total Keys'


@admin.register(EncryptedKey)
class EncryptedKeyAdmin(admin.ModelAdmin):
    list_display = [
        'user', 'key_type', 'created_at',
        'matrix_device_id', 'client_ip'
    ]
    list_filter = ['key_type', 'created_at']
    search_fields = ['user__username', 'matrix_device_id']
    readonly_fields = [
        'user', 'key_type', 'encrypted_payload', 'payload_hash',
        'created_at', 'client_ip', 'user_agent',
        'matrix_device_id', 'matrix_access_token_id'
    ]

    # Never allow deletion
    def has_delete_permission(self, request, obj=None):
        return False

    # Never allow editing
    def has_change_permission(self, request, obj=None):
        return False

    # Only allow viewing
    def has_add_permission(self, request):
        return False
```

**Admin can:**
- ✅ Search by username
- ✅ Filter by key type and date
- ✅ View all key history
- ✅ Copy encrypted payload to decrypt with private key
- ❌ Cannot delete or modify (immutable audit trail)

---

## Part 1C: Encryption Strategy (Your Requirement #2)

### Current Proposal Analysis

**Your suggested approach:**
> "We can have a pub/private key pair for the server. Encrypt the payload using the pubkey and in the synapse-li, store it encrypted in the db."

### Assessment: ✅ **GOOD APPROACH** with minor enhancement needed

**Strengths:**
1. ✅ Payload never transmitted in plain text
2. ✅ Database compromise doesn't expose passphrases
3. ✅ Only admin with private key can decrypt

**Challenges:**
1. ⚠️ Private key storage - where to keep it securely?
2. ⚠️ Key rotation - how to handle when private key needs rotation?
3. ⚠️ Client complexity - all clients need to encrypt before sending

### Recommended Implementation

**Use Hybrid Encryption (RSA + AES):**

```
Client Side:
1. Generate random AES-256 key
2. Encrypt passphrase with AES key
3. Encrypt AES key with server's RSA public key
4. Send: {encrypted_aes_key + encrypted_passphrase}

Server Side:
1. Store encrypted bundle in database (never decrypt)
2. Admin retrieves bundle
3. Admin uses private key to decrypt AES key
4. Admin uses AES key to decrypt passphrase
```

**Benefits:**
- ✅ Can encrypt large passphrases (RSA limited to small data)
- ✅ Better performance
- ✅ Standard approach (similar to TLS)

### Private Key Storage Options

**Option 1: Hardware Security Module (HSM)** - ⭐ RECOMMENDED
- Store private key in HSM
- Admin must authenticate to HSM to decrypt
- Keys never leave HSM
- **Cost:** $500-$5000 (e.g., YubiHSM, AWS CloudHSM)

**Option 2: Encrypted File + Passphrase**
- Private key stored as encrypted PEM file
- Admin enters passphrase to unlock
- Passphrase stored in admin's password manager
- **Cost:** Free

**Option 3: Split Key (Shamir's Secret Sharing)**
- Private key split into 3 parts
- Require any 2 parts to reconstruct
- Different admins hold different parts
- **Cost:** Free (software-based)

**Recommendation:** Start with **Option 2** (encrypted file), upgrade to **Option 1** (HSM) for high-security environments.

### Public Key Distribution

**Method 1: Hardcode in Client Config** (Element Web/Android)
```javascript
// Element Web config.json
{
  "li_public_key": "-----BEGIN PUBLIC KEY-----\nMIIB..."
}
```

**Method 2: Server Endpoint**
```
GET https://synapse.example.com/_synapse_li/public_key
Response: {"public_key": "-----BEGIN PUBLIC KEY-----..."}
```

**Recommendation:** **Method 2** - allows key rotation without client updates

---

## Part 1D: Request Authentication (Your Requirement #3)

### Challenge

> "We need to authenticate the request that is received in the synapse-li to make sure the real user with real session sends that request"

### Your Proposed Solution

> "Client calls the synapse instead of the synapse-li. Synapse has a middleware to authenticate the user and the request, so if that middleware passed, it shows the user and the request is valid. Then in the synapse, we can redirect the request to the synapse-li."

### Assessment: ✅ **EXCELLENT APPROACH**

This is the **correct and secure** way to handle authentication.

### How Synapse Authentication Works

Based on code analysis of `/home/user/Messenger/synapse/synapse/api/auth/`:

**Authentication Flow:**
```python
# 1. Client sends request to Synapse
GET /_matrix/client/r3/some_endpoint
Authorization: Bearer syt_1234567890abcdef

# 2. Synapse REST servlet calls:
requester = await self.auth.get_user_by_req(request)

# 3. Returns Requester object with:
requester.user              # UserID(@alice:example.com)
requester.device_id         # Device ID
requester.access_token_id   # Token ID in database
requester.authenticated_entity  # Who authenticated
```

### Recommended Implementation in Synapse

**Create Custom Endpoint in Synapse:**

**File:** `synapse/synapse/rest/client/li_proxy.py` (NEW FILE)

```python
"""Lawful Interception - Proxy endpoint to synapse-li"""

import logging
from typing import Tuple
from twisted.web.server import Request
from synapse.http.servlet import RestServlet, parse_json_object_from_request
from synapse.http.site import SynapseRequest
from synapse.api.errors import Codes, SynapseError
from synapse.types import JsonDict
import aiohttp

logger = logging.getLogger(__name__)


class LIProxyServlet(RestServlet):
    """
    Proxies key storage requests to synapse-li after authentication.

    Endpoint: POST /_synapse/client/v1/li/store_key

    Client sends:
    {
        "encrypted_payload": "...",
        "key_type": "passphrase" | "recovery_key"
    }

    Synapse validates authentication, then forwards to synapse-li with:
    {
        "username": "@alice:example.com",
        "device_id": "ABCDEFG",
        "access_token_id": 12345,
        "encrypted_payload": "...",
        "key_type": "...",
        "client_ip": "192.168.1.100",
        "user_agent": "Element/1.11.50"
    }
    """

    PATTERNS = [
        "^/_synapse/client/v1/li/store_key$"
    ]

    def __init__(self, hs):
        super().__init__()
        self.auth = hs.get_auth()
        self.config = hs.config
        self.synapse_li_url = self.config.li.synapse_li_url

    async def on_POST(self, request: SynapseRequest) -> Tuple[int, JsonDict]:
        # Authenticate the request
        requester = await self.auth.get_user_by_req(request)

        # Parse request body
        body = parse_json_object_from_request(request)

        # Validate required fields
        encrypted_payload = body.get("encrypted_payload")
        key_type = body.get("key_type")

        if not encrypted_payload or not key_type:
            raise SynapseError(
                400,
                "Missing encrypted_payload or key_type",
                Codes.MISSING_PARAM
            )

        if key_type not in ["passphrase", "recovery_key"]:
            raise SynapseError(
                400,
                "Invalid key_type",
                Codes.INVALID_PARAM
            )

        # Build payload for synapse-li
        li_payload = {
            "username": requester.user.to_string(),  # @alice:example.com
            "device_id": requester.device_id,
            "access_token_id": requester.access_token_id,
            "encrypted_payload": encrypted_payload,
            "key_type": key_type,
            "client_ip": request.getClientAddress().host,
            "user_agent": request.getHeader("User-Agent"),
        }

        # Forward to synapse-li
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.synapse_li_url}/api/v1/store-key/",
                    json=li_payload,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as response:
                    response_data = await response.json()

                    if response.status in [200, 201]:
                        logger.info(
                            f"Stored key for {requester.user} "
                            f"(type: {key_type})"
                        )
                        return 200, {"status": "success"}
                    else:
                        logger.error(
                            f"synapse-li returned {response.status}: "
                            f"{response_data}"
                        )
                        raise SynapseError(
                            500,
                            "Failed to store key",
                            Codes.UNKNOWN
                        )

        except Exception as e:
            logger.error(f"Error forwarding to synapse-li: {e}")
            raise SynapseError(
                500,
                "Failed to contact LI service",
                Codes.UNKNOWN
            )


def register_servlets(hs, http_server):
    LIProxyServlet(hs).register(http_server)
```

**Configuration:**

**File:** `synapse/synapse/config/li.py` (NEW FILE)

```python
from synapse.config._base import Config
from typing import Any


class LIConfig(Config):
    """Configuration for Lawful Interception"""

    section = "li"

    def read_config(self, config: dict, **kwargs: Any) -> None:
        li_config = config.get("li") or {}

        self.enabled = li_config.get("enabled", False)
        self.synapse_li_url = li_config.get(
            "synapse_li_url",
            "http://localhost:8001"
        )
```

**Homeserver Config:**

```yaml
# homeserver.yaml
li:
  enabled: true
  synapse_li_url: "http://synapse-li:8000"  # Internal network
```

**Register the servlet:**

**File:** `synapse/synapse/rest/client/__init__.py`

```python
# Add to imports:
from synapse.rest.client import li_proxy

# Add to register_servlets():
if hs.config.li.enabled:
    li_proxy.register_servlets(hs, client_resource)
```

### Security Benefits

1. ✅ **No custom authentication** - Uses Synapse's battle-tested auth
2. ✅ **Username verified** - Comes from authenticated session, not client claim
3. ✅ **Device tracking** - Full audit trail of which device sent key
4. ✅ **Internal network** - synapse-li never exposed to internet
5. ✅ **Rate limiting** - Inherits Synapse's rate limits
6. ✅ **Access control** - Can restrict by user type (no guests)

### Alternative: AppService Approach

If you don't want to modify Synapse:

1. Create an AppService (easier to maintain)
2. Register with Synapse
3. AppService receives authenticated events
4. Forward to synapse-li

**Trade-off:** Less control over endpoint, but no Synapse code changes.

---

## Part 1E: Client Modifications Required

### Overview

To send passphrases/recovery keys to synapse-li, you must modify:
1. ✅ Element Web
2. ✅ Element X Android
3. (Other clients if used)

### Element Web Changes

**Location:** `/home/user/Messenger/element-web/`

**What needs modification:**

1. **Key Setup/Reset Detection**
   - File: `src/stores/SetupEncryptionStore.ts`
   - File: `src/components/views/dialogs/security/CreateSecretStorageDialog.tsx`
   - When user sets up recovery key or passphrase

2. **Hook into Key Creation**

```typescript
// src/stores/SetupEncryptionStore.ts
// After recovery key is created:

private async sendKeyToLI(
    keyType: 'passphrase' | 'recovery_key',
    keyValue: string
): Promise<void> {
    try {
        // Fetch server public key
        const publicKey = await this.fetchLIPublicKey();

        // Encrypt payload
        const encryptedPayload = await this.encryptForLI(
            publicKey,
            keyValue
        );

        // Send to Synapse LI endpoint
        await this.matrixClient.http.authedRequest(
            Method.Post,
            '/_synapse/client/v1/li/store_key',
            undefined, // query params
            {
                encrypted_payload: encryptedPayload,
                key_type: keyType
            }
        );

        logger.info("Key sent to LI service");
    } catch (e) {
        // Silent fail - don't block user's key setup
        logger.error("Failed to send key to LI:", e);
    }
}

// Encryption helper
private async encryptForLI(
    publicKeyPem: string,
    data: string
): Promise<string> {
    // Import public key
    const publicKey = await window.crypto.subtle.importKey(
        'spki',
        this.pemToArrayBuffer(publicKeyPem),
        {
            name: 'RSA-OAEP',
            hash: 'SHA-256'
        },
        false,
        ['encrypt']
    );

    // Generate random AES key
    const aesKey = await window.crypto.subtle.generateKey(
        { name: 'AES-GCM', length: 256 },
        true,
        ['encrypt']
    );

    // Encrypt data with AES
    const iv = window.crypto.getRandomValues(new Uint8Array(12));
    const encryptedData = await window.crypto.subtle.encrypt(
        { name: 'AES-GCM', iv },
        aesKey,
        new TextEncoder().encode(data)
    );

    // Export AES key
    const exportedAesKey = await window.crypto.subtle.exportKey(
        'raw',
        aesKey
    );

    // Encrypt AES key with RSA public key
    const encryptedAesKey = await window.crypto.subtle.encrypt(
        { name: 'RSA-OAEP' },
        publicKey,
        exportedAesKey
    );

    // Combine: encryptedAesKey + iv + encryptedData
    const combined = new Uint8Array([
        ...new Uint8Array(encryptedAesKey),
        ...iv,
        ...new Uint8Array(encryptedData)
    ]);

    return this.base64Encode(combined);
}
```

3. **Retry Logic (Your Requirement #5)**

```typescript
private async sendKeyToLIWithRetry(
    keyType: 'passphrase' | 'recovery_key',
    keyValue: string,
    maxRetries: number = 3
): Promise<void> {
    for (let attempt = 1; attempt <= maxRetries; attempt++) {
        try {
            await this.sendKeyToLI(keyType, keyValue);
            return; // Success
        } catch (e) {
            if (attempt === maxRetries) {
                logger.error(`Failed to send key after ${maxRetries} attempts`);
            } else {
                logger.warn(`Attempt ${attempt} failed, retrying...`);
                await new Promise(resolve =>
                    setTimeout(resolve, 1000 * attempt)
                );
            }
        }
    }
}
```

**Trigger Points:**

| User Action | File | Function |
|-------------|------|----------|
| Set up recovery key | `CreateSecretStorageDialog.tsx` | After `onFinished()` |
| Reset recovery key | `SetupEncryptionStore.ts` | After `resetSecretStorage()` |
| Change passphrase | `CreateSecretStorageDialog.tsx` | After passphrase set |

### Element X Android Changes

**Location:** `/home/user/Messenger/element-x-android/`

**What needs modification:**

1. **Key Setup Detection**
   - File: `features/securebackup/impl/src/main/kotlin/io/element/android/features/securebackup/impl/setup/SecureBackupSetupPresenter.kt`
   - When `createRecovery()` succeeds

2. **Kotlin Implementation**

```kotlin
// features/securebackup/impl/src/main/kotlin/io/element/android/features/securebackup/impl/LIKeyUploader.kt

class LIKeyUploader(
    private val client: MatrixClient,
    private val context: Context
) {
    suspend fun uploadKey(
        keyType: String, // "passphrase" or "recovery_key"
        keyValue: String,
        maxRetries: Int = 3
    ): Result<Unit> {
        return withContext(Dispatchers.IO) {
            repeat(maxRetries) { attempt ->
                try {
                    // Fetch public key
                    val publicKey = fetchPublicKey()

                    // Encrypt payload
                    val encryptedPayload = encryptPayload(
                        publicKey,
                        keyValue
                    )

                    // Send to Synapse
                    client.sendToLI(encryptedPayload, keyType)

                    Timber.i("Key uploaded to LI service")
                    return@withContext Result.success(Unit)

                } catch (e: Exception) {
                    Timber.w(e, "Upload attempt ${attempt + 1} failed")
                    if (attempt == maxRetries - 1) {
                        return@withContext Result.failure(e)
                    }
                    delay(1000L * (attempt + 1))
                }
            }
            Result.failure(Exception("Upload failed"))
        }
    }

    private suspend fun fetchPublicKey(): PublicKey {
        // Fetch from /_synapse_li/public_key
        // Parse PEM, return PublicKey
    }

    private fun encryptPayload(
        publicKey: PublicKey,
        data: String
    ): String {
        // 1. Generate AES-256 key
        val aesKey = KeyGenerator.getInstance("AES").apply {
            init(256)
        }.generateKey()

        // 2. Encrypt data with AES
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, aesKey)
        val iv = cipher.iv
        val encryptedData = cipher.doFinal(data.toByteArray())

        // 3. Encrypt AES key with RSA
        val rsaCipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        rsaCipher.init(Cipher.ENCRYPT_MODE, publicKey)
        val encryptedAesKey = rsaCipher.doFinal(aesKey.encoded)

        // 4. Combine and encode
        val combined = encryptedAesKey + iv + encryptedData
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }
}

// Extension for MatrixClient
suspend fun MatrixClient.sendToLI(
    encryptedPayload: String,
    keyType: String
) {
    val body = buildJsonObject {
        put("encrypted_payload", encryptedPayload)
        put("key_type", keyType)
    }

    restClient.post(
        path = "/_synapse/client/v1/li/store_key",
        body = body
    )
}
```

3. **Integration Point**

```kotlin
// In SecureBackupSetupPresenter.kt

private suspend fun createRecovery(): Result<RecoveryKey> {
    // ... existing code ...

    val result = encryptionService.enableRecovery(...)

    result.onSuccess { recoveryKey ->
        // NEW: Upload to LI
        liKeyUploader.uploadKey(
            keyType = "recovery_key",
            keyValue = recoveryKey.value
        )
    }

    return result
}
```

---

## Part 1F: Deployment Architecture - Hidden Instance

### Single Server Deployment

The hidden LI instance can run on a **single server** as you suggested:

**Server Specifications:**

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 8 cores | 16 cores |
| RAM | 16 GB | 32 GB |
| Storage | 500 GB SSD | 1 TB NVMe SSD |
| Network | 1 Gbps | 10 Gbps (if frequent sync) |

**Docker Compose Setup:**

```yaml
# docker-compose.yml for LI Hidden Instance
version: '3.8'

services:
  postgres:
    image: postgres:15
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: synapse
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD: ${DB_PASSWORD}

  redis:
    image: redis:7-alpine
    command: redis-server --save 60 1 --loglevel warning

  synapse:
    image: matrixdotorg/synapse:latest
    volumes:
      - synapse_data:/data
    environment:
      SYNAPSE_SERVER_NAME: li.internal.example.com
      SYNAPSE_REPORT_STATS: "no"
    depends_on:
      - postgres
      - redis

  element-web:
    image: vectorim/element-web:latest
    volumes:
      - ./element-config.json:/app/config.json
    ports:
      - "8080:80"

  synapse-admin:
    image: awesometechnologies/synapse-admin:latest
    ports:
      - "8081:80"

  synapse-li:
    build: ./synapse_li
    environment:
      DATABASE_URL: postgresql://li:${LI_DB_PASSWORD}@postgres-li:5432/synapse_li
      DJANGO_SECRET_KEY: ${LI_SECRET_KEY}
    depends_on:
      - postgres-li
    ports:
      - "8000:8000"

  postgres-li:
    image: postgres:15
    volumes:
      - postgres_li_data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: synapse_li
      POSTGRES_USER: li
      POSTGRES_PASSWORD: ${LI_DB_PASSWORD}

  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    volumes:
      - minio_data:/data
    environment:
      MINIO_ROOT_USER: ${MINIO_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_PASSWORD}

volumes:
  postgres_data:
  postgres_li_data:
  synapse_data:
  minio_data:
```

### Sync Strategy: Main → Hidden Instance

**Your Question:**
> "Maybe a more straight-forward and more clean way is to sync the hidden instance data with the main instance whenever we want, without touching or working with the backup data."

**Assessment:** ✅ **CORRECT - This is the better approach**

**Recommended: PostgreSQL Logical Replication**

```sql
-- On MAIN instance PostgreSQL:

-- 1. Enable logical replication
ALTER SYSTEM SET wal_level = logical;
-- Restart PostgreSQL

-- 2. Create publication (publish all tables)
CREATE PUBLICATION synapse_pub FOR ALL TABLES;

-- 3. Create replication user
CREATE USER replicator WITH REPLICATION PASSWORD 'secure_password';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;


-- On HIDDEN instance PostgreSQL:

-- 1. Create subscription
CREATE SUBSCRIPTION synapse_sub
    CONNECTION 'host=main-postgres.example.com port=5432 dbname=synapse user=replicator password=secure_password'
    PUBLICATION synapse_pub;

-- 2. Check sync status
SELECT * FROM pg_stat_subscription;
```

**Benefits:**
- ✅ Real-time or near-real-time sync
- ✅ No downtime on main instance
- ✅ Can pause/resume sync on demand
- ✅ Minimal overhead on main instance
- ✅ Automatic schema changes propagation

**Media (MinIO) Sync:**

```bash
#!/bin/bash
# sync-media.sh

# Run on hidden instance (pull from main)
mc mirror --watch \
    main-minio/synapse-media \
    local-minio/synapse-media
```

**Or use MinIO site replication:**

```bash
# One-time setup
mc admin replicate add \
    main-minio \
    hidden-minio \
    --replicate "existing-objects,delete-marker,delete,bucket,bucket-config"
```

### On-Demand Sync vs Continuous Sync

**Option 1: Continuous Sync** ⭐ RECOMMENDED
- Logical replication always running
- Hidden instance always up-to-date
- Admin can investigate immediately
- **Load:** Minimal (~5% overhead on main)

**Option 2: On-Demand Sync**
- Admin triggers sync when needed
- Use `pg_dump` + `pg_restore`
- **Time:** 30 minutes - 2 hours depending on size
- **Load:** High during sync (30-50% overhead)

**Recommendation:** Use **continuous sync** with ability to pause if needed:

```sql
-- Pause replication (on hidden instance)
ALTER SUBSCRIPTION synapse_sub DISABLE;

-- Resume replication
ALTER SUBSCRIPTION synapse_sub ENABLE;
```

---

## Summary - Part 1

### What We've Covered

1. ✅ **System Architecture** - Dual instance design validated
2. ✅ **synapse-li Django Project** - Complete model and API design
3. ✅ **Encryption Strategy** - Hybrid RSA + AES encryption
4. ✅ **Request Authentication** - Synapse proxy endpoint (secure)
5. ✅ **Client Modifications** - Element Web & Android implementation
6. ✅ **Hidden Instance Deployment** - Single server Docker Compose
7. ✅ **Sync Strategy** - PostgreSQL logical replication

### Key Findings

**Feasibility:** ✅ **Fully Feasible**

The synapse-li architecture is **sound and implementable**. All components follow best practices:
- Secure authentication via Synapse
- End-to-end encryption of passphrases
- Immutable audit trail
- Clean separation of concerns

**Complexity:** **Medium**

- synapse-li Django app: **2-3 days**
- Synapse proxy endpoint: **1 day**
- Element Web modifications: **2-3 days**
- Element X Android modifications: **2-3 days**
- Hidden instance setup: **1 day**

**Total estimate:** 8-12 days of development

**Risks:** **Low**

- Well-defined interfaces
- Uses standard technologies
- No architectural blockers

### Next Steps

Continue to **Part 2** for analysis of:
- Soft delete implementation
- Showing deleted messages in hidden instance

---

**End of Part 1**
