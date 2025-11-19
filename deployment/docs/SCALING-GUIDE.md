# Scaling Guide: 100 to 20,000 Concurrent Users
## Infrastructure Sizing and Configuration for Different Scales

---

## Table of Contents

1. [Overview & Scaling Philosophy](#1-overview--scaling-philosophy)
2. [Scaling Fundamentals](#2-scaling-fundamentals)
3. [100 CCU Scale](#3-100-ccu-scale)
4. [1,000 CCU Scale](#4-1000-ccu-scale)
5. [5,000 CCU Scale](#5-5000-ccu-scale)
6. [10,000 CCU Scale](#6-10000-ccu-scale)
7. [20,000 CCU Scale](#7-20000-ccu-scale)
8. [Scaling Decision Matrix](#8-scaling-decision-matrix)
9. [Configuration Parameters by Scale](#9-configuration-parameters-by-scale)
10. [Media Storage Planning](#10-media-storage-planning)
11. [Voice/Video Call Infrastructure](#11-voicevideo-call-infrastructure)

---

## 1. Overview & Scaling Philosophy

### 1.1 Architecture Consistency

**IMPORTANT:** The architecture remains identical across all scales. We maintain:
- ✅ Full High Availability (HA) at all scales
- ✅ Same technology stack (Synapse, PostgreSQL, Redis, MinIO, LiveKit, coturn)
- ✅ Same topology and component relationships
- ✅ Same security and operational practices

**What Changes:**
- Number of servers/nodes
- Server resources (CPU, RAM, storage)
- Number of Synapse workers
- Configuration parameters (connection pools, caching, etc.)

### 1.2 Concurrent User Definition

**Concurrent Users (CCU):** Users actively connected and using the system simultaneously.

**Typical Activity Patterns:**
- **Peak hours:** 70-80% of CCU actively sending/receiving messages
- **Off-peak hours:** 40-50% of CCU idle but connected
- **Average message rate:** 2-5 messages per active user per minute
- **Media uploads:** 10-20% of active users upload files during peak hour
- **Voice/Video calls:** 5-15% of CCU in calls simultaneously at peak

### 1.3 Research Methodology

Numbers in this guide are derived from:
- ✅ Official Matrix.org scalability documentation
- ✅ Synapse performance benchmarks and worker architecture limits
- ✅ LiveKit official benchmarking data (c2-standard-16 baseline)
- ✅ coturn wiki performance characteristics
- ✅ PostgreSQL connection pool best practices
- ✅ Production deployment case studies from Matrix community
- ✅ Hardware vendor sizing recommendations (MinIO, Redis)

### 1.4 Scaling Calculation Model

Our sizing model uses these formulas:

**Synapse Workers:**
- Sync workers: `CEIL(CCU / 1250)` workers, minimum 2 for HA
- Generic workers: `CEIL(CCU / 2500)` workers, minimum 2 for HA
- Event persisters: `CEIL(CCU / 10000)` workers, minimum 2 for HA
- Federation senders: `CEIL(CCU / 5000)` workers, minimum 2 for HA

**Database Connections:**
- Total processes = 1 (main) + sum(all workers)
- cp_max per process: Ensure `total_processes × cp_max < PostgreSQL max_connections × 0.85`
- PostgreSQL max_connections: `100 + (CCU / 100)`, capped at 600

**LiveKit Instances:**
- Calls capacity per instance: ~1000 concurrent 1-on-1 calls or ~50 group calls (10 users each)
- Instances needed: `CEIL((CCU × 0.10) / 1000)` minimum 2 for HA

**coturn Instances:**
- Concurrent allocations per instance: ~2000 (on 4 vCPU)
- Instances needed: `CEIL((CCU × 0.15) / 2000)` minimum 2 for HA

---

## 2. Scaling Fundamentals

### 2.1 Bottleneck Analysis

**Primary Bottlenecks by Component:**

| Component | Bottleneck Factor | Scaling Strategy |
|-----------|------------------|------------------|
| Synapse Workers | CPU (Python GIL limits 1 core/worker) | Horizontal: Add more workers |
| PostgreSQL | Connections + I/O | Vertical: Bigger primary + Horizontal: Read replicas |
| Redis | Memory + Network | Vertical: More RAM per instance |
| MinIO | Network bandwidth | Horizontal: Add nodes to pool |
| LiveKit | CPU + Network | Horizontal: Add instances |
| coturn | Network bandwidth | Horizontal: Add instances |

### 2.2 Load Distribution Patterns

**Message Traffic:**
- 80% of traffic is sync requests (long-polling, typically 30s timeout)
- 15% is event sending (messages, reactions, read receipts)
- 5% is federation traffic

**Database Operations:**
- 60% read operations (event retrieval, state resolution)
- 30% write operations (event persistence)
- 10% maintenance operations (cleanup, statistics)

**Media Traffic:**
- 70% image uploads (avatars, photos)
- 20% file uploads (documents, archives)
- 10% video/audio uploads

### 2.3 Resource Calculation Formulas

**CPU Requirements:**
```
Synapse CPU = (sync_workers + generic_workers) × 1.5 vCPU + event_persisters × 2 vCPU + main × 2 vCPU
PostgreSQL CPU = 2 vCPU (base) + (CCU / 5000) × 2 vCPU (per PostgreSQL instance)
Redis CPU = 1 vCPU (Synapse) + 1 vCPU (LiveKit)
MinIO CPU = 1 vCPU per node
LiveKit CPU = 8 vCPU per instance (baseline from benchmarks)
coturn CPU = 4 vCPU per instance
```

**Memory Requirements:**
```
Synapse RAM per worker = 0.5GB (base) + (CCU / 10000) × 0.5GB
PostgreSQL RAM = 4GB (base) + (CCU / 1000) × 1GB (per PostgreSQL instance)
Redis RAM (Synapse) = 2GB (base) + (CCU / 5000) × 1GB
Redis RAM (LiveKit) = 1GB (base) + (active_calls / 1000) × 0.5GB
MinIO RAM = 8GB per node (minimum for production)
LiveKit RAM = 8GB per instance
coturn RAM = 4GB per instance
```

**Storage Requirements:**
```
PostgreSQL = 10GB (base) + (CCU × 500MB per year)
Media Storage (MinIO) = See Section 10
Monitoring (Prometheus + Loki) = 50GB (base) + (CCU / 100) × 1GB per month
```

### 2.4 High Availability Requirements

**Minimum Instances for HA:**
- Synapse: Workers in StatefulSets (Kubernetes handles replacement)
- PostgreSQL: 3 instances (1 primary + 2 replicas, synchronous replication)
- Redis: 3 instances (1 master + 2 replicas + 3 Sentinel)
- MinIO: 4 nodes minimum (EC:4 erasure coding, 1 node failure tolerance)
- LiveKit: 2 instances minimum (Redis-backed session management)
- coturn: 2 instances minimum (client DNS-based failover)

---

## 3. 100 CCU Scale

### 3.1 Use Case Profile

**Typical Deployments:**
- Small organizations (startups, small businesses)
- Department-level deployments within larger organizations
- Community servers
- Development/staging environments

**Expected Activity:**
- Peak concurrent users: 100
- Active messaging users at peak: 70-80
- Messages per minute: 140-400
- Media uploads per hour: 10-20 files
- Concurrent calls at peak: 5-10 users in calls
- Rooms: 50-100 active rooms

### 3.2 Infrastructure Sizing

#### Server Inventory (Minimum HA Configuration)

| Role | Count | CPU | RAM | Storage | Purpose |
|------|-------|-----|-----|---------|---------|
| **Control Plane** | 3 | 4 vCPU | 8GB | 100GB SSD | Kubernetes masters |
| **Application Nodes** | 3 | 8 vCPU | 16GB | 200GB SSD | Synapse, monitoring |
| **Database Node** | 3 | 4 vCPU | 16GB | 500GB NVMe | PostgreSQL cluster |
| **Storage Nodes** | 4 | 4 vCPU | 8GB | 1TB HDD | MinIO (media files) |
| **Call Servers** | 2 | 4 vCPU | 8GB | 50GB SSD | LiveKit + coturn |
| **Total Servers** | **15** | | | | |

**Total Resources:**
- vCPU: 92 cores
- RAM: 180GB
- Storage: 5.4TB (1TB usable for media with EC:4)

#### Component Configuration

**Synapse:**
```yaml
Main process: 1 instance
  Resources: 2 vCPU, 4GB RAM

Sync workers: 2 instances (HA minimum)
  Resources per worker: 1 vCPU, 1GB RAM
  Handles: ~50 users each

Generic workers: 2 instances (HA minimum)
  Resources per worker: 1 vCPU, 1GB RAM
  Handles: Client API, media, federation receiver

Event persisters: 2 instances (HA minimum)
  Resources per worker: 2 vCPU, 2GB RAM
  Handles: Database writes

Federation senders: 2 instances (HA minimum)
  Resources per worker: 0.5 vCPU, 0.5GB RAM
  Handles: Outbound federation

Total Synapse Processes: 9
```

**PostgreSQL:**
```yaml
Instances: 3 (1 primary + 2 replicas)
Resources per instance: 4 vCPU, 16GB RAM
Storage per instance: 500GB NVMe

Configuration:
  max_connections: 200
  shared_buffers: 4GB
  effective_cache_size: 12GB
  maintenance_work_mem: 1GB
  work_mem: 20MB

Synapse connection pool (cp_max):
  Main process: 10
  Each worker: 8
  Total: 10 + (8 × 8) = 74 connections < 200 × 0.85 = 170 ✓
```

**Redis:**
```yaml
Synapse Redis:
  Instances: 3 (1 master + 2 replicas)
  Resources per instance: 1 vCPU, 2GB RAM
  Persistence: AOF (durability)

LiveKit Redis:
  Instances: 3 (1 master + 2 replicas)
  Resources per instance: 1 vCPU, 1GB RAM
  Persistence: RDB (performance)
```

**MinIO:**
```yaml
Nodes: 4
Resources per node: 4 vCPU, 8GB RAM, 1TB HDD
Erasure Coding: EC:4 (1 node failure tolerance)
Usable capacity: ~1TB (25% overhead)

Expected usage:
  Year 1: ~200GB (20GB/user/year × 100 users × 10% upload rate)
  Year 2: ~400GB
  Remaining capacity: ~600GB
```

**LiveKit:**
```yaml
Instances: 2 (HA)
Resources per instance: 4 vCPU, 8GB RAM

Capacity per instance:
  1-on-1 calls: ~200 concurrent calls
  Group calls (5 users): ~20 concurrent calls

Expected load at 100 CCU:
  Concurrent call participants: ~10 (10% of CCU)
  Typical mix: 8 in 1-on-1, 2 in 1 group call
  Utilization: ~5% per instance
```

**coturn:**
```yaml
Instances: 2 (HA)
Resources per instance: 4 vCPU, 4GB RAM

Capacity per instance:
  Concurrent allocations: ~2000

Expected load at 100 CCU:
  Users needing TURN: ~15 (15% of CCU, behind NAT/firewall)
  Allocations per user: ~4 (audio + video + data)
  Total allocations: ~60
  Utilization: ~3% per instance
```

### 3.3 Configuration Parameters

**Synapse (homeserver.yaml):**
```yaml
database:
  args:
    cp_min: 5
    cp_max: 10  # Main process

# Workers use cp_max: 8

caches:
  global_factor: 0.5  # Smaller cache for small deployment

event_cache_size: 5K  # Events in memory

max_upload_size: 50M  # Maximum file size for media uploads (images, documents, etc.)

rate_limiting:
  rc_message:
    per_second: 5
    burst_count: 25
  rc_registration:
    per_second: 0.1
    burst_count: 3

federation:
  max_concurrent_requests: 5

worker_replication_secret: <generate-secret>
```

**PostgreSQL Tuning:**
```sql
max_connections = 200
shared_buffers = 4GB
effective_cache_size = 12GB
maintenance_work_mem = 1GB
work_mem = 20MB
random_page_cost = 1.1  # For SSD/NVMe
effective_io_concurrency = 200
wal_buffers = 16MB
max_wal_size = 4GB
checkpoint_completion_target = 0.9
```

---

## 4. 1,000 CCU Scale

### 4.1 Use Case Profile

**Typical Deployments:**
- Medium-sized organizations
- University departments
- Large community servers
- Regional service providers

**Expected Activity:**
- Peak concurrent users: 1,000
- Active messaging users at peak: 700-800
- Messages per minute: 1,400-4,000
- Media uploads per hour: 100-200 files
- Concurrent calls at peak: 50-100 users in calls
- Rooms: 500-1,000 active rooms

### 4.2 Infrastructure Sizing

#### Server Inventory

| Role | Count | CPU | RAM | Storage | Purpose |
|------|-------|-----|-----|---------|---------|
| **Control Plane** | 3 | 4 vCPU | 8GB | 100GB SSD | Kubernetes masters |
| **Application Nodes** | 5 | 16 vCPU | 32GB | 500GB SSD | Synapse, monitoring |
| **Database Nodes** | 3 | 8 vCPU | 32GB | 1TB NVMe | PostgreSQL cluster |
| **Storage Nodes** | 4 | 8 vCPU | 16GB | 2TB HDD | MinIO (media files) |
| **Call Servers** | 4 | 8 vCPU | 16GB | 100GB SSD | LiveKit + coturn (2+2) |
| **Total Servers** | **19** | | | | |

**Total Resources:**
- vCPU: 228 cores
- RAM: 468GB
- Storage: 11.7TB (2TB usable for media)

#### Component Configuration

**Synapse:**
```yaml
Main process: 1 instance
  Resources: 2 vCPU, 8GB RAM

Sync workers: 4 instances
  Resources per worker: 1.5 vCPU, 2GB RAM
  Handles: ~250 users each

Generic workers: 2 instances
  Resources per worker: 1.5 vCPU, 2GB RAM

Event persisters: 2 instances
  Resources per worker: 2 vCPU, 3GB RAM

Federation senders: 2 instances
  Resources per worker: 1 vCPU, 1GB RAM

Total Synapse Processes: 11
```

**PostgreSQL:**
```yaml
Instances: 3 (1 primary + 2 replicas)
Resources per instance: 8 vCPU, 32GB RAM
Storage per instance: 1TB NVMe

Configuration:
  max_connections: 300
  shared_buffers: 8GB
  effective_cache_size: 24GB
  maintenance_work_mem: 2GB
  work_mem: 26MB

Synapse connection pool (cp_max):
  Main process: 15
  Each worker: 12
  Total: 15 + (12 × 10) = 135 connections < 300 × 0.85 = 255 ✓
```

**Redis:**
```yaml
Synapse Redis:
  Instances: 3 (1 master + 2 replicas)
  Resources per instance: 2 vCPU, 4GB RAM

LiveKit Redis:
  Instances: 3 (1 master + 2 replicas)
  Resources per instance: 2 vCPU, 2GB RAM
```

**MinIO:**
```yaml
Nodes: 4
Resources per node: 8 vCPU, 16GB RAM, 2TB HDD
Erasure Coding: EC:4
Usable capacity: ~2TB

Expected usage:
  Year 1: ~2TB (20GB/user/year × 1000 users × 10% upload rate)
  Year 2: ~4TB (will need expansion)
```

**LiveKit:**
```yaml
Instances: 2 (HA)
Resources per instance: 8 vCPU, 16GB RAM

Capacity: ~1000 concurrent call participants per instance
Expected load: 50-100 participants (5-10% utilization)
```

**coturn:**
```yaml
Instances: 2 (HA)
Resources per instance: 8 vCPU, 8GB RAM

Capacity: ~4000 concurrent allocations per instance
Expected load: 600 allocations (15% utilization)
```

### 4.3 Configuration Parameters

**Synapse (homeserver.yaml):**
```yaml
database:
  args:
    cp_min: 5
    cp_max: 15  # Main process

# Workers use cp_max: 12

caches:
  global_factor: 1.0  # Standard cache size

event_cache_size: 10K

max_upload_size: 100M  # Maximum file size for media uploads (images, documents, etc.)

rate_limiting:
  rc_message:
    per_second: 10
    burst_count: 50

federation:
  max_concurrent_requests: 10
```

**PostgreSQL Tuning:**
```sql
max_connections = 300
shared_buffers = 8GB
effective_cache_size = 24GB
maintenance_work_mem = 2GB
work_mem = 26MB
max_wal_size = 8GB
checkpoint_completion_target = 0.9
autovacuum_max_workers = 4
```

---

## 5. 5,000 CCU Scale

### 5.1 Use Case Profile

**Typical Deployments:**
- Large organizations (1,000-5,000 employees)
- Universities (campus-wide)
- Regional service providers
- Large community networks

**Expected Activity:**
- Peak concurrent users: 5,000
- Active messaging users at peak: 3,500-4,000
- Messages per minute: 7,000-20,000
- Media uploads per hour: 500-1,000 files
- Concurrent calls at peak: 250-500 users in calls
- Rooms: 2,000-5,000 active rooms

### 5.2 Infrastructure Sizing

#### Server Inventory

| Role | Count | CPU | RAM | Storage | Purpose |
|------|-------|-----|-----|---------|---------|
| **Control Plane** | 3 | 8 vCPU | 16GB | 200GB SSD | Kubernetes masters |
| **Application Nodes** | 8 | 16 vCPU | 64GB | 1TB SSD | Synapse, monitoring |
| **Database Nodes** | 3 | 16 vCPU | 64GB | 2TB NVMe | PostgreSQL cluster |
| **Storage Nodes** | 4 | 16 vCPU | 32GB | 4TB HDD | MinIO (media files) |
| **Call Servers** | 6 | 16 vCPU | 32GB | 200GB SSD | LiveKit + coturn (3+3) |
| **Total Servers** | **24** | | | | |

**Total Resources:**
- vCPU: 448 cores
- RAM: 1,056GB (1TB)
- Storage: 21.4TB (4TB usable for media)

#### Component Configuration

**Synapse:**
```yaml
Main process: 1 instance
  Resources: 4 vCPU, 12GB RAM

Sync workers: 6 instances
  Resources per worker: 2 vCPU, 3GB RAM
  Handles: ~833 users each

Generic workers: 4 instances
  Resources per worker: 2 vCPU, 3GB RAM

Event persisters: 2 instances
  Resources per worker: 3 vCPU, 4GB RAM

Federation senders: 4 instances
  Resources per worker: 1.5 vCPU, 2GB RAM

Total Synapse Processes: 17
```

**PostgreSQL:**
```yaml
Instances: 3 (1 primary + 2 replicas)
Resources per instance: 16 vCPU, 64GB RAM
Storage per instance: 2TB NVMe

Configuration:
  max_connections: 400
  shared_buffers: 16GB
  effective_cache_size: 48GB
  maintenance_work_mem: 4GB
  work_mem: 40MB

Synapse connection pool (cp_max):
  Main process: 18
  Each worker: 12
  Total: 18 + (12 × 16) = 210 connections < 400 × 0.85 = 340 ✓
```

**Redis:**
```yaml
Synapse Redis:
  Instances: 3
  Resources per instance: 4 vCPU, 8GB RAM

LiveKit Redis:
  Instances: 3
  Resources per instance: 2 vCPU, 4GB RAM
```

**MinIO:**
```yaml
Nodes: 4
Resources per node: 16 vCPU, 32GB RAM, 4TB HDD
Erasure Coding: EC:4
Usable capacity: ~4TB

Expected usage:
  Year 1: ~10TB (will need expansion or additional pool)
  Recommendation: Add second pool of 4 nodes within 
```

**LiveKit:**
```yaml
Instances: 3 (HA + performance)
Resources per instance: 16 vCPU, 32GB RAM

Capacity: ~2000 concurrent call participants per instance
Expected load: 250-500 participants (8-12% utilization per instance)
```

**coturn:**
```yaml
Instances: 3 (HA + performance)
Resources per instance: 16 vCPU, 16GB RAM

Capacity: ~8000 concurrent allocations per instance
Expected load: 3,000 allocations (12% utilization per instance)
```

### 5.3 Configuration Parameters

**Synapse (homeserver.yaml):**
```yaml
database:
  args:
    cp_min: 5
    cp_max: 18  # Main process

# Workers use cp_max: 12

caches:
  global_factor: 2.0  # Larger cache

event_cache_size: 20K

max_upload_size: 100M  # Maximum file size for media uploads (images, documents, etc.)

rate_limiting:
  rc_message:
    per_second: 15
    burst_count: 75

federation:
  max_concurrent_requests: 20
```

**PostgreSQL Tuning:**
```sql
max_connections = 400
shared_buffers = 16GB
effective_cache_size = 48GB
maintenance_work_mem = 4GB
work_mem = 40MB
max_wal_size = 16GB
checkpoint_completion_target = 0.9
autovacuum_max_workers = 6
autovacuum_naptime = 30s
```

---

## 6. 10,000 CCU Scale

### 6.1 Use Case Profile

**Typical Deployments:**
- Enterprise organizations (5,000-10,000 employees)
- Large universities (multi-campus)
- National service providers
- Major community networks

**Expected Activity:**
- Peak concurrent users: 10,000
- Active messaging users at peak: 7,000-8,000
- Messages per minute: 14,000-40,000
- Media uploads per hour: 1,000-2,000 files
- Concurrent calls at peak: 500-1,000 users in calls
- Rooms: 5,000-10,000 active rooms

### 6.2 Infrastructure Sizing

#### Server Inventory

| Role | Count | CPU | RAM | Storage | Purpose |
|------|-------|-----|-----|---------|---------|
| **Control Plane** | 3 | 8 vCPU | 16GB | 200GB SSD | Kubernetes masters |
| **Application Nodes** | 12 | 32 vCPU | 128GB | 2TB SSD | Synapse, monitoring |
| **Database Nodes** | 3 | 32 vCPU | 128GB | 4TB NVMe | PostgreSQL cluster |
| **Storage Nodes** | 8 | 16 vCPU | 32GB | 4TB HDD | MinIO (2 pools of 4) |
| **Call Servers** | 8 | 16 vCPU | 32GB | 200GB SSD | LiveKit + coturn (4+4) |
| **Total Servers** | **34** | | | | |

**Total Resources:**
- vCPU: 704 cores
- RAM: 2,144GB (2.1TB)
- Storage: 42.4TB (8TB usable for media)

#### Component Configuration

**Synapse:**
```yaml
Main process: 1 instance
  Resources: 4 vCPU, 16GB RAM

Sync workers: 8 instances
  Resources per worker: 2 vCPU, 4GB RAM
  Handles: ~1,250 users each

Generic workers: 4 instances
  Resources per worker: 2 vCPU, 4GB RAM

Event persisters: 2 instances
  Resources per worker: 4 vCPU, 6GB RAM

Federation senders: 4 instances
  Resources per worker: 2 vCPU, 3GB RAM

Total Synapse Processes: 19
```

**PostgreSQL:**
```yaml
Instances: 3 (1 primary + 2 replicas)
Resources per instance: 32 vCPU, 128GB RAM
Storage per instance: 4TB NVMe

Configuration:
  max_connections: 500
  shared_buffers: 32GB
  effective_cache_size: 96GB
  maintenance_work_mem: 8GB
  work_mem: 50MB

Synapse connection pool (cp_max):
  Main process: 20
  Each worker: 15
  Total: 20 + (15 × 18) = 290 connections < 500 × 0.85 = 425 ✓
```

**Redis:**
```yaml
Synapse Redis:
  Instances: 3
  Resources per instance: 8 vCPU, 16GB RAM

LiveKit Redis:
  Instances: 3
  Resources per instance: 4 vCPU, 8GB RAM
```

**MinIO:**
```yaml
Pool 1: 4 nodes, 16 vCPU, 32GB RAM, 4TB HDD each
Pool 2: 4 nodes, 16 vCPU, 32GB RAM, 4TB HDD each
Total: 8 nodes
Erasure Coding: EC:4 per pool
Usable capacity: ~8TB total

Expected usage:
  Year 1: ~20TB (will need third pool)
```

**LiveKit:**
```yaml
Instances: 4 (HA + performance)
Resources per instance: 16 vCPU, 32GB RAM

Capacity: ~2000 concurrent call participants per instance
Expected load: 500-1,000 participants (12-25% utilization)
```

**coturn:**
```yaml
Instances: 4 (HA + performance)
Resources per instance: 16 vCPU, 16GB RAM

Capacity: ~8000 concurrent allocations per instance
Expected load: 6,000 allocations (18% utilization)
```

### 6.3 Configuration Parameters

**Synapse (homeserver.yaml):**
```yaml
database:
  args:
    cp_min: 5
    cp_max: 20  # Main process

# Workers use cp_max: 15

caches:
  global_factor: 3.0

event_cache_size: 30K

max_upload_size: 100M  # Maximum file size for media uploads (images, documents, etc.)

rate_limiting:
  rc_message:
    per_second: 20
    burst_count: 100

federation:
  max_concurrent_requests: 30
```

**PostgreSQL Tuning:**
```sql
max_connections = 500
shared_buffers = 32GB
effective_cache_size = 96GB
maintenance_work_mem = 8GB
work_mem = 50MB
max_wal_size = 32GB
checkpoint_completion_target = 0.9
autovacuum_max_workers = 8
autovacuum_naptime = 20s
```

---

## 7. 20,000 CCU Scale

### 7.1 Use Case Profile

**Typical Deployments:**
- Large enterprise organizations (10,000+ employees)
- National educational systems
- Large service providers
- Major public community platforms

**Expected Activity:**
- Peak concurrent users: 20,000
- Active messaging users at peak: 14,000-16,000
- Messages per minute: 28,000-80,000
- Media uploads per hour: 2,000-4,000 files
- Concurrent calls at peak: 1,000-2,000 users in calls
- Rooms: 10,000-20,000 active rooms

### 7.2 Infrastructure Sizing

#### Server Inventory

| Role | Count | CPU | RAM | Storage | Purpose |
|------|-------|-----|-----|---------|---------|
| **Control Plane** | 3 | 8 vCPU | 16GB | 200GB SSD | Kubernetes masters |
| **Application Nodes** | 21 | 32 vCPU | 128GB | 2TB SSD | Synapse, monitoring |
| **Database Nodes** | 5 | 32 vCPU | 128GB | 4TB NVMe | PostgreSQL (1 primary + 4 replicas) |
| **Storage Nodes** | 12 | 16 vCPU | 32GB | 4TB HDD | MinIO (3 pools of 4) |
| **Call Servers** | 10 | 16 vCPU | 32GB | 200GB SSD | LiveKit + coturn (5+5) |
| **Total Servers** | **51** | | | | |

**Total Resources:**
- vCPU: 1,024 cores (1.0TB)
- RAM: 3,712GB (3.6TB)
- Storage: 63.6TB (12TB usable for media)

#### Component Configuration

**Synapse:**
```yaml
Main process: 1 instance
  Resources: 4 vCPU, 16GB RAM

Sync workers: 18 instances
  Resources per worker: 2 vCPU, 4GB RAM
  Handles: ~1,111 users each

Generic workers: 8 instances
  Resources per worker: 2 vCPU, 4GB RAM

Event persisters: 4 instances
  Resources per worker: 4 vCPU, 6GB RAM

Federation senders: 8 instances
  Resources per worker: 2 vCPU, 3GB RAM

Total Synapse Processes: 39
```

**PostgreSQL:**
```yaml
Instances: 5 (1 primary + 4 replicas)
Resources per instance: 32 vCPU, 128GB RAM
Storage per instance: 4TB NVMe

Configuration:
  max_connections: 600
  shared_buffers: 32GB
  effective_cache_size: 96GB
  maintenance_work_mem: 8GB
  work_mem: 64MB

Synapse connection pool (cp_max):
  Main process: 25
  Each worker: 15
  Total: 25 + (15 × 38) = 595 connections < 600 × 0.85 = 510

  **NOTE:** This is at limit. Consider:
  - Reducing worker cp_max to 12 → Total: 25 + (12 × 38) = 481 ✓
  - Or increasing max_connections to 700
```

**Redis:**
```yaml
Synapse Redis:
  Instances: 3
  Resources per instance: 8 vCPU, 24GB RAM

LiveKit Redis:
  Instances: 3
  Resources per instance: 4 vCPU, 12GB RAM
```

**MinIO:**
```yaml
Pool 1: 4 nodes, 16 vCPU, 32GB RAM, 4TB HDD each
Pool 2: 4 nodes, 16 vCPU, 32GB RAM, 4TB HDD each
Pool 3: 4 nodes, 16 vCPU, 32GB RAM, 4TB HDD each
Total: 12 nodes
Erasure Coding: EC:4 per pool
Usable capacity: ~12TB total

Expected usage:
  Year 1: ~40TB (will need pools 4-5)
```

**LiveKit:**
```yaml
Instances: 5 (HA + performance)
Resources per instance: 16 vCPU, 32GB RAM

Capacity: ~2000 concurrent call participants per instance
Expected load: 1,000-2,000 participants (10-20% utilization)
```

**coturn:**
```yaml
Instances: 5 (HA + performance)
Resources per instance: 16 vCPU, 16GB RAM

Capacity: ~8000 concurrent allocations per instance
Expected load: 12,000 allocations (30% utilization)
```

### 7.3 Configuration Parameters

**Synapse (homeserver.yaml):**
```yaml
database:
  args:
    cp_min: 5
    cp_max: 25  # Main process

# Workers use cp_max: 12 (adjusted to stay under connection limit)

caches:
  global_factor: 4.0

event_cache_size: 50K

max_upload_size: 100M  # Maximum file size for media uploads (images, documents, etc.)

rate_limiting:
  rc_message:
    per_second: 25
    burst_count: 150

federation:
  max_concurrent_requests: 50
```

**PostgreSQL Tuning:**
```sql
max_connections = 600
shared_buffers = 32GB
effective_cache_size = 96GB
maintenance_work_mem = 8GB
work_mem = 64MB
max_wal_size = 64GB
checkpoint_completion_target = 0.9
autovacuum_max_workers = 10
autovacuum_naptime = 15s
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.025
```

---

## 8. Scaling Decision Matrix

### 8.1 Quick Reference Table

| Scale | Servers | Total vCPU | Total RAM | Usable Storage |
|-------|---------|------------|-----------|----------------|
| **100 CCU** | 15 | 92 | 180GB | 1TB |
| **1K CCU** | 19 | 228 | 468GB | 2TB |
| **5K CCU** | 24 | 448 | 1,056GB | 4TB |
| **10K CCU** | 34 | 704 | 2,144GB | 8TB |
| **20K CCU** | 51 | 1,024 | 3,712GB | 12TB |

### 8.2 When to Scale Up

**Signs you need to move to next scale tier:**

| Indicator | Threshold | Action |
|-----------|-----------|--------|
| **Average CCU** | >70% of current tier | Plan upgrade to next tier |
| **Peak CCU** | >90% of current tier | Urgent: Plan immediate upgrade |
| **CPU Usage** | >75% sustained | Add workers or upgrade nodes |
| **Memory Usage** | >85% sustained | Upgrade node RAM |
| **Database Connections** | >70% of max_connections | Add workers or scale database |
| **Storage Growth** | < capacity remaining | Add MinIO pool |
| **Message Latency** | >500ms p99 | Add sync workers |
| **Call Quality Issues** | >5% call failures | Add LiveKit/coturn instances |

### 8.3 Scaling Paths

**Vertical Scaling (Within Tier):**
- Increase CPU/RAM on existing nodes
- Expand storage capacity
- Optimize configurations

**Horizontal Scaling (To Next Tier):**
- Add more worker replicas
- Add database read replicas
- Add MinIO pools
- Add call server instances

**Example: 800 CCU on 1,000 CCU infrastructure**
- Current: 4 sync workers
- Add: 2 more sync workers (total 6)
- Adjust: Increase database shared_buffers
- Monitor: Plan full upgrade to 5K tier when approaching 900 CCU

---

## 9. Configuration Parameters by Scale

### 9.1 Synapse Worker Configuration

| Scale | Sync Workers | Generic Workers | Event Persisters | Federation Senders | Total Processes |
|-------|--------------|-----------------|------------------|-------------------|-----------------|
| **100 CCU** | 2 | 2 | 2 | 2 | 9 |
| **1K CCU** | 4 | 2 | 2 | 2 | 11 |
| **5K CCU** | 6 | 4 | 2 | 4 | 17 |
| **10K CCU** | 8 | 4 | 2 | 4 | 19 |
| **20K CCU** | 18 | 8 | 4 | 8 | 39 |

### 9.2 Database Connection Pools

| Scale | Main cp_max | Worker cp_max | Total Connections | PostgreSQL max_connections |
|-------|-------------|---------------|-------------------|----------------------------|
| **100 CCU** | 10 | 8 | 74 | 200 |
| **1K CCU** | 15 | 12 | 135 | 300 |
| **5K CCU** | 18 | 12 | 210 | 400 |
| **10K CCU** | 20 | 15 | 290 | 500 |
| **20K CCU** | 25 | 12 | 481 | 600 |

**Formula:**
```
Total Connections = main_cp_max + (worker_cp_max × number_of_workers)
Must be < (max_connections × 0.85)
```

### 9.3 Cache and Memory Settings

| Scale | Synapse global_factor | Event Cache | PostgreSQL shared_buffers | Redis RAM (Synapse) |
|-------|----------------------|-------------|---------------------------|---------------------|
| **100 CCU** | 0.5 | 5K | 4GB | 2GB |
| **1K CCU** | 1.0 | 10K | 8GB | 4GB |
| **5K CCU** | 2.0 | 20K | 16GB | 8GB |
| **10K CCU** | 3.0 | 30K | 32GB | 16GB |
| **20K CCU** | 4.0 | 50K | 32GB | 24GB |

### 9.4 Rate Limiting

| Scale | Messages per_second | Messages burst_count | Federation max_concurrent |
|-------|---------------------|---------------------|---------------------------|
| **100 CCU** | 5 | 25 | 5 |
| **1K CCU** | 10 | 50 | 10 |
| **5K CCU** | 15 | 75 | 20 |
| **10K CCU** | 20 | 100 | 30 |
| **20K CCU** | 25 | 150 | 50 |

---

## 10. Media Storage Planning

### 10.1 Storage Growth Model

**Assumptions (Conservative):**
- 10% of users actively upload files
- Average 20GB per active uploader per year
- Mix: 70% images, 20% documents, 10% video/audio

**Formula:**
```
Annual Storage Growth = CCU × 10% × 20GB
```

### 10.2 Storage Requirements by Scale

| Scale | Active Uploaders | Year 1 Growth | Year 2 Total | Year 3 Total | Initial Provision |
|-------|-----------------|---------------|--------------|--------------|-------------------|
| **100 CCU** | 10 | 200GB | 400GB | 600GB | 1TB |
| **1K CCU** | 100 | 2TB | 4TB | 6TB | 2TB (expand Y1) |
| **5K CCU** | 500 | 10TB | 20TB | 30TB | 4TB (add pool Q2) |
| **10K CCU** | 1,000 | 20TB | 40TB | 60TB | 8TB (add pool Q2) |
| **20K CCU** | 2,000 | 40TB | 80TB | 120TB | 12TB (add 2 pools Y1) |

### 10.3 MinIO Sizing

**Erasure Coding Overhead:**
- EC:4 = 100% overhead (4 data + 4 parity = 8 total drives for 4 drives usable)
- Usable capacity = Raw capacity × 50%

**Pool Expansion Timeline:**

**5,000 CCU Example:**
- **Initial:** 1 pool (4 nodes × 4TB) = 4TB usable
- **Month 6:** Add pool 2 = 8TB usable
- **Month 12:** Add pool 3 = 12TB usable
- **Year 2:** Usage ~20TB, need pools 4-5

**20,000 CCU Example:**
- **Initial:** 3 pools = 12TB usable
- **Quarter 2:** Add pool 4 = 16TB usable
- **Quarter 3:** Add pool 5 = 20TB usable
- **Quarter 4:** Add pool 6 = 24TB usable
- **Year 2:** Usage ~80TB, need pools 7-20

### 10.4 Media Retention Policies

**Recommended:**
- Local cache:  (Synapse media_retention)
- MinIO (S3): Permanent (unless explicitly deleted)
- Backup:  rolling

**Configuration:**
```yaml
# In homeserver.yaml
media_retention:
  local_media_lifetime: 30d  # How long to keep local media files cached on disk before deletion
  # Files remain in MinIO (S3) permanently unless explicitly deleted
  remote_media_lifetime: 14d
```

### 10.5 Bandwidth Planning for Media

| Scale | Avg Media Upload | Peak Media Upload | Required Bandwidth |
|-------|------------------|-------------------|-------------------|
| **100 CCU** | 2 Mbps | 10 Mbps | 100 Mbps uplink |
| **1K CCU** | 20 Mbps | 100 Mbps | 500 Mbps uplink |
| **5K CCU** | 100 Mbps | 500 Mbps | 2 Gbps uplink |
| **10K CCU** | 200 Mbps | 1 Gbps | 5 Gbps uplink |
| **20K CCU** | 400 Mbps | 2 Gbps | 10 Gbps uplink |

---

## 11. Voice/Video Call Infrastructure

### 11.1 Call Patterns

**Typical Distribution:**
- 1-on-1 calls: 70% of calls
- Small group (3-5 users): 20% of calls
- Large group (6-10 users): 8% of calls
- Conference (10+ users): 2% of calls

**Concurrent Call Assumptions:**
- 10% of CCU in calls at peak
- Average call duration: 
- Peak hours: 10 AM - 4 PM

### 11.2 LiveKit Capacity Planning

**Single Instance Capacity (16 vCPU, 32GB RAM):**
- 1-on-1 calls: ~1,000 concurrent calls (2,000 participants)
- Group calls (5 users): ~200 concurrent calls (1,000 participants)
- Conference calls (10 users): ~100 concurrent calls (1,000 participants)

**Bottleneck:** CPU for media forwarding, network bandwidth

**Instances Required by Scale:**

| Scale | Peak Call Participants | Instances Needed | Reasoning |
|-------|----------------------|------------------|-----------|
| **100 CCU** | 10 | 2 (HA minimum) | <1% utilization |
| **1K CCU** | 100 | 2 (HA minimum) | ~5% utilization |
| **5K CCU** | 500 | 3 | ~15% utilization |
| **10K CCU** | 1,000 | 4 | ~25% utilization |
| **20K CCU** | 2,000 | 5 | ~40% utilization |

### 11.3 coturn Capacity Planning

**Single Instance Capacity (8 vCPU, 8GB RAM):**
- Concurrent allocations: ~4,000
- Typical allocations per call participant: 4 (audio in/out, video in/out)

**Allocation Requirements:**
- 15% of CCU need TURN relay (behind NAT/firewall)
- Each participant uses 4 allocations

**Instances Required by Scale:**

| Scale | TURN Users | Total Allocations | Instances Needed |
|-------|-----------|-------------------|------------------|
| **100 CCU** | 15 | 60 | 2 (HA minimum) |
| **1K CCU** | 150 | 600 | 2 (HA minimum) |
| **5K CCU** | 750 | 3,000 | 3 |
| **10K CCU** | 1,500 | 6,000 | 4 |
| **20K CCU** | 3,000 | 12,000 | 5 |

### 11.4 Call Quality Metrics

**Monitoring Thresholds:**
- Packet loss: <1% acceptable, >3% poor
- Jitter: <30ms acceptable, >50ms poor
- Latency: <150ms acceptable, >300ms poor
- CPU usage: <70% normal, >85% add capacity

**When to Scale Call Infrastructure:**
- CPU usage >70% sustained
- Call failure rate >2%
- Poor quality reports from users
- Approaching capacity limits

### 11.5 Bandwidth Requirements for Calls

**Per Call Participant:**
- Audio only: 50-100 Kbps
- Video SD (480p): 500 Kbps - 1 Mbps
- Video HD (720p): 1.5 - 3 Mbps
- Screen share: 500 Kbps - 2 Mbps

**Aggregate Bandwidth by Scale:**

| Scale | Concurrent Calls | Video Calls | Audio Only | Total Bandwidth Needed |
|-------|-----------------|------------|------------|----------------------|
| **100 CCU** | 5 calls (10 users) | 3 | 2 | ~20 Mbps |
| **1K CCU** | 50 calls (100 users) | 30 | 20 | ~200 Mbps |
| **5K CCU** | 250 calls (500 users) | 150 | 100 | ~1 Gbps |
| **10K CCU** | 500 calls (1,000 users) | 300 | 200 | ~2 Gbps |
| **20K CCU** | 1,000 calls (2,000 users) | 600 | 400 | ~4 Gbps |

---

## Summary

### Key Takeaways

1. **Architecture is consistent across all scales** - Only numbers change
2. **HA is maintained at all scales** - Minimum 2 instances of each component
3. **Plan for growth** - Provision  ahead
4. **Monitor continuously** - Use thresholds to trigger scaling actions
5. **Storage grows fastest** - Plan MinIO pool expansions quarterly
6. **Database is critical** - Connection pool tuning is essential
7. **Calls need dedicated resources** - LiveKit and coturn scale separately

### Scaling Checklist

Before deploying at any scale:
- [ ] Verify hardware meets requirements for your scale
- [ ] Calculate database connection pools correctly
- [ ] Plan storage expansion for 2 years
- [ ] Configure monitoring with scale-appropriate thresholds
- [ ] Test failover procedures at your scale
- [ ] Document your specific configuration
- [ ] Plan capacity review schedule (quarterly recommended)

### Getting Help with Scaling

**If between scales (e.g., 3,000 CCU):**
1. Start with configuration for lower tier (1K)
2. Gradually add workers as you approach capacity
3. Monitor metrics to identify bottlenecks
4. Upgrade to next tier (5K) when consistently hitting limits

**Resource:** 

---


