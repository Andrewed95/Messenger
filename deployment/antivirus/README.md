# Matrix Antivirus System

Complete antivirus protection for Matrix/Synapse media files using ClamAV.

## Overview

The antivirus system provides real-time scanning of all uploaded and downloaded media files to protect users from malware and viruses.

**Components**:
1. **ClamAV DaemonSet** (`01-clamav/`): Antivirus engine running on every node
2. **Content Scanner** (`02-scan-workers/`): Media proxy that integrates Synapse with ClamAV

**Protection Level**: All media files are scanned before being served to clients.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                    MATRIX CLIENT REQUEST                       │
│                                                                │
│  Upload:  POST /_matrix/media/r0/upload                       │
│  Download: GET /_matrix/media/r0/download/...                 │
└──────────────────────────┬─────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│                     NGINX INGRESS / HAPROXY                    │
│                  (Routes media requests)                       │
└──────────────────────────┬─────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│               CONTENT SCANNER (Proxy + Scanner)                │
│                                                                │
│  1. Receive media request                                     │
│  2. Check cache (already scanned?)                            │
│     ├─ Cache hit → Serve immediately                          │
│     └─ Cache miss → Continue                                  │
│  3. Download from Synapse                                     │
│  4. Scan with ClamAV                                          │
│     ├─ Clean → Serve to client + cache result                 │
│     └─ Infected → Return HTTP 403                             │
│                                                                │
│  Replicas: 3-10 (auto-scales)                                 │
└──────────────────────┬────────────┬──────────────────────────┘
                       │            │
                       │            │
                       ▼            ▼
          ┌────────────────┐   ┌───────────────┐
          │    ClamAV      │   │    Synapse    │
          │   DaemonSet    │   │ Media Workers │
          │                │   │               │
          │  - clamd       │   │  Port: 8008   │
          │  - freshclam   │   └───────────────┘
          │                │
          │  Port: 3310    │
          │  Per Node      │
          └────────────────┘
```

## Components

### 1. ClamAV DaemonSet

**Purpose**: Antivirus scanning engine

**Deployment**: DaemonSet (one pod per node)

**Features**:
- ✅ ClamAV daemon (clamd) for scanning
- ✅ FreshClam for automatic virus definition updates (every )
- ✅ ~8M+ virus signatures
- ✅ Support for archives, PDFs, Office documents
- ✅ 1GB memory per node

**Location**: `01-clamav/`

### 2. Content Scanner

**Purpose**: Media proxy with virus scanning

**Deployment**: Deployment (3-10 replicas with HPA)

**Features**:
- ✅ Intercepts all media downloads
- ✅ Scans files with ClamAV before serving
- ✅ In-memory cache (1-hour TTL)
- ✅ Horizontal auto-scaling
- ✅ Prometheus metrics

**Location**: `02-scan-workers/`

## Quick Start

**WHERE:** Run all commands from your **management node**

**WORKING DIRECTORY:** `deployment/antivirus/`

### 1. Deploy ClamAV

```bash
# Deploy ClamAV DaemonSet
kubectl apply -f 01-clamav/deployment.yaml

# Verify ClamAV is running on all nodes
kubectl get daemonset clamav -n matrix

# Check virus definitions were downloaded
kubectl logs -n matrix <clamav-pod> -c init-freshclam

# Expected output:
# Updating ClamAV virus definitions...
# Database updated from database.clamav.net
# Virus definitions updated successfully
```

### 2. Deploy Content Scanner

```bash
# Deploy Content Scanner
kubectl apply -f 02-scan-workers/deployment.yaml

# Verify deployment
kubectl get deployment content-scanner -n matrix

# Check pods are running
kubectl get pods -n matrix -l app.kubernetes.io/name=content-scanner

# Expected: 3 pods running (READY 2/2)
```

### 3. Configure Matrix Integration

**WHAT:** Configure routing to send media downloads through content scanner

**Option A: HAProxy Routing** (Recommended)

**HOW:** Edit `main-instance/03-haproxy/haproxy.cfg` on your management node:

```haproxy
# Route media downloads through content scanner
frontend matrix_client
    # ... existing config ...

    # Media downloads
    acl is_media_download path_beg /_matrix/media/r0/download
    acl is_media_download path_beg /_matrix/media/r0/thumbnail
    use_backend content_scanner if is_media_download

backend content_scanner
    balance roundrobin
    server scanner1 content-scanner.matrix.svc.cluster.local:8080 check
```

**Option B: NGINX Ingress Annotation**

Add to Synapse Ingress:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/configuration-snippet: |
      location ~ ^/_matrix/media/r0/(download|thumbnail)/ {
        proxy_pass http://content-scanner.matrix.svc.cluster.local:8080;
      }
```

**Option C: Synapse Configuration** (Direct proxy)

Edit `homeserver.yaml`:

```yaml
media_storage_providers:
  - module: synapse.rest.media.v1.media_repository.MediaRepositoryResource
    config:
      download_proxy: http://content-scanner.matrix.svc.cluster.local:8080

# Note: The content scanner proxies to synapse-media-repository.matrix.svc.cluster.local:8008
```

### 4. Verify Integration

```bash
# Test clean file upload and download
# (via Element or curl)

# Test EICAR virus (should be blocked)
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > eicar.txt
# Upload via Element
# Expected: HTTP 403 Forbidden on download

# Check Content Scanner logs
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner | grep infected
```

## How It Works

### Upload Flow (with scanning)

```
1. Client → POST /_matrix/media/r0/upload
   ↓
2. NGINX Ingress → Synapse Media Worker
   ↓
3. Synapse → Save to MinIO (synapse-media bucket)
   ↓
4. Synapse → Return media_id to client
```

**Note**: Uploads are scanned on **first download**, not on upload.

### Download Flow (with scanning)

```
1. Client → GET /_matrix/media/r0/download/{server}/{media_id}
   ↓
2. NGINX/HAProxy → Content Scanner (not Synapse)
   ↓
3. Content Scanner → Check cache
   ├─ Cache hit → Return cached result
   └─ Cache miss → Continue
   ↓
4. Content Scanner → Download from Synapse
   ↓
5. Content Scanner → Scan with ClamAV
   ├─ Clean (exit 0) → Serve to client + cache
   └─ Infected (exit 1) → Return HTTP 403
```

### Thumbnail Flow

Thumbnails are also scanned:

```
GET /_matrix/media/r0/thumbnail/{server}/{media_id}
  → Content Scanner
  → ClamAV scan
  → Serve or block
```

## Resource Requirements

### Per-Node Requirements (ClamAV)

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|-----------|-------------|-----------|----------------|--------------|---------|
| clamd     | 500m        | 2000m     | 1Gi            | 2Gi          | -       |
| freshclam | 200m        | 1000m     | 512Mi          | 1Gi          | -       |
| virus-db  | -           | -         | -              | -            | 2Gi     |
| **Total** | **700m**    | **3000m** | **1.5Gi**      | **3Gi**      | **2Gi** |

### Cluster-wide Requirements (Content Scanner)

| Deployment | Min Replicas | Max Replicas | CPU/Pod | Memory/Pod |
|------------|--------------|--------------|---------|------------|
| Content Scanner | 3 | 10 | 500m-2000m | 1Gi-2Gi |

**Example** (3-node cluster, 5 scanner replicas):
- **Total CPU**: ~5 cores (request), ~15 cores (limit)
- **Total Memory**: ~10Gi (request), ~20Gi (limit)
- **Total Storage**: ~6Gi (virus DB per node)

## Monitoring

### Prometheus Metrics

**ClamAV** (via ServiceMonitor):
```promql
# Virus definitions version
clamav_database_version

# Scans performed
clamav_scans_total

# Infected files
clamav_infected_total
```

**Content Scanner**:
```promql
# Scan rate
rate(content_scanner_scans_total[5m])

# Infected file rate
rate(content_scanner_infected_total[5m])

# Cache hit ratio
rate(content_scanner_cache_hits_total[5m]) / rate(content_scanner_scans_total[5m])

# Average scan duration
rate(content_scanner_scan_duration_seconds_sum[5m]) / rate(content_scanner_scan_duration_seconds_count[5m])
```

### Grafana Dashboard

Create dashboard with panels:

1. **Scan Rate**: `rate(content_scanner_scans_total[5m])`
2. **Infected Files**: `rate(content_scanner_infected_total[5m])`
3. **Cache Hit Ratio**: (formula above)
4. **Scan Latency (95th)**: `histogram_quantile(0.95, rate(content_scanner_scan_duration_seconds_bucket[5m]))`
5. **ClamAV Health**: `up{job="clamav"}`

### Logs

**ClamAV logs**:
```bash
kubectl logs -n matrix <clamav-pod> -c clamd -f
```

**Content Scanner logs**:
```bash
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner -f
```

**Loki queries**:
```logql
# Find infected files
{namespace="matrix", app_kubernetes_io_name="content-scanner"} |= "infected"

# Find scan errors
{namespace="matrix", app_kubernetes_io_name="content-scanner"} |= "error"

# ClamAV virus definition updates
{namespace="matrix", app_kubernetes_io_name="clamav"} |= "Database updated"
```

## Scaling

### ClamAV (DaemonSet)

**Auto-scales** with cluster nodes:
- Add node → ClamAV pod automatically scheduled
- Remove node → ClamAV pod terminated

**No manual scaling required.**

### Content Scanner (Deployment)

**HPA auto-scaling**:
- Min replicas: 3
- Max replicas: 10
- Target CPU: 70%
- Target memory: 80%

**Manual scaling**:
```bash
kubectl scale deployment content-scanner -n matrix --replicas=5
```

## Performance

### Scan Performance

| File Size | Scan Time (avg) | Notes |
|-----------|-----------------|-------|
| < 1MB     | 50-100ms        | Most images |
| 1-10MB    | 100-500ms       | Videos, documents |
| 10-50MB   | 500ms-2s        | Large videos |
| 50-100MB  | 2-5s            | Max scan size |

**Cache hit**: < 10ms (memory lookup)

### Throughput

**Single Content Scanner pod**:
- ~10-20 scans/sec (with caching)
- ~2-5 scans/sec (cold cache, large files)

**3 replicas**: ~30-60 scans/sec (with caching)

**10 replicas**: ~100-200 scans/sec (with caching)

## Security

### Threat Protection

**Protected against**:
- ✅ Malware (viruses, trojans, worms)
- ✅ Ransomware
- ✅ Spyware
- ✅ Phishing documents
- ✅ Macro viruses (Office files)
- ✅ Infected archives (zip, tar, rar)
- ✅ PDF exploits

**Not protected against**:
- ❌ Zero-day exploits (not yet in virus DB)
- ❌ Encrypted archives (ClamAV cannot scan inside)
- ❌ Steganography (hidden data in images)

### False Positives

**Rate**: < 0.01% with up-to-date virus definitions

**Handling**:
1. User reports blocked file
2. Admin tests file locally with ClamAV
3. If false positive:
   - Report to ClamAV team
   - Temporarily whitelist file hash
   - Wait for virus DB update

### Privacy

**Metadata removal**: Enabled by default

**EXIF data removed from**:
- JPEG images
- PNG images
- TIFF images

**Purpose**: Remove location, camera info, timestamps

## Troubleshooting

### Files blocked incorrectly (false positive)

```bash
# 1. Check ClamAV virus DB version
kubectl exec -n matrix <clamav-pod> -c clamd -- clamdscan --version

# 2. Test file manually
kubectl exec -n matrix <clamav-pod> -c clamd -- \
  clamdscan /path/to/file

# 3. Update virus definitions
kubectl exec -n matrix <clamav-pod> -c freshclam -- \
  freshclam --no-daemon
```

### Scans timing out

```bash
# 1. Check scan duration
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner | grep "scan_duration"

# 2. Increase timeout (clamd.conf)
# Edit ConfigMap:
kubectl edit configmap clamav-config -n matrix

# Add:
# ReadTimeout 1200  # 

# 3. Restart ClamAV
kubectl delete pod <clamav-pod> -n matrix
```

### High memory usage

```bash
# Check ClamAV memory
kubectl top pod -n matrix -l app.kubernetes.io/name=clamav

# Increase limits if needed
kubectl edit daemonset clamav -n matrix
```

**Note**: ClamAV requires ~1GB RAM minimum for virus DB.

### Content Scanner not scanning

```bash
# 1. Check ClamAV connectivity
kubectl exec -it -n matrix <content-scanner-pod> -c content-scanner -- \
  nc -zv clamav.matrix.svc.cluster.local 3310

# 2. Check scan script
kubectl exec -it -n matrix <content-scanner-pod> -c content-scanner -- \
  /app/scan.sh /tmp/test.txt

# 3. Check logs
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner
```

## Compliance

### Audit Trail

All scans are logged:

```logql
# All scans
{namespace="matrix", app_kubernetes_io_name="content-scanner"}

# Infected files with metadata
{namespace="matrix", app_kubernetes_io_name="content-scanner"} | json | infected="true"
```

**Logs include**:
- Timestamp
- File hash
- File size
- Scan result (clean/infected)
- Virus name (if infected)
- User (if logged by Synapse)

### Retention

**Scan logs**:  (via Loki)

**Infected files**:
- Not served to users (HTTP 403)
- Still stored in MinIO (for investigation)
- Can be deleted manually or via retention policy

### Reporting

**Weekly report** (via Grafana):
1. Total scans performed
2. Infected files detected
3. Most common viruses
4. Cache hit ratio
5. Average scan latency

## Best Practices

1. **Keep virus definitions updated**: FreshClam runs every  (default)
2. **Monitor scan latency**: Alert if > 2 seconds average
3. **Monitor infected file rate**: Alert if sudden spike
4. **Test monthly**: Upload EICAR test file to verify scanning works
5. **Review logs weekly**: Check for false positives or errors
6. **Allocate sufficient resources**: ClamAV needs 1-2GB RAM per node
7. **Use caching**: 1-hour TTL reduces scan load significantly
8. **Scale Content Scanner**: Add replicas during high traffic periods

## Upgrade

### Update ClamAV

```bash
# Edit version in deployment.yaml
# clamav/clamav:1.4.1 → clamav/clamav:1.5.0

kubectl apply -f 01-clamav/deployment.yaml

# Verify rolling update
kubectl rollout status daemonset/clamav -n matrix
```

### Update Content Scanner

```bash
# Edit version in deployment.yaml
# vectorim/matrix-content-scanner:v2.1.0 → v2.2.0

kubectl apply -f 02-scan-workers/deployment.yaml

# Verify rolling update
kubectl rollout status deployment/content-scanner -n matrix
```

## References

- [ClamAV Documentation](https://docs.clamav.net/)
- [matrix-content-scanner-python](https://github.com/element-hq/matrix-content-scanner-python)
- [Matrix Content Scanning MSC](https://github.com/matrix-org/matrix-spec-proposals/issues/1453)
- [ClamAV Virus Database](https://www.clamav.net/documents/clamav-virus-database-faq)
- [Synapse Media Repository](https://matrix-org.github.io/synapse/latest/media_repository.html)

---

**Antivirus System Version**: 1.0
**Last Updated**: 2025-11-18
**ClamAV Version**: 1.4.1
**Content Scanner Version**: 2.1.0
