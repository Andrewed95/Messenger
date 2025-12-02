# MinIO Distributed Storage

## Overview

MinIO provides S3-compatible object storage for the Matrix deployment using distributed mode with erasure coding for high availability and data protection.

**Use Cases**:
- Synapse media storage (images, videos, files)
- CloudNativePG PostgreSQL backups (PITR WAL archiving)
- LI instance media access (shared bucket, read-only)

**Why MinIO instead of single-server storage?**
- S3-compatible API (industry standard)
- Erasure coding for data protection
- Distributed mode for high availability
- Scales horizontally
- Self-healing on drive failures

## Architecture

### Distributed Erasure Coding (EC:4)

```
┌─────────────────────────────────────────────────────────┐
│  MinIO Distributed Cluster (EC:4)                       │
│                                                          │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐   │
│  │ Server1 │  │ Server2 │  │ Server3 │  │ Server4 │   │
│  │ 2 vols  │  │ 2 vols  │  │ 2 vols  │  │ 2 vols  │   │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘   │
│      ↓             ↓             ↓             ↓        │
│  [Vol 0][Vol 1] [Vol 2][Vol 3] [Vol 4][Vol 5] [Vol 6][Vol 7]
│                                                          │
│  Total: 8 drives (4 servers × 2 volumes)                │
│  EC:4 = 4 data shards + 4 parity shards                 │
│  Efficiency: 50% (2Ti usable from 4Ti raw)              │
│  Fault Tolerance: Can lose any 4 drives                 │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

**Erasure Coding Explanation**:
- **EC:4** splits data into 4 data shards + 4 parity shards
- Minimum 8 drives required (4 + 4)
- Can reconstruct data with any 4 shards (out of 8)
- Can tolerate **4 simultaneous drive failures**
- **50% storage efficiency**: 500Gi × 2 × 4 = 4Ti raw → 2Ti usable

### Comparison with Alternatives

| Solution | HA | Complexity | Data Protection | On-Premise | S3 API |
|----------|----|-----------|-----------------| -----------|--------|
| Single NFS | ❌ | Low | None | ✅ | ❌ |
| Ceph RBD | ✅ | Very High | Replication | ✅ | ❌ |
| Ceph Object | ✅ | Very High | Replication | ✅ | ✅ |
| MinIO | ✅ | **Medium** | **Erasure Coding** | ✅ | ✅ |
| AWS S3 | ✅ | Low | Managed | ❌ | ✅ |

**Why MinIO for our use case**:
- ✅ Simpler than Ceph for Kubernetes
- ✅ Native S3 API (Synapse, CloudNativePG support)
- ✅ Erasure coding more efficient than 3x replication
- ✅ On-premise deployment capable
- ✅ Operator-managed (easier than manual deployment)

## Components

### 1. MinIO Tenant CRD
- **Servers**: 4 (minimum for distributed mode)
- **Volumes per Server**: 2 (total 8 drives)
- **Storage per Volume**: 500Gi
- **Total Raw**: 4Ti (2Ti usable with EC:4)
- **Buckets**: synapse-media, postgresql-backups

### 2. Secrets
- **minio-config**: Root credentials + EC:4 configuration
- **minio-credentials**: Application S3 access (both MinIO Tenant and CloudNativePG formats)

### 3. PodDisruptionBudget
- Ensures minimum 3 out of 4 servers available during updates

## Prerequisites

**WHERE:** Run these commands from your **management node**

1. **MinIO Operator** installed:
```bash
kubectl apply -k "github.com/minio/operator?ref=v6.0.4"
```

2. **StorageClass** named `standard` (or adjust in manifests)

3. **Generate credentials**:
```bash
# Root password (min 32 characters)
openssl rand -base64 32

# S3 access credentials
echo "Access Key: synapse-s3-user"
openssl rand -base64 24  # Secret key
```

## Deployment

**WHERE:** Run all deployment commands from your **management node**

**WORKING DIRECTORY:** `deployment/infrastructure/03-minio/`

### Step 1: Update Secrets

**WHAT:** Configure MinIO root credentials and S3 application credentials

**HOW:** Edit `secrets.yaml` on your management node and replace:
- `MINIO_ROOT_PASSWORD` with secure root password
- `CONSOLE_SECRET_KEY` and `secret-key` with same secure S3 password

```bash
# Generate passwords
ROOT_PASS=$(openssl rand -base64 32)
S3_PASS=$(openssl rand -base64 24)

# Update secrets.yaml with these values
# Then apply:
kubectl apply -f secrets.yaml
```

### Step 2: Deploy MinIO Tenant

```bash
kubectl apply -f tenant.yaml
```

### Step 3: Wait for Deployment

```bash
# Watch pods come up
kubectl get pods -n matrix -l v1.min.io/tenant=matrix-minio -w

# Wait for tenant to be ready
kubectl wait --for=condition=Available tenant/matrix-minio -n matrix --timeout=10m
```

### Step 4: Verify Deployment

```bash
# Check tenant status
kubectl get tenant matrix-minio -n matrix

# Check pods (should see 4 pods)
kubectl get pods -n matrix -l v1.min.io/tenant=matrix-minio

# Check services
kubectl get svc -n matrix | grep minio
```

Expected services:
- `minio` - S3 API (port 80/443)
- `matrix-minio-console` - Web UI (port 9090)
- `matrix-minio-hl` - Headless service

## Verification

**WHERE:** Run all verification commands from your **management node**

### Access MinIO Console

**Note:** This creates a port-forward tunnel to access the MinIO web console from your local browser

```bash
# Port-forward to console
kubectl port-forward -n matrix svc/matrix-minio-console 9090:9090

# Open browser: http://localhost:9090
# Login with: MINIO_ROOT_USER / MINIO_ROOT_PASSWORD from secrets
```

### Check Buckets

**Note:** These commands execute MinIO Client (mc) commands inside the MinIO pod

```bash
# Get a pod name
POD=$(kubectl get pods -n matrix -l v1.min.io/tenant=matrix-minio -o jsonpath='{.items[0].metadata.name}')

# List buckets using mc (MinIO Client)
kubectl exec -n matrix $POD -- mc ls local/
```

Expected output:
```
[2024-11-17 10:00:00 UTC]     0B postgresql-backups/
[2024-11-17 10:00:00 UTC]     0B synapse-media/
```

### Test S3 Upload

**WHAT:** Verify S3 API functionality by uploading and downloading a test file

**Note:** All commands execute inside the MinIO pod using MinIO Client (mc)

```bash
# Create test file
kubectl exec -n matrix $POD -- sh -c 'echo "test" > /tmp/test.txt'

# Upload to bucket
kubectl exec -n matrix $POD -- mc cp /tmp/test.txt local/synapse-media/test.txt

# List bucket
kubectl exec -n matrix $POD -- mc ls local/synapse-media/

# Download
kubectl exec -n matrix $POD -- mc cp local/synapse-media/test.txt /tmp/test-download.txt

# Verify
kubectl exec -n matrix $POD -- cat /tmp/test-download.txt
```

### Check Erasure Coding

**Note:** Verify distributed storage configuration and drive health

```bash
# Get drive status
kubectl exec -n matrix $POD -- mc admin info local/

# Should show:
# - 8 drives online
# - Storage: ~2Ti available (from 4Ti total)
# - Erasure Coding: EC:4
```

### Verify Healing

**Note:** Check if MinIO is performing any data healing operations

```bash
# Check for any offline drives (should be none)
kubectl exec -n matrix $POD -- mc admin heal local/ --verbose

# Should show: "All drives are healthy"
```

## Application Integration

### Synapse Media Storage

**Configuration** (synapse homeserver.yaml):
```yaml
media_storage_providers:
  - module: s3_storage_provider.S3StorageProviderBackend
    store_local: true
    store_remote: true
    store_synchronous: true
    config:
      bucket: synapse-media
      endpoint_url: http://minio.matrix.svc.cluster.local:9000
      access_key_id: synapse-s3-user
      secret_access_key: <from-secret>
      region_name: us-east-1
```

### CloudNativePG Backups

**Already configured** in `../01-postgresql/main-cluster.yaml`:
```yaml
backup:
  barmanObjectStore:
    destinationPath: s3://postgresql-backups/main/
    endpointURL: http://minio.matrix.svc.cluster.local:9000
    s3Credentials:
      accessKeyId:
        name: minio-credentials
        key: access-key
      secretAccessKey:
        name: minio-credentials
        key: secret-key
```

### LI Instance Media Access (Shared Bucket)

**Architecture**: LI Synapse uses main MinIO directly (no separate bucket, no sync).

**Configuration** (synapse-li homeserver.yaml):
```yaml
media_storage_providers:
  - module: s3_storage_provider.S3StorageProviderBackend
    store_local: true
    store_remote: true
    store_synchronous: true
    config:
      bucket: synapse-media  # SAME bucket as main instance
      endpoint_url: http://minio.matrix.svc.cluster.local:9000
      access_key_id: synapse-s3-user
      secret_access_key: <from-secret>
```

**Benefits**:
- Real-time media access (no sync lag)
- Reduced storage requirements on LI server
- Simpler architecture (no rclone, no separate bucket)

**⚠️ CRITICAL WARNING**:
- LI admins must NOT modify or delete media files
- Any changes affect the main instance
- Media quarantine/deletion must be done through main Synapse Admin

## Monitoring

### Prometheus Metrics

MinIO exposes Prometheus metrics at:
- Endpoint: `http://minio:9000/minio/v2/metrics/cluster`
- Auth: Public (configured via MINIO_PROMETHEUS_AUTH_TYPE)

**Key Metrics**:
- `minio_cluster_capacity_usable_total_bytes` - Usable capacity
- `minio_cluster_capacity_usable_free_bytes` - Free space
- `minio_cluster_nodes_online_total` - Online nodes
- `minio_cluster_disk_online_total` - Online disks
- `minio_cluster_disk_offline_total` - Offline disks
- `minio_s3_requests_total` - S3 API requests
- `minio_s3_errors_total` - S3 API errors
- `minio_heal_objects_total` - Healing operations

### Grafana Dashboard

Import MinIO dashboard: https://grafana.com/grafana/dashboards/13502

### Key Metrics to Monitor

```promql
# Offline disks (should be 0)
minio_cluster_disk_offline_total

# Online nodes (should be 4)
minio_cluster_nodes_online_total

# Storage utilization
(minio_cluster_capacity_usable_free_bytes / minio_cluster_capacity_usable_total_bytes)
```

## Maintenance

**WHERE:** Run all maintenance commands from your **management node**

### Scaling Storage

#### Vertical Scaling (Increase Volume Size)

**Current limitation**: MinIO doesn't support expanding existing volumes.

**Workaround**: Add new pool with larger volumes:
```yaml
pools:
  - name: pool-0
    servers: 4
    volumesPerServer: 2
    volumeClaimTemplate:
      spec:
        resources:
          requests:
            storage: 500Gi  # Original

  - name: pool-1  # New pool
    servers: 4
    volumesPerServer: 2
    volumeClaimTemplate:
      spec:
        resources:
          requests:
            storage: 1Ti  # Larger volumes
```

#### Horizontal Scaling (Add More Servers)

```yaml
pools:
  - name: pool-0
    servers: 8  # Increased from 4
    volumesPerServer: 2
```

**Note**: Requires re-balancing data. Plan carefully.

### Updating MinIO Version

**WHAT:** Update MinIO to a newer version

**HOW:** Edit `tenant.yaml` on your management node, update the image version, then apply:

```bash
# Update image in tenant.yaml
image: quay.io/minio/minio:RELEASE.2024-12-01T00-00-00Z

# Apply (performs rolling update)
kubectl apply -f tenant.yaml

# Monitor rollout
kubectl rollout status statefulset -n matrix -l v1.min.io/tenant=matrix-minio
```

### Password Rotation

**Root password**:

**WHAT:** Rotate MinIO root administrator password

```bash
# Update secret
kubectl edit secret minio-config -n matrix

# Restart pods to pick up new password
kubectl rollout restart statefulset -n matrix -l v1.min.io/tenant=matrix-minio
```

**Application credentials**:

**WHAT:** Rotate S3 application access credentials

**Note:** User creation executes inside MinIO pod using mc admin command

```bash
# Create new user in MinIO console or via mc
kubectl exec -n matrix $POD -- mc admin user add local/ newuser newpassword

# Update secret
kubectl edit secret minio-credentials -n matrix

# Update application configs (Synapse, CloudNativePG)
```

### Drive Replacement

**WHAT:** Handle drive failures with automatic healing

MinIO handles drive failures automatically with erasure coding:

1. **Detect failure**:
```bash
kubectl exec -n matrix $POD -- mc admin info local/
```

2. **If PVC fails**, delete the pod:
```bash
kubectl delete pod $FAILED_POD -n matrix
```

3. **Kubernetes recreates pod** with new PVC

4. **MinIO auto-heals** data from parity shards

## Troubleshooting

**WHERE:** Run all troubleshooting commands from your **management node**

### Pods Not Starting

**Note:** Diagnose MinIO Tenant deployment issues

```bash
# Check events
kubectl describe tenant matrix-minio -n matrix

# Check pod logs
kubectl logs -n matrix $POD

# Common issues:
# - StorageClass doesn't exist → create or adjust in tenant.yaml
# - Insufficient storage → check node disk space
# - Secret missing → verify secrets.yaml applied
```

### Drives Showing Offline

**Note:** Diagnose and repair drive failures

```bash
# Check drive status
kubectl exec -n matrix $POD -- mc admin info local/

# Force heal
kubectl exec -n matrix $POD -- mc admin heal local/ --recursive

# If PVC is corrupted, delete pod to recreate
```

### Bucket Not Accessible

**Note:** Troubleshoot S3 bucket access issues

```bash
# List buckets
kubectl exec -n matrix $POD -- mc ls local/

# If missing, create manually
kubectl exec -n matrix $POD -- mc mb local/synapse-media

# Set policy
kubectl exec -n matrix $POD -- mc anonymous set download local/synapse-media
```

### Performance Issues

**Note:** Diagnose slow storage or resource constraints

```bash
# Check resource usage
kubectl top pods -n matrix -l v1.min.io/tenant=matrix-minio

# Check for slow drives
kubectl exec -n matrix $POD -- mc admin speedtest local/

# Increase pod resources in tenant.yaml if needed
```

### Connection Refused

**Note:** Test connectivity to MinIO service from within the cluster

```bash
# Test from another pod
kubectl run -n matrix minio-test --rm -it --image=alpine -- sh
apk add curl
curl -I http://minio.matrix.svc.cluster.local:9000/minio/health/live

# Check service
kubectl get svc minio -n matrix

# Check endpoints
kubectl get endpoints minio -n matrix
```

## Backup & Recovery

**WHERE:** Run all backup/recovery commands from your **management node**

### Disaster Recovery

**Scenario**: Entire MinIO cluster lost

**CRITICAL:** MinIO stores PostgreSQL backups and media. If lost, both are affected.

1. **Restore from CloudNativePG backups** (PostgreSQL data):
```bash
# CloudNativePG has its own backups to MinIO
# If MinIO is lost, PostgreSQL backups are also lost
# CRITICAL: Backup PostgreSQL data externally!
```

2. **Restore media from external backup**:

**Note:** This command assumes you have external rclone backup configured

```bash
# Use rclone to restore from external backup
rclone copy backup:synapse-media main:synapse-media
```

**Recommendation**:
- Replicate MinIO data to external S3 (AWS/Backblaze)
- Use rclone for periodic off-site backups
- Consider PostgreSQL backups to external storage too

### Data Export

**WHAT:** Export all bucket data for external backup

**Note:** Commands execute inside MinIO pod, then copy to management node

```bash
# Export all data from bucket
kubectl exec -n matrix $POD -- mc mirror local/synapse-media /tmp/backup/

# Copy to local machine
kubectl cp matrix/$POD:/tmp/backup ./local-backup/
```

## Security Considerations

1. **Access Control**: Root credentials in secret, application credentials separate
2. **TLS**: Auto-generated certificates (requestAutoCert: true)
3. **Network Policies**: See `../04-networking/networkpolicies.yaml`
4. **Bucket Policies**: Default is private (no public access)
5. **Encryption at Rest**: Not enabled by default (add KES if required)

### Enabling Server-Side Encryption (Optional)

Requires MinIO KES (Key Encryption Service):
```yaml
# Add to tenant.yaml
kes:
  image: quay.io/minio/kes:latest
  replicas: 3
  configuration:
    name: kes-config
```

## Scaling Guidelines

| CCU Range | Servers | Volumes/Server | Total Storage | Usable (EC:4) |
|-----------|---------|----------------|---------------|---------------|
| 100 | 4 | 2 × 100Gi | 800Gi | 400Gi |
| 1,000 | 4 | 2 × 250Gi | 2Ti | 1Ti |
| 5,000 | 4 | 2 × 500Gi | 4Ti | **2Ti** (current) |
| 10,000 | 4 | 2 × 1Ti | 8Ti | 4Ti |
| 20,000 | 8 | 2 × 1Ti | 16Ti | 8Ti |

**Note**: For 20K CCU, consider adding a second pool instead of scaling existing pool.

## Differences from Simple Storage

| Feature | Simple NFS/PVC | MinIO Distributed |
|---------|----------------|-------------------|
| HA | ❌ Single point of failure | ✅ 4-node cluster |
| Data Protection | ❌ None | ✅ EC:4 (4 drive failures) |
| S3 API | ❌ | ✅ Native S3 |
| Auto-healing | ❌ | ✅ Automatic |
| Scalability | Limited | ✅ Horizontal |
| Complexity | Low | Medium |
| Resource Usage | 1 pod | 4 pods |

## References

- [MinIO Operator Documentation](https://min.io/docs/minio/kubernetes/upstream/)
- [Erasure Coding Guide](https://min.io/docs/minio/linux/operations/concepts/erasure-coding.html)
- [MinIO Kubernetes Deployment](https://github.com/minio/operator)
- [S3 API Documentation](https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html)
