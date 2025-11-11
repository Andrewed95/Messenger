# High Availability and Routing Architecture

> **⚠️ IMPORTANT UPDATE:** This deployment now uses HAProxy routing layer for production-grade intelligent routing to specialized workers. While this document provides general HA concepts, please refer to **[HAPROXY-ARCHITECTURE.md](HAPROXY-ARCHITECTURE.md)** for the complete routing architecture, including:
> - Intelligent routing to specialized workers (sync, event-creator, federation, media, etc.)
> - Advanced load balancing strategies (token hashing, room hashing, origin hashing)
> - Health-aware routing with automatic fallbacks
> - Service discovery via DNS SRV records
> - Production-proven patterns from Element's ess-helm

This document explains the general high availability principles and how all components in the Matrix deployment connect to each other.

---

## Table of Contents

1. [Overview](#overview)
2. [Traffic Flow](#traffic-flow)
3. [Component Connections](#component-connections)
4. [High Availability Mechanisms](#high-availability-mechanisms)
5. [Failover Scenarios](#failover-scenarios)
6. [Load Balancing Strategies](#load-balancing-strategies)
7. [Service Discovery](#service-discovery)
8. [Network Policies](#network-policies)

---

## Overview

The deployment uses multiple layers of high availability and redundancy:

- **No Single Points of Failure**: Every critical component has multiple replicas
- **Automatic Failover**: Failed components are automatically replaced
- **Load Distribution**: Traffic is distributed across healthy instances
- **Health Monitoring**: Kubernetes continuously monitors component health

### Architecture Layers

```
┌─────────────────────────────────────────────────┐
│              CLIENT LAYER                        │
│  Users access via web browser or mobile app     │
└─────────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────┐
│          EDGE LAYER (External Access)            │
│  • DNS                                           │
│  • Load Balancer (MetalLB)                      │
│  • Ingress Controller (NGINX)                   │
└─────────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────┐
│        APPLICATION LAYER (Synapse)               │
│  • Main Process (coordinates)                   │
│  • Sync Workers (handle /sync requests)         │
│  • Generic Workers (handle API requests)        │
│  • Federation Senders (outbound federation)     │
│  • Event Persisters (database writes)           │
│  • Element Web (static web client)              │
│  • Synapse Admin (admin interface)              │
└─────────────────────────────────────────────────┘
         │              │              │
         ▼              ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│  DATA LAYER  │ │ CACHE LAYER  │ │ STORAGE LAYER│
│              │ │              │ │              │
│ PostgreSQL   │ │ Redis        │ │ MinIO        │
│ (3 replicas) │ │ (3 replicas) │ │ (4 nodes)    │
│              │ │              │ │              │
│ Primary +    │ │ Master +     │ │ Erasure      │
│ 2 Standby    │ │ 2 Replicas   │ │ Coded        │
└──────────────┘ └──────────────┘ └──────────────┘
```

---

## Traffic Flow

### External Client Request Flow

Here's what happens when a user accesses your Matrix server:

```
1. User types https://chat.example.com in browser
                      │
                      ▼
2. DNS resolves to Load Balancer IP (MetalLB)
   Example: chat.example.com → 192.168.1.240
                      │
                      ▼
3. Request hits NGINX Ingress Controller
   - Running on Kubernetes nodes
   - LoadBalancer Service provides external IP
                      │
                      ▼
4. NGINX routes based on URL path:
   ┌───────────────────────────────────────────────────┐
   │ Path                    →  Backend Service        │
   ├───────────────────────────────────────────────────┤
   │ /                       →  Element Web (direct)   │
   │ /_matrix/*              →  HAProxy Layer          │
   │ /_synapse/admin/*       →  HAProxy Layer          │
   │ /.well-known/matrix/*   →  HAProxy Layer          │
   │ /admin                  →  Synapse Admin (direct) │
   └───────────────────────────────────────────────────┘
                      │
                      ▼
5. HAProxy intelligently routes Matrix traffic:
   ┌────────────────────────────────────────────────────┐
   │ Request Type              →  Worker Type           │
   ├────────────────────────────────────────────────────┤
   │ /sync                     →  Sync Workers          │
   │ /rooms/.../send/          →  Event Creators        │
   │ /sendToDevice             →  To-Device Workers     │
   │ /media/*                  →  Media Repo Workers    │
   │ /federation/*             →  Federation Workers    │
   │ (and 8 more worker types) →  Specialized workers   │
   └────────────────────────────────────────────────────┘
   See HAPROXY-ARCHITECTURE.md for complete routing details
                      │
                      ▼
5. Request reaches appropriate backend pod
   - Pod handles request
   - Accesses database/cache as needed
                      │
                      ▼
6. Response returns through same path
   NGINX → LoadBalancer → Internet → User
```

### Synapse to PostgreSQL Connection

```
Synapse Pod
    │
    ▼
Connects to: synapse-postgres-pooler-rw.matrix.svc.cluster.local:5432
    │
    ├─────> PgBouncer Pooler (3 instances)
    │       │  Session-mode connection pooling
    │       │  Distributes connections
    │       │
    │       ▼
    │    PostgreSQL Primary
    │       │  Handles all writes
    │       │  Replicates to standbys
    │       │
    │       ├─> Standby Replica 1 (synchronous)
    │       └─> Standby Replica 2 (synchronous)
    │
    └─────> Direct connection fallback (if pooler fails)
```

**Why PgBouncer?**
- **Connection Pooling**: Synapse creates many connections; PgBouncer reuses them
- **Connection Limits**: Prevents exhausting PostgreSQL's max_connections
- **Performance**: Faster connection establishment
- **Compatibility**: Configured for Synapse's isolation level requirements

**Synapse Configuration** (in `manifests/05-synapse-main.yaml`):
```yaml
database:
  name: psycopg2
  args:
    host: synapse-postgres-pooler-rw.matrix.svc.cluster.local
    port: 5432
    user: synapse
    password: "YOUR_PASSWORD"
    database: synapse
    cp_min: 5      # Minimum connection pool size
    cp_max: 25     # Maximum connection pool size (main process)
```

**Why these pool sizes? (Example for 20K CCU scale)**
- Main process: `cp_max: 25` (handles many different endpoints)
- Workers: `cp_max: 12` (adjusted to stay under connection limit)
- Total: 1 main + 38 workers = 39 processes (20K CCU scale)
- Maximum connections: (1 × 25) + (38 × 12) = 481 connections
- PostgreSQL limit: 600 connections (20K CCU scale)
- Headroom: 119 connections for overhead and other processes

**📊 Scale-Specific Values:** See [SCALING-GUIDE.md](SCALING-GUIDE.md) Section 9.2 for connection pool calculations at your scale.

### Synapse to Redis Connection

```
Synapse Main Process
    │
    ▼
Connects to: redis-synapse-master.matrix.svc.cluster.local:6379
    │
    ├─────> Redis Master (active)
    │       │  Handles all reads/writes
    │       │  Publishes worker replication stream
    │       │
    │       ├─> Redis Replica 1 (standby)
    │       └─> Redis Replica 2 (standby)
    │
    └─────> Sentinel monitors all 3 instances
            │  Detects failures
            │  Promotes replica to master if needed
            │  Updates Service to point to new master

Synapse Workers
    │
    ▼
Connect to SAME Redis master
    │  Subscribe to replication stream
    │  Receive coordination messages
    │  Share cache data
```

**Why Stable Service Instead of Sentinel Direct Connection?**
- Synapse doesn't natively support Redis Sentinel protocol
- `redis-synapse-master` Service always points to current master
- Sentinel updates the Service backend when failover occurs
- Synapse just connects to the Service - transparent failover

**Worker Replication via Redis:**
```
Main Process                Workers
     │                         │
     ├──> Publishes event      │
     │    to Redis             │
     │                         │
     │    ┌────────────────────┘
     │    │
     ▼    ▼
   Redis Master
     │
     └──> Workers subscribe
          Receive event
          Update local state
```

### Synapse to MinIO (Object Storage) Connection

```
Synapse Pod (any process)
    │
    ▼
Connects to: minio-api.minio.svc.cluster.local:9000
    │
    ├─────> MinIO Node 1 ─────┐
    ├─────> MinIO Node 2 ─────┤
    ├─────> MinIO Node 3 ─────┤ Erasure Coding (EC:4)
    └─────> MinIO Node 4 ─────┘ Data split across 4 nodes
                                 Can lose 1 node without data loss
```

**Upload Process:**
1. User uploads file via Element Web
2. Request → NGINX Ingress → Synapse Worker
3. Synapse saves file to local PVC first
4. Synapse asynchronously uploads to MinIO (S3)
5. Synapse records S3 location in PostgreSQL
6. Automated cleanup job deletes local copy (see `manifests/10-operational-automation.yaml`)

**Configuration** (in `manifests/05-synapse-main.yaml`):
```yaml
media_storage_providers:
  - module: s3_storage_provider.S3StorageProviderBackend
    store_local: true           # Save locally first
    store_remote: true          # Upload to S3
    store_synchronous: false    # Async upload (non-blocking)
    config:
      bucket: synapse-media
      endpoint_url: "http://minio-api.minio.svc.cluster.local:9000"
```

---

## Component Connections

### Synapse Main Process Connections

The main process coordinates everything:

```
Synapse Main Process (synapse-main-xxx)
    │
    ├─> PostgreSQL (via PgBouncer)
    │   Purpose: Primary database for all data
    │   Connection: synapse-postgres-pooler-rw.matrix.svc.cluster.local:5432
    │
    ├─> Redis
    │   Purpose: Worker coordination, caching
    │   Connection: redis-synapse-master.matrix.svc.cluster.local:6379
    │
    ├─> MinIO
    │   Purpose: Media file storage
    │   Connection: minio-api.minio.svc.cluster.local:9000
    │
    ├─> Synapse Workers (HTTP replication)
    │   Purpose: Distribute work, receive events
    │   Connection: Each worker at <worker-pod>:9093
    │   │
    │   ├─> Sync Workers (8 instances)
    │   │   Connection: synapse-sync-worker-0..7:9093
    │   │
    │   ├─> Generic Workers (4 instances)
    │   │   Connection: synapse-generic-worker-0..3:9093
    │   │
    │   ├─> Event Persisters (2 instances)
    │   │   Connection: synapse-event-persister-0..1:9093
    │   │
    │   └─> Federation Senders (4 instances)
    │       Connection: synapse-federation-sender-0..3:9093
    │
    └─> coturn (TURN/STUN)
        Purpose: Provide TURN credentials for calls
        Configuration: turn_uris in homeserver.yaml
```

### Worker Connections

Workers connect to main process and shared resources:

```
Synapse Worker (any type)
    │
    ├─> Synapse Main Process (HTTP replication)
    │   Purpose: Receive work assignments, report status
    │   Connection: synapse-main.matrix.svc.cluster.local:9093
    │
    ├─> PostgreSQL (via PgBouncer)
    │   Purpose: Database queries
    │   Connection: synapse-postgres-pooler-rw.matrix.svc.cluster.local:5432
    │
    └─> Redis
        Purpose: Replication stream, caching
        Connection: redis-synapse-master.matrix.svc.cluster.local:6379
```

**Worker Types and Their Specialization:**

1. **Sync Workers** (8 instances)
   - Handle `/_matrix/client/*/sync` requests
   - Long-polling connections from clients
   - Most connection-intensive workers
   - Routed with session affinity (same user → same worker)

2. **Generic Workers** (4 instances)
   - Handle general client API calls
   - Federation receiver traffic
   - Media uploads/downloads
   - Room operations, user operations

3. **Event Persisters** (2 instances)
   - Specialized for database writes
   - Write events to PostgreSQL
   - High database connection usage
   - `cp_max: 20` (higher than other workers)

4. **Federation Senders** (4 instances)
   - Handle outbound federation traffic
   - Send events to other Matrix servers
   - Retry logic for failed sends

### Element Web Connections

```
Element Web Pod
    │
    ├─> Synapse (via NGINX Ingress)
    │   Purpose: All Matrix API calls
    │   Connection: https://chat.example.com/_matrix/*
    │   │  (Internally routes to Synapse workers)
    │
    ├─> LiveKit (for group calls)
    │   Purpose: WebRTC SFU for group video
    │   Connection: Configured in Element Web config.json
    │
    └─> Jitsi (optional, for video conferences)
        Purpose: Alternative video conferencing
        Configuration: jitsi section in config.json
```

**Element Web is Stateless:**
- Static JavaScript files served by nginx
- All state stored in Synapse (via API calls)
- Can scale horizontally (currently 3 replicas)
- Load balanced by NGINX Ingress

### coturn (TURN/STUN) Connections

```
Client (Element Web/Mobile)
    │
    ├─> STUN (UDP 3478)
    │   Purpose: Discover public IP address
    │   Connection: Direct to coturn pod IP
    │
    └─> TURN (UDP/TCP 3478, UDP 49152-65535)
        Purpose: Relay media if direct connection fails
        Connection: Direct to coturn pod IP
        Authentication: Shared secret from Synapse

coturn Pod
    │
    └─> Uses hostNetwork: true
        Binds directly to node's network interface
        Why: NAT traversal requires real public IP
```

**coturn Deployment Strategy:**
- DaemonSet with `hostNetwork: true`
- Runs on 2 specific nodes (labeled `coturn=true`)
- Each instance uses node's IP directly
- Synapse provides multiple TURN URIs (both nodes)

**Connection Flow:**
1. Client requests TURN credentials from Synapse
2. Synapse generates credentials using shared secret
3. Client connects to coturn with credentials
4. coturn validates and relays media traffic

### LiveKit (Video SFU) Connections

```
Client (Element Call widget in Element Web)
    │
    ├─> LiveKit SFU (WebSocket)
    │   Purpose: Join video room, send/receive tracks
    │   Connection: wss://livekit.chat.example.com
    │   │  (Or via Synapse proxy)
    │
    └─> Requests token from Synapse
        Synapse generates JWT token
        Client uses token to authenticate to LiveKit

LiveKit Pod
    │
    ├─> Redis (LiveKit instance)
    │   Purpose: Room state, participant tracking
    │   Connection: redis-livekit-master.livekit.svc.cluster.local:6379
    │   Note: Separate Redis from Synapse's Redis
    │
    └─> Uses hostNetwork: true
        Direct access to node network
        Why: WebRTC requires predictable addressing
```

**Why Separate Redis for LiveKit?**
- LiveKit has native Redis Sentinel support
- Different access patterns than Synapse
- Isolation: LiveKit issues don't affect Synapse
- Can scale independently

---

## High Availability Mechanisms

### PostgreSQL High Availability

**Architecture:**
```
┌─────────────────────────────────────────┐
│     CloudNativePG Operator              │
│  Manages cluster, handles failover      │
└─────────────────────────────────────────┘
            │
            ├──> Primary Instance
            │    │  Handles all writes
            │    │  Streaming replication to standbys
            │    │
            │    ├──> Synchronous Replication
            │    │    │  ANY 1 of 2 replicas must confirm
            │    │    │  Zero data loss on failover
            │    │    │
            │    │    ├──> Standby Replica 1
            │    │    └──> Standby Replica 2
            │
            └──> PgBouncer Pooler (3 instances)
                 Always routes to current primary
```

**Failover Process:**
1. CloudNativePG detects primary failure (health checks)
2. Waits `switchoverDelay: 300` seconds (5 minutes)
3. If primary still down, promotes a standby replica
4. New primary starts accepting writes
5. PgBouncer automatically redirects to new primary
6. Clients experience brief connection interruption (~30 seconds)

**Why 5 Minute Delay?**
- Prevents false positives from network blips
- Allows temporary issues to resolve
- Reduces unnecessary failovers
- Configurable in `manifests/01-postgresql-cluster.yaml`

**Data Safety:**
```yaml
synchronous:
  method: any    # ANY 1 of 2 replicas must confirm
  number: 1      # At least 1 replica confirms write
  dataDurability: required  # Don't acknowledge until replicated
```

**What This Means:**
- Every write waits for confirmation from 1 standby
- If primary crashes, standby has all data
- Zero data loss on failover
- Slight performance cost (replication latency)

### Redis High Availability

**Architecture:**
```
┌─────────────────────────────────────────┐
│        Redis Sentinel (3 instances)      │
│  Monitors master and replicas           │
│  Triggers failover if master fails      │
└─────────────────────────────────────────┘
         │        │        │
         ▼        ▼        ▼
    ┌────────────────────────┐
    │  Redis Master (active) │
    │   Handles all traffic  │
    └────────────────────────┘
         │                │
         ▼                ▼
    ┌─────────┐     ┌─────────┐
    │ Replica │     │ Replica │
    │   1     │     │   2     │
    └─────────┘     └─────────┘
```

**Failover Process:**
1. Sentinel detects master failure (health checks every 1 second)
2. Sentinel quorum (2 of 3) agrees master is down
3. Sentinel selects best replica (most up-to-date)
4. Sentinel promotes replica to master
5. Sentinel updates remaining replicas to follow new master
6. Sentinel updates `redis-synapse-master` Service backend
7. New connections automatically route to new master
8. Existing connections may fail, clients reconnect

**Downtime:** ~5-10 seconds

**Synapse Behavior:**
- Synapse retries failed Redis operations
- Worker coordination briefly disrupted
- Workers reconnect to new master
- No data loss (Redis persistence enabled)

### MinIO High Availability

**Architecture:**
```
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
│ MinIO    │  │ MinIO    │  │ MinIO    │  │ MinIO    │
│ Node 1   │  │ Node 2   │  │ Node 3   │  │ Node 4   │
└──────────┘  └──────────┘  └──────────┘  └──────────┘
     │             │             │             │
     └─────────────┴─────────────┴─────────────┘
                   │
              Erasure Coding (EC:4)
              Each object split into 4 data shards
              Can lose 1 node without data loss
```

**How Erasure Coding Works:**
1. File uploaded to MinIO
2. MinIO splits file into 4 shards
3. Each shard stored on different node
4. Can reconstruct file from any 3 shards

**Failure Scenarios:**
- **1 node fails**: No data loss, full read/write capability
- **2 nodes fail**: Data loss, read-only mode
- **3 nodes fail**: Cluster unavailable

**Healing Process:**
1. Failed node returns online
2. MinIO automatically re-balances data
3. Missing shards reconstructed from surviving nodes
4. Cluster returns to full redundancy

### Synapse Worker High Availability

**Architecture:**
```
Kubernetes manages worker lifecycle:

┌────────────────────────────────────┐
│  StatefulSet: synapse-sync-worker  │
│  Replicas: 8                       │
└────────────────────────────────────┘
         │
         ├──> Pod: synapse-sync-worker-0
         ├──> Pod: synapse-sync-worker-1
         ├──> Pod: synapse-sync-worker-2
         ├──> Pod: synapse-sync-worker-3
         ├──> Pod: synapse-sync-worker-4
         ├──> Pod: synapse-sync-worker-5
         ├──> Pod: synapse-sync-worker-6
         └──> Pod: synapse-sync-worker-7

If Pod fails:
  │
  ├──> Kubernetes detects (liveness probe)
  ├──> Kubernetes terminates pod
  ├──> Kubernetes creates new pod (same name)
  ├──> New pod starts and registers with main process
  └──> Load balancer routes new traffic to healthy pods
```

**Failover Time:** ~30 seconds

**Impact:**
- In-flight requests to failed worker are lost
- Clients automatically retry
- Other workers continue handling traffic
- No permanent data loss (state in PostgreSQL)

### NGINX Ingress High Availability

**Architecture:**
```
NGINX Ingress Controller (3 replicas)
     │
     ├──> Pod: nginx-ingress-controller-1
     ├──> Pod: nginx-ingress-controller-2
     └──> Pod: nginx-ingress-controller-3
              │
              ▼
      MetalLB LoadBalancer Service
       (Announces same IP from all healthy pods)
```

**How MetalLB Provides HA:**
- Layer 2 mode: Uses ARP to announce IP
- All NGINX pods can handle traffic at that IP
- If pod fails, MetalLB updates ARP to point to healthy pod
- Failover time: <1 second

---

## Failover Scenarios

### Scenario 1: PostgreSQL Primary Fails

**Timeline:**
```
T+0s:   Primary PostgreSQL crashes
T+30s:  CloudNativePG detects failure (health checks fail)
T+300s: switchoverDelay expires (5 minutes)
T+301s: CloudNativePG promotes Standby Replica 1 to primary
T+302s: PgBouncer connects to new primary
T+310s: All Synapse processes reconnected
T+315s: Service fully operational
```

**User Impact:**
- Ongoing database writes fail (rare, mostly reads)
- Synapse retries failed operations
- Brief message delivery delay (a few seconds)
- No message loss
- No user-visible downtime if operations complete in retry window

### Scenario 2: Redis Master Fails

**Timeline:**
```
T+0s:   Redis master crashes
T+1s:   Sentinel detects failure
T+2s:   Sentinel quorum reached (2 of 3 agree)
T+3s:   Sentinel promotes Replica 1 to master
T+4s:   Sentinel updates Service endpoint
T+5s:   Synapse reconnects to new master
T+10s:  All workers reconnected
```

**User Impact:**
- Worker coordination briefly disrupted
- Active /sync requests may timeout (clients retry)
- Cache temporarily empty (repopulates quickly)
- No permanent data loss
- Downtime: 5-10 seconds

### Scenario 3: Synapse Worker Dies

**Timeline:**
```
T+0s:   Worker pod crashes
T+10s:  Kubernetes detects (liveness probe fails)
T+11s:  Kubernetes terminates pod
T+12s:  Kubernetes schedules new pod
T+30s:  New pod started and ready
T+31s:  Service routes traffic to new pod
```

**User Impact:**
- In-flight requests to that worker fail
- Clients automatically retry (transparent)
- Other workers continue serving traffic
- No data loss
- Minimal user-visible impact

### Scenario 4: Entire Node Fails

**Timeline:**
```
T+0s:   Node crashes (hardware failure, network disconnect)
T+40s:  Kubernetes marks node as NotReady
T+5m:   Kubernetes evicts pods from dead node
T+6m:   New pods scheduled on healthy nodes
T+8m:   New pods ready and serving traffic
```

**User Impact:**
- All pods on that node unavailable
- Other replicas continue serving (HA design)
- PostgreSQL/Redis/MinIO: automatic failover (if primary was on that node)
- Workers: traffic routed to survivors, new pods created
- Degraded performance until pods rescheduled
- No permanent data loss

---

## Load Balancing Strategies

### Sync Worker Load Balancing

**Strategy:** Consistent hashing by username

**Why:**
- /sync is a long-polling request (can last 30+ seconds)
- Users repeatedly connect for sync
- Routing same user to same worker improves cache efficiency

**NGINX Configuration** (in `manifests/09-ingress.yaml`):
```nginx
upstream synapse_sync_workers {
  # Hash by Authorization header (contains username)
  hash $http_authorization consistent;

  server synapse-sync-worker-0:8083;
  server synapse-sync-worker-1:8083;
  server synapse-sync-worker-2:8083;
  server synapse-sync-worker-3:8083;
  server synapse-sync-worker-4:8083;
  server synapse-sync-worker-5:8083;
  server synapse-sync-worker-6:8083;
  server synapse-sync-worker-7:8083;
}
```

**Behavior:**
- User `@alice:example.com` always routes to worker-3
- User `@bob:example.com` always routes to worker-7
- If worker fails, that user's requests go to different worker
- Session affinity maintained per user

### Generic Worker Load Balancing

**Strategy:** Least connections

**Why:**
- Generic workers handle various requests
- Some requests fast (GET), some slow (POST)
- Least connections ensures even load distribution

**NGINX Configuration:**
```nginx
upstream synapse_generic_workers {
  least_conn;  # Route to worker with fewest active connections

  server synapse-generic-worker-0:8081;
  server synapse-generic-worker-1:8081;
  server synapse-generic-worker-2:8081;
  server synapse-generic-worker-3:8081;
}
```

**Behavior:**
- Each request routed to worker with least active connections
- Balances load even if some requests slower than others
- No session affinity needed

### PostgreSQL Connection Load Balancing

**Strategy:** PgBouncer session pooling

**How It Works:**
```
Synapse (19 processes)
  Each process: cp_max connections

       │
       ▼
  PgBouncer (3 instances)
    Manages connection pool
    Session mode (required for Synapse)

       │
       ▼
  PostgreSQL Primary
    max_connections: 500
```

**Connection Pooling:**
- Synapse process requests connection from PgBouncer
- PgBouncer assigns existing connection from pool (if available)
- If no connection available, PgBouncer creates new one
- When Synapse finishes, connection returns to pool
- Next Synapse request reuses same connection

**Benefits:**
- Fewer total connections to PostgreSQL
- Faster connection establishment
- Better PostgreSQL performance (fewer connection overhead)

---

## Service Discovery

Kubernetes uses DNS for service discovery. Every Service gets a DNS name:

### Service DNS Names

**Format:** `<service-name>.<namespace>.svc.cluster.local`

**Examples:**
```
synapse-main.matrix.svc.cluster.local
  ↓         ↓      ↓     ↓
  Service   Namespace   Kubernetes cluster domain
```

**All Services in Deployment:**

| Service | DNS Name | Purpose |
|---------|----------|---------|
| Synapse Main | `synapse-main.matrix.svc.cluster.local` | Main process |
| PostgreSQL Pooler | `synapse-postgres-pooler-rw.matrix.svc.cluster.local` | Database connection |
| PostgreSQL Direct | `synapse-postgres-rw.matrix.svc.cluster.local` | Database (bypass pooler) |
| Redis (Synapse) | `redis-synapse-master.matrix.svc.cluster.local` | Cache/coordination |
| Redis (LiveKit) | `redis-livekit-master.livekit.svc.cluster.local` | LiveKit cache |
| MinIO | `minio-api.minio.svc.cluster.local` | Object storage |
| Element Web | `element-web.matrix.svc.cluster.local` | Web client |
| Synapse Admin | `synapse-admin.matrix.svc.cluster.local` | Admin UI |

### How DNS Resolution Works

1. Application makes request to `synapse-postgres-pooler-rw.matrix.svc.cluster.local`
2. Kubernetes DNS (CoreDNS) resolves to Service IP (ClusterIP)
3. Service IP load-balances across backend pods (iptables rules)
4. Traffic reaches pod

**Service Types:**

- **ClusterIP** (most services): Only accessible within cluster
- **LoadBalancer** (NGINX Ingress): Gets external IP from MetalLB
- **Headless** (StatefulSets): Each pod gets own DNS entry

---

## Network Policies

By default, all pods can communicate with all other pods. Network policies can restrict this for security.

**Example Policy (not currently implemented):**
```yaml
# Restrict Synapse to only communicate with authorized services
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: synapse-network-policy
  namespace: matrix
spec:
  podSelector:
    matchLabels:
      app: synapse
  policyTypes:
    - Egress
  egress:
    # Allow PostgreSQL
    - to:
      - podSelector:
          matchLabels:
            cnpg.io/cluster: synapse-postgres
      ports:
        - protocol: TCP
          port: 5432

    # Allow Redis
    - to:
      - podSelector:
          matchLabels:
            app.kubernetes.io/name: redis
      ports:
        - protocol: TCP
          port: 6379

    # Allow MinIO
    - to:
      - namespaceSelector:
          matchLabels:
            name: minio
      ports:
        - protocol: TCP
          port: 9000

    # Allow DNS
    - to:
      - namespaceSelector:
          matchLabels:
            name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

**To implement network policies:**
1. Install network policy provider (Calico, Cilium, etc.)
2. Create NetworkPolicy resources
3. Test thoroughly (can break communication if misconfigured)

---

## Summary

**Key Takeaways:**

1. **Every Critical Component Has Redundancy**
   - PostgreSQL: 3 instances (1 primary + 2 standby)
   - Redis: 3 instances (1 master + 2 replicas)
   - MinIO: 4 nodes (erasure coded)
   - Workers: Multiple instances of each type

2. **Automatic Failover Everywhere**
   - PostgreSQL: CloudNativePG handles failover (~5 minutes)
   - Redis: Sentinel handles failover (~5 seconds)
   - Workers: Kubernetes recreates failed pods (~30 seconds)
   - Ingress: MetalLB redirects traffic (<1 second)

3. **Load Balancing Matches Workload**
   - Sync workers: Session affinity (consistent hashing)
   - Generic workers: Least connections
   - PostgreSQL: PgBouncer connection pooling
   - NGINX: Round-robin to healthy pods

4. **Service Discovery via Kubernetes DNS**
   - Every service has predictable DNS name
   - DNS automatically updated on failover
   - Applications don't need to know pod IPs

5. **Connection Pooling Critical for Performance**
   - PgBouncer reduces PostgreSQL connection overhead
   - Synapse's `cp_max` limits per-process connections
   - Total connections kept under PostgreSQL's limit

---

**Related Documentation:**

- [Main README](../README.md) - Overview and quick start
- [Deployment Guide](DEPLOYMENT-GUIDE.md) - Step-by-step deployment
- [Configuration Reference](CONFIGURATION-REFERENCE.md) - All settings explained

**For Troubleshooting:**

If components can't connect:
1. Check Service exists: `kubectl get svc -n <namespace>`
2. Check DNS resolves: `kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup <service-dns-name>`
3. Check pods are ready: `kubectl get pods -n <namespace>`
4. Check logs: `kubectl logs -n <namespace> <pod-name>`
