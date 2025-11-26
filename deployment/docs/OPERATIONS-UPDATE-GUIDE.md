# Operations and Update Guide
## Complete Guide for Managing, Updating, and Scaling Your Matrix/Synapse Deployment


---

## Table of Contents

1. [Overview](#1-overview)
2. [Updating Service Versions](#2-updating-service-versions)
3. [Changing Configurations](#3-changing-configurations)
4. [Scaling Services](#4-scaling-services)
5. [Backup and Restore](#5-backup-and-restore)
6. [Maintenance Windows](#6-maintenance-windows)
7. [Monitoring During Operations](#7-monitoring-during-operations)
8. [Troubleshooting Common Issues](#8-troubleshooting-common-issues)

---

## 1. Overview

### 1.1 General Principles

**Before ANY change:**
1. ✅ Review current system status
2. ✅ Create backup (database and configs)
3. ✅ Plan rollback strategy
4. ✅ Schedule maintenance window (if needed)
5. ✅ Test in staging (if available)

**During change:**
1. Monitor logs and metrics
2. Validate each step before proceeding
3. Document what you're doing

**After change:**
1. Validate service health
2. Test functionality
3. Monitor for 
4. Document what changed

### 1.2 Safety Levels

| Risk Level | Examples | Backup Required | Maintenance Window | Can Rollback |
|------------|----------|-----------------|-------------------|--------------|
| **Low** | Scale up replicas, update monitoring | Optional | No | Yes (instant) |
| **Medium** | Update service versions, config changes | Yes | Recommended | Yes (minutes) |
| **High** | Database schema changes, major version upgrades | Yes (multiple) | Yes | Maybe (hours) |
| **Critical** | PostgreSQL major version, storage migration | Yes (offsite too) | Yes | Difficult |

---

## 2. Updating Service Versions

### 2.1 Synapse Version Update

**Risk Level:** Medium
**Downtime:** None (rolling update)
**Backup Required:** Yes

**When to Update:**
- Security patches released
- New features needed
- Bug fixes available

**Pre-Update Checklist (Required):**

```bash
# WHERE: kubectl-configured workstation
# WHEN: Before starting update
# WHY: Establish baseline and prepare rollback capability

# 1. Record current version (for rollback reference)
kubectl get deployment synapse-main -n matrix -o jsonpath='{.spec.template.spec.containers[0].image}'
# Note the current version (e.g., matrixdotorg/synapse:v1.102.0)

# 2. Review changelog for breaking changes
# Visit: https://github.com/element-hq/synapse/releases
# Check for: breaking changes, database migrations, config changes

# 3. Backup database (rollback safety)
kubectl exec -n matrix matrix-postgresql-0 -- \
  pg_dump -U synapse matrix > synapse-backup-$(date +%Y%m%d).sql

# 4. Backup current config (rollback safety)
kubectl get configmap synapse-config -n matrix -o yaml > synapse-config-backup-$(date +%Y%m%d).yaml
```

**NOTE**: System health checks (pod status, resource usage) are automatically monitored via Prometheus/Grafana. Check Grafana dashboards before proceeding if you observe alerts.

**Update Procedure (Centralized Approach):**

All image versions are managed centrally in `values/images.yaml`. This ensures consistency across all deployments and simplifies updates.

```bash
# WHERE: kubectl-configured workstation, deployment/ directory
# WHEN: During planned maintenance or off-peak hours
# WHY: Centralized image management ensures consistency

# Step 1: Update version in values/images.yaml
# Edit the file and change the Synapse version:
nano values/images.yaml

# Change synapse version (all instances use same version):
# synapse:
#   main:
#     image: matrixdotorg/synapse:v1.120.0  # ← Update version here
#   workers:
#     image: matrixdotorg/synapse:v1.120.0  # ← Must match main
#   li:
#     image: matrixdotorg/synapse:v1.120.0  # ← Must match main

# Step 2: Apply updated manifests
# The deployment manifests reference images.yaml values
# Re-apply all Synapse deployments to pick up new images:

# Main Synapse
kubectl apply -f main-instance/01-synapse/
kubectl rollout status statefulset/synapse-main -n matrix

# Workers (one at a time to minimize disruption)
kubectl apply -f main-instance/02-workers/synchrotron-deployment.yaml
kubectl rollout status deployment/synapse-synchrotron -n matrix

kubectl apply -f main-instance/02-workers/generic-worker-deployment.yaml
kubectl rollout status deployment/synapse-generic-worker -n matrix

kubectl apply -f main-instance/02-workers/event-persister-deployment.yaml
kubectl rollout status statefulset/synapse-event-persister -n matrix

kubectl apply -f main-instance/02-workers/federation-sender-deployment.yaml
kubectl rollout status statefulset/synapse-federation-sender -n matrix

# Media repository and other workers
kubectl apply -f main-instance/02-workers/media-repository-statefulset.yaml
kubectl rollout status statefulset/synapse-media-repository -n matrix

kubectl apply -f main-instance/02-workers/
kubectl rollout status deployment -l app.kubernetes.io/name=synapse -n matrix

# Step 3: Update LI instance (if applicable)
kubectl apply -f li-instance/01-synapse-li/
kubectl rollout status statefulset/synapse-li -n matrix
```

**Alternative: Use deploy-all.sh for Full Redeployment:**

```bash
# For comprehensive updates affecting multiple services:
./scripts/deploy-all.sh --phase 2  # Redeploy main instance
./scripts/deploy-all.sh --phase 3  # Redeploy LI instance (if needed)
```

**Post-Update Validation:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: Immediately after update completes
# WHY: Verify update was successful
# HOW:

# 1. Verify all pods are running
kubectl get pods -n matrix
# All synapse pods should show Running, with recent restarts

# 2. Check Synapse version
kubectl exec -n matrix deployment/synapse-main -- \
  python -m synapse.app.homeserver --version
# Should show v1.103.0 (new version)

# 3. Test basic functionality
# Via Element Web:
# - Send message in test room
# - Upload file
# - Sync to another device
# All should work normally

# 4. Check federation
curl https://your-domain.com/_matrix/federation/v1/version
# Should return version info

# 5. Monitor metrics
# Check Grafana dashboard for:
# - Response times (should be normal)
# - Error rates (should not increase)
# - Database connections (should be stable)

# 6. Check logs for 
kubectl logs -n matrix deployment/synapse-main --tail=100 --follow
# Watch for any errors or warnings
```

**Rollback Procedure (if needed):**

```bash
# WHERE: kubectl-configured workstation
# WHEN: If update causes issues
# WHY: Restore service to working state
# HOW:

# Rollback all Synapse components to previous version
kubectl set image deployment/synapse-main \
  synapse=matrixdotorg/synapse:v1.102.0 \
  -n matrix

kubectl set image statefulset/synapse-sync-worker \
  synapse=matrixdotorg/synapse:v1.102.0 \
  -n matrix

kubectl set image statefulset/synapse-generic-worker \
  synapse=matrixdotorg/synapse:v1.102.0 \
  -n matrix

kubectl set image statefulset/synapse-event-persister \
  synapse=matrixdotorg/synapse:v1.102.0 \
  -n matrix

kubectl set image statefulset/synapse-federation-sender \
  synapse=matrixdotorg/synapse:v1.102.0 \
  -n matrix

# Wait for rollout to complete
kubectl rollout status deployment/synapse-main -n matrix
# Repeat for each StatefulSet

# Verify rollback
kubectl exec -n matrix deployment/synapse-main -- \
  python -m synapse.app.homeserver --version
# Should show v1.102.0 (previous version)
```

### 2.2 PostgreSQL Version Update

**Risk Level:** High (minor version) / Critical (major version)
**Downtime:** None (minor version) / Yes (major version)
**Backup Required:** Yes (multiple backups)

**Minor Version Update (e.g., 16.2 → 16.3):**

```bash
# WHERE: kubectl-configured workstation
# WHEN: During maintenance window
# WHY: CloudNativePG handles rolling updates automatically
# HOW:

# 1. Backup database first
kubectl exec -n matrix synapse-postgres-1 -- \
  pg_dumpall -U postgres > postgres-full-backup-$(date +%Y%m%d).sql

# 2. Update PostgreSQL Cluster manifest
kubectl edit cluster synapse-postgres -n matrix

# Change:
# spec:
#   imageName: ghcr.io/cloudnative-pg/postgresql:16.3

# CloudNativePG will automatically:
# - Update standby replicas first
# - Perform switchover to updated replica
# - Update old primary
# - Switchover back if needed

# 3. Monitor update
kubectl get cluster synapse-postgres -n matrix -w
# Watch "Phase" field - should stay "Cluster in healthy state"

# 4. Verify all pods updated
kubectl get pods -n matrix -l cnpg.io/cluster=synapse-postgres \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# All should show new version (16.3)

# 5. Test database connectivity
kubectl exec -n matrix deployment/synapse-main -- \
  psql -h synapse-postgres-rw.matrix.svc.cluster.local -U synapse -c "SELECT version();"
# Should connect and show PostgreSQL 16.3
```

**Major Version Update (e.g., 16.x → 17.x):**

**WARNING:** Major PostgreSQL upgrades require pg_upgrade and significant downtime. Not recommended without deep PostgreSQL expertise.

**Recommended approach:** Create new PostgreSQL 17 cluster, use logical replication to migrate data, then switchover. This is complex and beyond scope - consult CloudNativePG documentation or hire expert.

### 2.3 Redis Version Update

**Risk Level:** Low
**Downtime:** Brief (seconds during failover)
**Backup Required:** No (stateless cache)

```bash
# WHERE: kubectl-configured workstation
# WHEN: Anytime (minimal impact)
# WHY: Update to latest version
# HOW:

# Redis Synapse (used by Synapse)
helm upgrade redis-synapse bitnami/redis \
  -f deployment/values/redis-synapse-values.yaml \
  --set image.tag=7.2.4 \
  -n redis-synapse

# Redis LiveKit (used by LiveKit)
helm upgrade redis-livekit bitnami/redis \
  -f deployment/values/redis-livekit-values.yaml \
  --set image.tag=7.2.4 \
  -n redis-livekit

# Monitor update
kubectl get pods -n redis-synapse -w
kubectl get pods -n redis-livekit -w

# Verify Sentinel failover worked
kubectl logs -n redis-synapse redis-synapse-master-0 --tail=50
# Should show new connections after restart
```

### 2.4 MinIO Version Update

**Risk Level:** Low
**Downtime:** None (rolling update)
**Backup Required:** Recommended (object data should exist elsewhere)

```bash
# WHERE: kubectl-configured workstation
# WHEN: During maintenance window
# WHY: Update to latest version
# HOW:

# Update MinIO Operator first
kubectl minio update

# Update Tenant (rolling update, no downtime)
kubectl edit tenant synapse-storage -n minio-tenant

# Change:
# spec:
#   image: quay.io/minio/minio:RELEASE.2024-11-07T00-52-20Z

# MinIO Operator will perform rolling update
# Monitor progress
kubectl get pods -n minio-tenant -w

# Verify all pods updated
kubectl get pods -n minio-tenant -l v1.min.io/tenant=synapse-storage \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Test MinIO access
mc alias set synapse-minio https://minio.your-domain.com ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
mc admin info synapse-minio
# Should show cluster health
```

### 2.5 Element Web Version Update

**Risk Level:** Low
**Downtime:** None
**Backup Required:** No (static files)

```bash
# WHERE: kubectl-configured workstation
# WHEN: Anytime
# WHY: Update to latest version with new features/fixes
# HOW:

# Update deployment image
kubectl set image deployment/element-web \
  element=vectorim/element-web:v1.11.50 \
  -n matrix

# Monitor rollout
kubectl rollout status deployment/element-web -n matrix

# Verify update
kubectl get deployment element-web -n matrix -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show new version

# Test in browser
# Visit https://chat.your-domain.com
# Check version in Settings → Help & About
```

### 2.6 Monitoring Stack Updates (Prometheus, Grafana, Loki)

**Risk Level:** Low
**Downtime:** None (monitoring only)
**Backup Required:** Yes (Grafana dashboards and datasources)

```bash
# WHERE: kubectl-configured workstation
# WHEN: Anytime (monitoring is non-critical)
# WHY: Get latest features and fixes
# HOW:

# Backup Grafana dashboards first
kubectl exec -n monitoring deployment/grafana -- \
  grafana-cli admin export-dashboard > grafana-dashboards-backup-$(date +%Y%m%d).json

# Update Prometheus Operator (updates all components)
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -f deployment/values/prometheus-values.yaml \
  --version 55.0.0 \
  -n monitoring

# Monitor update
kubectl get pods -n monitoring -w

# Verify Grafana accessible
kubectl port-forward -n monitoring svc/grafana 3000:80
# Visit http://localhost:3000

# Verify Prometheus accessible
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Visit http://localhost:9090

# Update Loki
helm upgrade loki grafana/loki-stack \
  -f deployment/values/loki-values.yaml \
  --version 2.10.0 \
  -n monitoring

kubectl rollout status deployment/loki -n monitoring
```

---

## 3. Changing Configurations

### 3.1 Synapse Configuration Changes

**Risk Level:** Medium
**Downtime:** Brief (during restart)
**Backup Required:** Yes

**Common Configuration Changes:**
- Rate limiting adjustments
- Federation settings
- Media repository settings
- Logging levels

**Procedure:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: During maintenance window or off-peak hours
# WHY: Depends on what you're changing
# HOW:

# Step 1: Backup current configuration
kubectl get configmap synapse-config -n matrix -o yaml > \
  synapse-config-backup-$(date +%Y%m%d-%H%M%S).yaml

# Step 2: Edit configuration
kubectl edit configmap synapse-config -n matrix

# Example: Increase rate limit
# Find the rate_limiting section and modify:
# rc_message:
#   per_second: 20  # was 10
#   burst_count: 100  # was 50

# Save and exit editor

# Step 3: Verify syntax (optional but recommended)
kubectl get configmap synapse-config -n matrix -o jsonpath='{.data.homeserver\.yaml}' | \
  python -c "import sys, yaml; yaml.safe_load(sys.stdin)"
# No output = valid YAML

# Step 4: Restart Synapse to apply changes
# Main process
kubectl rollout restart deployment/synapse-main -n matrix
kubectl rollout status deployment/synapse-main -n matrix

# Workers (if config affects them)
kubectl rollout restart statefulset/synapse-sync-worker -n matrix
kubectl rollout restart statefulset/synapse-generic-worker -n matrix
kubectl rollout restart statefulset/synapse-event-persister -n matrix
kubectl rollout restart statefulset/synapse-federation-sender -n matrix

# Step 5: Verify config loaded correctly
kubectl logs -n matrix deployment/synapse-main --tail=50 | grep -i "config\|error"
# Look for "Configuration loaded successfully" or similar
# Should NOT show config errors

# Step 6: Test affected functionality
# Example: If you changed rate limiting, test sending messages
# Send 25 messages quickly via Element Web
# Should not be rate-limited (was 10, now 20 per second)
```

**Rollback:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: If config change causes issues
# WHY: Restore working configuration
# HOW:

# Restore backup
kubectl apply -f synapse-config-backup-YYYYMMDD-HHMMSS.yaml

# Restart Synapse
kubectl rollout restart deployment/synapse-main -n matrix
kubectl rollout restart statefulset/synapse-sync-worker -n matrix
# etc.

# Verify rollback
kubectl logs -n matrix deployment/synapse-main --tail=50
```

### 3.2 PostgreSQL Configuration Changes

**Risk Level:** Medium to High (depending on setting)
**Downtime:** None (most settings) or Brief (some require restart)
**Backup Required:** Yes

**Common Changes:**
- max_connections
- shared_buffers
- work_mem
- Autovacuum settings

```bash
# WHERE: kubectl-configured workstation
# WHEN: During maintenance window
# WHY: Optimize database performance
# HOW:

# Step 1: Backup current config
kubectl get cluster synapse-postgres -n matrix -o yaml > \
  postgres-config-backup-$(date +%Y%m%d).yaml

# Step 2: Edit PostgreSQL Cluster
kubectl edit cluster synapse-postgres -n matrix

# Find postgresql.parameters section and modify
# Example: Increase max_connections
# spec:
#   postgresql:
#     parameters:
#       max_connections: "600"  # was 500

# Step 3: CloudNativePG will automatically apply changes
# Some settings apply immediately, others require restart
# Check which type:
# https://www.postgresql.org/docs/16/view-pg-settings.html

# Step 4: Verify change applied
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "SHOW max_connections;"
# Should show: 600

# Step 5: Monitor database performance
kubectl logs -n matrix synapse-postgres-1 --tail=50

# Check connections are under new limit
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"
# Should be < 600
```

**Settings Requiring Restart:**
- max_connections
- shared_buffers
- wal_buffers

**Settings Applied Immediately:**
- work_mem
- maintenance_work_mem
- autovacuum settings (most)

### 3.3 Resource Limits Changes

**Risk Level:** Low
**Downtime:** None (if increasing) / Brief (if decreasing)
**Backup Required:** No

**When to Change:**
- Pods OOMKilled frequently → Increase memory
- CPU throttling observed → Increase CPU
- Over-provisioned → Decrease to save costs

```bash
# WHERE: kubectl-configured workstation
# WHEN: Anytime (if increasing); maintenance window (if decreasing)
# WHY: Optimize resource usage
# HOW:

# Example: Increase Synapse main process memory

# Step 1: Edit deployment
kubectl edit deployment synapse-main -n matrix

# Find resources section:
# resources:
#   requests:
#     cpu: 2000m
#     memory: 4Gi
#   limits:
#     cpu: 4000m
#     memory: 8Gi  # Change from 6Gi to 8Gi

# Step 2: Kubernetes will automatically restart pod with new limits
kubectl rollout status deployment/synapse-main -n matrix

# Step 3: Verify new limits
kubectl get pod -n matrix -l app=synapse,component=main \
  -o jsonpath='{.items[0].spec.containers[0].resources}'
# Should show new limits

# Step 4: Monitor resource usage
kubectl top pod -n matrix -l app=synapse,component=main
# Usage should be well under new limits
```

### 3.4 TLS Certificate Configuration

**Risk Level:** Low
**Downtime:** None
**Backup Required:** No (cert-manager handles automatically)

```bash
# WHERE: kubectl-configured workstation
# WHEN: When adding new domains or changing cert issuer
# WHY: Add/update TLS certificates
# HOW:

# Add new domain to certificate
kubectl edit certificate synapse-tls -n matrix

# Add to spec.dnsNames:
# spec:
#   dnsNames:
#   - chat.example.com
#   - matrix.example.com
#   - new-domain.example.com  # Add this

# cert-manager will automatically:
# 1. Request new certificate from Let's Encrypt
# 2. Update Secret with new cert
# 3. Ingress controller will reload

# Monitor certificate issuance
kubectl get certificate synapse-tls -n matrix -w
# Wait for "Ready: True"

# Verify new certificate
kubectl get secret synapse-tls-secret -n matrix -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -text | grep DNS:
# Should include new-domain.example.com

# Test HTTPS
curl -v https://new-domain.example.com
# Should show valid certificate
```

---

## 4. Scaling Services

### 4.1 Scaling Synapse Workers

**Risk Level:** Low
**Downtime:** None
**Backup Required:** No

**When to Scale:**
- High CPU/memory usage on workers
- Slow sync response times
- Growing user base

**Scaling Sync Workers:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: During high load or proactively
# WHY: Improve sync performance, handle more users
# HOW:

# Current replica count
kubectl get statefulset synapse-sync-worker -n matrix
# Note REPLICAS column (e.g., 8)

# Scale up (e.g., 8 → 12)
kubectl scale statefulset synapse-sync-worker --replicas=12 -n matrix

# Monitor scaling
kubectl get pods -n matrix -l component=sync-worker -w
# Wait for all 12 pods to be Running

# Verify workers registered with main process
kubectl logs -n matrix deployment/synapse-main --tail=100 | grep "Finished connecting to"
# Should show connections from all 12 workers

# Update Ingress to include new workers
# Edit NGINX config to add new worker endpoints
kubectl edit configmap ingress-nginx-controller -n ingress-nginx

# Add to upstream configuration:
# upstream synapse_sync_workers {
#   least_conn;
#   server synapse-sync-worker-0.synapse-sync-worker.matrix.svc.cluster.local:8083;
#   server synapse-sync-worker-1.synapse-sync-worker.matrix.svc.cluster.local:8083;
#   ...
#   server synapse-sync-worker-11.synapse-sync-worker.matrix.svc.cluster.local:8083;
# }

# Or use automatic discovery via Service (recommended)
# Workers are already behind synapse-sync-worker Service
# No manual Ingress update needed if using Service-based routing

# Verify load distribution
# Check worker logs to ensure all receiving traffic
for i in {0..11}; do
  echo "Worker $i:"
  kubectl logs -n matrix synapse-sync-worker-$i --tail=10 | grep "Processed request" | wc -l
done
# All workers should show request processing
```

**Scaling Down:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: During low usage period
# WHY: Reduce costs
# HOW:

# IMPORTANT: Scale down gradually (one or two replicas at a time)
# Wait  between steps to ensure traffic redistributes

# Scale from 12 → 10
kubectl scale statefulset synapse-sync-worker --replicas=10 -n matrix

# Wait 
sleep 600

# Check remaining workers handling load okay
kubectl top pods -n matrix -l component=sync-worker
# CPU/memory should not spike on remaining pods

# If stable, continue scaling down
kubectl scale statefulset synapse-sync-worker --replicas=8 -n matrix

# Update instance_map in Synapse config if workers removed
# Remove entries for sync_worker_11, sync_worker_12, etc.
kubectl edit configmap synapse-config -n matrix
# Remove from instance_map and stream_writers

# Restart main process to reload config
kubectl rollout restart deployment/synapse-main -n matrix
```

**Scaling Generic Workers:**

Same procedure as sync workers, scale `synapse-generic-worker` StatefulSet.

**Scaling Event Persisters:**

```bash
# WARNING: Event persisters handle database writes
# Only scale if database can handle additional connections
# Check current connection usage first:

kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname='synapse';"

# If well under max_connections (e.g., < 300 of 500), safe to scale
kubectl scale statefulset synapse-event-persister --replicas=3 -n matrix

# Update homeserver.yaml stream_writers
kubectl edit configmap synapse-config -n matrix

# Add event_persister_3 to stream_writers:
# stream_writers:
#   events:
#   - event_persister_1
#   - event_persister_2
#   - event_persister_3

# Restart main process
kubectl rollout restart deployment/synapse-main -n matrix
```

### 4.2 Scaling PostgreSQL

**Risk Level:** High
**Downtime:** None (adding replicas) / Yes (changing primary resources)
**Backup Required:** Yes

**Adding Read Replicas:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: When read load is high
# WHY: Distribute read queries across more nodes
# HOW:

# Current replica count
kubectl get cluster synapse-postgres -n matrix
# Note INSTANCES column (e.g., 3)

# Edit cluster to add replicas
kubectl edit cluster synapse-postgres -n matrix

# Change:
# spec:
#   instances: 4  # was 3

# CloudNativePG will automatically create new replica
kubectl get pods -n matrix -l cnpg.io/cluster=synapse-postgres -w
# Wait for synapse-postgres-4 to be Running

# Verify replication
kubectl exec -n matrix synapse-postgres-4 -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return: t (true = replica)

# Check replication lag
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"
# Should show new replica with minimal lag
```

**Scaling Primary Resources:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: During maintenance window
# WHY: Database needs more CPU/memory
# HOW:

# Edit cluster
kubectl edit cluster synapse-postgres -n matrix

# Change resources:
# spec:
#   resources:
#     requests:
#       memory: "8Gi"  # was 4Gi
#       cpu: "4"       # was 2
#     limits:
#       memory: "16Gi"  # was 8Gi
#       cpu: "8"        # was 4

# CloudNativePG will perform rolling restart
# Replicas first, then primary (with switchover)
kubectl get cluster synapse-postgres -n matrix -w
# Monitor "Phase" - should stay "healthy" throughout

# Verify new resources
kubectl get pods -n matrix -l cnpg.io/cluster=synapse-postgres \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources}{"\n"}{end}'
```

### 4.3 Scaling MinIO

**Risk Level:** Medium
**Downtime:** None (adding pools) / Brief (expanding existing pool)
**Backup Required:** Recommended

**Adding New MinIO Server Pool:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: When storage capacity running low
# WHY: Expand storage capacity
# HOW:

# Check current capacity
mc admin info synapse-minio
# Note used/total capacity

# Edit tenant to add pool
kubectl edit tenant synapse-storage -n minio-tenant

# Add new pool:
# spec:
#   pools:
#   - servers: 4
#     name: pool-0
#     volumesPerServer: 4
#     volumeClaimTemplate:
#       spec:
#         storageClassName: ${STORAGE_CLASS_MINIO}
#         accessModes:
#         - ReadWriteOnce
#         resources:
#           requests:
#             storage: 500Gi
#   - servers: 4      # New pool
#     name: pool-1
#     volumesPerServer: 4
#     volumeClaimTemplate:
#       spec:
#         storageClassName: ${STORAGE_CLASS_MINIO}
#         accessModes:
#         - ReadWriteOnce
#         resources:
#           requests:
#             storage: 500Gi

# MinIO Operator will create new pool
# Data will automatically rebalance across pools
kubectl get pods -n minio-tenant -w
# Wait for new pool-1-* pods to be Running

# Verify new pool
mc admin info synapse-minio
# Should show increased capacity
```

**Expanding Existing Pool:**

MinIO does not support expanding existing volumes. You must add a new pool (above).

### 4.4 Scaling Redis

**Risk Level:** Low
**Downtime:** None
**Backup Required:** No

**Scaling Redis Replicas:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: To improve read performance or availability
# WHY: More replicas = more read capacity + higher availability
# HOW:

# Upgrade Helm release with new replica count
helm upgrade redis-synapse bitnami/redis \
  -f deployment/values/redis-synapse-values.yaml \
  --set replica.replicaCount=4 \
  -n redis-synapse

# Monitor scaling
kubectl get pods -n redis-synapse -w
# Should see new replica pods starting

# Verify Sentinel knows about new replicas
kubectl exec -n redis-synapse redis-synapse-master-0 -- \
  redis-cli -a $REDIS_PASSWORD SENTINEL replicas mymaster
# Should show all replicas
```

---

## 5. Backup and Restore

### 5.1 PostgreSQL Backup

**Automated Backups (CloudNativePG):**

Backups are configured in `01-postgresql-cluster.yaml`:

```yaml
backup:
  barmanObjectStore:
    destinationPath: s3://synapse-backups/
    s3Credentials:
      accessKeyId:
        name: minio-backup-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: minio-backup-credentials
        key: SECRET_ACCESS_KEY
    wal:
      compression: gzip
  retentionPolicy: "30d"
```

**Manual Backup:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: Before major changes
# WHY: Extra safety layer
# HOW:

# Full cluster backup
kubectl exec -n matrix synapse-postgres-1 -- \
  pg_dumpall -U postgres | gzip > postgres-full-backup-$(date +%Y%m%d-%H%M%S).sql.gz

# Database-only backup (faster)
kubectl exec -n matrix synapse-postgres-1 -- \
  pg_dump -U synapse synapse | gzip > synapse-db-backup-$(date +%Y%m%d-%H%M%S).sql.gz

# Copy backup off-cluster (IMPORTANT)
# Store in multiple locations:
# 1. Local machine
# 2. S3/object storage
# 3. Offsite backup service

# Upload to S3 (example)
aws s3 cp synapse-db-backup-$(date +%Y%m%d-%H%M%S).sql.gz \
  s3://your-backup-bucket/synapse/
```

**Restore from Backup:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: After data loss or corruption
# WHY: Recover data
# HOW:

# WARNING: This will overwrite existing data

# Step 1: Stop Synapse (prevent writes during restore)
kubectl scale deployment synapse-main --replicas=0 -n matrix
kubectl scale statefulset synapse-sync-worker --replicas=0 -n matrix
kubectl scale statefulset synapse-generic-worker --replicas=0 -n matrix
kubectl scale statefulset synapse-event-persister --replicas=0 -n matrix
kubectl scale statefulset synapse-federation-sender --replicas=0 -n matrix

# Step 2: Drop existing database (if corrupted)
kubectl exec -it -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "DROP DATABASE synapse;"

# Step 3: Create new database
kubectl exec -it -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "CREATE DATABASE synapse OWNER synapse;"

# Step 4: Restore backup
gunzip -c synapse-db-backup-YYYYMMDD-HHMMSS.sql.gz | \
  kubectl exec -i -n matrix synapse-postgres-1 -- \
  psql -U synapse synapse

# Step 5: Verify restore
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U synapse -c "SELECT count(*) FROM events;"
# Should show expected number of events

# Step 6: Restart Synapse
kubectl scale deployment synapse-main --replicas=1 -n matrix
kubectl scale statefulset synapse-sync-worker --replicas=8 -n matrix
kubectl scale statefulset synapse-generic-worker --replicas=4 -n matrix
kubectl scale statefulset synapse-event-persister --replicas=2 -n matrix
kubectl scale statefulset synapse-federation-sender --replicas=4 -n matrix

# Step 7: Verify functionality
# Test via Element Web - send messages, check history
```

### 5.2 MinIO Backup

**Data Durability:**

MinIO with EC:4 erasure coding can tolerate 1 node failure without data loss.

**Backup Strategy:**

```bash
# WHERE: kubectl-configured workstation or mc-configured machine
# WHEN: Before major changes or periodically
# WHY: Extra protection against corruption/deletion
# HOW:

# Option 1: Mirror to another MinIO/S3 bucket
mc mirror synapse-minio/synapse-media \
  backup-s3/synapse-media-backup \
  --preserve

# Option 2: Create versioned bucket (prevents accidental deletion)
mc version enable synapse-minio/synapse-media

# Option 3: Export critical media to tarball
mc mirror synapse-minio/synapse-media /tmp/media-export
tar czf media-backup-$(date +%Y%m%d).tar.gz /tmp/media-export/
# Upload tarball to offsite storage
```

### 5.3 Configuration Backup

```bash
# WHERE: kubectl-configured workstation
# WHEN: Before any config changes
# WHY: Enable quick rollback
# HOW:

# Backup all ConfigMaps
kubectl get configmap -n matrix -o yaml > \
  configmaps-backup-$(date +%Y%m%d-%H%M%S).yaml

# Backup all Secrets
kubectl get secret -n matrix -o yaml > \
  secrets-backup-$(date +%Y%m%d-%H%M%S).yaml

# Backup specific resources
kubectl get deployment,statefulset,service,ingress -n matrix -o yaml > \
  matrix-resources-backup-$(date +%Y%m%d-%H%M%S).yaml

# Store backups in version control (EXCEPT secrets)
git add configmaps-backup-*.yaml matrix-resources-backup-*.yaml
git commit -m "Backup before [change description]"
git push

# Encrypt and store secrets separately
gpg --encrypt --recipient your-email@example.com secrets-backup-*.yaml
# Store encrypted file in secure location
```

---

## 6. Maintenance Windows

### 6.1 Planning Maintenance Windows

**When to Schedule:**
- Major version upgrades
- Database schema changes
- Infrastructure changes (node replacement, storage migration)
- Changes requiring extended downtime

**Preparation:**

```bash
#  before:
# - Announce maintenance window to users
# - Create detailed runbook
# - Test procedure in staging (if available)
# - Identify rollback points

#  before:
# - Backup all data
# - Verify backup integrity
# - Prepare rollback procedures
# - Review runbook with team

#  before:
# - Verify system health
# - Check no critical issues ongoing
# - Ensure team members available
```

**Announcement Template:**

```
Subject: Scheduled Maintenance - [Date] [Time]

Our Matrix chat service will undergo maintenance on [Date] from [Start Time] to [End Time] [Timezone].

During this time:
- ✅ Existing messages and files remain accessible
- ⚠️ Sending new messages may be unavailable for up to [Duration]
- ⚠️ File uploads may be disabled

What we're doing:
- [Brief description, e.g., "Upgrading to Matrix Synapse 1.103 for improved performance"]

Questions? Contact [support-email]

Thank you for your patience.
```

### 6.2 Maintenance Mode

**Enable Maintenance Mode:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: Start of maintenance window
# WHY: Prevent new data while working on system
# HOW:

# Option 1: Scale Synapse to 0 replicas (full downtime)
kubectl scale deployment synapse-main --replicas=0 -n matrix
kubectl scale statefulset synapse-sync-worker --replicas=0 -n matrix
kubectl scale statefulset synapse-generic-worker --replicas=0 -n matrix

# Option 2: Set Ingress to maintenance page (read-only mode)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: maintenance-page
  namespace: matrix
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head><title>Maintenance</title></head>
    <body>
      <h1>Scheduled Maintenance in Progress</h1>
      <p>Our Matrix service is currently undergoing maintenance.</p>
      <p>Expected completion: [Time]</p>
      <p>Existing messages remain accessible in read-only mode.</p>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: maintenance-page
  namespace: matrix
spec:
  replicas: 1
  selector:
    matchLabels:
      app: maintenance
  template:
    metadata:
      labels:
        app: maintenance
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: page
          mountPath: /usr/share/nginx/html
      volumes:
      - name: page
        configMap:
          name: maintenance-page
---
apiVersion: v1
kind: Service
metadata:
  name: maintenance-page
  namespace: matrix
spec:
  selector:
    app: maintenance
  ports:
  - port: 80
EOF

# Update Ingress to point to maintenance page
kubectl patch ingress synapse-ingress -n matrix --type=json \
  -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/name", "value":"maintenance-page"}]'
```

**Disable Maintenance Mode:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: End of maintenance window
# WHY: Restore normal operation
# HOW:

# Restore Ingress
kubectl patch ingress synapse-ingress -n matrix --type=json \
  -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/name", "value":"synapse-main"}]'

# Or restore replicas (if scaled to 0)
kubectl scale deployment synapse-main --replicas=1 -n matrix
kubectl scale statefulset synapse-sync-worker --replicas=8 -n matrix
kubectl scale statefulset synapse-generic-worker --replicas=4 -n matrix

# Delete maintenance page
kubectl delete deployment,service,configmap maintenance-page -n matrix

# Verify service restored
curl https://your-domain.com/_matrix/client/versions
# Should return JSON with versions (not maintenance page)
```

---

## 7. Monitoring During Operations

### 7.1 Key Metrics to Watch

**Before Operation:**
- Baseline metrics (CPU, memory, response times, error rates)
- Current user count
- Database connections
- Queue depths

**During Operation:**
- Pod status (Running, CrashLoopBackOff, etc.)
- Resource usage (ensure not hitting limits)
- Error rates (should not increase)
- Response times (should remain stable)

**After Operation:**
- Compare to baseline
- Monitor for 
- Check for memory leaks (gradually increasing memory)
- Verify no elevated error rates

### 7.2 Monitoring Commands

```bash
# Real-time pod status
kubectl get pods -n matrix -w

# Resource usage
kubectl top pods -n matrix

# Detailed pod info
kubectl describe pod <pod-name> -n matrix

# Logs (follow mode)
kubectl logs -f -n matrix deployment/synapse-main

# Recent errors
kubectl logs -n matrix deployment/synapse-main --tail=100 | grep -i error

# Multiple pods at once
kubectl logs -n matrix -l app=synapse --tail=50 --prefix

# Database connections
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "SELECT count(*), state FROM pg_stat_activity WHERE datname='synapse' GROUP BY state;"

# Redis info
kubectl exec -n redis-synapse redis-synapse-master-0 -- \
  redis-cli -a $REDIS_PASSWORD INFO stats

# MinIO stats
mc admin info synapse-minio
```

### 7.3 Grafana Dashboards

**Key Dashboards to Monitor:**

1. **Synapse Overview**
   - Requests per second
   - Response time (p50, p95, p99)
   - Error rate
   - Active users

2. **Database Performance**
   - Connection pool usage
   - Query duration
   - Transaction rate
   - Replication lag

3. **Worker Distribution**
   - Requests per worker
   - CPU/memory per worker
   - Queue depths

4. **Infrastructure**
   - Node CPU/memory
   - Disk I/O
   - Network throughput

**Accessing Grafana:**

```bash
# WHERE: Your local machine
# WHEN: During operations
# WHY: Visual monitoring
# HOW:

# Port-forward to Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80

# Visit http://localhost:3000
# Login with admin credentials
# Navigate to "Synapse" folder → "Overview" dashboard
```

---

## 8. Troubleshooting Common Issues

### 8.1 Update Failed - Pods CrashLooping

**Symptoms:**
- Pods in CrashLoopBackOff state after update
- Logs show startup errors

**Diagnosis:**

```bash
# Check pod status
kubectl get pods -n matrix

# Check events
kubectl get events -n matrix --sort-by='.lastTimestamp' | tail -20

# Check logs
kubectl logs -n matrix <pod-name>

# Describe pod for detailed error
kubectl describe pod <pod-name> -n matrix
```

**Common Causes & Solutions:**

1. **Configuration Error:**
   ```bash
   # Logs show "Config error" or "Invalid configuration"
   # Solution: Restore previous config
   kubectl apply -f synapse-config-backup-YYYYMMDD.yaml
   kubectl rollout restart deployment/synapse-main -n matrix
   ```

2. **Database Migration Failure:**
   ```bash
   # Logs show "Schema version mismatch" or "Migration failed"
   # Solution: Rollback to previous Synapse version
   kubectl set image deployment/synapse-main synapse=matrixdotorg/synapse:v1.102.0 -n matrix
   ```

3. **Insufficient Resources:**
   ```bash
   # Logs show "OOMKilled" or "Killed"
   # Solution: Increase memory limits
   kubectl edit deployment synapse-main -n matrix
   # Increase spec.template.spec.containers[0].resources.limits.memory
   ```

4. **Dependency Unavailable:**
   ```bash
   # Logs show "Cannot connect to database" or "Redis unavailable"
   # Solution: Check dependencies
   kubectl get pods -n matrix | grep postgres
   kubectl get pods -n redis-synapse
   # Ensure all dependency pods are Running
   ```

### 8.2 Configuration Change Not Applied

**Symptoms:**
- Changed ConfigMap but behavior unchanged
- Logs show old configuration values

**Diagnosis:**

```bash
# Verify ConfigMap updated
kubectl get configmap synapse-config -n matrix -o yaml

# Check pod creation time (must be after ConfigMap update)
kubectl get pods -n matrix -o wide
# AGE column should show recent restart
```

**Solution:**

```bash
# ConfigMaps don't automatically reload - must restart pods
kubectl rollout restart deployment/synapse-main -n matrix

# Verify pods restarted
kubectl get pods -n matrix -l component=main
# AGE should be < 

# Check logs to confirm new config loaded
kubectl logs -n matrix deployment/synapse-main | grep "config"
```

### 8.3 Scale-Up Not Working

**Symptoms:**
- Scaled StatefulSet but new pods not receiving traffic
- Load not distributing to new workers

**Diagnosis:**

```bash
# Check all pods running
kubectl get pods -n matrix -l component=sync-worker
# All should show Running

# Check worker registration
kubectl logs -n matrix deployment/synapse-main | grep "Finished connecting"
# Should show connections from all workers

# Check instance_map includes new workers
kubectl get configmap synapse-config -n matrix -o yaml | grep -A 50 "instance_map"
```

**Solution:**

```bash
# Update instance_map in homeserver.yaml
kubectl edit configmap synapse-config -n matrix

# Add new worker entries:
# instance_map:
#   sync_worker_9:
#     host: synapse-sync-worker-8.synapse-sync-worker.matrix.svc.cluster.local
#     port: 9093
#   sync_worker_10:
#     host: synapse-sync-worker-9.synapse-sync-worker.matrix.svc.cluster.local
#     port: 9093

# Restart main process to reload config
kubectl rollout restart deployment/synapse-main -n matrix

# Verify workers registered
kubectl logs -n matrix deployment/synapse-main --tail=50 | grep "sync_worker"
```

### 8.4 Database Connection Pool Exhausted

**Symptoms:**
- Errors: "FATAL: remaining connection slots are reserved"
- Synapse slow or timing out
- Database CPU high

**Diagnosis:**

```bash
# Check current connections
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "SELECT count(*), usename, application_name FROM pg_stat_activity WHERE datname='synapse' GROUP BY usename, application_name;"

# Check max_connections
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U postgres -c "SHOW max_connections;"

# Compare: current should be < max
```

**Solution:**

```bash
# Option 1: Increase PostgreSQL max_connections
kubectl edit cluster synapse-postgres -n matrix
# Change spec.postgresql.parameters.max_connections to higher value (e.g., 600)

# Option 2: Reduce Synapse connection pool (cp_max)
kubectl edit configmap synapse-config -n matrix
# Reduce database.args.cp_max (e.g., from 25 to 15)
kubectl rollout restart deployment/synapse-main -n matrix

# Option 3: Scale down workers
kubectl scale statefulset synapse-event-persister --replicas=1 -n matrix
# Fewer workers = fewer connections
```

### 8.5 Rollback Not Working

**Symptoms:**
- Attempted rollback but issues persist
- Old version shows same problems

**Diagnosis:**

```bash
# Check if issue is configuration, not version
kubectl describe pod <pod-name> -n matrix
# Look at Image field - is it correct version?

# Check configuration
kubectl get configmap synapse-config -n matrix -o yaml > current-config.yaml
diff current-config.yaml synapse-config-backup-YYYYMMDD.yaml
# Are there unexpected differences?
```

**Solution:**

```bash
# Full rollback (version + config)
# 1. Restore config
kubectl apply -f synapse-config-backup-YYYYMMDD.yaml

# 2. Rollback version
kubectl set image deployment/synapse-main synapse=matrixdotorg/synapse:v1.102.0 -n matrix

# 3. Restart all components
kubectl rollout restart deployment/synapse-main -n matrix
kubectl rollout restart statefulset/synapse-sync-worker -n matrix
kubectl rollout restart statefulset/synapse-generic-worker -n matrix

# 4. Verify
kubectl get pods -n matrix
# All should be Running

kubectl logs -n matrix deployment/synapse-main --tail=50
# Should show successful startup
```

---

## 9. Scaling StatefulSet Workers (Event-Persisters/Federation-Senders)

**⚠️ CRITICAL:** These workers require special handling - scaling requires full Synapse restart.

### 9.1 Why Restart is Required

Event-persister and federation-sender workers use StatefulSets with predictable pod names referenced in `homeserver.yaml`:
- `instance_map` lists each worker by name (synapse-event-persister-0, synapse-event-persister-1)
- `stream_writers.events` delegates writes to specific event-persister instances
- `federation_sender_instances` lists specific federation-sender instances

When you scale these workers, the instance names change, requiring all Synapse processes to reload configuration.

### 9.2 Scaling Event-Persisters

**Risk Level:** High
**Downtime:** 2-5 minutes
**Backup Required:** Yes

**Pre-Scaling:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: Maintenance window required
# WHY: Verify system can handle change

# 1. Check current database connections (must be under limit)
kubectl exec -n matrix matrix-postgresql-1 -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname='matrix';"
# Should show < 400 (out of 500 max_connections)

# 2. Backup configuration
kubectl get configmap synapse-config -n matrix -o yaml > \
  synapse-config-backup-$(date +%Y%m%d-%H%M%S).yaml

# 3. Note current replica count
kubectl get statefulset synapse-event-persister -n matrix
# REPLICAS column shows current count (e.g., 2)
```

**Scaling Procedure:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: During planned maintenance (2-5 min downtime)
# WHY: Add capacity for write load
# HOW:

# Step 1: Update StatefulSet replicas
kubectl scale statefulset synapse-event-persister --replicas=3 -n matrix

# Wait for new pod to be Running
kubectl get pods -n matrix -l app.kubernetes.io/component=event-persister -w
# Wait until all 3 pods show Running

# Step 2: Update homeserver.yaml instance_map
kubectl edit configmap synapse-config -n matrix

# Add new worker to instance_map:
# instance_map:
#   synapse-event-persister-2:  # Add this block
#     host: synapse-event-persister-2.synapse-event-persister.matrix.svc.cluster.local
#     port: 9093

# Add to stream_writers.events:
# stream_writers:
#   events:
#     - synapse-event-persister-0
#     - synapse-event-persister-1
#     - synapse-event-persister-2  # Add this line

# Save and exit

# Step 3: Restart ALL Synapse processes (required for instance_map reload)
kubectl rollout restart statefulset/synapse-main -n matrix
kubectl rollout restart statefulset/synapse-event-persister -n matrix
kubectl rollout restart statefulset/synapse-federation-sender -n matrix
kubectl rollout restart deployment/synapse-synchrotron -n matrix
kubectl rollout restart deployment/synapse-generic-worker -n matrix
kubectl rollout restart statefulset/synapse-media-repository -n matrix

# Step 4: Monitor restart progress
kubectl get pods -n matrix -w
# All pods should show Running within 2-3 minutes

# Step 5: Verify event-persisters registered
kubectl logs -n matrix synapse-main-0 --tail=100 | grep event-persister
# Should show connections from all 3 event-persisters

# Step 6: Test write operations
# Send test messages via Element Web
# Should work normally with writes distributed across 3 persisters
```

**Post-Scaling Validation:**

```bash
# Check all workers processing events
for i in {0..2}; do
  echo "Event-persister-$i:"
  kubectl logs -n matrix synapse-event-persister-$i --tail=20 | grep "Processed" | wc -l
done
# All 3 should show activity

# Monitor database connections (should be higher but under limit)
kubectl exec -n matrix matrix-postgresql-1 -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname='matrix';"
# Should still be < 500
```

### 9.3 Scaling Federation-Senders

**Same procedure as event-persisters:**

```bash
# Scale StatefulSet
kubectl scale statefulset synapse-federation-sender --replicas=3 -n matrix

# Edit configmap - add to instance_map and federation_sender_instances
kubectl edit configmap synapse-config -n matrix

# instance_map:
#   synapse-federation-sender-2:
#     host: synapse-federation-sender-2.synapse-federation-sender.matrix.svc.cluster.local
#     port: 9093

# federation_sender_instances:
#   - synapse-federation-sender-0
#   - synapse-federation-sender-1
#   - synapse-federation-sender-2  # Add this

# Restart ALL Synapse processes
kubectl rollout restart statefulset/synapse-main -n matrix
kubectl rollout restart statefulset/synapse-event-persister -n matrix
kubectl rollout restart statefulset/synapse-federation-sender -n matrix
kubectl rollout restart deployment/synapse-synchrotron -n matrix
kubectl rollout restart deployment/synapse-generic-worker -n matrix
kubectl rollout restart statefulset/synapse-media-repository -n matrix
```

### 9.4 Scaling Down

```bash
# Reverse procedure - remove from config first, then scale down

# Step 1: Edit config, remove worker from instance_map and stream_writers
kubectl edit configmap synapse-config -n matrix

# Step 2: Restart all Synapse processes
kubectl rollout restart statefulset/synapse-main -n matrix
# ... restart other workers

# Step 3: Wait for restarts to complete
kubectl get pods -n matrix -w

# Step 4: Scale down StatefulSet
kubectl scale statefulset synapse-event-persister --replicas=2 -n matrix
```

### 9.5 Important Notes

**Connection Pool Formula:**
- Each worker opens cp_max connections (currently 10)
- With 3 event-persisters: 3 × 10 = 30 additional connections
- Total workers × cp_max must be < PostgreSQL max_connections (500)
- Current setting: 45 workers × 10 = 450 connections (safe margin)
- If scaling beyond 45 total workers, reduce cp_max in homeserver.yaml

**Why No HPA:**
- Event-persisters and federation-senders cannot use HorizontalPodAutoscaler
- Manual scaling only due to instance_map requirement
- Other workers (synchrotron, generic, media) do use HPA and scale automatically

---

## Summary

### Quick Reference: Common Operations

| Operation | Risk | Downtime | Command |
|-----------|------|----------|---------|
| Update Synapse | Medium | None | `kubectl set image deployment/synapse-main synapse=matrixdotorg/synapse:VERSION` |
| Update config | Medium | Brief | `kubectl edit configmap synapse-config -n matrix` + restart |
| Scale workers | Low | None | `kubectl scale statefulset/synapse-sync-worker --replicas=N` |
| Update PostgreSQL (minor) | High | None | `kubectl edit cluster synapse-postgres` (change imageName) |
| Backup database | Low | None | `kubectl exec synapse-postgres-1 -- pg_dump` |
| Restore database | High | Yes | Stop Synapse → Drop DB → Restore → Start Synapse |
| Add PostgreSQL replica | High | None | `kubectl edit cluster synapse-postgres` (increase instances) |
| Scale MinIO | Medium | None | `kubectl edit tenant synapse-storage` (add pool) |

### Always Remember:

1. ✅ **Backup before changes**
2. ✅ **Test in staging (if available)**
3. ✅ **Monitor during and after**
4. ✅ **Have rollback plan ready**
5. ✅ **Document what you did**

### Getting Help:

- Check pod logs: `kubectl logs -n matrix <pod-name>`
- Check events: `kubectl get events -n matrix --sort-by='.lastTimestamp'`
- Describe resources: `kubectl describe <resource> <name> -n matrix`
- Review Grafana dashboards
- Consult main `README.md` and `HAPROXY-ARCHITECTURE.md` for architecture details

---


