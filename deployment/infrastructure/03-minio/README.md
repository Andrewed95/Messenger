# MinIO Distributed Object Storage

## Overview

MinIO provides S3-compatible object storage for Matrix media files and PostgreSQL backups.

**Why MinIO?**
- Synapse requires S3-compatible storage for media files
- CloudNativePG backs up to S3 for PITR
- LI instance needs separate media storage
- Production systems need distributed, redundant storage

## Architecture

### Distributed Mode with Erasure Coding

**Configuration:**
- **4 servers** (pods) in distributed mode
- **2 volumes per server** = 8 total drives
- **EC:4** erasure coding (4 data + 4 parity shards)
- **Can tolerate 4 drive failures** without data loss

**Topology:**
```
┌─────────────────────────────────────┐
│  matrix-minio-pool-0-0              │
│  - Volume 0: 500Gi                  │
│  - Volume 1: 500Gi                  │
│  Total: 1Ti per server              │
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│  matrix-minio-pool-0-1              │
│  - Volume 0: 500Gi                  │
│  - Volume 1: 500Gi                  │
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│  matrix-minio-pool-0-2              │
│  - Volume 0: 500Gi                  │
│  - Volume 1: 500Gi                  │
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│  matrix-minio-pool-0-3              │
│  - Volume 0: 500Gi                  │
│  - Volume 1: 500Gi                  │
└─────────────────────────────────────┘

Total Raw Storage: 4Ti
Usable Storage (EC:4): ~2Ti (50% efficiency)
```

### Erasure Coding EC:4 Explained

**How it works:**
- Each object is split into 4 data shards
- 4 parity shards are generated
- Total: 8 shards distributed across 8 drives
- Can reconstruct data from any 4 of 8 shards

**Benefits:**
- Better than RAID for distributed systems
- Can lose up to 4 drives without data loss
- Automatic healing when drives are replaced
- Higher availability than replication

**Storage Efficiency:**
- Raw capacity: 4Ti
- Parity overhead: 50% (4 parity for 4 data)
- Usable capacity: ~2Ti

## Components

### 1. Secrets (secrets.yaml)

**minio-config:**
- Root credentials (admin access)
- Erasure coding configuration: EC:4
- Performance tuning parameters

**minio-user:**
- Application access credentials
- Used by Synapse for media storage
- Base64 encoded

**minio-credentials:**
- Plain text credentials
- Used by CloudNativePG for backups
- Used by sync system for LI replication

### 2. Tenant (tenant.yaml)

**MinIO Tenant CRD:**
- Distributed deployment with 4 servers
- 2 volumes per server (8 total drives)
- Automatic bucket creation
- TLS auto-generation
- Prometheus monitoring enabled

**Pre-created Buckets:**
- `synapse-media` - Main instance media files
- `synapse-media-li` - LI instance media files
- `postgresql-backups` - Database backups

### 3. Services

**minio (created by operator):**
- S3 API endpoint: port 9000
- Used by applications

**minio-console:**
- Web UI: port 9090
- Management interface

### 4. PodDisruptionBudget

- Ensures minimum 3/4 servers available during updates
- Prevents data loss during maintenance

## Prerequisites

1. **MinIO Operator** installed in cluster:
```bash
kubectl apply -k "github.com/minio/operator?ref=v6.0.2"
```

2. **StorageClass** named `standard`:
```bash
kubectl get storageclass standard
```

3. **Generate Secure Passwords**:
```bash
# Root password
openssl rand -base64 32

# User password
openssl rand -base64 32
```

## Deployment

### Step 1: Install MinIO Operator

```bash
# Install operator
kubectl apply -k "github.com/minio/operator?ref=v6.0.2"

# Wait for operator to be ready
kubectl wait --for=condition=Available deployment/minio-operator -n minio-operator --timeout=5m
```

### Step 2: Update Secrets

```bash
# Edit secrets.yaml and replace:
# - MINIO_ROOT_PASSWORD
# - CONSOLE_SECRET_KEY (base64 encoded)
# - secret-key in minio-credentials

# Apply secrets
kubectl apply -f secrets.yaml
```

### Step 3: Deploy MinIO Tenant

```bash
kubectl apply -f tenant.yaml
```

### Step 4: Wait for Tenant

```bash
# Watch tenant creation
kubectl get tenant matrix-minio -n matrix -w

# Wait for all pods
kubectl wait --for=condition=Ready pod -l v1.min.io/tenant=matrix-minio -n matrix --timeout=10m
```

Expected: 4 pods running (one per server)

## Verification

### Check Tenant Status

```bash
kubectl get tenant matrix-minio -n matrix
```

Expected output:
```
NAME           STATE         AGE
matrix-minio   Initialized   5m
```

### Check Pods

```bash
kubectl get pods -n matrix -l v1.min.io/tenant=matrix-minio
```

Expected: 4 pods in Running state

### Check Buckets

```bash
# Port-forward to MinIO
kubectl port-forward -n matrix svc/minio 9000:9000

# In another terminal, install mc (MinIO client)
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc

# Configure mc
./mc alias set matrix http://localhost:9000 admin <root-password>

# List buckets
./mc ls matrix/
```

Expected:
```
[2025-11-17 10:00:00 UTC]     0B synapse-media/
[2025-11-17 10:00:00 UTC]     0B synapse-media-li/
[2025-11-17 10:00:00 UTC]     0B postgresql-backups/
```

### Check Erasure Coding

```bash
# Check drive status
./mc admin info matrix/
```

Should show: 8 drives online (4 servers × 2 volumes)

### Test Upload/Download

```bash
# Upload test file
echo "test data" > test.txt
./mc cp test.txt matrix/synapse-media/

# Download test file
./mc cp matrix/synapse-media/test.txt downloaded.txt

# Verify
diff test.txt downloaded.txt

# Cleanup
./mc rm matrix/synapse-media/test.txt
```

## Application Integration

### Synapse Media Storage

**Configuration in homeserver.yaml:**
```yaml
media_storage_providers:
  - module: s3_storage_provider.S3StorageProviderBackend
    store_local: True
    store_remote: True
    store_synchronous: True
    config:
      bucket: synapse-media
      endpoint_url: http://minio.matrix.svc.cluster.local:9000
      access_key_id: synapse
      secret_access_key: <from-minio-credentials-secret>
      region_name: us-east-1
```

**Python requirements:**
```txt
boto3>=1.26.0
botocore>=1.29.0
```

### CloudNativePG Backup

**Already configured in PostgreSQL clusters:**
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

### LI Media Sync (rclone)

**rclone configuration:**
```ini
[minio-main]
type = s3
provider = Minio
access_key_id = synapse
secret_access_key = <from-secret>
endpoint = http://minio.matrix.svc.cluster.local:9000

[minio-li]
type = s3
provider = Minio
access_key_id = synapse
secret_access_key = <from-secret>
endpoint = http://minio.matrix.svc.cluster.local:9000
```

**Sync command:**
```bash
rclone sync minio-main:synapse-media minio-li:synapse-media-li \
  --progress \
  --transfers 4 \
  --checkers 8
```

## Monitoring

### Prometheus Metrics

MinIO exposes Prometheus metrics at `/minio/v2/metrics/cluster`.

**ServiceMonitor (auto-created by operator):**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: matrix-minio
spec:
  selector:
    matchLabels:
      v1.min.io/tenant: matrix-minio
  endpoints:
    - port: http-minio
      path: /minio/v2/metrics/cluster
```

**Key Metrics:**
- `minio_cluster_capacity_usable_total_bytes` - Usable capacity
- `minio_cluster_capacity_usable_free_bytes` - Free space
- `minio_s3_requests_total` - Request count
- `minio_s3_requests_errors_total` - Error count
- `minio_heal_objects_heal_total` - Healed objects
- `minio_heal_objects_errors_total` - Heal errors

### MinIO Console

Access web UI:
```bash
kubectl port-forward -n matrix svc/minio-console 9090:9090
```

Navigate to: http://localhost:9090

Login with root credentials.

### Health Check

```bash
# Check cluster health
./mc admin health matrix/
```

Expected: All drives online, no errors

## Maintenance

### Scaling Storage

**Option 1: Increase volume size (vertical scaling)**
```bash
# Edit tenant.yaml, increase storage request
storage: 1Ti  # was 500Gi

# Apply changes
kubectl apply -f tenant.yaml

# Operator will expand PVCs automatically
```

**Option 2: Add new pool (horizontal scaling)**
```yaml
pools:
  - name: pool-0
    servers: 4
    volumesPerServer: 2
    # ... existing config

  - name: pool-1  # New pool
    servers: 4
    volumesPerServer: 2
    volumeClaimTemplate:
      spec:
        resources:
          requests:
            storage: 500Gi
```

### Updating MinIO Version

```bash
# Edit tenant.yaml, update image tag
image: quay.io/minio/minio:RELEASE.2024-12-01T00-00-00Z

# Apply
kubectl apply -f tenant.yaml

# Operator performs rolling update
kubectl rollout status statefulset/matrix-minio-pool-0 -n matrix
```

### Password Rotation

**Root password:**
```bash
# Create new secret
kubectl create secret generic minio-config-new \
  --from-file=config.env=<new-config> -n matrix

# Update tenant to use new secret
kubectl patch tenant matrix-minio -n matrix \
  --type merge -p '{"spec":{"configuration":{"name":"minio-config-new"}}}'

# Restart pods
kubectl rollout restart statefulset/matrix-minio-pool-0 -n matrix
```

**User password:**
```bash
# Use MinIO console or mc to update user
./mc admin user add matrix/ synapse <new-password>
```

### Backup Configuration

MinIO configuration is stored in:
1. Secrets (credentials)
2. Tenant CRD (deployment config)

**Backup:**
```bash
kubectl get secret minio-config -n matrix -o yaml > minio-config-backup.yaml
kubectl get secret minio-credentials -n matrix -o yaml > minio-creds-backup.yaml
kubectl get tenant matrix-minio -n matrix -o yaml > tenant-backup.yaml
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events
kubectl describe pod matrix-minio-pool-0-0 -n matrix

# Check logs
kubectl logs matrix-minio-pool-0-0 -n matrix

# Common issues:
# - PVC not bound: Check StorageClass
# - Image pull error: Check image name/tag
# - Resource limits: Check node resources
```

### Drives Offline

```bash
# Check drive status
./mc admin info matrix/

# If drives offline:
# 1. Check PVC status
kubectl get pvc -n matrix -l v1.min.io/tenant=matrix-minio

# 2. Check if pods can mount volumes
kubectl describe pod <pod-name> -n matrix

# 3. Healing will start automatically once drives are online
./mc admin heal matrix/ --recursive
```

### High Error Rate

```bash
# Check error logs
kubectl logs matrix-minio-pool-0-0 -n matrix | grep ERROR

# Check metrics
./mc admin prometheus metrics matrix/

# Common causes:
# - Network issues
# - Disk full
# - Corrupted data (triggers healing)
```

### Bucket Not Accessible

```bash
# Check bucket policy
./mc admin policy list matrix/

# Set policy if needed
./mc admin policy attach matrix/ readwrite --user synapse

# Check user
./mc admin user list matrix/
```

### Console Not Accessible

```bash
# Check console service
kubectl get svc minio-console -n matrix

# Check if pod is running
kubectl get pods -n matrix -l v1.min.io/console=matrix-minio

# Port-forward directly to pod
kubectl port-forward matrix-minio-pool-0-0 -n matrix 9090:9090
```

## Data Recovery

### Lost Drive Scenario

**EC:4 can tolerate up to 4 drive failures.**

If a drive fails:
1. MinIO automatically detects failure
2. Reads data from remaining drives
3. Reconstructs missing data from parity
4. Continues serving requests (degraded mode)

**When drive is replaced:**
```bash
# MinIO automatically starts healing
# Monitor healing progress
./mc admin heal matrix/ --recursive --verbose

# Check heal status
kubectl logs matrix-minio-pool-0-0 -n matrix | grep heal
```

### Disaster Recovery

**Full cluster loss:**

1. **Restore from Backup** (if using external backup)
2. **Rebuild Cluster** with same configuration
3. **Restore Data** from backup source

**Partial data loss:**
- If < 4 drives lost: Automatic recovery
- If ≥ 5 drives lost: Data loss, restore from backup

## Performance Tuning

### For Higher Throughput

```yaml
# Increase resources in tenant.yaml
resources:
  limits:
    cpu: 4
    memory: 8Gi

# Increase API limits in minio-config
MINIO_API_REQUESTS_MAX="20000"
```

### For More Parallelism

```yaml
# Add more servers (must be multiple of 4)
servers: 8  # Instead of 4

# Or add more volumes per server
volumesPerServer: 4  # Instead of 2
```

### Network Optimization

```yaml
# Enable faster network if available
# Set pod annotations for network policies
annotations:
  k8s.v1.cni.cncf.io/networks: high-speed-network
```

## Security Considerations

1. **TLS**: Auto-generated by operator, certificates in /tmp/certs
2. **Authentication**: Root and user credentials required
3. **Network Policies**: See ../04-networking/networkpolicies.yaml
4. **Encryption at Rest**: Enable if required by cloud provider
5. **Audit Logging**: Enable via MINIO_AUDIT_WEBHOOK

### Enable Audit Logging

```yaml
# In minio-config secret
MINIO_AUDIT_WEBHOOK_ENABLE_target1="on"
MINIO_AUDIT_WEBHOOK_ENDPOINT_target1="http://audit-service:8080/webhook"
```

## Scaling Guidelines

| CCU Range | Servers | Volumes/Server | Storage/Volume | Total Raw | Usable (EC:4) |
|-----------|---------|----------------|----------------|-----------|---------------|
| 100 | 4 | 2 | 100Gi | 800Gi | 400Gi |
| 1,000 | 4 | 2 | 250Gi | 2Ti | 1Ti |
| 5,000 | 4 | 2 | 500Gi | 4Ti | 2Ti |
| 10,000 | 8 | 2 | 500Gi | 8Ti | 4Ti |
| 20,000 | 8 | 4 | 500Gi | 16Ti | 8Ti |

**Note**: Always provision 2x expected usage to account for:
- Temporary uploads
- Backup retention
- Growth over time

## Comparison with Alternatives

| Feature | MinIO | Ceph | AWS S3 |
|---------|-------|------|--------|
| S3 Compatible | ✅ Yes | ✅ Yes | ✅ Native |
| On-Premises | ✅ Yes | ✅ Yes | ❌ No |
| Kubernetes Native | ✅ Yes | ⚠️ Complex | ❌ No |
| Erasure Coding | ✅ EC:4 | ✅ Configurable | ✅ Automatic |
| Operator | ✅ Yes | ⚠️ Rook | ❌ N/A |
| Complexity | ⭐⭐ Low | ⭐⭐⭐⭐⭐ High | ⭐ Managed |
| Cost | ✅ Free | ✅ Free | ❌ Pay per GB |

**Why MinIO for this deployment:**
- ✅ Native Kubernetes integration
- ✅ Simple operator-based deployment
- ✅ S3-compatible (works with Synapse)
- ✅ Erasure coding for data protection
- ✅ Lower complexity than Ceph
- ✅ Air-gapped deployment support

## References

- [MinIO Documentation](https://min.io/docs/minio/kubernetes/upstream/)
- [MinIO Operator](https://github.com/minio/operator)
- [Erasure Coding](https://min.io/docs/minio/linux/operations/concepts/erasure-coding.html)
- [Tenant CRD Reference](https://github.com/minio/operator/blob/master/docs/tenant_crd.adoc)
