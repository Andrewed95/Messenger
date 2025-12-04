# Synapse Workers Deployment

This directory contains Kubernetes manifests for horizontally scalable Synapse worker processes. Workers distribute load across multiple pods for production Matrix deployments supporting 100-20,000 concurrent users.

> **Note on Federation**: Federation is **disabled by default** per CLAUDE.md section 12. The `federation-sender-deployment.yaml` is NOT deployed by default. Only deploy it if you enable federation. See "Federation Workers (Optional)" section below.

## Worker Types

Nine worker types are configured:

### 1. Generic Worker (`generic-worker-deployment.yaml`)
**Purpose**: Handles general client API endpoints
**Endpoints**: Most `/_matrix/client/*` endpoints except /sync
**Scaling**: 2-16 replicas (HPA enabled)
**Resources**: 512Mi-1Gi memory, 250-500m CPU per pod

**Use Case**: General client requests (messages, rooms, events, etc.)

### 2. Event Persister (`event-persister-deployment.yaml`)
**Purpose**: Dedicated database write workers
**Endpoints**: Internal only (no HTTP endpoints)
**Scaling**: 2-8 replicas (manual)
**Resources**: 1-2Gi memory, 500-1000m CPU per pod

**Use Case**: Offload event writing from main process
**CRITICAL**: Changing replica count requires restarting ALL Synapse processes

### 3. Federation Sender (`federation-sender-deployment.yaml`) - OPTIONAL
**Purpose**: Outbound federation traffic to remote Matrix servers
**Endpoints**: Internal only (no HTTP endpoints)
**Scaling**: 2-8 replicas (manual)
**Resources**: 512Mi-1Gi memory, 250-500m CPU per pod

**Use Case**: Handle federation traffic distribution
**IMPORTANT**: Federation is disabled by default. Only deploy this worker if federation is enabled.

### 4. Media Repository (`media-repository-statefulset.yaml`)
**Purpose**: Media upload/download handling
**Endpoints**: `/_matrix/media/*`, upload/download endpoints
**Scaling**: 2-8 replicas (HPA enabled)
**Resources**: 1-2Gi memory, 500-1000m CPU per pod

**Use Case**: Offload media processing and thumbnailing
**Note**: Uses MinIO S3 for storage, local 10Gi cache per pod

### 5. Synchrotron (`synchrotron-deployment.yaml`)
**Purpose**: `/sync` endpoint handling (most resource-intensive)
**Endpoints**: `/_matrix/client/*/sync` and related
**Scaling**: 4-16 replicas (aggressive HPA)
**Resources**: 1-2Gi memory, 500-1000m CPU per pod

**Use Case**: Handle thousands of long-polling /sync connections
**Note**: Most heavily scaled worker type, uses strong anti-affinity

### 6. Presence Writer (`presence-writer-deployment.yaml`)
**Purpose**: Handles user presence updates (online/offline/unavailable)
**Endpoints**: Internal only (stream writer)
**Scaling**: 2 replicas (StatefulSet)
**Resources**: 256-512Mi memory, 100-250m CPU per pod

**Use Case**: Offload presence stream processing from main process
**CRITICAL**: Listed in instance_map - changing replicas requires config update

### 7. Typing Writer (`typing-writer-deployment.yaml`)
**Purpose**: Handles typing indicator updates ("User is typing...")
**Endpoints**: Internal only (stream writer)
**Scaling**: 2 replicas (StatefulSet)
**Resources**: 256-512Mi memory, 100-250m CPU per pod

**Use Case**: Offload typing notification stream from main process
**CRITICAL**: Listed in instance_map - changing replicas requires config update

### 8. To-Device Writer (`todevice-writer-deployment.yaml`)
**Purpose**: Handles to-device messages (E2EE key exchanges, etc.)
**Endpoints**: Internal only (stream writer)
**Scaling**: 2 replicas (StatefulSet)
**Resources**: 256-512Mi memory, 100-250m CPU per pod

**Use Case**: Offload E2EE key exchange traffic from main process
**CRITICAL**: Listed in instance_map - changing replicas requires config update

### 9. Receipts Writer (`receipts-writer-deployment.yaml`)
**Purpose**: Handles read receipt updates
**Endpoints**: Internal only (stream writer)
**Scaling**: 2 replicas (StatefulSet)
**Resources**: 256-512Mi memory, 100-250m CPU per pod

**Use Case**: Offload read receipt stream from main process
**CRITICAL**: Listed in instance_map - changing replicas requires config update

## Architecture

```
┌─────────────────┐
│  Main Process   │ ← Background tasks, pushers, admin
│   (1 replica)   │
└────────┬────────┘
         │
         │ Replication (port 9093)
         │
    ┌────┴──────────────────────────────┐
    │          Redis Pub/Sub            │
    └────┬──────────────────────────────┘
         │
    ┌────┴─────────────────────────────────┐
    │                                      │
┌───▼────────┐ ┌──────────┐ ┌───────────┐ │
│  Generic   │ │  Media   │ │Synchrotron│ │
│  Workers   │ │Repository│ │  Workers  │ │
│  (2-16)    │ │  (2-8)   │ │   (4-16)  │ │
└────────────┘ └──────────┘ └───────────┘ │
                                          │
┌──────────────┐ ┌───────────────────────┐
│    Event     │ │  Federation           │
│  Persisters  │ │   Senders (OPTIONAL)  │
│   (2-8)      │ │   (2-8)               │
└──────────────┘ └───────────────────────┘
```

> **Note**: Federation Senders are OPTIONAL - only deployed when federation is enabled.

## Deployment Order

Deploy workers AFTER the main process is running:

```bash
# 1. Ensure main process is healthy
kubectl get statefulset -n matrix synapse-main
kubectl logs -n matrix synapse-main-0 | grep "Synapse now listening"

# 2. Deploy workers in order
kubectl apply -f event-persister-deployment.yaml      # Deploy first (write workers)
kubectl apply -f media-repository-statefulset.yaml    # Media handling
kubectl apply -f synchrotron-deployment.yaml          # Sync endpoints
kubectl apply -f generic-worker-deployment.yaml       # General endpoints (last)

# OPTIONAL: Deploy federation-sender ONLY if federation is enabled
# kubectl apply -f federation-sender-deployment.yaml

# 3. Verify workers are running
kubectl get deployments -n matrix | grep synapse
kubectl get pods -n matrix -l app.kubernetes.io/name=synapse

# 4. Check worker health
kubectl logs -n matrix -l app.kubernetes.io/component=generic-worker --tail=50
kubectl logs -n matrix -l app.kubernetes.io/component=event-persister --tail=50
```

### Startup Dependencies

Workers depend on PostgreSQL, Redis, and the main Synapse process. The deployment handles
these dependencies through:

1. **Deployment Ordering**: The `deploy-all.sh` script deploys infrastructure (PostgreSQL,
   Redis, MinIO) before main instance components. Follow this order for manual deployments.

2. **Kubernetes Restart Policy**: If a worker starts before dependencies are ready, it will
   crash and Kubernetes will automatically restart it. This is expected behavior during
   initial deployment.

3. **Readiness Probes**: Workers have readiness probes that prevent traffic routing until
   the worker is fully initialized and connected to its dependencies.

**Note**: Workers do not include explicit wait-for-postgres/redis init containers by design.
The startup mechanism relies on Kubernetes' restart capability and proper deployment ordering.
If you prefer cleaner startup logs without initial crash loops, you can add wait init containers:

```yaml
# Example wait-for-postgres init container (optional)
initContainers:
  - name: wait-for-postgres
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z matrix-postgresql-rw.matrix.svc.cluster.local 5432; do echo waiting for postgres; sleep 2; done']
  - name: wait-for-redis
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z redis.matrix.svc.cluster.local 6379; do echo waiting for redis; sleep 2; done']
  # ... existing generate-worker-config init container
```

## Configuring Stream Writers

When event persisters are deployed, you need to update the homeserver.yaml to distribute writes across workers.

**Option 1: Update ConfigMap** (requires main process restart)

Edit `main-instance/01-synapse/configmap.yaml`:

```yaml
# Find the stream_writers section and update:
stream_writers:
  events: event_persister  # Send to event persister pods
  typing: event_persister
  to_device: event_persister
  account_data: event_persister
  receipts: event_persister
  presence: event_persister
```

Then apply and restart:
```bash
kubectl apply -f ../01-synapse/configmap.yaml
kubectl rollout restart statefulset -n matrix synapse-main
```

**Option 2: Dynamic Configuration** (if using instance_map)

For production deployments with multiple event persisters, configure instance_map:

```yaml
instance_map:
  main:
    host: synapse-main-0.synapse-main.matrix.svc.cluster.local
    port: 9093
  event_persister_0:
    host: synapse-event-persister-0.synapse-event-persister.matrix.svc.cluster.local
    port: 9093
  event_persister_1:
    host: synapse-event-persister-1.synapse-event-persister.matrix.svc.cluster.local
    port: 9093

stream_writers:
  events:
    - event_persister_0
    - event_persister_1
```

## HAProxy Integration (Phase 2.3)

Workers expose endpoints that HAProxy routes to based on URL patterns:

**Generic Workers**:
- `/_matrix/client/*/rooms/*/messages`
- `/_matrix/client/*/rooms/*/members`
- `/_matrix/client/*/keys/*`
- Most read-only client endpoints

**Synchrotron Workers**:
- `/_matrix/client/*/sync` (all /sync variants)
- `/_matrix/client/*/events`
- `/_matrix/client/*/initialSync`

**Media Workers**:
- `/_matrix/media/*`
- `/_matrix/client/*/upload`
- `/_matrix/client/*/download`

HAProxy configuration will be in `../03-haproxy/`.

## Scaling Guidelines

### By User Count

> **Note**: Federation-sender is NOT deployed by default. The replica counts below only apply if federation is enabled.

**100-1,000 CCU**:
```yaml
generic-worker: 2 replicas
event-persister: 2 replicas
media-repository: 2 replicas
synchrotron: 4 replicas
# federation-sender: 1 replica (OPTIONAL - only if federation enabled)
```

**1,000-5,000 CCU**:
```yaml
generic-worker: 4 replicas
event-persister: 4 replicas
media-repository: 4 replicas
synchrotron: 8 replicas
# federation-sender: 2 replicas (OPTIONAL - only if federation enabled)
```

**5,000-10,000 CCU**:
```yaml
generic-worker: 8 replicas
event-persister: 6 replicas
media-repository: 6 replicas
synchrotron: 12 replicas
# federation-sender: 4 replicas (OPTIONAL - only if federation enabled)
```

**10,000-20,000 CCU**:
```yaml
generic-worker: 12 replicas
event-persister: 8 replicas
media-repository: 8 replicas
synchrotron: 16 replicas
# federation-sender: 6 replicas (OPTIONAL - only if federation enabled)
```

### Horizontal Pod Autoscaling (HPA)

Three worker types have HPA configured:

1. **generic-worker**: 2-16 replicas, CPU 70%, Memory 80%
2. **media-repository**: 2-8 replicas, CPU 70%, Memory 80%
3. **synchrotron**: 4-16 replicas, CPU 60%, Memory 70% (more aggressive)

Event persisters use manual scaling due to their stateful nature.
Federation senders (if enabled) also use manual scaling.

## Monitoring

All workers expose Prometheus metrics on port 9090 at `/_synapse/metrics`.

**Key Worker Metrics**:
```promql
# Request rate per worker type
rate(synapse_http_server_requests_total{job="synapse-workers"}[5m])

# Worker replication lag
synapse_replication_tcp_resource_lag{job="synapse-workers"}

# Worker connection count
synapse_replication_tcp_resource_connections_per_worker

# Event persistence rate (event persisters)
rate(synapse_storage_events_persisted_events_total[5m])
```

ServiceMonitors are created automatically via worker Services.

## Troubleshooting

### Worker won't start

```bash
# Check worker logs
kubectl logs -n matrix <worker-pod-name>

# Check init container logs
kubectl logs -n matrix <worker-pod-name> -c generate-worker-config

# Verify main process replication endpoint
kubectl exec -n matrix synapse-main-0 -- curl -v http://127.0.0.1:9093/health
```

### Workers can't connect to main process

```bash
# Test replication connectivity
kubectl run -n matrix tmp-test --rm -it --image=curlimages/curl -- \
  curl http://synapse-main-0.synapse-main.matrix.svc.cluster.local:9093/health

# Verify Redis is accessible
kubectl exec -n matrix <worker-pod> -- \
  redis-cli -h redis.matrix.svc.cluster.local -a "$REDIS_PASSWORD" ping
```

### High replication lag

```bash
# Check Redis performance
kubectl top pods -n matrix -l app.kubernetes.io/name=redis

# Check main process load
kubectl top pods -n matrix synapse-main-0

# Verify event persister count
kubectl get pods -n matrix -l app.kubernetes.io/component=event-persister

# Check replication metrics
kubectl port-forward -n matrix synapse-main-0 9090:9090
curl http://localhost:9090/_synapse/metrics | grep replication_lag
```

### Event persister scaling

When scaling event persisters:

1. Update deployment replicas
2. Update homeserver.yaml instance_map (if using named instances)
3. **Restart ALL processes**:
```bash
kubectl rollout restart statefulset -n matrix synapse-main
kubectl rollout restart deployment -n matrix synapse-generic-worker
kubectl rollout restart deployment -n matrix synapse-synchrotron
kubectl rollout restart deployment -n matrix synapse-media-repository
kubectl rollout restart deployment -n matrix synapse-event-persister
# Only if federation is enabled:
# kubectl rollout restart deployment -n matrix synapse-federation-sender
```

## Performance Tuning

### Connection Pooling

Each worker maintains database connections. With many workers, increase PostgreSQL max_connections:

```yaml
# In infrastructure/01-postgresql/main-cluster.yaml
postgresql:
  parameters:
    max_connections: "500"  # Adjust based on worker count
```

Formula: `max_connections = (workers × cp_max) + 50`

### Redis Memory

Workers use Redis for replication. Monitor Redis memory:

```bash
kubectl exec -n matrix redis-0 -- redis-cli -a "$REDIS_PASSWORD" info memory
```

Increase Redis memory if approaching limits (see `infrastructure/02-redis/`).

### Worker Resources

Adjust per-worker resources based on metrics:

```bash
# Check actual resource usage
kubectl top pods -n matrix -l app.kubernetes.io/name=synapse

# If consistently hitting limits, increase in deployment YAML
```

## Security

### Network Policies

Workers are allowed to:
- Access PostgreSQL (main cluster)
- Access Redis
- Access MinIO (media workers only)
- Connect to main process replication endpoint (port 9093)
- Be accessed by HAProxy/Ingress (client-facing workers only)

Network isolation is the organization's responsibility (per CLAUDE.md 7.4).

### Worker Isolation

Workers run with:
- Non-root user (991:991)
- Read-only root filesystem
- All capabilities dropped
- seccompProfile: RuntimeDefault

## Integration with Main Process

Workers require the main process for:
1. **Background tasks**: Main process runs all background jobs
2. **Pushers**: Push notifications handled by main
3. **Admin API**: Admin endpoints stay on main
4. **Replication**: All events replicated through main process
5. **Federation receivers**: Inbound federation handled by main

Main process must be running and healthy before deploying workers.

## Next Steps

After deploying workers:

1. **Phase 2.3**: Deploy HAProxy for intelligent routing to worker pools
2. **Phase 2.3**: Deploy Element Web for client access
3. **Phase 2.4**: Deploy supporting services (LiveKit, coturn, key_vault)

## References

- [Synapse Workers Documentation](https://matrix-org.github.io/synapse/latest/workers.html)
- [Worker Configuration](https://matrix-org.github.io/synapse/latest/usage/configuration/config_documentation.html#worker-configuration)
- [Scaling Synapse](https://matrix-org.github.io/synapse/latest/usage/administration/admin_faq.html#scaling-synapse)
