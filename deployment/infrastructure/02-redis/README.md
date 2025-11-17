# Redis with Sentinel - High Availability Caching

## Overview

This directory contains Redis with Sentinel configuration for automatic failover and high availability.

**Why Redis Sentinel?**
- Synapse uses Redis for worker HTTP replication
- LiveKit uses Redis for distributed state management
- key_vault uses Redis for Django session storage
- Production systems require automatic failover

## Architecture

### Redis Sentinel Pattern
- **3 Redis instances** in StatefulSet (1 master + 2 replicas)
- **3 Sentinel processes** (sidecar containers)
- **Automatic failover** in 5-10 seconds
- **Quorum**: 2 (majority of 3 Sentinels must agree)

**Topology**:
```
┌─────────────────────────────────────────┐
│  redis-0 (Initial Master)               │
│  ├─ redis container (port 6379)         │
│  └─ sentinel sidecar (port 26379)       │
└─────────────────────────────────────────┘
         ↓ replication
┌─────────────────────────────────────────┐
│  redis-1 (Replica)                      │
│  ├─ redis container (port 6379)         │
│  └─ sentinel sidecar (port 26379)       │
└─────────────────────────────────────────┘
         ↓ replication
┌─────────────────────────────────────────┐
│  redis-2 (Replica)                      │
│  ├─ redis container (port 6379)         │
│  └─ sentinel sidecar (port 26379)       │
└─────────────────────────────────────────┘
```

## Components

### 1. Redis ConfigMap
- AOF persistence enabled (appendonly yes)
- RDB disabled (AOF is safer)
- 2GB memory limit with allkeys-lru eviction
- Password authentication enabled

### 2. Sentinel ConfigMap
- Monitors master at `redis-0.redis-headless`
- Quorum: 2 (needs 2 Sentinels to agree on failover)
- Down after: 5000ms (5 seconds)
- Failover timeout: 10000ms (10 seconds)
- Parallel syncs: 1 (one replica at a time)

### 3. StatefulSet
- 3 replicas for HA
- Each pod runs 2 containers:
  - Redis (main database)
  - Sentinel (monitoring and failover)
- Pod anti-affinity (prefer different nodes)
- PVC for persistent data (10Gi per instance)

### 4. Services
- `redis-headless`: For StatefulSet pod discovery
- `redis`: For application connections

### 5. PodDisruptionBudget
- Ensures minimum 2 pods available during updates

## Prerequisites

1. **StorageClass** named `standard` (or adjust in manifests)
2. **Generate Redis password**:
```bash
openssl rand -base64 32
```

## Deployment

### Step 1: Create Password Secret

```bash
# Edit redis-secret.yaml and replace password
kubectl apply -f redis-secret.yaml
```

### Step 2: Deploy Redis with Sentinel

```bash
kubectl apply -f redis-statefulset.yaml
```

### Step 3: Wait for Pods

```bash
kubectl wait --for=condition=Ready pod/redis-0 -n matrix --timeout=5m
kubectl wait --for=condition=Ready pod/redis-1 -n matrix --timeout=5m
kubectl wait --for=condition=Ready pod/redis-2 -n matrix --timeout=5m
```

## Verification

### Check Pods

```bash
kubectl get pods -n matrix -l app.kubernetes.io/name=redis
```

Expected output:
```
NAME      READY   STATUS    RESTARTS   AGE
redis-0   2/2     Running   0          2m
redis-1   2/2     Running   0          2m
redis-2   2/2     Running   0          2m
```

### Check Replication Status

```bash
# Get password
REDIS_PASSWORD=$(kubectl get secret redis-password -n matrix -o jsonpath='{.data.password}' | base64 -d)

# Check replication on redis-0
kubectl exec -n matrix redis-0 -c redis -- redis-cli -a "$REDIS_PASSWORD" INFO replication
```

Expected output:
```
# Replication
role:master
connected_slaves:2
slave0:ip=10.x.x.x,port=6379,state=online,offset=xxxx
slave1:ip=10.x.x.x,port=6379,state=online,offset=xxxx
```

### Check Sentinel Status

```bash
# Check sentinel info
kubectl exec -n matrix redis-0 -c sentinel -- redis-cli -p 26379 SENTINEL masters

# Check all sentinels
kubectl exec -n matrix redis-0 -c sentinel -- redis-cli -p 26379 SENTINEL sentinels mymaster
```

### Test Failover (Optional)

```bash
# Manually trigger failover
kubectl exec -n matrix redis-0 -c sentinel -- redis-cli -p 26379 SENTINEL failover mymaster

# Watch pods
kubectl get pods -n matrix -w -l app.kubernetes.io/name=redis
```

Expected: New master elected within 5-10 seconds

## Application Connection Strings

### Synapse (Worker Replication)

```yaml
# homeserver.yaml
redis:
  enabled: true
  host: redis.matrix.svc.cluster.local
  port: 6379
  password: <from-secret>
  dbid: 0
```

**Synapse uses master for writes, sentinels handle failover transparently**

### LiveKit (Distributed State)

```yaml
# livekit.yaml
redis:
  address: redis:6379
  password: <from-secret>
  db: 1
  use_tls: false
```

### key_vault (Django Sessions)

```python
# settings.py
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.redis.RedisCache',
        'LOCATION': 'redis://redis.matrix.svc.cluster.local:6379/2',
        'OPTIONS': {
            'PASSWORD': '<from-secret>',
        }
    }
}

SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
SESSION_CACHE_ALIAS = 'default'
```

### Client Libraries with Sentinel Support

For applications that support Sentinel natively:

**Python (redis-py)**:
```python
from redis.sentinel import Sentinel

sentinel = Sentinel([
    ('redis-0.redis-headless.matrix.svc.cluster.local', 26379),
    ('redis-1.redis-headless.matrix.svc.cluster.local', 26379),
    ('redis-2.redis-headless.matrix.svc.cluster.local', 26379)
], password='xxx')

master = sentinel.master_for('mymaster', password='xxx')
slave = sentinel.slave_for('mymaster', password='xxx')
```

**Go (go-redis)**:
```go
import "github.com/go-redis/redis/v8"

client := redis.NewFailoverClient(&redis.FailoverOptions{
    MasterName:    "mymaster",
    SentinelAddrs: []string{
        "redis-0.redis-headless.matrix.svc.cluster.local:26379",
        "redis-1.redis-headless.matrix.svc.cluster.local:26379",
        "redis-2.redis-headless.matrix.svc.cluster.local:26379",
    },
    Password: "xxx",
})
```

## Monitoring

### Prometheus Metrics

Redis doesn't expose Prometheus metrics natively. Options:

1. **redis_exporter** (recommended):
```bash
# Deploy redis_exporter as sidecar or separate deployment
# It will expose metrics on port 9121
```

2. **Manual queries**:
```bash
# Memory usage
kubectl exec -n matrix redis-0 -c redis -- redis-cli -a "$REDIS_PASSWORD" INFO memory

# Stats
kubectl exec -n matrix redis-0 -c redis -- redis-cli -a "$REDIS_PASSWORD" INFO stats

# Replication
kubectl exec -n matrix redis-0 -c redis -- redis-cli -a "$REDIS_PASSWORD" INFO replication
```

### Key Metrics to Monitor
- `used_memory_rss` - Resident memory
- `connected_clients` - Active connections
- `evicted_keys` - Keys evicted due to maxmemory
- `keyspace_hits` / `keyspace_misses` - Cache hit ratio
- `master_link_status` - Replication health
- Sentinel: `sentinel_master` - Master status

## Maintenance

### Scaling Replicas

```bash
# Scale to 5 instances
kubectl scale statefulset redis -n matrix --replicas=5

# Update Sentinel quorum (requires config update)
# Quorum should be (N/2) + 1, e.g., for 5 instances: quorum=3
```

### Updating Redis Version

```bash
# Update image in redis-statefulset.yaml
# Redis will perform rolling update automatically
kubectl apply -f redis-statefulset.yaml
```

Rolling update order:
1. redis-2 (replica) updated
2. Wait for sync
3. redis-1 (replica) updated
4. Wait for sync
5. redis-0 (master) updated - triggers failover to replica

### Password Rotation

```bash
# 1. Update secret with new password
kubectl create secret generic redis-password-new \
  --from-literal=password=NEW_PASSWORD -n matrix

# 2. Update redis-statefulset.yaml to use new secret
# 3. Perform rolling restart
kubectl rollout restart statefulset/redis -n matrix

# 4. Update all application configs
```

## Troubleshooting

### Sentinels Not Detecting Master

```bash
# Check sentinel logs
kubectl logs -n matrix redis-0 -c sentinel

# Verify sentinel can resolve master hostname
kubectl exec -n matrix redis-0 -c sentinel -- nslookup redis-0.redis-headless.matrix.svc.cluster.local

# Check sentinel configuration
kubectl exec -n matrix redis-0 -c sentinel -- cat /data/sentinel.conf
```

### Replication Lag

```bash
# Check replication offset difference
kubectl exec -n matrix redis-0 -c redis -- redis-cli -a "$REDIS_PASSWORD" INFO replication | grep offset
```

### Split Brain (Multiple Masters)

```bash
# Check all instances
for i in 0 1 2; do
  echo "=== redis-$i ==="
  kubectl exec -n matrix redis-$i -c redis -- redis-cli -a "$REDIS_PASSWORD" ROLE
done

# If multiple masters detected, manually fix:
kubectl exec -n matrix redis-1 -c redis -- redis-cli -a "$REDIS_PASSWORD" REPLICAOF redis-0.redis-headless.matrix.svc.cluster.local 6379
```

### High Memory Usage

```bash
# Check memory stats
kubectl exec -n matrix redis-0 -c redis -- redis-cli -a "$REDIS_PASSWORD" INFO memory

# Check keyspace
kubectl exec -n matrix redis-0 -c redis -- redis-cli -a "$REDIS_PASSWORD" INFO keyspace

# If needed, flush specific database
kubectl exec -n matrix redis-0 -c redis -- redis-cli -a "$REDIS_PASSWORD" FLUSHDB
```

### Connection Issues

```bash
# Test connection from another pod
kubectl run -n matrix redis-test --rm -it --image=redis:7.2-alpine -- redis-cli -h redis -a "$REDIS_PASSWORD" ping

# Check service endpoints
kubectl get endpoints redis -n matrix
```

## Backup & Recovery

### AOF Persistence

Redis is configured with AOF (Append-Only File) for durability:
- Every write is logged
- Replayed on startup
- Automatic rewrite when file grows

**Backup AOF files**:
```bash
# From each pod
kubectl cp matrix/redis-0:/data/appendonly.aof ./backup/redis-0-appendonly.aof -c redis
```

### Restore from Backup

```bash
# 1. Stop Redis pods
kubectl scale statefulset redis -n matrix --replicas=0

# 2. Restore AOF file to PVC
kubectl run -n matrix redis-restore --image=redis:7.2-alpine --command -- sleep 3600
kubectl cp ./backup/redis-0-appendonly.aof matrix/redis-restore:/data/appendonly.aof

# 3. Scale back up
kubectl scale statefulset redis -n matrix --replicas=3
```

## Performance Tuning

Current configuration optimized for:
- **Memory**: 2GB max per instance
- **Eviction**: allkeys-lru (Least Recently Used)
- **Persistence**: AOF with fsync everysec

### For Higher Throughput

```yaml
# Adjust in redis.conf
appendfsync no  # Faster but less durable
```

### For More Memory

```yaml
# Increase in StatefulSet resources
resources:
  limits:
    memory: "4Gi"

# Update maxmemory in redis.conf
maxmemory 4gb
```

### For Read-Heavy Workload

```yaml
# Use read-only replicas
# Connect to: redis-1 or redis-2 for reads
# Connect to: redis (service) for writes
```

## Security Considerations

1. **Password Protection**: Enabled via `requirepass` and `masterauth`
2. **Network Policies**: See `../04-networking/networkpolicies.yaml`
3. **No External Access**: ClusterIP only, no LoadBalancer/NodePort
4. **TLS**: Currently disabled (add if required)

### Enabling TLS (Optional)

```yaml
# Generate certificates first
# Update redis.conf:
tls-port 6379
port 0
tls-cert-file /path/to/redis.crt
tls-key-file /path/to/redis.key
tls-ca-cert-file /path/to/ca.crt
```

## Differences from Bitnami Chart

| Feature | Bitnami Chart | This Deployment |
|---------|---------------|-----------------|
| Complexity | 2000+ lines values.yaml | 250 lines manifest |
| Helm Required | Yes | No (raw Kubernetes) |
| Sentinel Mode | Optional | Always enabled |
| Container Pattern | Separate deployments | Sidecar pattern |
| Configuration | Helm values | ConfigMaps |
| Customization | Template-based | Direct YAML |
| Use Case | General purpose | Matrix-specific |

## Scaling Guidelines

| CCU Range | Redis Instances | Memory per Instance | Notes |
|-----------|-----------------|---------------------|-------|
| 100 | 3 | 256Mi-1Gi | Minimum HA |
| 1,000 | 3 | 1-2Gi | Standard |
| 5,000 | 3 | 2-4Gi | Increase memory |
| 10,000 | 5 | 4Gi | Add replicas |
| 20,000 | 5 | 8Gi | Max memory + replicas |

## References

- [Redis Sentinel Documentation](https://redis.io/docs/management/sentinel/)
- [Redis Persistence](https://redis.io/docs/management/persistence/)
- [Redis Replication](https://redis.io/docs/management/replication/)
- [Kubernetes StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
