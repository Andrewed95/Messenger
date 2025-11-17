# Internal Knowledge Base - Matrix/Synapse Deployment Solution

> **INTERNAL REFERENCE ONLY** - Comprehensive technical knowledge for complete rebuild

## Table of Contents
1. [System Overview](#system-overview)
2. [Requirements Matrix](#requirements-matrix)
3. [Architecture Patterns](#architecture-patterns)
4. [Component Specifications](#component-specifications)
5. [LI System Details](#li-system-details)
6. [Scaling Guidelines](#scaling-guidelines)
7. [Configuration Standards](#configuration-standards)
8. [Security Considerations](#security-considerations)
9. [Integration Points](#integration-points)

---

## System Overview

### Core Objectives
- **Scale**: 100 to 20,000 concurrent users with elastic architecture
- **HA**: No single points of failure, automatic failover
- **LI**: Two-instance lawful intercept system (PRIMARY REQUIREMENT)
- **Antivirus**: ClamAV integration with async scanning (REQUIRED)
- **Air-gapped**: Works after initial deployment without internet
- **Platform**: OVH VMs running Debian + Kubernetes

### Deployment Model
- **Infrastructure**: Kubernetes (k3s or standard)
- **Database**: CloudNativePG with synchronous replication
- **Object Storage**: MinIO distributed mode (EC:4)
- **Caching**: Redis Sentinel for automatic failover
- **Ingress**: HAProxy with intelligent routing
- **Monitoring**: Prometheus + Grafana + Loki

---

## Requirements Matrix

### CCU to Resource Mapping

| CCU Range | Worker Config | PostgreSQL | Redis | MinIO | Notes |
|-----------|---------------|------------|-------|-------|-------|
| 100 | Basic (1x each type) | 1 primary + 1 replica | 3-node Sentinel | 4-node (min) | Single-node K8s OK |
| 1,000 | Moderate (2x hotpath) | 1 primary + 2 replicas | 3-node Sentinel | 4-node | Multi-node K8s |
| 5,000 | Scaled (4x hotpath) | 1 primary + 2 replicas | 3-node Sentinel | 6-node | PodDisruptionBudgets |
| 10,000 | Large (8x hotpath) | 1 primary + 2 replicas | 5-node Sentinel | 8-node | Dedicated nodes |
| 20,000 | Massive (16x hotpath) | 1 primary + 3 replicas | 5-node Sentinel | 12-node | Full HA topology |

### Hotpath Workers (scale these first)
- `event_persister` - Database writes
- `synchrotron` - Real-time sync
- `client_reader` - Read operations
- `federation_sender` - Outbound federation
- `media_repository` - Media handling

### Fixed Workers (1-2 instances typically)
- `event_creator` - Room event creation
- `pusher` - Push notifications
- `appservice` - Application service traffic
- `user_dir` - User directory updates
- `background_worker` - Cleanup tasks

---

## Architecture Patterns

### Two-Instance Model

```
┌─────────────────────────────────────────┐
│         MAIN PRODUCTION INSTANCE         │
│  ┌─────────────────────────────────────┐ │
│  │ Synapse Workers (22 types)          │ │
│  │ - HAProxy routing                   │ │
│  │ - Redis pub/sub replication         │ │
│  │ - MinIO for media                   │ │
│  │ - PostgreSQL primary                │ │
│  ├─────────────────────────────────────┤ │
│  │ Element Web (public)                │ │
│  │ Element Call (MatrixRTC)            │ │
│  │ LiveKit SFU                         │ │
│  │ coturn (TURN/STUN)                  │ │
│  ├─────────────────────────────────────┤ │
│  │ LI Components:                      │ │
│  │ - key_vault (network isolated)      │ │
│  │ - Synapse proxy endpoint            │ │
│  │ - Client LI key capture             │ │
│  └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
              ↓
    PostgreSQL Logical Replication
    rclone S3-to-S3 media sync
              ↓
┌─────────────────────────────────────────┐
│         HIDDEN LI INSTANCE               │
│  ┌─────────────────────────────────────┐ │
│  │ synapse-li (read-only replica)      │ │
│  │ - redaction_retention_period: null  │ │
│  │ - PostgreSQL replica                │ │
│  │ - MinIO replica                     │ │
│  ├─────────────────────────────────────┤ │
│  │ element-web-li                      │ │
│  │ - Shows deleted messages (red)      │ │
│  │ - Styled with CSS                   │ │
│  ├─────────────────────────────────────┤ │
│  │ synapse-admin-li                    │ │
│  │ - Sync button (triggers sync)       │ │
│  │ - Statistics dashboard              │ │
│  │ - Malicious files tab               │ │
│  │ - Decryption tab (RSA browser)      │ │
│  ├─────────────────────────────────────┤ │
│  │ Sync System (Celery)                │ │
│  │ - File-based checkpoints            │ │
│  │ - PostgreSQL LSN tracking           │ │
│  │ - rclone for media                  │ │
│  └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

### Network Isolation

```
┌──────────────────────────────────────────┐
│  Main Instance Network                    │
│  ┌────────────────────────────────────┐  │
│  │ key_vault (NetworkPolicy)          │  │
│  │ - ONLY accessible from Synapse     │  │
│  │ - NOT accessible from LI instance  │  │
│  └────────────────────────────────────┘  │
│                ↓                          │
│       Synapse Proxy Endpoint              │
│  /_synapse/client/v1/li/store_key        │
└──────────────────────────────────────────┘
```

---

## Component Specifications

### 1. PostgreSQL (CloudNativePG)

**Configuration:**
```yaml
instances: 3  # 1 primary + 2 replicas
primaryUpdateStrategy: unsupervised
storage:
  size: 500Gi  # Scale based on CCU
synchronousReplication:
  enabled: true
  method: any
  number: 1  # At least 1 sync replica
postgresql:
  parameters:
    max_connections: "500"
    shared_buffers: "4GB"
    effective_cache_size: "12GB"
    maintenance_work_mem: "1GB"
    checkpoint_completion_target: "0.9"
    wal_buffers: "16MB"
    default_statistics_target: "100"
    random_page_cost: "1.1"
    effective_io_concurrency: "200"
    work_mem: "10MB"
    min_wal_size: "1GB"
    max_wal_size: "4GB"
```

**Backup Strategy:**
- Point-in-time recovery (PITR)
- Daily base backups
- WAL archiving to MinIO
- Retention: 30 days

**For LI Instance:**
- Use PostgreSQL logical replication from main
- Read-only replica
- `redaction_retention_period: null` in Synapse config

---

### 2. Redis Sentinel

**Configuration:**
```yaml
replicas: 3  # Minimum for quorum
sentinel:
  enabled: true
  quorum: 2
  downAfterMilliseconds: 5000
  failoverTimeout: 10000
  parallelSyncs: 1
master:
  persistence:
    enabled: true
    rdb: true
    aof: true
replica:
  persistence:
    enabled: true
    rdb: true
    aof: true
```

**Uses:**
- Synapse worker HTTP replication
- LiveKit distributed state
- Session data for key_vault

---

### 3. MinIO

**Configuration:**
```yaml
mode: distributed
replicas: 4  # Minimum for EC:4
zones: 1
drivesPerNode: 1
erasureCodingScheme: "EC:4"  # 4 data + 4 parity
persistence:
  size: 2Ti  # Scale based on media usage
resources:
  requests:
    memory: 4Gi
    cpu: 2
```

**Buckets:**
- `synapse-media` - Main media storage
- `synapse-media-li` - LI instance media (synced via rclone)
- `postgresql-backups` - Database backups

**S3 Configuration for Synapse:**
```yaml
media_storage_providers:
- module: s3_storage_provider.S3StorageProviderBackend
  store_local: True
  store_remote: True
  store_synchronous: True
  config:
    bucket: synapse-media
    endpoint_url: http://minio:9000
    access_key_id: <from-secret>
    secret_access_key: <from-secret>
```

---

### 4. Synapse Workers (22 Types from ESS)

**Worker Types & Endpoints:**

1. **synchrotron** (scale 4x-16x)
   - Endpoints: `/sync`, `/events`, `/initialSync`
   - Purpose: Real-time client sync

2. **event_persister** (scale 2x-8x)
   - Handles: Event persistence to database
   - Purpose: Write performance

3. **client_reader** (scale 4x-16x)
   - Endpoints: `/publicRooms`, `/profile`, `/keys`
   - Purpose: Read operations

4. **federation_sender** (scale 2x-8x)
   - Handles: Outbound federation
   - Purpose: External server communication

5. **media_repository** (scale 2x-8x)
   - Endpoints: `/_matrix/media/`
   - Purpose: Media upload/download

6. **event_creator** (scale 1x-2x)
   - Endpoints: `/send`, `/state`
   - Purpose: Room event creation

7. **pusher** (scale 1x-2x)
   - Handles: Push notifications via Sygnal

8. **appservice** (scale 1x)
   - Handles: Application service traffic

9. **user_dir** (scale 1x)
   - Handles: User directory updates

10. **frontend_proxy** (scale 2x)
    - Handles: Client API routing

11. **federation_reader** (scale 2x-4x)
    - Endpoints: `/federation/v1/`

12. **federation_inbound** (scale 2x-4x)
    - Handles: Inbound federation

13. **room_worker** (scale 1x-2x)
    - Handles: Room state resolution

14. **presence** (scale 1x-2x)
    - Handles: User presence

15. **typing** (scale 1x)
    - Handles: Typing notifications

16. **to_device** (scale 1x-2x)
    - Handles: To-device messages

17. **account_data** (scale 1x)
    - Handles: Account data sync

18. **receipts** (scale 1x)
    - Handles: Read receipts

19. **background_worker** (scale 1x)
    - Handles: Cleanup, stats

20. **stream_writers.events** (scale 2x-4x)
    - Handles: Event stream writes

21. **stream_writers.typing** (scale 1x)
    - Handles: Typing stream

22. **stream_writers.presence** (scale 1x)
    - Handles: Presence stream

**HAProxy Routing Strategy:**
```
- Consistent hashing by room_id for room-specific operations
- Round-robin for general operations
- Token-based stickiness for sync endpoints
```

---

### 5. LiveKit SFU

**Configuration:**
```yaml
replicas: 3
mode: distributed
redis:
  enabled: true
  useExternalRedis: true
  address: redis-sentinel:26379
config:
  room:
    auto_create: false  # Controlled by lk-jwt-service
  rtc:
    port_range_start: 50000
    port_range_end: 60000
    use_external_ip: true
  turn:
    enabled: false  # Use dedicated coturn
```

**MatrixRTC Integration:**
- lk-jwt-service provides JWT tokens
- Full-access users (local) can create rooms
- Restricted users (remote) can join existing rooms
- Announced via `.well-known/matrix/client`

---

### 6. coturn (TURN/STUN)

**Deployment:**
```yaml
kind: DaemonSet  # One per node
hostNetwork: true  # Required for TURN
ports:
  - 3478/UDP  # STUN
  - 3478/TCP  # STUN over TCP
  - 5349/TCP  # TURNS
  - 49152-65535/UDP  # TURN relay range
```

**Configuration:**
```
listening-port=3478
tls-listening-port=5349
external-ip=<node-ip>
relay-ip=<node-ip>
min-port=49152
max-port=65535
user=<username>:<password>
realm=turn.example.com
lt-cred-mech
```

---

### 7. ClamAV Antivirus

**Architecture:**
```
┌────────────────────┐
│ ClamAV DaemonSet   │  ← One per node, shared socket
└────────────────────┘
          ↓
┌────────────────────┐
│ Scan Workers       │  ← Deployment, multiple replicas
│ (Python workers)   │     Consume from queue
└────────────────────┘
          ↓
┌────────────────────┐
│ Synapse Spam       │  ← synapse-http-antispam module
│ Checker Module     │     Forwards to scan workers
└────────────────────┘
```

**ClamAV DaemonSet:**
```yaml
kind: DaemonSet
volumes:
  - name: clamav-socket
    hostPath:
      path: /var/run/clamav
      type: DirectoryOrCreate
  - name: virus-db
    emptyDir:
      sizeLimit: 2Gi
```

**Scan Worker (Python):**
```python
# Async file scanning
async def scan_file(file_path):
    # Use clamd socket
    cd = clamd.ClamdUnixSocket("/var/run/clamav/clamd.sock")
    result = cd.scan(file_path)
    if result[file_path][0] == 'FOUND':
        # Quarantine via Synapse admin API
        await quarantine_media(file_path)
```

**Synapse Configuration:**
```yaml
modules:
  - module: synapse_http_antispam.HTTPAntispam
    config:
      base_url: http://antivirus-scanner:8080
      authorization: <bearer-token>
      enabled_callbacks:
        - check_media_file_for_spam
      async:
        check_media_file_for_spam: true
```

---

## LI System Details

### Key Capture Flow

```
┌──────────────────┐
│ Element Web/X    │
│ - User sets      │
│   recovery key   │
└──────────────────┘
        ↓
   Encrypt with
   RSA public key
   (2048-bit)
        ↓
┌──────────────────┐
│ POST to Synapse  │
│ /_synapse/client │
│ /v1/li/store_key │
└──────────────────┘
        ↓
┌──────────────────┐
│ Synapse Proxy    │
│ - Authenticates  │
│ - Forwards to    │
│   key_vault      │
└──────────────────┘
        ↓
┌──────────────────┐
│ key_vault API    │
│ - Deduplicates   │
│   (SHA256 hash)  │
│ - Stores in PG   │
└──────────────────┘
```

**LIKeyCapture.kt (Android):**
```kotlin
object LIKeyCapture {
    private const val MAX_RETRIES = 5
    private const val RETRY_DELAY_MS = 10_000L
    private const val REQUEST_TIMEOUT_SECONDS = 30L

    suspend fun captureKey(
        homeserverUrl: String,
        accessToken: String,
        userId: String,
        recoveryKey: String
    ) {
        val encryptedPayload = LIEncryption.encryptKey(recoveryKey)
        // POST with 5 retries, 10s delay
    }
}
```

**LIKeyCapture.ts (Element Web):**
```typescript
export async function captureKey(options: KeyCaptureOptions): Promise<void> {
    const encryptedPayload = encryptKey(options.recoveryKey);
    // 5 retry attempts, 10 second interval, 30 second timeout
    await retry(async () => {
        await axios.post(
            `${baseUrl}/_synapse/client/v1/li/store_key`,
            { username: userId, encrypted_payload: encryptedPayload },
            { headers: { Authorization: `Bearer ${accessToken}` } }
        );
    }, { retries: 5, delay: 10000, timeout: 30000 });
}
```

### Soft Delete Configuration

**synapse-li homeserver.yaml:**
```yaml
redaction_retention_period: null  # Never delete
```

**element-web-li CSS:**
```scss
.mx_EventTile_redacted {
    background-color: rgba(255, 0, 0, 0.08) !important;
    border-left: 3px solid rgba(255, 0, 0, 0.3);
    opacity: 0.85;

    .mx_EventTile_redactedBadge {
        display: inline-flex;
        color: #d32f2f;
    }
}
```

### Sync System

**Architecture:**
```
┌────────────────────────┐
│ synapse-admin-li       │
│ - Sync Button clicked  │
└────────────────────────┘
          ↓
┌────────────────────────┐
│ Celery Task Queue      │
│ - File-based locking   │
│   (fcntl)              │
└────────────────────────┘
          ↓
┌────────────────────────┐
│ PostgreSQL Sync        │
│ - Read LSN checkpoint  │
│ - Logical replication  │
│ - Update checkpoint    │
└────────────────────────┘
          ↓
┌────────────────────────┐
│ MinIO Sync (rclone)    │
│ - S3-to-S3 copy        │
│ - Incremental          │
└────────────────────────┘
```

**Sync Checkpoint File:**
```json
{
  "last_postgres_lsn": "0/1234567",
  "last_s3_sync_time": "2025-11-17T10:30:00Z",
  "sync_status": "completed",
  "last_error": null
}
```

### Statistics Dashboard

**Queries in synapse-admin:**

```sql
-- Daily messages
SELECT COUNT(*) FROM events
WHERE type = 'm.room.message'
AND origin_server_ts >= $start_timestamp;

-- Daily media (GB)
SELECT SUM(media_length) / 1024^3 FROM local_media_repository
WHERE created_ts >= $start_timestamp;

-- Top 10 rooms by messages
SELECT room_id, COUNT(*) as msg_count FROM events
WHERE type = 'm.room.message'
GROUP BY room_id
ORDER BY msg_count DESC
LIMIT 10;

-- Top 10 users by messages
SELECT sender, COUNT(*) as msg_count FROM events
WHERE type = 'm.room.message'
GROUP BY sender
ORDER BY msg_count DESC
LIMIT 10;
```

### Decryption Tab (Browser-based RSA)

```typescript
async function decryptKey(encryptedPayload: string, privateKey: string) {
    // Import private key
    const binaryKey = pemToArrayBuffer(privateKey);
    const cryptoKey = await window.crypto.subtle.importKey(
        'pkcs8',
        binaryKey,
        { name: 'RSA-OAEP', hash: 'SHA-256' },
        false,
        ['decrypt']
    );

    // Decrypt
    const encryptedData = base64ToArrayBuffer(encryptedPayload);
    const decryptedData = await window.crypto.subtle.decrypt(
        { name: 'RSA-OAEP' },
        cryptoKey,
        encryptedData
    );

    return arrayBufferToString(decryptedData);
}
```

---

## Scaling Guidelines

### Horizontal Scaling Priorities

**Phase 1 (100 → 1K CCU):**
1. Scale `synchrotron` to 2 replicas
2. Scale `event_persister` to 2 replicas
3. Scale `client_reader` to 2 replicas
4. Scale `media_repository` to 2 replicas
5. Add 2nd PostgreSQL replica

**Phase 2 (1K → 5K CCU):**
1. Scale `synchrotron` to 4 replicas
2. Scale `federation_sender` to 2 replicas
3. Scale `federation_reader` to 2 replicas
4. Scale LiveKit to 3 replicas
5. Increase MinIO to 6 nodes

**Phase 3 (5K → 10K CCU):**
1. Scale `synchrotron` to 8 replicas
2. Scale `event_persister` to 4 replicas
3. Scale `client_reader` to 8 replicas
4. Add dedicated node pools
5. Increase MinIO to 8 nodes

**Phase 4 (10K → 20K CCU):**
1. Scale `synchrotron` to 16 replicas
2. Scale `event_persister` to 8 replicas
3. Scale all federation workers to 4 replicas
4. Add 3rd PostgreSQL replica
5. Increase MinIO to 12 nodes
6. Use Redis 5-node cluster

### Resource Allocation per CCU Range

**100 CCU:**
- Total CPU: 8 cores
- Total RAM: 16 GB
- Storage: 500 GB

**1,000 CCU:**
- Total CPU: 16 cores
- Total RAM: 32 GB
- Storage: 1 TB

**5,000 CCU:**
- Total CPU: 32 cores
- Total RAM: 64 GB
- Storage: 2 TB

**10,000 CCU:**
- Total CPU: 64 cores
- Total RAM: 128 GB
- Storage: 4 TB

**20,000 CCU:**
- Total CPU: 128 cores
- Total RAM: 256 GB
- Storage: 8 TB

---

## Configuration Standards

### Centralized Configuration Directory

**Structure:**
```
deployment/config/
├── postgresql/
│   ├── main.yaml
│   └── li.yaml
├── redis/
│   └── sentinel.yaml
├── minio/
│   └── distributed.yaml
├── synapse/
│   ├── homeserver.yaml
│   ├── workers/
│   │   ├── synchrotron.yaml
│   │   ├── event-persister.yaml
│   │   └── ... (all 22 types)
│   └── log.yaml
├── synapse-li/
│   ├── homeserver.yaml
│   └── log.yaml
├── element-web/
│   └── config.json
├── element-web-li/
│   └── config.json
├── synapse-admin-li/
│   └── config.json
├── key_vault/
│   ├── settings.py
│   └── env.yaml
├── livekit/
│   └── config.yaml
├── lk-jwt-service/
│   └── config.yaml
├── coturn/
│   └── turnserver.conf
├── haproxy/
│   └── haproxy.cfg
├── antivirus/
│   ├── clamd.conf
│   └── scanner.yaml
├── monitoring/
│   ├── prometheus.yaml
│   ├── grafana.yaml
│   └── loki.yaml
└── sync/
    └── celery.yaml
```

### ConfigMap Pattern

**For each service:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <service>-config
  namespace: matrix
data:
  config.yaml: |
    <configuration>
```

**Mount in Deployment:**
```yaml
volumes:
  - name: config
    configMap:
      name: <service>-config
volumeMounts:
  - name: config
    mountPath: /config
    readOnly: true
```

---

## Security Considerations

### Network Policies

**key_vault Isolation:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: key-vault-isolation
spec:
  podSelector:
    matchLabels:
      app: key-vault
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: synapse  # Only Synapse can access
      ports:
        - protocol: TCP
          port: 8000
```

**LI Instance Isolation:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: li-instance-isolation
spec:
  podSelector:
    matchLabels:
      instance: li
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: sync-worker  # Only sync workers
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgresql-li
        - podSelector:
            matchLabels:
              app: minio-li
```

### Secret Management

**Pattern:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <service>-secrets
type: Opaque
stringData:
  password: <value>
  api-key: <value>
```

**Secrets per service:**
- `postgresql-passwords` - Superuser, replication, app passwords
- `redis-password` - Redis master password
- `minio-credentials` - Access key, secret key
- `synapse-secrets` - Registration, macaroon, form secrets
- `key-vault-secrets` - Django secret, database password, RSA keys
- `livekit-secrets` - API key, API secret
- `turn-credentials` - TURN static auth secret
- `monitoring-secrets` - Grafana admin, Prometheus basic auth

### Air-gapped Considerations

**Pre-deployment:**
1. Pull all container images to local registry
2. Download all Helm charts
3. Download ClamAV virus database
4. Package all Python/Node dependencies

**Local Registry:**
```
registry.local:5000/
├── synapse:v1.122.0
├── element-web:v1.11.84
├── postgresql:16.1
├── redis:7.2
├── minio:RELEASE.2024-11-07
├── haproxy:3.0
├── livekit:v1.8.1
├── coturn:4.6.3
├── clamav:1.4.1
└── ... (all others)
```

**Certificate Management:**
- Use organization's internal CA
- Generate all certs before air-gap
- 5-year validity minimum
- Include renewal procedures in docs

---

## Integration Points

### Matrix Federation

**Required:**
- `.well-known/matrix/server` delegation
- `.well-known/matrix/client` for client discovery
- Port 8448 for federation (or port 443 with delegation)

**Configuration:**
```json
// .well-known/matrix/server
{
  "m.server": "matrix.example.com:8448"
}

// .well-known/matrix/client
{
  "m.homeserver": {
    "base_url": "https://matrix.example.com"
  },
  "org.matrix.msc3575.proxy": {
    "url": "https://matrix.example.com"
  },
  "org.matrix.msc4143.rtc_foci": [
    {
      "type": "livekit",
      "livekit_service_url": "https://mrtc.example.com/livekit/jwt"
    }
  ]
}
```

### Push Notifications (Sygnal)

**Configuration:**
```yaml
apps:
  com.example.app.ios:
    type: apns
    keyfile: /data/apns-key.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: com.example.app

  com.example.app.android:
    type: gcm
    api_version: v1
    project_id: my-project-123456
    service_account_file: /data/fcm-service-account.json
```

**Synapse Integration:**
```yaml
push:
  include_content: false
  push_gatew_urls:
    - https://push.example.com/_matrix/push/v1/notify
```

### Monitoring Integration

**Metrics Exporters:**
- Synapse: Built-in Prometheus exporter on port 9090
- PostgreSQL: `postgres_exporter`
- Redis: `redis_exporter`
- MinIO: Built-in metrics endpoint
- HAProxy: Stats socket
- LiveKit: Built-in metrics

**Grafana Dashboards:**
1. System Overview (CPU, RAM, disk, network)
2. Synapse Performance (RPS, latency, queue depth)
3. PostgreSQL Health (connections, replication lag, query performance)
4. Redis Health (ops/sec, memory, latency)
5. MinIO Health (bandwidth, requests, errors)
6. Federation Health (send rate, receive rate, backlog)
7. Media Health (uploads, downloads, storage growth)
8. LiveKit Health (participants, rooms, bandwidth)

**Alerting Rules:**
- Database replication lag > 5 seconds
- Worker queue depth > 1000
- Media upload failures > 5% over 5 minutes
- Federation send backlog > 10000
- Disk usage > 80%
- Memory usage > 90%
- PostgreSQL connection saturation > 80%
- Redis memory usage > 80%

---

## Repository Analysis Summary

### Analyzed Repositories (39 total)

**LI-specific (5):**
- synapse-li - Synapse fork with LI proxy endpoint
- element-web-li - Modified Element Web for deleted message display
- synapse-admin-li - Admin panel with sync, statistics, decryption
- key_vault - Django service for encrypted key storage
- element-x-android - Android app with LIKeyCapture.kt

**Core Matrix (4):**
- synapse - Main homeserver implementation
- element-web - Web client
- element-call - MatrixRTC video conferencing
- matrix-authentication-service - MSC3861 OIDC auth

**Infrastructure (9):**
- ess-helm - Official Element Server Suite Helm charts
- cloudnative-pg - PostgreSQL operator
- livekit-helm - LiveKit Helm charts
- prometheus-community-helm - Monitoring charts
- bitnami-charts - Redis, MinIO dependencies
- cert-manager - TLS certificate management
- ingress-nginx - Alternative ingress
- metallb - LoadBalancer for bare-metal
- gateway-api - Kubernetes Gateway API

**Integration Services (6):**
- lk-jwt-service - LiveKit JWT authorization
- sygnal - Push notification gateway
- coturn - TURN/STUN server
- stunner - Alternative Kubernetes WebRTC gateway
- synapse-s3-storage-provider - S3 backend for media
- matrix-content-scanner-python - ClamAV integration

**Antivirus/Spam (3):**
- synapse-http-antispam - HTTP spam checker module
- synapse-spamcheck-badlist - CSAM badlist filter
- matrix-content-scanner-python - Media scanning

**Admin Tools (2):**
- synapse-admin - Standard admin UI
- synapse-admin-li - LI-enhanced admin UI

**Other (10):**
- element-docker-demo - Demo deployment
- matrix-docker-ansible-deploy - Ansible playbooks
- matrix-authentication-service-chart - MAS Helm chart
- docs - Documentation repository
- charts - Additional charts
- helm-charts - Chart repository
- kubernetes-ingress - NGINX ingress
- operator (MinIO) - MinIO operator
- deployment - Current deployment attempt
- element-x-android - Mobile client

---

## End of Knowledge Base

This knowledge base serves as the comprehensive reference for rebuilding the complete Matrix/Synapse deployment solution with full LI capabilities, HA, antivirus, and air-gapped support for 100-20K CCU.
