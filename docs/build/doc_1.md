# Matrix/Synapse Production HA Deployment - Architecture & Planning
## Document 1: Architecture & Planning (Large Scale - 10,000 CCU)

**Version:** 3.2 FINAL - Routing Clarification  
**Target Scale:** 10,000 concurrent users  
**Last Updated:** November 2025  
**Domain Example:** chat.z3r0d3v.com

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Network Topology](#network-topology)
4. [Server Specifications](#server-specifications)
5. [IP Address Planning](#ip-address-planning)
6. [Port Requirements](#port-requirements)
7. [Data Flow Diagram](#data-flow-diagram)
8. [Scaling Considerations](#scaling-considerations)
9. [High Availability Strategy](#high-availability-strategy)

---

## 1. Executive Summary

This document describes the production architecture for a Matrix/Synapse messenger deployment targeting **10,000 concurrent users** (Large Scale). The architecture emphasizes:

- **High Availability**: No single point of failure for critical services
- **Scalability**: Horizontal scaling through worker distribution and database clustering
- **Performance**: Optimized for 50K-100K messages/day and 200-500GB media uploads/day
- **Reliability**: Multiple failover mechanisms and automated recovery
- **Federation Disabled**: Optimized resource allocation without federation overhead
- **Intranet Operation**: Post-deployment operation without internet dependency
- **Proper UDP Handling**: Direct access for TURN/LiveKit media traffic

### Key Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **Patroni for PostgreSQL HA** | Industry-standard HA solution with automatic failover (10-30s RTO) |
| **MinIO for Media Storage** | S3-compatible, distributed erasure coding (EC:4), survives 1 node failure |
| **HAProxy + Keepalived** | VIP failover for HTTP/HTTPS load balancing only |
| **Direct TURN/LiveKit Access** | UDP media traffic bypasses HAProxy entirely |
| **Specialized Workers** | Better cache locality vs generic workers |
| **PgBouncer Connection Pooling** | Transaction-mode pooling, **small pool sizes per process** |
| **pgBackRest for Backups** | Incremental backups, parallel operations, PITR support |
| **Split-Horizon DNS** | Servers use /etc/hosts, clients use proper DNS for UDP services |

---

## 2. Architecture Overview

### 2.1 High-Level Architecture

```
                                  Internet (Initial Setup Only)
                                           |
                                           | (Cut after deployment)
                                           v
                            ┌──────────────────────────┐
                            │  HAProxy VIP (Keepalived)│
                            │   10.0.1.10 (Virtual IP) │
                            │   HTTPS/HTTP ONLY        │
                            └──────────────────────────┘
                                       |
                    ┌──────────────────┴──────────────────┐
                    |                                     |
              ┌─────▼─────┐                       ┌──────▼──────┐
              │ HAProxy-1 │                       │  HAProxy-2  │
              │ 10.0.1.11 │                       │  10.0.1.12  │
              └───────────┘                       └─────────────┘
                    |                                     |
      ┌─────────────┼─────────────┬──────────────────────┘
      |             |             |
  [Synapse]   [PostgreSQL]   [MinIO]
  Workers     3-node          4-node
  (Main+18)   Patroni         Cluster
              + PgBouncer
              + DB VIP
              
  [Coturn TURN Servers]        [LiveKit + JWT Service]
  DIRECT ACCESS via            DIRECT ACCESS for UDP
  Client DNS Resolution        RTC Ports (7882, 50100-50200)
  Ports: 3478, 5349           HTTP/WS via HAProxy (7880, 8080)
  49152-65535 UDP             
```

**CRITICAL UDP ARCHITECTURE NOTE:**
- HAProxy handles **HTTP/HTTPS traffic ONLY**
- TURN servers (Coturn) are accessed **DIRECTLY** by clients via DNS
- LiveKit UDP ports (7882, 50100-50200) are accessed **DIRECTLY** by clients
- LiveKit HTTP/WebSocket (7880, 8080) goes through HAProxy for control plane
- Clients MUST resolve `coturn1/2.chat.z3r0d3v.com` to actual TURN server IPs
- Clients MUST resolve `livekit.chat.z3r0d3v.com` to actual LiveKit server IP for UDP

### 2.2 Service Topology

The deployment consists of **18 servers total** organized into the following service groups:

#### Application Layer (1 server)
- **Synapse Server**: Main process + 18 workers
  - 8× Sync workers (client synchronization)
  - 4× Client reader workers (API requests - specialized preset)
  - 4× Federation senders (disabled but configured for future)
  - 2× Event persisters (database writes)
  - Traefik reverse proxy (internal routing, **bound to network interface**)
  - Element Web client (**served on base domain: chat.z3r0d3v.com**)
  - **Synapse Admin UI** (deployed via playbook, **accessible on matrix subdomain**)
  - Valkey (single instance for caching)

#### Database Layer (3 servers + DB VIP)
- **Patroni PostgreSQL Cluster**: 3-node HA cluster
  - etcd embedded for DCS (Distributed Configuration Store)
  - Automatic leader election and failover
  - Streaming replication (synchronous)
  - **PgBouncer connection pooling (transaction mode)** - all instances point to writer VIP
  - **HAProxy for DB writer VIP (10.0.3.10)** - routes writes to current Patroni primary only
  - **Small connection pools per process** to avoid exhaustion

**Database Architecture:**
- Each Patroni node runs PgBouncer locally
- **All PgBouncer instances connect to DB writer VIP (10.0.3.10:5432)**, NOT to localhost
- HAProxy for DB VIP uses Patroni `/master` health check endpoint
- HAProxy marks replica nodes as `backup` to prevent write routing to read-only nodes
- This ensures writes always go to the current Patroni primary, even after failover

#### Storage Layer (4 servers + S3 VIP)
- **MinIO Distributed Cluster**: 4-node erasure-coded storage
  - 16 drives total (4 per node)
  - EC:4 parity (survives loss of 1 complete node or 4 drives)
  - 75% usable capacity of raw storage
  - S3-compatible API for media storage
  - **HAProxy for S3 VIP (10.0.4.10)** - load balances across MinIO nodes

#### Load Balancer Layer (2 servers)
- **HAProxy + Keepalived**: Active-passive pair
  - Virtual IP (VIP) for single entry point
  - Automatic failover via VRRP
  - TLS termination
  - **HTTP/HTTPS/WebSocket traffic ONLY**
  - Health checks for Synapse workers
  - **Reverse proxy for .well-known files from matrix subdomain**
  - **Does NOT proxy UDP traffic**
  - **Secure X-Forwarded-For handling** (strips forged headers)

#### WebRTC Layer (4 servers)
- **Coturn TURN Servers**: 2 servers
  - **DIRECTLY accessible by clients via DNS**
  - UDP/TCP relay for NAT traversal
  - Static auth via shared secret
  - **Clients resolve coturn1/2.chat.z3r0d3v.com to actual IPs**
  - **UDP ports 3478, 5349, 49152-65535 must be directly accessible**
  - **NO HAProxy in the path for TURN traffic**

- **LiveKit SFU + JWT Service**: 1 dedicated server
  - LiveKit for multi-party video conferencing
  - **HTTP/WebSocket control plane (7880, 8080) via HAProxy**
  - **UDP RTC ports (7882, 50100-50200) DIRECTLY accessible**
  - **Clients must resolve livekit.chat.z3r0d3v.com to actual IP for UDP**
  - **lk-jwt-service for authentication** (CRITICAL for Element Call)
  - Redis for cluster coordination
  - Element Call integration via MatrixRTC

- **Redis Server**: 1 dedicated server (can be co-located with LiveKit)
  - Coordination for LiveKit cluster
  - Pub/sub for room state

#### Operational Services (2 servers)
- **Monitoring Server**: 1 dedicated server
  - Prometheus + Grafana
  - Node exporters on all servers
  - PostgreSQL exporter
  - **Scrapes Synapse metrics via HTTPS paths** (no port conflict)

- **Backup Server**: 1 dedicated server
  - pgBackRest repository
  - Media rsync target
  - Backup orchestration scripts
  - 360-day retention

---

## 3. Network Topology

### 3.1 Network Architecture

All servers reside on a **private network** with the following characteristics:

- **Initial Phase**: Internet access for software installation and certificate acquisition
- **Operational Phase**: No internet access; all communication via private IPs
- **DNS Resolution**: 
  - **Servers**: `/etc/hosts` on all servers (no DNS server required)
  - **Clients**: Proper DNS records pointing to actual service IPs for UDP services
- **Entry Point**: HAProxy VIP (10.0.1.10) **for HTTP/HTTPS ONLY**
- **Security**: Private network isolation, no public IPs in production

### 3.2 Critical DNS/Network Pattern

**SERVERS (use /etc/hosts)**:
- All servers use /etc/hosts for name resolution
- This is for server-to-server communication
- HAProxy VIP used for HTTP/HTTPS services

**CLIENTS (require proper DNS)**:
- Clients CANNOT use the same /etc/hosts pattern
- Clients need proper DNS records:
  - `chat.z3r0d3v.com` → HAProxy VIP (10.0.1.10) - for HTTPS
  - `matrix.chat.z3r0d3v.com` → HAProxy VIP (10.0.1.10) - for HTTPS  
  - **`coturn1.chat.z3r0d3v.com` → 10.0.5.11** (TURN server 1 DIRECT)
  - **`coturn2.chat.z3r0d3v.com` → 10.0.5.12** (TURN server 2 DIRECT)
  - **`livekit.chat.z3r0d3v.com` → 10.0.5.21** (LiveKit DIRECT for UDP)

**Why This Matters**:
- UDP traffic for TURN media relay MUST reach TURN servers directly
- UDP traffic for LiveKit RTC MUST reach LiveKit server directly
- HAProxy cannot proxy UDP in the way needed for WebRTC
- This is not optional - UDP media will fail without direct access

### 3.3 Network Segments

```
Management Network:   10.0.0.0/24
  - SSH access
  - Management tools

Load Balancer Network: 10.0.1.0/24
  - HAProxy nodes
  - VIP address (HTTP/HTTPS only)

Application Network:   10.0.2.0/24
  - Synapse server
  - Traefik

Database Network:      10.0.3.0/24
  - Patroni nodes
  - etcd cluster
  - PgBouncer instances
  - DB writer VIP (10.0.3.10)
  - DB PgBouncer VIP (10.0.3.10:6432)

Storage Network:       10.0.4.0/24
  - MinIO nodes
  - S3 VIP (10.0.4.10)
  - High bandwidth requirements

WebRTC Network:        10.0.5.0/24
  - Coturn servers (DIRECT client access)
  - LiveKit node (DIRECT client access for UDP)
  - Redis (LiveKit coordination)

Service Network:       10.0.6.0/24
  - Monitoring
  - Backup server
```

### 3.4 Traffic Flow

1. **User HTTP Request** → HAProxy VIP (10.0.1.10)
2. **HAProxy** → Load balances to Traefik on Synapse server (10.0.2.10:81)
3. **Traefik** → Routes to Synapse workers internally
4. **Synapse** → PgBouncer (any node:6432) → DB Writer VIP (10.0.3.10:5432) → HAProxy → Patroni primary
5. **Synapse** → MinIO VIP (10.0.4.10) for media storage/retrieval
6. **Element Call Control** → HAProxy → JWT service (8080) → LiveKit HTTP (7880)
7. **Voice/Video TURN** → **DIRECT to Coturn servers** (3478/5349 + relay ports)
8. **LiveKit UDP Media** → **DIRECT to LiveKit server** (7882, 50100-50200)
9. **Monitoring** → Prometheus scrapes metrics via HTTPS paths through HAProxy
10. **Backup** → pgBackRest pulls from Patroni replica, rsync pulls media
11. **.well-known Discovery** → HAProxy reverse proxies from matrix subdomain

---

## 4. Server Specifications

### 4.1 Large Scale (10,000 CCU) Specifications

#### Synapse Application Server
- **Quantity**: 1
- **vCPU**: 48
- **RAM**: 128 GB
- **Storage**: 2 TB NVMe SSD
- **Network**: 10 Gbps
- **OS**: Debian 12 (Bookworm)
- **Role**: Synapse main + 18 workers, Traefik, Element Web, Valkey

**Rationale**: 
- 48 vCPU supports 18 workers + main process with headroom
- 128 GB RAM for caching (cache_factor=10: ~6.5GB per process × 19 = ~124GB)
- 2 TB for local temp storage, logs, Docker volumes

**Services on this server**:
- Synapse (main + workers) via playbook
- Traefik (reverse proxy, **bound to 10.0.2.10:81** for HAProxy access)
- Element Web client (**served on chat.z3r0d3v.com**)
- **Synapse Admin UI**: Web-based management interface
  - Accessible at `https://matrix.chat.z3r0d3v.com/synapse-admin`
  - **IP-restricted to admin networks only**
  - Used for user management, room administration, server stats
- Valkey (Redis-compatible cache)
- Node exporter for monitoring

#### Patroni PostgreSQL Nodes (×3)
- **Quantity**: 3
- **vCPU**: 16 each
- **RAM**: 64 GB each
- **Storage**: 1 TB NVMe SSD each
- **Network**: 10 Gbps
- **OS**: Debian 12 (Bookworm)
- **Role**: PostgreSQL 16 + Patroni + etcd + PgBouncer

**Rationale**:
- 16 vCPU for complex query processing and vacuum operations
- 64 GB RAM: `shared_buffers=16GB`, `effective_cache_size=48GB`
- 1 TB storage for database growth (100-500GB expected + WAL + backups)
- 3 nodes minimum for etcd quorum and replication

**CRITICAL Configuration**:
- Each node runs PgBouncer that connects to **DB writer VIP (10.0.3.10:5432)**
- PgBouncer does NOT connect to localhost PostgreSQL
- This ensures writes always route to current Patroni primary
- HAProxy at 10.0.3.10 uses `/master` health check to identify primary
- **Small connection pool sizes** to avoid exhaustion (default_pool_size: 50)

#### Database HAProxy Nodes (×2, reuse Patroni nodes 1-2)
- **Role**: HAProxy for DB writer VIP + Keepalived
- **VIP**: 10.0.3.10 (PostgreSQL writes port 5432, PgBouncer port 6432)
- **Health Check**: Patroni `/master` endpoint on port 8008
- **Configuration**: Primary server active, replicas marked as `backup`
- **Purpose**: Route all writes to current Patroni primary only

#### MinIO Storage Nodes (×4)
- **Quantity**: 4
- **vCPU**: 8 each
- **RAM**: 32 GB each
- **Storage**: 8 TB each (4 drives × 2TB per node = 32TB raw, 24TB usable)
- **Network**: 10 Gbps (high bandwidth critical)
- **OS**: Debian 12 (Bookworm)
- **Role**: MinIO distributed object storage

**Rationale**:
- 8 vCPU for parallel I/O operations
- 32 GB RAM for caching and metadata
- 8 TB per node: Handles 200-500GB/day × 30-60 days with headroom
- 4 nodes minimum for erasure coding (EC:4)

#### MinIO HAProxy Nodes (×2, reuse MinIO nodes 1-2)
- **Role**: HAProxy for S3 VIP + Keepalived
- **VIP**: 10.0.4.10 (S3 API port 9000)
- **Load Balancing**: Round-robin across all MinIO nodes
- **Purpose**: Single endpoint for S3 API access

#### HAProxy + Keepalived Nodes (×2)
- **Quantity**: 2
- **vCPU**: 4 each
- **RAM**: 8 GB each
- **Storage**: 100 GB SSD each
- **Network**: 10 Gbps
- **OS**: Debian 12 (Bookworm)
- **Role**: HAProxy load balancer + Keepalived for VIP
- **Scope**: **HTTP/HTTPS/WebSocket ONLY** - does NOT handle UDP
- **Security**: Strips forged X-Forwarded-For headers from clients

**Rationale**:
- 4 vCPU sufficient for TLS termination and load balancing
- 8 GB RAM for connection states
- Minimal storage requirements

#### Coturn TURN Servers (×2)
- **Quantity**: 2
- **vCPU**: 8 each
- **RAM**: 16 GB each
- **Storage**: 100 GB SSD each
- **Network**: 5 Gbps (high bandwidth for relayed media)
- **OS**: Debian 12 (Bookworm)
- **Role**: TURN relay for WebRTC NAT traversal
- **Access**: **DIRECT from clients via DNS** - NOT through HAProxy
- **DNS Required**: `coturn1.chat.z3r0d3v.com`, `coturn2.chat.z3r0d3v.com`
- **Ports**: 3478 (TCP/UDP), 5349 (TCP/UDP), 49152-65535 (UDP)

**Rationale**:
- 8 vCPU for handling many concurrent relay sessions
- 16 GB RAM for session state
- High bandwidth essential for media relay
- **MUST be directly accessible** - UDP relay cannot go through HTTP proxy
- **Hostnames required for TURN over TLS** (`turns:` URIs must match certificate)

#### LiveKit + JWT Service Server (×1)
- **Quantity**: 1 (consolidated for simplicity)
- **vCPU**: 16
- **RAM**: 32 GB
- **Storage**: 100 GB SSD
- **Network**: 5 Gbps
- **OS**: Debian 12 (Bookworm)
- **Role**: LiveKit SFU + lk-jwt-service authentication bridge
- **Access**: 
  - HTTP/WebSocket (7880, 8080): via HAProxy
  - **UDP RTC (7882, 50100-50200): DIRECT from clients**
- **DNS Required**: `livekit.chat.z3r0d3v.com` must resolve to actual IP

**Rationale**:
- 16 vCPU for transcoding and mixing multiple streams
- 32 GB RAM for media buffers
- Consolidated deployment simplifies management
- **JWT service is CRITICAL** - without it, Element Call cannot authenticate
- **UDP ports MUST be directly accessible** - cannot go through HTTP proxy

#### Redis Coordination Server (×1)
- **Quantity**: 1 (can be co-located with LiveKit if needed)
- **vCPU**: 4
- **RAM**: 8 GB
- **Storage**: 50 GB SSD
- **Network**: 1 Gbps
- **OS**: Debian 12 (Bookworm)
- **Role**: Redis for LiveKit cluster coordination

**Rationale**:
- 4 vCPU sufficient for coordination workload
- 8 GB RAM for in-memory data structures
- Handles room state and pub/sub for LiveKit cluster

#### Monitoring Server
- **Quantity**: 1
- **vCPU**: 8
- **RAM**: 32 GB
- **Storage**: 500 GB SSD
- **Network**: 1 Gbps
- **OS**: Debian 12 (Bookworm)
- **Role**: Prometheus + Grafana + Exporters

**Rationale**:
- 8 vCPU for metric processing
- 32 GB RAM for Prometheus time-series data
- 500 GB for metric retention (30-90 days)
- **Scrapes Synapse metrics via HTTPS paths** (no port conflicts)

#### Backup Server
- **Quantity**: 1
- **vCPU**: 8
- **RAM**: 32 GB
- **Storage**: 5 TB SSD
- **Network**: 10 Gbps (for large data transfers)
- **OS**: Debian 12 (Bookworm)
- **Role**: pgBackRest repository + media backups

**Rationale**:
- 8 vCPU for backup compression and processing
- 32 GB RAM for efficient rsync and pgBackRest operations
- 5 TB storage: 360-day retention for DB backups + incremental media backups

---

## 5. IP Address Planning

### 5.1 IP Address Schema

The following IP addressing scheme is used throughout this documentation. **REPLACE ALL IPs** with your actual private network addresses.

#### Load Balancer Network (10.0.1.0/24)
```
10.0.1.10   haproxy-vip                # CHANGE_TO_YOUR_VIP (HTTP/HTTPS only)
10.0.1.11   haproxy1.internal          # CHANGE_TO_YOUR_HAPROXY1_IP
10.0.1.12   haproxy2.internal          # CHANGE_TO_YOUR_HAPROXY2_IP
```

#### Application Network (10.0.2.0/24)
```
10.0.2.10   synapse.internal           # CHANGE_TO_YOUR_SYNAPSE_IP
```

#### Database Network (10.0.3.0/24)
```
10.0.3.10   patroni-vip.internal       # CHANGE_TO_YOUR_DB_VIP (HAProxy for DB writes)
10.0.3.11   patroni1.internal          # CHANGE_TO_YOUR_PATRONI1_IP
10.0.3.12   patroni2.internal          # CHANGE_TO_YOUR_PATRONI2_IP
10.0.3.13   patroni3.internal          # CHANGE_TO_YOUR_PATRONI3_IP
```

**Database VIP Notes**:
- 10.0.3.10:5432 - PostgreSQL writes (HAProxy routes to current Patroni primary only)
- 10.0.3.10:6432 - PgBouncer access (load-balanced across all nodes)
- All PgBouncer instances connect to 10.0.3.10:5432 internally
- HAProxy health check uses Patroni `/master` endpoint to identify primary
- Replica nodes marked as `backup` to prevent write routing

#### Storage Network (10.0.4.0/24)
```
10.0.4.10   minio-vip.internal         # CHANGE_TO_YOUR_MINIO_VIP (HAProxy for S3 API)
10.0.4.11   minio1.internal            # CHANGE_TO_YOUR_MINIO1_IP
10.0.4.12   minio2.internal            # CHANGE_TO_YOUR_MINIO2_IP
10.0.4.13   minio3.internal            # CHANGE_TO_YOUR_MINIO3_IP
10.0.4.14   minio4.internal            # CHANGE_TO_YOUR_MINIO4_IP
```

#### WebRTC Network (10.0.5.0/24)
```
10.0.5.11   coturn1.internal coturn1.chat.z3r0d3v.com  # CHANGE IPs, hostname for TLS
10.0.5.12   coturn2.internal coturn2.chat.z3r0d3v.com  # CHANGE IPs, hostname for TLS
10.0.5.21   livekit.internal livekit.chat.z3r0d3v.com  # CHANGE IPs, subdomain for LiveKit
10.0.5.30   redis.internal                              # CHANGE_TO_YOUR_REDIS_IP
```

#### Service Network (10.0.6.0/24)
```
10.0.6.10   monitoring.internal        # CHANGE_TO_YOUR_MONITORING_IP
10.0.6.20   backup.internal            # CHANGE_TO_YOUR_BACKUP_IP
```

### 5.2 /etc/hosts Configuration (SERVERS ONLY)

**CRITICAL**: This /etc/hosts pattern is for **SERVERS ONLY**, not for clients.

Each server requires `/etc/hosts` entries for all other servers. Example for Synapse server:

```bash
# /etc/hosts on synapse.internal
127.0.0.1   localhost
10.0.2.10   synapse.internal synapse

# HAProxy (VIP and nodes) - HTTP/HTTPS services only
10.0.1.10   haproxy-vip chat.z3r0d3v.com matrix.chat.z3r0d3v.com
10.0.1.11   haproxy1.internal haproxy1
10.0.1.12   haproxy2.internal haproxy2

# Patroni PostgreSQL Cluster
10.0.3.10   patroni-vip.internal patroni-vip
10.0.3.11   patroni1.internal patroni1
10.0.3.12   patroni2.internal patroni2
10.0.3.13   patroni3.internal patroni3

# MinIO Cluster
10.0.4.10   minio-vip.internal minio-vip
10.0.4.11   minio1.internal minio1
10.0.4.12   minio2.internal minio2
10.0.4.13   minio3.internal minio3
10.0.4.14   minio4.internal minio4

# Coturn Servers (actual IPs - for DIRECT access)
10.0.5.11   coturn1.internal coturn1 coturn1.chat.z3r0d3v.com
10.0.5.12   coturn2.internal coturn2 coturn2.chat.z3r0d3v.com

# LiveKit Server (actual IP - for DIRECT UDP access)
10.0.5.21   livekit.internal livekit livekit.chat.z3r0d3v.com
10.0.5.30   redis.internal redis

# Service Servers
10.0.6.10   monitoring.internal monitoring
10.0.6.20   backup.internal backup
```

**This file must be replicated to all 18 servers with appropriate hostname adjustments.**

### 5.3 DNS Configuration (CLIENTS)

**CRITICAL**: Clients require proper DNS records, NOT /etc/hosts:

```dns
# A Records for clients
chat.z3r0d3v.com.           IN  A   10.0.1.10   ; HAProxy VIP (HTTPS)
matrix.chat.z3r0d3v.com.    IN  A   10.0.1.10   ; HAProxy VIP (HTTPS)
coturn1.chat.z3r0d3v.com.   IN  A   10.0.5.11   ; TURN server 1 (DIRECT)
coturn2.chat.z3r0d3v.com.   IN  A   10.0.5.12   ; TURN server 2 (DIRECT)
livekit.chat.z3r0d3v.com.   IN  A   10.0.5.21   ; LiveKit (DIRECT for UDP)
```

**Why Different for Clients**:
- Clients need DIRECT access to TURN servers for UDP media relay
- Clients need DIRECT access to LiveKit for UDP RTC ports
- HTTP/HTTPS still goes through HAProxy VIP
- UDP traffic CANNOT go through HAProxy

---

## 6. Port Requirements

### 6.1 External Ports (HAProxy VIP)

These ports are exposed on the HAProxy VIP (10.0.1.10) **for HTTP/HTTPS ONLY**:

| Port | Protocol | Service | Purpose |
|------|----------|---------|---------|
| 80 | TCP | HTTP | Redirect to HTTPS |
| 443 | TCP | HTTPS | Main entry (Element Web, Synapse API, LiveKit HTTP/WS) |
| 8448 | TCP | HTTPS | Matrix Federation (disabled but configured) |

**HAProxy does NOT handle UDP traffic or TURN ports.**

### 6.2 TURN Server Ports (DIRECT Client Access)

**Coturn servers (10.0.5.11, 10.0.5.12) - MUST be directly accessible**:

| Port | Protocol | Service | Access |
|------|----------|---------|--------|
| 3478 | TCP/UDP | TURN | **DIRECT from clients** |
| 5349 | TCP/UDP | TURN (TLS) | **DIRECT from clients** |
| 49152-65535 | UDP | Relay ports | **DIRECT from clients** |

**CRITICAL**: These ports are accessed **DIRECTLY** by clients. NO proxy in between. Clients resolve `coturn1/2.chat.z3r0d3v.com` to actual IPs.

### 6.3 LiveKit Server Ports

**LiveKit server (10.0.5.21)**:

| Port | Protocol | Service | Access |
|------|----------|---------|--------|
| 7880 | TCP | HTTP/WebSocket | Via HAProxy |
| 8080 | TCP | JWT Service | Via HAProxy |
| 7881 | TCP | RTC TCP fallback | **DIRECT from clients** (optional) |
| 7882 | UDP | RTC connection | **DIRECT from clients** (required) |
| 50100-50200 | UDP | RTC media | **DIRECT from clients** (required) |

**CRITICAL**: UDP ports (7882, 50100-50200) are accessed **DIRECTLY** by clients. Clients must resolve `livekit.chat.z3r0d3v.com` to actual IP (10.0.5.21).

### 6.4 Internal Service Ports

#### Synapse (10.0.2.10)
| Port | Service | Access From |
|------|---------|-------------|
| 81 | Traefik | **HAProxy (bound to 10.0.2.10:81, NOT 127.0.0.1)** |
| 8008 | Main Synapse process | Traefik (internal) |
| 9093 | Worker HTTP replication | Synapse workers (internal) |
| 18008+ | Worker ports (18008-18025) | Traefik (internal routing) |
| **Metrics: HTTPS paths only** | No port exposure | Monitoring via `/metrics/synapse/*` |

#### Patroni/PostgreSQL (10.0.3.11-13)
| Port | Service | Access From |
|------|---------|-------------|
| 5432 | PostgreSQL | PgBouncer (local), HAProxy (for VIP routing), Backup |
| 6432 | PgBouncer | Synapse via VIP or direct |
| 8008 | Patroni REST API | HAProxy health checks, Admin |
| 2379 | etcd client | Patroni cluster |
| 2380 | etcd peer | Patroni cluster |
| 9187 | PostgreSQL exporter | Monitoring |

#### MinIO (10.0.4.11-14)
| Port | Service | Access From |
|------|---------|-------------|
| 9000 | MinIO API (S3) | Synapse via VIP |
| 9001 | MinIO Console (web UI) | Admin via HAProxy (optional) |

#### HAProxy (10.0.1.11-12)
| Port | Service | Access From |
|------|---------|-------------|
| 80 | HTTP | Clients |
| 443 | HTTPS | Clients |
| 8448 | Federation | Other homeservers (if enabled) |
| 8404 | Stats page | Monitoring, Admin |

#### Redis (10.0.5.30)
| Port | Service | Access From |
|------|---------|-------------|
| 6379 | Redis | LiveKit |

#### Monitoring (10.0.6.10)
| Port | Service | Access From |
|------|---------|-------------|
| 9090 | Prometheus | Admin |
| 3000 | Grafana | Admin |

#### All Servers
| Port | Service | Access From |
|------|---------|-------------|
| 22 | SSH | Admin network |
| 9100 | Node exporter | Monitoring |

---

## 7. Data Flow Diagram

### 7.1 Client Message Flow

```
[User Client]
      |
      | HTTPS (443)
      v
[HAProxy VIP 10.0.1.10]
      |
      | Load balance (strips forged XFF headers)
      v
[HAProxy1 or HAProxy2]
      |
      | Forward to Traefik (10.0.2.10:81)
      v
[Traefik on Synapse Server]
      |
      | Route to worker
      v
[Synapse Worker (sync/client-reader)]
      |
      | HTTP replication (9093)
      v
[Synapse Main Process]
      |
      | PgBouncer (any node:6432) - small pool size
      v
[PgBouncer connects to Writer VIP 10.0.3.10:5432]
      |
      | HAProxy routes using /master health check
      v
[Patroni Primary (current leader only)]
      |
      | Write to DB
      v
[PostgreSQL Database]
```

### 7.2 Media Upload/Download Flow

```
[User Client]
      |
      | HTTPS POST /media/upload
      v
[HAProxy] → [Traefik (10.0.2.10:81)] → [Synapse Client Reader Worker]
      |
      | S3 PUT request to MinIO VIP
      v
[MinIO VIP 10.0.4.10 via HAProxy]
      |
      | Load-balanced across nodes
      v
[MinIO Cluster Nodes 1-4]
      |
      | Erasure coding
      v
[Distributed across 4 nodes]
```

### 7.3 WebRTC Call Flow (CORRECTED)

```
[User Client A] ←──TURN UDP (3478/5349 + relay ports)──→ [Coturn Server (10.0.5.11)] ←──→ [User Client B]
      |                  DIRECT ACCESS (no HAProxy)                                         |
      |                                                                                      |
      | HTTPS to JWT service via HAProxy                                                    | HTTPS to JWT service
      v                                                                                      v
[https://livekit.chat.z3r0d3v.com/sfu/get via HAProxy] ←────────────────────────────────┘
      |
      | JWT token from lk-jwt-service
      v
[LiveKit SFU at 10.0.5.21]
      |
      | UDP RTC (7882, 50100-50200) - DIRECT ACCESS (no HAProxy)
      |
      └─────────────────── Media Mix via UDP ──────────────────────────┘
```

**Key points**:
1. Clients request JWT token from lk-jwt-service via HAProxy (HTTPS)
2. JWT service validates via Matrix homeserver OpenID
3. Clients connect to LiveKit HTTP/WebSocket via HAProxy (7880, 8080)
4. **Clients connect to LiveKit UDP ports DIRECTLY** (7882, 50100-50200) - NO HAProxy
5. **Clients connect to TURN servers DIRECTLY** (3478, 5349, relay ports) - NO HAProxy
6. UDP traffic bypasses HAProxy entirely
7. DNS resolution: `livekit.chat.z3r0d3v.com` → 10.0.5.21 (actual IP)
8. DNS resolution: `coturn1/2.chat.z3r0d3v.com` → 10.0.5.11/12 (actual IPs)

### 7.4 Service Discovery Flow

```
[Element Client]
      |
      | Request .well-known/matrix/client
      v
[https://chat.z3r0d3v.com/.well-known/matrix/client]
      |
      | HAProxy reverse proxy
      v
[https://matrix.chat.z3r0d3v.com/.well-known/matrix/client]
      |
      | Served by matrix-static-files
      v
[Returns homeserver URL + MatrixRTC config with LiveKit URL]
```

### 7.5 Monitoring Flow

```
[Prometheus on Monitoring Server]
      |
      | Scrape via HTTPS through HAProxy (with basic auth)
      v
[https://chat.z3r0d3v.com/metrics/synapse/main-process]
[https://chat.z3r0d3v.com/metrics/synapse/worker/TYPE-ID]
      |
      | Exposed by Traefik (no port 9100 conflict)
      v
[Synapse Main + Workers]
```

---

## 8. Scaling Considerations

### 8.1 Vertical Scaling Triggers

Monitor these metrics and scale up when thresholds are consistently exceeded:

| Metric | Warning | Action | Scale Up To |
|--------|---------|--------|-------------|
| **Synapse CPU** | >70% sustained | Add more vCPUs | 64-96 vCPU |
| **Synapse RAM** | >90% | Increase RAM or reduce cache_factor | 192-256 GB |
| **DB CPU** | >70% sustained | Add vCPUs to Patroni nodes | 24-32 vCPU |
| **DB RAM** | >85% | Increase RAM | 96-128 GB |
| **MinIO Bandwidth** | >70% network saturation | Add network bandwidth | 20-40 Gbps |
| **Sync p95 Latency** | >300ms | Add sync workers or scale Synapse | More workers |
| **DB Connections** | >400 active | Increase PostgreSQL max_connections | 600-800 |

### 8.2 Horizontal Scaling Options

#### Adding More Synapse Workers
- Increase worker count in `vars.yml`
- Run `ansible-playbook --tags=setup-all,start`
- HAProxy automatically picks up new workers via health checks
- Recommended limit: 12 sync workers (diminishing returns beyond this)
- **CRITICAL**: Ensure database connection pool sizes remain small per process

#### Adding TURN Servers
- Deploy additional Coturn servers on new IPs
- Add DNS records for new servers (e.g., `coturn3.chat.z3r0d3v.com`)
- Add new TURN URIs to Synapse configuration
- Ensure direct client access to new servers

#### Adding LiveKit Capacity
- Currently single-node deployment for simplicity
- Can scale to multiple nodes if needed (requires Redis coordination)
- Each node needs own public/routable IP for UDP traffic
- Update DNS/routing to include new nodes

### 8.3 Database Connection Pool Management

**CRITICAL**: Keep pool sizes small per process to avoid exhaustion:

- **Synapse main process**: `cp_min: 5`, `cp_max: 10`
- **Each worker**: Inherits same pool size
- **Total connections**: (19 processes × 10) + overhead = ~200-250 active
- **PostgreSQL max_connections**: 500 (with headroom for admin, monitoring)
- **PgBouncer pool_size**: 50 per database
- **Never exceed**: Total connections > max_connections - 100

---

## 9. High Availability Strategy

### 9.1 Failure Scenarios and Recovery

#### HAProxy Node Failure
- **Detection**: Keepalived detects via VRRP heartbeat (1-2s)
- **Action**: Automatic VIP failover to standby HAProxy
- **RTO**: <5 seconds
- **User Impact**: Brief connection interruption, automatic reconnect
- **Scope**: HTTP/HTTPS traffic only - UDP services unaffected

#### TURN Server Failure
- **Detection**: Client connection timeout
- **Action**: Client retries with second TURN server
- **RTO**: 5-10 seconds
- **User Impact**: Brief interruption in calls using that server
- **Mitigation**: Multiple TURN URIs configured, automatic fallback

#### LiveKit Node Failure
- **Detection**: Service unavailable
- **Action**: Service restart required (single node) or failover (multi-node)
- **RTO**: Service restart time or immediate (multi-node)
- **User Impact**: Active calls drop, need to rejoin
- **UDP Dependency**: Direct access means no HAProxy failure affects LiveKit

#### Patroni Primary Failure
- **Detection**: Patroni health checks (10s interval)
- **Action**: Automatic leader election, replica promoted to primary
- **RTO**: 10-30 seconds
- **User Impact**: Brief write unavailability, reads continue
- **HAProxy**: Automatically routes to new primary via `/master` health check

#### Database Connection Pool Exhaustion
- **Detection**: Connection refused errors in Synapse logs
- **Prevention**: Small pool sizes per process (cp_max: 10)
- **Action**: If occurs, increase PostgreSQL max_connections
- **Mitigation**: PgBouncer queues excess connections

---

## Summary

This architecture provides:
- **18 servers** total across 7 functional layers
- **No single point of failure** for critical services
- **Automatic failover** for HAProxy, PostgreSQL, MinIO
- **Horizontal scalability** via workers and distributed services
- **High performance** optimized for 10,000 concurrent users
- **360-day backup retention** with PITR capability
- **Proper UDP handling** for TURN/LiveKit media traffic
- **Direct client access** to WebRTC services for optimal performance
- **Split-horizon DNS** (servers use /etc/hosts, clients need proper DNS)
- **Secure X-Forwarded-For handling** (prevents header forgery)
- **Proper connection pool management** (prevents database exhaustion)

**Critical Architecture Verified**:
1. ✅ HAProxy handles HTTP/HTTPS/WebSocket ONLY
2. ✅ TURN servers accessed DIRECTLY by clients via DNS (no HAProxy)
3. ✅ LiveKit UDP ports accessed DIRECTLY by clients via DNS (no HAProxy)
4. ✅ Servers use /etc/hosts, clients require proper DNS records
5. ✅ UDP media traffic bypasses HAProxy entirely
6. ✅ DNS must resolve coturn1/2 and livekit to actual IPs for clients
7. ✅ Database connection pools sized appropriately (cp_max: 10 per process)
8. ✅ HAProxy strips forged X-Forwarded-For headers for security

**Database Architecture Verified**:
1. ✅ PgBouncer on all nodes connects to writer VIP (10.0.3.10:5432), NOT localhost
2. ✅ HAProxy for writer VIP uses `/master` health check to identify primary
3. ✅ Replica nodes marked as `backup` to prevent write routing
4. ✅ Writes always route to current Patroni primary, even after failover
5. ✅ Small connection pool sizes prevent exhaustion

**Next Steps**: Proceed to Document 2 (Infrastructure Setup) to deploy external services.

---

**Document Control**
- **Version**: 3.2 FINAL - Routing Clarification
- **Critical Fix**: Removed incorrect claim about API working via base domain
- **All v3.1 fixes retained**: Metrics format, connection pools, security, UDP architecture
- **Production Ready**: ✅ Yes
- **Next**: Deploy infrastructure via Document 2
