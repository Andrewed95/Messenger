# Matrix Synapse Main Instance

Complete production deployment of Matrix Synapse homeserver with worker architecture, Element Web client, and intelligent load balancing.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                         Internet                            │
└────────────────┬─────────────────────┬──────────────────────┘
                 │                     │
        ┌────────▼────────┐   ┌────────▼────────┐
        │ NGINX Ingress   │   │ NGINX Ingress   │
        │ matrix.ex.com   │   │ element.ex.com  │
        │ (Client+Fed)    │   │ (Web Client)    │
        └────────┬────────┘   └────────┬────────┘
                 │                     │
        ┌────────▼────────┐   ┌────────▼────────┐
        │  HAProxy x2     │   │ Element Web x2  │
        │ (Load Balancer) │   │ (Web Client)    │
        └────────┬────────┘   └─────────────────┘
                 │
    ┌────────────┼─────────────────────┐
    │            │                     │
    │   ┌────────▼────────┐            │
    │   │ Main Process    │            │
    │   │   (1 replica)   │            │
    │   └────────┬────────┘            │
    │            │                     │
    │            │ Replication         │
    │       ┌────▼─────┐               │
    │       │  Redis   │               │
    │       └────┬─────┘               │
    │            │                     │
    │   ┌────────┴─────────────┐       │
    │   │   Worker Pools       │       │
    │   ├──────────────────────┤       │
    │   │ Synchrotron (4-16)   │       │
    │   │ Generic (2-16)       │       │
    │   │ Media (2-8)          │       │
    │   │ Event Persist (2-8)  │       │
    │   │ Fed Sender (2-8)     │       │
    │   └──────────────────────┘       │
    │                                  │
    └──────────────────────────────────┘
```

## Directory Structure

```
main-instance/
├── 01-synapse/          # Synapse homeserver main process
│   ├── configmap.yaml         # homeserver.yaml + log.yaml
│   ├── secrets.yaml           # All credentials and keys
│   ├── main-statefulset.yaml  # Main process StatefulSet
│   ├── services.yaml          # Services + ServiceMonitor
│   └── README.md              # Detailed documentation
│
├── 02-workers/          # Synapse worker processes
│   ├── generic-worker-deployment.yaml      # General client endpoints
│   ├── event-persister-deployment.yaml     # Database writes
│   ├── federation-sender-deployment.yaml   # Outbound federation
│   ├── media-repository-statefulset.yaml   # Media handling
│   ├── synchrotron-deployment.yaml         # /sync endpoints
│   └── README.md                           # Worker documentation
│
├── 02-element-web/      # Element Web client
│   └── deployment.yaml        # Deployment + Service + Ingress + ConfigMap
│
├── 03-haproxy/          # HAProxy load balancer
│   └── deployment.yaml        # Deployment + Services + Ingress + ConfigMap
│
├── 04-livekit/          # LiveKit WebRTC SFU
│   ├── deployment.yaml        # Deployment + Services
│   └── README.md              # LiveKit documentation
│
├── 06-coturn/           # TURN/STUN server for calls
│   └── deployment.yaml        # DaemonSet + Services + Secret
│
└── README.md            # This file
```

**Note:** Directory numbering has gaps (no 05, 07, 08) as some planned components were not included:
- 05: Reserved
- 07: Sygnal (push notifications) - NOT included (requires external Apple/Google servers)
- 08: key_vault - Moved to LI instance (li-instance/05-key-vault/)

## Components

### 1. Synapse Main Process (01-synapse/)
- **Purpose**: Core homeserver process
- **Replicas**: 1 (must not scale)
- **Handles**: Background tasks, pushers, admin API
- **Resources**: 2-4Gi memory, 1-2 CPU cores
- **Ports**: 8008 (HTTP), 9093 (replication), 9090 (metrics)

### 2. Synapse Workers (02-workers/)
Nine worker types for horizontal scaling:
- **Synchrotron** (4-16 replicas): /sync long-polling connections
- **Generic Worker** (2-16 replicas): General client API requests
- **Media Repository** (2-8 replicas): Media upload/download/thumbnailing
- **Event Persister** (2-8 replicas): Database write distribution
- **Federation Sender** (2-8 replicas): Outbound federation traffic

### 3. Element Web (02-element-web/)
- **Purpose**: Official Matrix web client
- **Replicas**: 2 for HA
- **Resources**: 64-128Mi memory, 50-100m CPU
- **Endpoint**: https://chat.example.com

### 4. HAProxy (03-haproxy/)
- **Purpose**: Intelligent routing to worker pools
- **Replicas**: 2 for HA
- **Routing**:
  - `/_matrix/client/*/sync` → Synchrotron workers
  - `/_matrix/media/*` → Media workers
  - `/_matrix/client/*` → Generic workers
  - `/_synapse/admin/*` → Main process
  - `/_matrix/federation/*` → Main process
- **Endpoints**:
  - Port 8008: Client API
  - Port 8448: Federation API
  - Port 8404: Statistics dashboard

## Deployment Order

Deploy components in this order:

```bash
# 1. Ensure Phase 1 infrastructure is running
kubectl get cluster -n matrix matrix-postgresql
kubectl get statefulset -n matrix redis
kubectl get tenant -n matrix minio

# 2. Deploy Synapse main process
cd 01-synapse
kubectl apply -f secrets.yaml
kubectl apply -f configmap.yaml
kubectl apply -f main-statefulset.yaml
kubectl apply -f services.yaml

# Wait for main process to be ready
kubectl wait --for=condition=ready pod/synapse-main-0 -n matrix --timeout=300s

# 3. Deploy workers (in order)
cd ../02-workers
kubectl apply -f event-persister-deployment.yaml
kubectl apply -f federation-sender-deployment.yaml
kubectl apply -f media-repository-deployment.yaml
kubectl apply -f synchrotron-deployment.yaml
kubectl apply -f generic-worker-deployment.yaml

# Wait for workers to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=synapse -n matrix --timeout=300s

# 4. Deploy HAProxy
cd ../03-haproxy
kubectl apply -f deployment.yaml

# Wait for HAProxy
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=haproxy -n matrix --timeout=120s

# 5. Deploy Element Web
cd ../02-element-web
kubectl apply -f deployment.yaml

# Wait for Element Web
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=element-web -n matrix --timeout=120s
```

## Verification

### Check All Components

```bash
# Check main process
kubectl get statefulset -n matrix synapse-main
kubectl logs -n matrix synapse-main-0 | grep "Synapse now listening"

# Check workers
kubectl get deployments -n matrix | grep synapse
kubectl get pods -n matrix -l app.kubernetes.io/name=synapse

# Check HAProxy
kubectl get deployment -n matrix haproxy
kubectl get pods -n matrix -l app.kubernetes.io/name=haproxy

# Check Element Web
kubectl get deployment -n matrix element-web
kubectl get pods -n matrix -l app.kubernetes.io/name=element-web
```

### Test Client API via HAProxy

```bash
# Port-forward HAProxy
kubectl port-forward -n matrix svc/haproxy-client 8008:8008

# Test health endpoint
curl http://localhost:8008/health

# Test client API
curl http://localhost:8008/_matrix/client/versions
```

### Test Federation via HAProxy

```bash
# Port-forward HAProxy federation
kubectl port-forward -n matrix svc/haproxy-federation 8448:8448

# Test federation endpoint
curl http://localhost:8448/_matrix/federation/v1/version
```

### Check HAProxy Statistics

```bash
# Port-forward stats
kubectl port-forward -n matrix svc/haproxy-stats 8404:8404

# View statistics dashboard
open http://localhost:8404/stats
```

### Test Element Web

```bash
# Get Element Web URL from Ingress
kubectl get ingress -n matrix element-web

# Access in browser
open https://chat.example.com
```

## Traffic Flow

### Client Request Flow

1. **User** → https://matrix.example.com/_matrix/client/*/sync
2. **NGINX Ingress** → TLS termination, forwards to HAProxy
3. **HAProxy** → Routes based on URL pattern
4. **Synchrotron Worker** → Handles /sync long-polling
5. **Worker** → Queries PostgreSQL, gets updates via Redis replication
6. **Response** → Back through HAProxy → NGINX → User

### Federation Request Flow

1. **Remote Server** → https://matrix.example.com:8448/_matrix/federation/...
2. **NGINX Ingress** → TLS termination, forwards to HAProxy (port 8448)
3. **HAProxy** → Routes to main process
4. **Main Process** → Handles inbound federation
5. **Federation Sender Workers** → Handle outbound federation (separate process)

### Media Upload Flow

1. **User** → https://matrix.example.com/_matrix/media/*/upload
2. **NGINX Ingress** → Forwards with 100MB body size limit
3. **HAProxy** → Routes to media workers
4. **Media Worker** → Processes upload, stores in MinIO S3
5. **Response** → Media URL returned to client

## Scaling

### By User Count

**100-1,000 CCU**:
- Main process: 2Gi memory, 1 CPU
- Workers: 2 synchrotron, 2 generic, 2 media, 2 event-persister, 1 fed-sender
- HAProxy: 256Mi memory, 250m CPU

**1,000-5,000 CCU**:
- Main process: 4Gi memory, 2 CPU
- Workers: 4 synchrotron, 4 generic, 4 media, 4 event-persister, 2 fed-sender
- HAProxy: 512Mi memory, 500m CPU

**5,000-10,000 CCU**:
- Main process: 8Gi memory, 4 CPU
- Workers: 8 synchrotron, 8 generic, 6 media, 6 event-persister, 4 fed-sender
- HAProxy: 1Gi memory, 1 CPU

**10,000-20,000 CCU**:
- Main process: 16Gi memory, 8 CPU
- Workers: 12 synchrotron, 12 generic, 8 media, 8 event-persister, 6 fed-sender
- HAProxy: 2Gi memory, 2 CPU

### Horizontal Pod Autoscaling (HPA)

Three worker types have HPA enabled:
- **synchrotron**: 4-16 replicas (CPU 60%, Memory 70%)
- **generic-worker**: 2-16 replicas (CPU 70%, Memory 80%)
- **media-repository**: 2-8 replicas (CPU 70%, Memory 80%)

## Monitoring

### Prometheus Metrics

All components expose metrics:
- **Synapse**: Port 9090, `/_synapse/metrics`
- **HAProxy**: Port 8404, `/stats;csv` (Prometheus format)

ServiceMonitors are configured for automatic scraping.

**Key Metrics**:
```promql
# Request rate by backend
rate(haproxy_backend_http_requests_total[5m])

# Backend latency
haproxy_backend_response_time_average_seconds

# Worker health
up{job="synapse-workers"}

# Sync connection count
synapse_replication_tcp_resource_connections_per_worker{worker_type="synchrotron"}
```

### Logs

All components log to stdout (captured by Kubernetes):

```bash
# Main process logs
kubectl logs -n matrix synapse-main-0 -f

# Worker logs (all)
kubectl logs -n matrix -l app.kubernetes.io/name=synapse -f

# HAProxy logs
kubectl logs -n matrix -l app.kubernetes.io/name=haproxy -f

# Element Web logs
kubectl logs -n matrix -l app.kubernetes.io/name=element-web -f
```

## Troubleshooting

### Synapse main won't start

See `01-synapse/README.md` troubleshooting section.

### Workers not connecting to main

```bash
# Check replication endpoint
kubectl exec -n matrix synapse-main-0 -- curl http://127.0.0.1:9093/health

# Check worker logs
kubectl logs -n matrix -l app.kubernetes.io/component=generic-worker

# Verify Redis connectivity
kubectl exec -n matrix <worker-pod> -- redis-cli -h redis ping
```

### HAProxy routing issues

```bash
# Check HAProxy stats
kubectl port-forward -n matrix svc/haproxy-stats 8404:8404
open http://localhost:8404/stats

# Check backend health (should all be green)
# Look for: synchrotron_workers, media_workers, generic_workers, synapse_main

# Check HAProxy logs for routing decisions
kubectl logs -n matrix -l app.kubernetes.io/name=haproxy | grep backend
```

### Element Web can't connect

```bash
# Check Element Web config
kubectl exec -n matrix <element-web-pod> -- cat /app/config.json

# Verify homeserver URL is correct (should be https://matrix.example.com)

# Test client API endpoint
curl https://matrix.example.com/_matrix/client/versions

# Check CORS headers
curl -H "Origin: https://chat.example.com" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: X-Requested-With" \
  -X OPTIONS \
  https://matrix.example.com/_matrix/client/versions -v
```

### 502/503 errors

```bash
# Check all backends are healthy in HAProxy
kubectl port-forward -n matrix svc/haproxy-stats 8404:8404
open http://localhost:8404/stats

# Check worker pod health
kubectl get pods -n matrix -l app.kubernetes.io/name=synapse

# Check for crashlooping pods
kubectl get pods -n matrix --field-selector=status.phase!=Running

# Check events
kubectl get events -n matrix --sort-by='.lastTimestamp'
```

## Security

### TLS/SSL
- **External**: TLS terminated at NGINX Ingress (Let's Encrypt)
- **Internal**: Unencrypted HTTP within cluster (trusted network)
- **Federation**: TLS on port 8448 (standard Matrix federation)

### Network Policies
- Enforced by Phase 1 NetworkPolicies
- HAProxy can access: Synapse main, all workers
- Workers can access: PostgreSQL, Redis, MinIO
- Element Web: Isolated, no backend access

### Secrets Management
- All secrets in Kubernetes Secrets
- In production: Use sealed-secrets, external-secrets, or Vault
- Signing key: Generated per-deployment, never shared

## Next Steps

After deploying the main instance:

1. **Phase 2.4**: Deploy supporting services
   - LiveKit (video/voice calling)
   - coturn (TURN/STUN server)
   - NOTE: Sygnal (push) not included - requires external servers
   - key_vault (E2EE recovery key storage - CRITICAL for LI)

2. **Phase 3**: Deploy LI instance
   - Synapse LI (read-only instance)
   - Element Web LI (with deleted message display)
   - Synapse Admin LI (forensics interface)
   - Sync system (PostgreSQL logical replication)

3. **Phase 4**: Deploy monitoring stack
   - Prometheus + Alertmanager
   - Grafana + dashboards
   - Loki for log aggregation

4. **Phase 5**: Deploy antivirus system
   - ClamAV DaemonSet
   - Scan workers
   - Synapse spam checker integration

## References

- [Synapse Documentation](https://matrix-org.github.io/synapse/latest/)
- [Element Web](https://github.com/element-hq/element-web)
- [HAProxy Documentation](https://www.haproxy.org/documentation.html)
- [Matrix Specification](https://spec.matrix.org/)
