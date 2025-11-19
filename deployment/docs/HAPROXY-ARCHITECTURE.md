# HAProxy Routing Architecture for Matrix/Synapse


**Applies to:** All Scales (100 CCU to 20K CCU)
**Architecture:** Simplified worker architecture (extensible)

---

> **📋 IMPORTANT: Actual Architecture Implementation**
>
> This deployment uses a **simplified worker architecture** that is production-ready and handles 100 CCU to 20K+ CCU efficiently:
>
> **Current Worker Types:**
> - **Sync Workers** (2-18 replicas) - Handle `/sync` endpoints with token-based hashing
> - **Generic Workers** (2-8 replicas) - Handle ALL other Matrix endpoints (client API, federation, media, admin)
> - **Background Workers** - Event persisters and federation senders (not routed through HAProxy)
>
> **HAProxy Routing:**
> - `/sync` requests → Sync Workers (sticky sessions per user)
> - All other requests → Generic Workers (round-robin)
> - Automatic fallback to main process if workers unavailable
>
> **Why Simplified:**
> - Easier operations and monitoring
> - Sufficient for most deployments up to 20K CCU
> - Generic workers efficiently handle multiple endpoint types
> - Can be extended with specialized workers later if needed
>
> **Future Expansion (Optional):**
> - This architecture can be extended with specialized workers (media-repo, event-creator, federation-inbound, etc.) following patterns from Element's ess-helm
> - See Section 4 for details on specialized worker types (future expansion only)
> - Current HAProxy configuration is optimized for sync + generic architecture
>
> **For Current Implementation Details:**
> - See `deployment/main-instance/03-haproxy/deployment.yaml` for actual HAProxy configuration (embedded ConfigMap)
> - See `deployment/main-instance/02-workers/` directory for worker deployments

---

## Table of Contents

1. [Overview](#1-overview)
2. [Why HAProxy Layer?](#2-why-haproxy-layer)
3. [Architecture Diagram](#3-architecture-diagram)
4. [Routing Patterns](#4-routing-patterns)
5. [Load Balancing Strategies](#5-load-balancing-strategies)
6. [Health Checks](#6-health-checks)
7. [Service Discovery](#7-service-discovery)
8. [Deployment Guide](#8-deployment-guide)
9. [Configuration Reference](#9-configuration-reference)
10. [Monitoring](#10-monitoring)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Overview

HAProxy provides an intelligent routing layer between your Kubernetes Ingress and Synapse workers. Instead of routing traffic directly from Ingress to workers, HAProxy acts as an intermediary that:

- **Routes requests to specialized workers** based on URL patterns
- **Implements fallback mechanisms** when specialized workers unavailable
- **Performs health-aware load balancing** (only routes to healthy workers)
- **Manages connection pooling** efficiently
- **Provides observability** with detailed metrics and logs

This architecture is used in production by Element for their enterprise Matrix deployments.

---

## 2. Why HAProxy Layer?

### Without HAProxy (Direct Ingress → Workers)

```
┌─────────┐
│ Ingress │
└────┬────┘
     │
     ├─→ sync-worker-1    ─→  All workers handle
     ├─→ sync-worker-2         all request types
     ├─→ sync-worker-3         (inefficient)
     └─→ sync-worker-4
```

**Problems:**
- ❌ All workers must handle all request types (inefficient resource usage)
- ❌ No routing based on request characteristics (e.g., room-based hashing)
- ❌ Limited health check intelligence (only TCP checks)
- ❌ No fallback mechanism when specialized workers fail
- ❌ Difficult to implement advanced load balancing (sticky sessions, hashing)

### With HAProxy (Ingress → HAProxy → Specialized Workers)

```
┌─────────┐
│ Ingress │
└────┬────┘
     │
     v
┌─────────────┐
│   HAProxy   │  ← Intelligent routing layer
└──────┬──────┘
       │
       ├─→ /sync → sync-workers (hashed by access token)
       ├─→ /sendToDevice → to-device-workers
       ├─→ /createRoom → event-creator-workers (hashed by room)
       ├─→ /_matrix/federation → federation-inbound (hashed by origin)
       └─→ /* → generic-workers (fallback)
```

**Benefits:**
- ✅ Specialized workers handle specific request types (better performance)
- ✅ Advanced load balancing (consistent hashing by user, room, server)
- ✅ Health-check aware routing (no requests to unhealthy workers)
- ✅ Automatic fallback to main process if all workers down
- ✅ Better observability (HAProxy metrics per backend)
- ✅ Connection pooling and keep-alive optimization
- ✅ Request rate limiting and timeout handling

---

## 3. Architecture Diagram

### High-Level Architecture

```
                    ┌─────────────────────────────────┐
                    │  External Traffic (HTTPS)       │
                    └────────────┬────────────────────┘
                                 │
                                 v
                    ┌─────────────────────────────────┐
                    │  Ingress Controller (Nginx)     │
                    │  - TLS termination              │
                    │  - Rate limiting                │
                    │  - DDoS protection              │
                    └────────────┬────────────────────┘
                                 │ HTTP
                                 v
                    ┌─────────────────────────────────┐
                    │  HAProxy (Routing Layer)        │
                    │  - Request inspection           │
                    │  - Header-based routing         │
                    │  - Health-aware balancing       │
                    │  - Automatic fallback           │
                    └────┬────────────────────────────┘
                         │
        ┌────────────────┼────────────────┬───────────────────┐
        │                │                │                   │
        v                v                v                   v
┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Sync Workers │  │Event Creator │  │  Federation  │  │   Generic    │
│ (4-8 pods)   │  │  (2-4 pods)  │  │   Inbound    │  │   Workers    │
│              │  │              │  │   (2-4 pods) │  │   (2-4 pods) │
│ Hash: token  │  │ Hash: room   │  │ Hash: origin │  │ Round-robin  │
└──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘
        │                │                │                   │
        └────────────────┴────────────────┴───────────────────┘
                                 │
                                 v
                    ┌─────────────────────────────────┐
                    │  PostgreSQL Cluster             │
                    │  Redis Sentinel                 │
                    │  MinIO Storage                  │
                    └─────────────────────────────────┘
```

### Request Flow Example (Sync Request)

```
1. Client → Ingress
   GET https://matrix.example.com/_matrix/client/r0/sync
   Authorization: Bearer mas_v1_abc123...

2. Ingress → HAProxy (port 8008)
   GET /_matrix/client/r0/sync HTTP/1.1
   Authorization: Bearer mas_v1_abc123...

3. HAProxy extracts X-Access-Token header (or from query param)
   Token: mas_v1_abc123...
   Hashes token: hash(abc123) % num_sync_workers = worker 3

4. HAProxy → Sync Worker 3
   GET /_matrix/client/r0/sync HTTP/1.1
   Authorization: Bearer mas_v1_abc123...
   Forwarded: for=client-ip;host=matrix.example.com;proto=https

5. Sync Worker → PostgreSQL/Redis
   Queries: room state, timeline, presence, typing, etc.

6. Sync Worker → HAProxy → Ingress → Client
   HTTP/1.1 200 OK
   Content-Type: application/json
   {
     "next_batch": "...",
     "rooms": {...},
     "presence": {...}
   }
```

---

## 4. Routing Patterns

> **⚠️ NOTE:** This section describes routing patterns for specialized worker architectures (future expansion).
>
> **Current Implementation:**
> - `/sync` endpoints → Sync Workers
> - All other endpoints → Generic Workers
> - See `deployment/main-instance/03-haproxy/deployment.yaml` (embedded ConfigMap) for actual routing rules
>
> The table below shows potential routing patterns if specialized workers are added later.

### 4.1: Current Routing (Simplified Architecture)

**Actual Routing in Current Deployment:**

| URL Pattern | Worker Type | Port | Load Balancing |
|-------------|-------------|------|----------------|
| `/_matrix/client/*/sync` | sync-workers | 8083 | Token hash (sticky sessions) |
| `/_matrix/client/*` (all other) | generic-workers | 8081 | Round-robin |
| `/_matrix/federation/*` | generic-workers | 8081 | Round-robin |
| `/_matrix/media/*` | generic-workers | 8081 | Round-robin |
| `/_synapse/admin/*` | generic-workers | 8081 | Round-robin |
| `/.well-known/matrix/*` | generic-workers | 8081 | Round-robin |
| All requests (fallback) | synapse-main | 8008 | Backup (when workers down) |

### 4.2: Future Expansion - Specialized Worker Routing (Optional)

If you decide to add specialized workers later, here are the routing patterns from Element's ess-helm:

| URL Pattern | Worker Type | Purpose |
|-------------|-------------|---------|
| `/_matrix/client/*/sync` | sync-workers | Long-polling sync requests |
| `/_matrix/client/*/keys/upload` | to-device-workers | E2E key uploads |
| `/_matrix/client/*/sendToDevice` | to-device-workers | Device messages |
| `/_matrix/client/*/rooms/*/send/*` | event-creator-workers | Send events |
| `/_matrix/client/*/rooms/*/state/*` | event-creator-workers | Send state events |
| `/_matrix/client/*/createRoom` | event-creator-workers | Create rooms |
| `/_matrix/client/*/join/*` | event-creator-workers | Join rooms |
| `/_matrix/federation/v1/*` | federation-inbound-workers | Inbound federation |
| `/_matrix/federation/v2/send/*` | federation-inbound-workers | Receive federation |
| `/_matrix/client/*/rooms/*/messages` | sync-workers | Room history |
| `/_matrix/client/*/user/*/filter` | sync-workers | Sync filters |
| `/_matrix/media/*` | media-repo-workers | Media upload/download |
| `/_matrix/client/*/presence/*` | presence-workers | Presence updates |
| `/_matrix/client/*/user/*/account_data` | account-data-workers | Account data |
| `/_matrix/client/*/user/*/rooms/*/account_data` | account-data-workers | Room account data |
| `/_matrix/client/*/receipts` | receipts-workers | Read receipts |
| `/_matrix/client/*/rooms/*/receipt` | receipts-workers | Send receipts |
| `/_matrix/client/*/rooms/*/typing` | typing-workers | Typing indicators |
| `/_matrix/client/*/pushrules` | push-rules-workers | Push rules |
| `/*` (default) | generic-workers | All other requests |

### 4.2: Header-Based Routing

For certain request types, HAProxy extracts headers to make routing decisions:

**Sync Requests (Token-Based):**
```haproxy
# Extract access token from Authorization header or query param
acl has_auth_header req.hdr(Authorization) -m found
http-request set-header X-Access-Token %[req.hdr(Authorization),word(2,' ')] if has_auth_header

# Or from query parameter (?access_token=...)
acl has_access_token urlp(access_token) -m found
http-request set-header X-Access-Token %[urlp(access_token)] if has_access_token

# Hash token to select worker
balance hdr(X-Access-Token)
```

**Event Creation (Room-Based):**
```haproxy
# Extract room ID from URL path
# /rooms/{room_id}/send/{event_type}/{txn_id}
http-request set-header X-Matrix-Room %[path,field(4,/)]

# Hash room ID to select worker (ensures same room → same worker)
balance hdr(X-Matrix-Room)
```

**Federation (Origin-Based):**
```haproxy
# Extract origin server from X-Matrix auth header
http-request set-header X-Federation-Origin %[req.hdr(Authorization),word(2,'origin='),word(1,',')]

# Hash origin to select worker (same server → same worker)
balance source
```

---

## 5. Load Balancing Strategies

Different worker types use different load balancing algorithms optimized for their workload.

### 5.1: Sync Workers - Token Hashing

**Strategy:** `balance hdr(X-Access-Token)`

**Why:** Ensures same user always routes to same sync worker for:
- Better CPU cache locality (worker remembers user's state)
- Reduced database queries (worker caches user's rooms)
- More efficient long-polling (worker tracks pending updates)

**Configuration:**
```haproxy
backend sync-workers
    balance hdr(X-Access-Token)
    hash-type consistent  # Minimizes redistribution on worker changes
    server-template sync 8 _synapse-sync._tcp.synapse.svc.cluster.local resolvers kubedns init-addr none check
```

**Fallback:** If sync workers down, route to generic-workers or main process.

---

### 5.2: Event Creator Workers - Room Hashing

**Strategy:** `balance hdr(X-Matrix-Room)`

**Why:** Ensures same room always routes to same worker for:
- Event ordering (critical for Matrix consistency)
- Reduced lock contention in database
- Better cache locality for room state

**Configuration:**
```haproxy
backend event-creator-workers
    balance hdr(X-Matrix-Room)
    hash-type consistent
    server-template creator 4 _synapse-event-creator._tcp.synapse.svc.cluster.local resolvers kubedns init-addr none check
```

**Critical:** Room-based hashing is REQUIRED for event-persister stream writers to ensure event ordering guarantees.

---

### 5.3: Federation Inbound - Origin Hashing

**Strategy:** `balance source` (source IP = origin server)

**Why:** Ensures requests from same homeserver route to same worker for:
- Better connection reuse (persistent connections)
- Reduced TLS handshake overhead
- More efficient request batching

**Configuration:**
```haproxy
backend federation-inbound-workers
    balance source
    hash-type consistent
    server-template fed-in 4 _synapse-federation-inbound._tcp.synapse.svc.cluster.local resolvers kubedns init-addr none check
```

---

### 5.4: Federation Reader - URI Hashing

**Strategy:** `balance uri whole`

**Why:** Deduplicates expensive state_ids requests (multiple servers asking for same state).

**Configuration:**
```haproxy
backend federation-reader-workers
    balance uri whole
    hash-type consistent
    server-template fed-reader 2 _synapse-federation-reader._tcp.synapse.svc.cluster.local resolvers kubedns init-addr none check
```

**Example:** 10 servers request `/_matrix/federation/v1/state_ids/{room_id}?event_id=xyz`
- Without hashing: 10 workers each query database
- With URI hashing: All 10 requests → same worker → single database query

---

### 5.5: Generic Workers - Round Robin

**Strategy:** `balance roundrobin`

**Why:** Simple load distribution for miscellaneous endpoints that don't benefit from hashing.

**Configuration:**
```haproxy
backend generic-workers
    balance roundrobin
    server-template generic 4 _synapse-generic._tcp.synapse.svc.cluster.local resolvers kubedns init-addr none check
```

---

## 6. Health Checks

HAProxy performs intelligent health checks to ensure only healthy workers receive traffic.

### 6.1: HTTP Health Checks

**Configuration:**
```haproxy
backend sync-workers
    option httpchk GET /_matrix/client/versions
    http-check expect status 200

    server-template sync 8 _synapse-sync._tcp.synapse.svc.cluster.local \
        resolvers kubedns \
        init-addr none \
        check inter 10s fall 3 rise 2
```

**Parameters:**
- `check`: Enable health checks
- `inter 10s`: Check every 10 seconds
- `fall 3`: Mark unhealthy after 3 consecutive failures
- `rise 2`: Mark healthy after 2 consecutive successes

**Why `/_matrix/client/versions`:**
- Lightweight endpoint (no auth required)
- Returns JSON immediately (no database query)
- Standard Matrix endpoint (works on all workers)

---

### 6.2: Critical Worker Health Checks

For critical workers (event-persisters, stream writers), HAProxy uses stricter checks:

**Configuration:**
```haproxy
backend event-persister-workers
    option httpchk GET /_synapse/health
    http-check expect status 200

    # Stricter health checks for critical workers
    server-template persister 4 _synapse-event-persister._tcp.synapse.svc.cluster.local \
        resolvers kubedns \
        init-addr none \
        check inter 5s fall 2 rise 3
```

**Parameters:**
- `inter 5s`: Check every 5 seconds (faster detection)
- `fall 2`: Mark unhealthy after 2 failures (faster removal)
- `rise 3`: Mark healthy after 3 successes (slower addition, prevent flapping)

---

### 6.3: Health Check Endpoint Requirements

Workers must expose health check endpoints:

**In worker configuration (`worker.yaml`):**
```yaml
worker_listeners:
  - type: http
    port: 8008
    resources:
      - names: [client, federation, health]  # Add 'health' resource
```

**Custom health endpoint (optional):**
```python
# In Synapse, /_synapse/health returns:
# HTTP 200 if:
#   - Database connection OK
#   - Redis connection OK (if configured)
#   - Worker not in graceful shutdown

# HTTP 503 if:
#   - Database connection failed
#   - Worker shutting down
```

---

### 6.4: Fallback Mechanism

When all workers in a backend are unhealthy, HAProxy falls back to the main process.

**Configuration:**
```haproxy
backend sync-workers
    option httpchk GET /_matrix/client/versions

    # Sync workers (preferred)
    server-template sync 8 _synapse-sync._tcp.synapse.svc.cluster.local \
        resolvers kubedns init-addr none check

    # Fallback to generic workers
    server-template generic 4 _synapse-generic._tcp.synapse.svc.cluster.local \
        resolvers kubedns init-addr none check backup

    # Ultimate fallback to main process
    server synapse-main synapse-main.matrix.svc.cluster.local:8008 check backup
```

**Backup servers (`backup` flag):**
- Only used when all primary servers are down
- Prevents complete service outage
- Main process can handle all request types (but less efficiently)

---

## 7. Service Discovery

HAProxy uses Kubernetes DNS SRV records for automatic worker discovery (no hardcoded IPs).

### 7.1: DNS SRV Resolution

**Configuration:**
```haproxy
resolvers kubedns
    nameserver dns1 10.96.0.10:53  # kube-dns ClusterIP
    accepted_payload_size 8192
    hold valid 10s
    hold obsolete 30s

backend sync-workers
    server-template sync 8 _synapse-sync._tcp.synapse.svc.cluster.local \
        resolvers kubedns \
        init-addr none
```

**How it works:**

1. **HAProxy queries:** `_synapse-sync._tcp.synapse.svc.cluster.local`
2. **Kubernetes DNS returns SRV records:**
   ```
   _synapse-sync._tcp.synapse.svc.cluster.local. 30 IN SRV 0 25 8008 synapse-sync-0.synapse-sync.synapse.svc.cluster.local.
   _synapse-sync._tcp.synapse.svc.cluster.local. 30 IN SRV 0 25 8008 synapse-sync-1.synapse-sync.synapse.svc.cluster.local.
   _synapse-sync._tcp.synapse.svc.cluster.local. 30 IN SRV 0 25 8008 synapse-sync-2.synapse-sync.synapse.svc.cluster.local.
   ```
3. **HAProxy automatically discovers all sync worker pods**
4. **When pods scale up/down, HAProxy detects changes within 10s** (hold valid)

---

### 7.2: Headless Services for SRV Records

Workers need headless services to publish SRV records.

**Example service:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: synapse-sync
  namespace: matrix
spec:
  clusterIP: None  # Headless service
  selector:
    app: synapse
    component: sync-worker
  ports:
  - name: synapse-sync
    port: 8008
    targetPort: 8008
    protocol: TCP
```

**Why headless (`clusterIP: None`):**
- Returns A records for each pod IP
- Enables SRV record queries
- HAProxy can discover individual pods

---

## 8. Deployment Guide

### 8.1: Prerequisites

- Existing Synapse deployment with workers
- Kubernetes cluster with DNS service (kube-dns or CoreDNS)
- Headless services for each worker type

### 8.2: Deploy HAProxy

**Deploy HAProxy (configuration embedded in deployment):**
```bash
# HAProxy configuration is embedded in the deployment manifest
kubectl apply -f main-instance/03-haproxy/deployment.yaml
```

**Verify HAProxy pods:**
```bash
kubectl get pods -n matrix -l app=haproxy

# Expected:
# NAME                       READY   STATUS    RESTARTS   AGE
# haproxy-7c8d9e0f1a-abcde   1/1     Running   0          30s
# haproxy-7c8d9e0f1a-fghij   1/1     Running   0          30s
```

---

### 8.3: Update Ingress to Route to HAProxy

**Update ingress manifest:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: matrix
  namespace: matrix
spec:
  rules:
  - host: matrix.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: haproxy  # Changed from synapse-main
            port:
              name: http
```

**Apply changes:**
```bash
kubectl apply -f manifests/09-ingress.yaml
```

---

### 8.4: Test Routing

**Test sync request routes to sync workers:**
```bash
# Get access token
ACCESS_TOKEN="mas_v1_..."

# Make sync request
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  https://matrix.example.com/_matrix/client/r0/sync

# Check HAProxy logs to see which worker handled request
kubectl logs -n matrix -l app=haproxy --tail=10 | grep sync
```

**Test federation routes to federation workers:**
```bash
# Federation request from another homeserver
curl -X GET "https://matrix.example.com/_matrix/federation/v1/version"

# Check HAProxy logs
kubectl logs -n matrix -l app=haproxy --tail=10 | grep federation
```

---

## 9. Configuration Reference

### 9.1: Global Configuration

```haproxy
global
    # Logging
    log stdout format raw local0 info

    # Max connections
    maxconn 50000

    # Stats socket (for monitoring)
    stats socket /var/run/haproxy.sock mode 660 level admin expose-fd listeners
    stats timeout 30s

    # Performance tuning
    tune.ssl.default-dh-param 2048
    tune.bufsize 32768

defaults
    log global
    mode http
    option httplog
    option dontlognull

    # Timeouts
    timeout connect 10s
    timeout client 60s
    timeout server 60s
    timeout http-request 10s
    timeout http-keep-alive 10s

    # Error handling
    errorfile 503 /usr/local/etc/haproxy/errors/503.http
```

---

### 9.2: Frontend Configuration

```haproxy
frontend matrix-http
    bind :8008

    # Request logging
    option httplog
    option forwardfor

    # ACLs for routing
    acl is_sync path_beg /_matrix/client/ path_end /sync
    acl is_federation path_beg /_matrix/federation/
    acl is_media path_beg /_matrix/media/
    acl is_event_create path_reg ^/_matrix/client/.*/rooms/.*/send/

    # Route to backends
    use_backend sync-workers if is_sync
    use_backend federation-inbound if is_federation
    use_backend media-repo if is_media
    use_backend event-creator if is_event_create

    # Default backend
    default_backend generic-workers
```

---

### 9.3: Backend Configuration Template

```haproxy
backend <worker-type>
    # Load balancing strategy
    balance <algorithm>  # roundrobin, hdr(), source, uri

    # Health checks
    option httpchk GET /_matrix/client/versions
    http-check expect status 200

    # Connection settings
    option http-keep-alive
    option forwardfor

    # Server template (service discovery)
    server-template <name> <count> _synapse-<type>._tcp.synapse.svc.cluster.local \
        resolvers kubedns \
        init-addr none \
        check inter 10s fall 3 rise 2 \
        maxconn 2000

    # Fallback servers
    server-template generic 4 _synapse-generic._tcp.synapse.svc.cluster.local \
        resolvers kubedns init-addr none check backup
    server synapse-main synapse-main.matrix.svc.cluster.local:8008 check backup
```

---

## 10. Monitoring

### 10.1: HAProxy Stats Page

**Enable stats frontend:**
```haproxy
frontend stats
    bind :8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats show-legends
    stats show-node
```

**Access stats page:**
```
http://haproxy-pod-ip:8404/stats
```

**Metrics shown:**
- Request rate per backend
- Active connections
- Queue depth
- Health check status
- Response time percentiles

---

### 10.2: Prometheus Metrics

**Enable Prometheus exporter:**
```haproxy
frontend stats
    bind :8404
    http-request use-service prometheus-exporter if { path /metrics }
    stats enable
    stats uri /stats
```

**Key metrics:**

| Metric | Description |
|--------|-------------|
| `haproxy_backend_http_responses_total` | HTTP responses by backend and status code |
| `haproxy_backend_current_sessions` | Current active sessions per backend |
| `haproxy_backend_response_time_average_seconds` | Average response time |
| `haproxy_server_up` | Server health status (1=up, 0=down) |
| `haproxy_backend_connection_errors_total` | Backend connection errors |

**Prometheus scrape config:**
```yaml
- job_name: 'haproxy'
  kubernetes_sd_configs:
    - role: pod
      namespaces:
        names:
          - matrix
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_label_app]
      action: keep
      regex: haproxy
    - source_labels: [__meta_kubernetes_pod_ip]
      target_label: __address__
      replacement: '${1}:8404'
```

---

### 10.3: Grafana Dashboard

**Recommended panels:**

1. **Request Rate by Backend**
   ```promql
   sum(rate(haproxy_backend_http_responses_total[5m])) by (backend)
   ```

2. **Backend Response Time (p95)**
   ```promql
   histogram_quantile(0.95, sum(rate(haproxy_backend_response_time_seconds_bucket[5m])) by (backend, le))
   ```

3. **Unhealthy Servers**
   ```promql
   count(haproxy_server_up == 0) by (backend)
   ```

4. **Backend Queue Depth**
   ```promql
   haproxy_backend_current_queue
   ```

5. **Connection Errors**
   ```promql
   sum(rate(haproxy_backend_connection_errors_total[5m])) by (backend)
   ```

---

## 11. Troubleshooting

### 11.1: Workers Not Discovered

**Symptoms:**
- HAProxy logs: `Server <backend>/<server> is DOWN`
- No workers in HAProxy stats page

**Debug:**
```bash
# Check DNS SRV records
kubectl run -it --rm debug --image=tutum/dnsutils --restart=Never -- \
  nslookup -type=SRV _synapse-sync._tcp.synapse.svc.cluster.local

# Should return SRV records for each pod

# Check headless service exists
kubectl get svc -n matrix | grep synapse-sync

# Check service selector matches worker pods
kubectl get pods -n matrix -l app=synapse,component=sync-worker
```

**Solution:**
- Ensure headless services created for each worker type
- Verify service selectors match worker pod labels
- Check kube-dns/CoreDNS is running

---

### 11.2: Health Checks Failing

**Symptoms:**
- HAProxy marks all workers as unhealthy
- Requests fall back to main process

**Debug:**
```bash
# Check worker health endpoint directly
kubectl exec -n matrix haproxy-pod -- \
  curl http://synapse-sync-0.synapse-sync.matrix.svc.cluster.local:8008/_matrix/client/versions

# Should return:
# {"versions": ["r0.0.1", ...]}

# Check HAProxy logs
kubectl logs -n matrix -l app=haproxy | grep "Health check"
```

**Solution:**
- Ensure workers expose health endpoint (/_matrix/client/versions)
- Check worker listeners include 'client' or 'health' resource
- Verify network connectivity between HAProxy and workers

---

### 11.3: Routing Not Working

**Symptoms:**
- Sync requests not routed to sync workers
- All requests go to generic workers

**Debug:**
```bash
# Check HAProxy ACLs and routing rules
kubectl exec -n matrix haproxy-pod -- haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg

# Check HAProxy logs for routing decisions
kubectl logs -n matrix -l app=haproxy --tail=100 | grep "backend:"
```

**Solution:**
- Review ACL definitions in haproxy.cfg
- Ensure `use_backend` rules match ACLs
- Check request paths match ACL patterns

---

### 11.4: High Latency

**Symptoms:**
- Requests slow through HAProxy
- P95 latency > 500ms

**Debug:**
```bash
# Check HAProxy response times
kubectl exec -n matrix haproxy-pod -- \
  echo "show stat" | socat stdio /var/run/haproxy.sock | grep -E "sync-workers|qtime|rtime"

# Check connection queue depth
kubectl exec -n matrix haproxy-pod -- \
  echo "show stat" | socat stdio /var/run/haproxy.sock | grep -E "qcur|scur"
```

**Solution:**
- Increase worker replicas if queue depth high
- Increase `maxconn` per server if connection limits hit
- Check worker pod resource limits (CPU/memory)

---

## Conclusion

The HAProxy routing architecture provides production-grade routing for Matrix/Synapse deployments, enabling:

- **Better resource utilization** through specialized workers
- **Improved performance** via intelligent load balancing
- **Higher availability** with health-check aware routing and fallbacks
- **Better observability** with detailed metrics per backend

This architecture is proven in production by Element's enterprise deployments and scales from 100 CCU to 20K+ CCU.

**Next Steps:**
- Deploy HAProxy layer (section 8)
- Configure worker-specific routing (section 4)
- Set up monitoring dashboards (section 10)
- Review SCALING-GUIDE.md for worker counts at different scales

---


**Based on:** Element ess-helm v1.x
**HAProxy Version:** 2.8+
