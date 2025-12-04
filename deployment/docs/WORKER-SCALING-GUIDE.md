# Synapse Worker Scaling Guide

Comprehensive guide for scaling Synapse workers based on load and concurrent users.

---

## Overview

Synapse uses a **worker architecture** to distribute load across multiple processes. This guide explains:
- Which workers to scale and when
- How to calculate required replica counts
- HPA vs manual scaling trade-offs
- Monitoring and tuning procedures

---

## Scaling Decision Tree

```
1. Are you experiencing high CPU on synapse-main?
   └─> Scale synchrotron workers (handles /sync requests)

2. Are you experiencing slow message delivery?
   └─> Scale event-persister workers (handles event writes)

3. Are you experiencing federation delays? (only if federation is enabled)
   └─> Scale federation-sender workers (OPTIONAL - only deployed if federation enabled)

4. Are you experiencing slow media uploads/downloads?
   └─> Scale media-repository workers (handles media operations)

5. Are you experiencing slow typing indicators / read receipts?
   └─> Scale typing-writer / receipts-writer workers
```

---

## Worker Types and Scaling Methods

### Synchrotron Workers (Deployment)

**Purpose**: Handle /sync requests from clients (most frequent operation)

**Scaling Method**: HPA (automatic) or manual

**Replica Formula**:
```
replicas = ceil(CCU / 250)
```

**Examples**:
- 100 CCU: 2 replicas (min HA)
- 1,000 CCU: 4 replicas
- 5,000 CCU: 8 replicas
- 10,000 CCU: 12 replicas
- 20,000 CCU: 16 replicas

**HPA Configuration**: See `deployment/main-instance/02-workers/hpa.yaml`

**Manual Scaling**:
```bash
# WHERE: kubectl-configured workstation
# WHEN: Need immediate scale-up without HPA
kubectl scale deployment synapse-synchrotron --replicas=8 -n matrix
kubectl get deployment synapse-synchrotron -n matrix
```

**Monitoring Metrics**:
- CPU utilization (target: 60-70%)
- `/sync` request latency (target: <500ms p95)
- Queue depth (target: <100)

---

### Generic Workers (Deployment)

**Purpose**: Handle general API requests (room joins, invites, profile updates)

**Scaling Method**: HPA (automatic) or manual

**Replica Formula**:
```
replicas = ceil(CCU / 300)
```

**Examples**:
- 100 CCU: 2 replicas (min HA)
- 1,000 CCU: 4 replicas
- 5,000 CCU: 6 replicas
- 10,000 CCU: 8 replicas
- 20,000 CCU: 10 replicas

**HPA Configuration**: See `deployment/main-instance/02-workers/hpa.yaml`

**Manual Scaling**:
```bash
kubectl scale deployment synapse-generic-worker --replicas=6 -n matrix
```

**Monitoring Metrics**:
- CPU utilization (target: 60-70%)
- API request latency (target: <1s p95)
- Request rate per worker (target: <50 req/s per worker)

---

### Event Persister Workers (StatefulSet)

**Purpose**: Write events to database (messages, state changes)

**Scaling Method**: MANUAL ONLY (cannot use HPA)

**Reason**: Listed in `stream_writers.events` in configmap.yaml, requires predictable pod names

**Replica Formula**:
```
replicas = max(2, ceil(messages_per_second / 50))
```

**Examples**:
- 100 CCU (~10 msg/s): 2 replicas
- 1,000 CCU (~50 msg/s): 2 replicas
- 5,000 CCU (~200 msg/s): 3 replicas
- 10,000 CCU (~400 msg/s): 4 replicas
- 20,000 CCU (~800 msg/s): 4 replicas

**Scaling Procedure**:

**Step 1: Update configmap.yaml**

```bash
# WHERE: kubectl-configured workstation
# WHEN: Scaling event-persister workers
kubectl edit configmap synapse-config -n matrix

# Add new worker to stream_writers.events:
stream_writers:
  events:
    - synapse-event-persister-0
    - synapse-event-persister-1
    - synapse-event-persister-2
    - synapse-event-persister-3  # NEW
    - synapse-event-persister-4  # NEW (if scaling to 5)

# Also add to instance_map:
instance_map:
  synapse-event-persister-3:
    host: synapse-event-persister-3.synapse-event-persister.matrix.svc.cluster.local
    port: 9093
  synapse-event-persister-4:
    host: synapse-event-persister-4.synapse-event-persister.matrix.svc.cluster.local
    port: 9093
```

**Step 2: Scale StatefulSet**

```bash
kubectl scale statefulset synapse-event-persister --replicas=5 -n matrix
kubectl wait --for=condition=ready pod/synapse-event-persister-3 -n matrix --timeout=5m
kubectl wait --for=condition=ready pod/synapse-event-persister-4 -n matrix --timeout=5m
```

**Step 3: Restart main process**

```bash
kubectl rollout restart statefulset synapse-main -n matrix
kubectl rollout status statefulset synapse-main -n matrix
```

**Monitoring Metrics**:
- Database write latency (target: <50ms p95)
- Events persisted per second (target: <100 per worker)
- Database connection pool usage (target: <80%)

---

### Federation Sender Workers (StatefulSet) - OPTIONAL

> **IMPORTANT**: Federation is DISABLED by default per CLAUDE.md section 12. This worker is NOT deployed by default. Only deploy and scale if you have enabled federation.

**Purpose**: Send events to other Matrix servers (outbound federation)

**Scaling Method**: MANUAL ONLY (cannot use HPA)

**Reason**: Listed in `federation_sender_instances` in configmap.yaml

**Replica Formula** (only if federation enabled):
```
replicas = max(2, ceil(federated_servers / 50))
```

**Examples**:
- Federation disabled (default): 0 replicas (NOT deployed)
- 1-50 servers: 2 replicas
- 100 servers: 2 replicas
- 200 servers: 4 replicas
- 500+ servers: 6+ replicas

**Scaling Procedure**: Same as event-persister (update configmap -> scale -> restart main)

**Monitoring Metrics**:
- Federation send queue depth (target: <1000)
- Outbound federation latency (target: <5s p95)
- Failed send rate (target: <1%)

---

### Media Repository Workers (StatefulSet)

**Purpose**: Handle media uploads, downloads, thumbnails

**Scaling Method**: MANUAL ONLY (cannot use HPA)

**Reason**: Listed in `instance_map` and `media_instance_running_background_jobs`

**Replica Formula**:
```
replicas = max(2, ceil(CCU / 1000))
```

**Examples**:
- 100 CCU: 2 replicas
- 1,000 CCU: 2 replicas
- 5,000 CCU: 2-3 replicas
- 10,000 CCU: 3 replicas
- 20,000 CCU: 4 replicas

**Scaling Procedure**: Same as event-persister, but also update `media_instance_running_background_jobs` in configmap

**Monitoring Metrics**:
- Media upload/download latency (target: <2s for 1MB file)
- S3 operation latency (target: <500ms)
- Thumbnail generation queue (target: <50)

---

### Stream Writer Workers (StatefulSets)

**Types**: typing-writer, todevice-writer, receipts-writer, presence-writer

**Purpose**: Handle high-frequency write streams

**Scaling Method**: MANUAL ONLY (cannot use HPA)

**Reason**: Listed in `stream_writers` in configmap.yaml

**Replica Formulas**:
```
typing-writer:    max(2, ceil(CCU / 5000))    # Low volume
todevice-writer:  max(2, ceil(CCU / 1000))    # High volume (E2EE keys)
receipts-writer:  max(2, ceil(CCU / 2000))    # Medium volume
presence-writer:  max(2, ceil(CCU / 3000))    # Medium volume
```

**Examples** (20,000 CCU):
- typing-writer: 2 replicas
- todevice-writer: 4 replicas (most critical for E2EE)
- receipts-writer: 3 replicas
- presence-writer: 3 replicas

**Scaling Procedure**: Same as event-persister (update configmap -> scale -> restart main)

**Monitoring Metrics**:
- Stream processing latency (target: <100ms)
- Queue depth per stream (target: <500)
- Replication lag (target: <1s)

---

## Scaling Strategy by Load

### Phase 1: 100-1,000 CCU (Small)

**Configuration**:
- Synchrotron: 2-4 replicas (HPA enabled)
- Generic worker: 2-4 replicas (HPA enabled)
- Event persister: 2 replicas (manual)
- Federation sender: 2 replicas (manual)
- Media repository: 2 replicas (manual)
- Stream writers: 2 replicas each (manual)

**Monitoring Focus**: CPU utilization, /sync latency

---

### Phase 2: 1,000-5,000 CCU (Medium)

**Configuration**:
- Synchrotron: 4-8 replicas (HPA enabled)
- Generic worker: 4-6 replicas (HPA enabled)
- Event persister: 2-3 replicas (manual)
- Federation sender: 2-4 replicas (manual)
- Media repository: 2-3 replicas (manual)
- Stream writers: 2 replicas each (manual)

**Monitoring Focus**: Database write latency, replication lag

---

### Phase 3: 5,000-10,000 CCU (Large)

**Configuration**:
- Synchrotron: 8-12 replicas (HPA enabled)
- Generic worker: 6-8 replicas (HPA enabled)
- Event persister: 3-4 replicas (manual)
- Federation sender: 4 replicas (manual)
- Media repository: 3 replicas (manual)
- Stream writers: 2-3 replicas each (manual)

**Monitoring Focus**: PostgreSQL connection pool, Redis memory

---

### Phase 4: 10,000-20,000 CCU (Very Large)

**Configuration**:
- Synchrotron: 12-16 replicas (HPA enabled)
- Generic worker: 8-10 replicas (HPA enabled)
- Event persister: 4 replicas (manual)
- Federation sender: 4-6 replicas (manual)
- Media repository: 3-4 replicas (manual)
- Stream writers: 3-4 replicas each (manual)

**Monitoring Focus**: All metrics, capacity planning for 30K+ CCU

---

## Troubleshooting

### High /sync Latency

**Symptoms**:
- Clients experience delays receiving messages
- /sync requests taking >1s

**Diagnosis**:
```bash
# Check synchrotron CPU:
kubectl top pods -n matrix -l app.kubernetes.io/component=synchrotron

# Check metrics (if available):
curl -s http://synapse-synchrotron-0.matrix.svc.cluster.local:9090/_synapse/metrics | grep synapse_http_server_response_time_seconds
```

**Solution**:
- Scale synchrotron workers (HPA will do this automatically if enabled)
- If HPA not enabled, manually scale: `kubectl scale deployment synapse-synchrotron --replicas=X -n matrix`

---

### Slow Message Delivery

**Symptoms**:
- Messages take several seconds to appear in rooms
- Database write latency high

**Diagnosis**:
```bash
# Check event-persister logs:
kubectl logs -n matrix -l app.kubernetes.io/component=event-persister --tail=100 | grep "slow"

# Check database activity:
kubectl exec -n matrix matrix-postgresql-0 -- psql -U synapse -d matrix -c "SELECT * FROM pg_stat_activity WHERE state = 'active';"
```

**Solution**:
- Scale event-persister workers (manual procedure above)
- Increase PostgreSQL resources if connection pool saturated

---

### Federation Queue Buildup (only if federation enabled)

> **Note**: This section only applies if you have enabled federation. Federation is disabled by default.

**Symptoms**:
- Federation send queue growing
- Delayed message delivery to remote servers

**Diagnosis**:
```bash
# Check federation metrics:
curl -s http://synapse-federation-sender-0.matrix.svc.cluster.local:9090/_synapse/metrics | grep synapse_federation_send_queue

# Check logs:
kubectl logs -n matrix -l app.kubernetes.io/component=federation-sender --tail=100 | grep "queue"
```

**Solution**:
- Scale federation-sender workers (manual procedure)
- Check network connectivity to remote servers
- Review federation allow/deny lists

---

## Best Practices

1. **Enable HPA for eligible workers** (synchrotron, generic-worker)
   - Automatic scaling reduces operational burden
   - Set appropriate min/max replicas

2. **Monitor before scaling**
   - Don't scale preemptively
   - Wait for consistent high load (>70% CPU for 5+ minutes)

3. **Scale StatefulSets during low traffic**
   - Requires main process restart
   - Plan maintenance window

4. **Test scaling in staging first**
   - Validate configuration changes
   - Ensure no connectivity issues

5. **Document scaling changes**
   - Record date, reason, new replica counts
   - Track performance impact

6. **Keep replica counts in config.env**
   - Maintain environment-specific values
   - Easy rollback if issues occur

---

## See Also

- **SCALING-GUIDE.md**: Overall system scaling (infrastructure + workers)
- **OPERATIONS-UPDATE-GUIDE.md**: Update procedures
- **deployment/main-instance/01-synapse/configmap.yaml**: Worker configuration
