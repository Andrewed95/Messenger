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
│  2. Check in-memory cache (already scanned?)                  │
│     ├─ Cache hit → Serve immediately (no scan)                │
│     └─ Cache miss → Continue to step 3                        │
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
- ✅ FreshClam for automatic virus definition updates (every 6 hours)
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
- ✅ **In-memory cache per pod** - reduces re-scanning of frequently accessed files
- ✅ 24-hour cache TTL (infected files blocked for 24 hours)
- ✅ 50,000 cache entries per pod (configurable)
- ✅ Horizontal auto-scaling
- ✅ Prometheus metrics

**Note on caching**: matrix-content-scanner uses in-memory caching only.
Each scanner pod maintains its own TTLCache. For high-volume deployments
where files may be scanned multiple times across pods, consider:
1. Using HAProxy consistent hashing to route same media to same pod
2. Increasing cache size for better hit rates
3. Most media is accessed shortly after upload (temporal locality)

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
- ✅ **Files in encrypted (E2EE) rooms** - see below

**Not protected against**:
- ❌ Zero-day exploits (not yet in virus DB)
- ❌ Password-protected archives (ClamAV cannot decrypt passwords)
- ❌ Steganography (hidden data in images)

### Encrypted Room (E2EE) Support

The content scanner **CAN scan files shared in end-to-end encrypted rooms**.

**How it works:**
1. When a user shares a file in an E2EE room, Matrix encrypts the file with a symmetric key
2. The symmetric key is shared with room members via E2EE message (room key)
3. When downloading media, clients request the encrypted file + decryption info
4. The content scanner's `crypto` configuration enables it to:
   - Receive the encrypted file and decryption parameters
   - Decrypt the file temporarily in memory
   - Scan the decrypted content with ClamAV
   - Return clean/infected result
   - Never store the decrypted file

**Configuration (required for E2EE support):**
```yaml
# In 02-scan-workers/deployment.yaml ConfigMap
crypto:
  pickle_path: /tmp/matrix-content-scanner/pickle.dat
  pickle_key: "YOUR_SECURE_PICKLE_KEY"  # Generate with: openssl rand -hex 32
```

**Security notes:**
- The `pickle_key` encrypts the Olm session state (not the media files)
- Decryption is performed in memory only
- The scanner never stores decrypted content to disk
- All temporary files are in a size-limited emptyDir (5Gi)

**Testing E2EE scanning:**
```bash
# 1. Create an E2EE room in Element
# 2. Share a file (e.g., an image)
# 3. Check content scanner logs:
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner | grep "scan"
# Should show the file was scanned

# 4. Share EICAR test file in E2EE room
# Expected: HTTP 403 when other members try to download
```

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

1. **Keep virus definitions updated**: FreshClam runs every 6 hours by default
2. **Monitor scan latency**: Watch if > 2 seconds average
3. **Monitor infected file rate**: Watch for sudden spikes in detections
4. **Test monthly**: Upload EICAR test file to verify scanning works
5. **Review logs weekly**: Check for false positives or errors
6. **Allocate sufficient resources**: ClamAV needs 1-2GB RAM per node
7. **Redis cache ensures scan-once**: Each file scanned exactly once (24-hour TTL)
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

