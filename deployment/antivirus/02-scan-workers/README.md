# Matrix Content Scanner

Media scanning proxy that integrates Matrix Synapse with ClamAV antivirus.

## Overview

The Matrix Content Scanner is a **Python service** that intercepts media download requests and scans files for viruses before serving them to clients.

**How it works**:
1. Client requests media from Matrix (e.g., `/_matrix/media/r0/download/...`)
2. Request is proxied to Content Scanner (not directly to Synapse)
3. Content Scanner downloads media from Synapse
4. Media is scanned using ClamAV
5. **If clean**: Media served to client
6. **If infected**: HTTP 403 returned to client

**Based on**: [element-hq/matrix-content-scanner-python](https://github.com/element-hq/matrix-content-scanner-python)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        CLIENT REQUEST                       │
│                                                             │
│  GET /_matrix/media/r0/download/example.com/abc123          │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                  CONTENT SCANNER (Proxy)                    │
│                                                             │
│  1. Download media from Synapse                            │
│     ↓                                                       │
│  2. Save to /tmp                                           │
│     ↓                                                       │
│  3. Call ClamAV scan script                                │
│     ├─ Clean → Return media (200)                          │
│     └─ Infected → Return error (403)                       │
│                                                             │
│  Cache: Remember scan results ( TTL)                 │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ├─ ClamAV Service
                          │  (clamav:3310)
                          │
                          └─ Synapse Media Workers
                             (synapse-media:8008)
```

## Features

- ✅ **Virus scanning**: Integrates with ClamAV for malware detection
- ✅ **Caching**: Avoids re-scanning the same file (1-hour TTL)
- ✅ **Horizontal scaling**: 3-10 replicas with HPA
- ✅ **High availability**: PodDisruptionBudget (min 2 available)
- ✅ **Metadata removal**: Strips EXIF data from images for privacy
- ✅ **Prometheus metrics**: Scan rate, infected files, latency
- ✅ **Health checks**: Kubernetes probes for reliability

## Installation

### 1. Ensure ClamAV is Running

```bash
# Verify ClamAV DaemonSet
kubectl get daemonset clamav -n matrix

# Test ClamAV connectivity
kubectl run -it --rm --restart=Never test-clamav --image=busybox -n matrix -- \
  nc -zv clamav.matrix.svc.cluster.local 3310
```

### 2. Deploy Content Scanner

```bash
# Apply Content Scanner deployment
kubectl apply -f deployment.yaml

# Verify deployment
kubectl get deployment content-scanner -n matrix

# Check pods
kubectl get pods -n matrix -l app.kubernetes.io/name=content-scanner

# Expected output:
# NAME                               READY   STATUS    RESTARTS   AGE
# content-scanner-abc123-xyz         2/2     Running   0          2m
# content-scanner-def456-uvw         2/2     Running   0          2m
# content-scanner-ghi789-rst         2/2     Running   0          2m
```

### 3. Verify Service

```bash
# Check ClusterIP service
kubectl get svc content-scanner -n matrix

# Test health endpoint
kubectl run -it --rm --restart=Never test-scanner --image=curlimages/curl -n matrix -- \
  curl http://content-scanner.matrix.svc.cluster.local:8080/health

# Expected output:
# {"status": "ok"}
```

### 4. Configure Synapse to Use Scanner

Update Synapse homeserver.yaml to proxy media through scanner:

```yaml
# In homeserver.yaml
media_storage_providers:
  - module: synapse.rest.media.v1.media_repository.MediaRepositoryResource
    config:
      # Proxy media downloads through content scanner
      download_proxy: http://content-scanner.matrix.svc.cluster.local:8080
```

**OR** configure NGINX Ingress to route media requests:

```yaml
# In HAProxy or NGINX Ingress configuration
location ~ ^/_matrix/media/r0/(download|thumbnail)/ {
    proxy_pass http://content-scanner.matrix.svc.cluster.local:8080;
}
```

## Configuration

### Content Scanner (config.yaml)

**Web Server**:
```yaml
web:
  host: 0.0.0.0
  port: 8080
```

**Scan Settings**:
```yaml
scan:
  # Scan script (calls ClamAV)
  script: /app/scan.sh

  # Max file size (100MB)
  max_size: 104857600

  # Remove metadata from images
  remove_metadata: true
```

**Proxy to Synapse**:
```yaml
proxy:
  # Upstream Synapse media repository
  base_homeserver_url: http://synapse-media-repository.matrix.svc.cluster.local:8008
```

**Result Cache**:
```yaml
result_cache:
  type: memory     # In-memory cache (can use Redis for shared cache)
  ttl: 3600        # 
  max_size: 10000  # 10,000 entries
```

### Scan Script (scan.sh)

The scan script calls `clamdscan` (ClamAV client):

```bash
#!/bin/bash
FILE="$1"

# Scan file using clamdscan
if clamdscan --fdpass --no-summary "$FILE" 2>&1 | grep -q "Infected files: 0"; then
  echo "File is clean"
  exit 0    # Clean
else
  echo "File is infected!"
  exit 1    # Infected
fi
```

**Exit codes**:
- `0`: File is clean
- `1`: File is infected
- `2`: Error during scan

## Testing

### Test Clean File

```bash
# Create test file
echo "This is a clean file" > /tmp/test-clean.txt

# Upload to Matrix via Element or curl
# Then download and verify it passes through scanner
```

### Test Infected File (EICAR Test)

```bash
# Create EICAR test virus (standard test file, not real virus)
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.txt

# Upload to Matrix
# Expected: Scanner blocks download with HTTP 403

# Check scanner logs
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner

# Expected output:
# File is infected!
# Returning 403 Forbidden
```

### Test Caching

```bash
# Download same file twice
# First request: Scans file
# Second request: Uses cached result (faster)

# Check logs for cache hit
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner | grep "cache hit"
```

## Monitoring

### Prometheus Metrics

Content Scanner exposes metrics on port 9000:

**Available metrics**:
```promql
# Total scans
content_scanner_scans_total

# Infected files detected
content_scanner_infected_total

# Scan duration
content_scanner_scan_duration_seconds

# Cache hits
content_scanner_cache_hits_total

# Errors
content_scanner_errors_total
```

**Example queries**:

**Scan rate (last )**:
```promql
rate(content_scanner_scans_total[5m])
```

**Infected file rate**:
```promql
rate(content_scanner_infected_total[5m])
```

**Average scan duration**:
```promql
rate(content_scanner_scan_duration_seconds_sum[5m]) / rate(content_scanner_scan_duration_seconds_count[5m])
```

**Cache hit ratio**:
```promql
rate(content_scanner_cache_hits_total[5m]) / rate(content_scanner_scans_total[5m])
```

### ServiceMonitor

Content Scanner has a ServiceMonitor for automatic Prometheus scraping:

```bash
# Check ServiceMonitor
kubectl get servicemonitor content-scanner -n matrix

# Verify scraping in Prometheus
# Navigate to: http://localhost:9090/targets
# Search for: content-scanner
```

### Logs

```bash
# View logs
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner -f

# Search logs via Loki
{namespace="matrix", app_kubernetes_io_name="content-scanner"}

# Find infected files
{namespace="matrix", app_kubernetes_io_name="content-scanner"} |= "infected"

# Find scan errors
{namespace="matrix", app_kubernetes_io_name="content-scanner"} |= "error"
```

## Scaling

### Horizontal Pod Autoscaler (HPA)

Content Scanner uses HPA for automatic scaling:

**Configuration**:
- **Min replicas**: 3
- **Max replicas**: 10
- **Target CPU**: 70%
- **Target memory**: 80%

**Check HPA status**:
```bash
kubectl get hpa content-scanner -n matrix

# Example output:
# NAME              REFERENCE                    TARGETS          MINPODS   MAXPODS   REPLICAS   AGE
# content-scanner   Deployment/content-scanner   45%/70%, 60%/80%   3         10        5          10m
```

**Manual scaling** (override HPA):
```bash
# Scale to 5 replicas
kubectl scale deployment content-scanner -n matrix --replicas=5

# Disable HPA
kubectl delete hpa content-scanner -n matrix
```

### Resource Recommendations

**Small deployment (100-1K CCU)**:
- Replicas: 3
- CPU: 500m per pod
- Memory: 1Gi per pod

**Medium deployment (1K-5K CCU)**:
- Replicas: 5
- CPU: 1000m per pod
- Memory: 2Gi per pod

**Large deployment (5K-20K CCU)**:
- Replicas: 10
- CPU: 2000m per pod
- Memory: 2Gi per pod

## Troubleshooting

### Content Scanner not starting

**1. Check pod status**:
```bash
kubectl describe pod <content-scanner-pod> -n matrix
```

**2. Check init container (wait-for-clamav)**:
```bash
kubectl logs <content-scanner-pod> -n matrix -c wait-for-clamav
```

**Common issues**:
- ClamAV not running
- Service DNS resolution failure
- Network policies blocking traffic

### Scans failing

**1. Check content-scanner logs**:
```bash
kubectl logs <content-scanner-pod> -n matrix -c content-scanner
```

**2. Test ClamAV connectivity**:
```bash
kubectl exec -it -n matrix <content-scanner-pod> -c content-scanner -- \
  nc -zv clamav.matrix.svc.cluster.local 3310
```

**3. Test scan script manually**:
```bash
kubectl exec -it -n matrix <content-scanner-pod> -c content-scanner -- \
  /app/scan.sh /tmp/test.txt
```

**Common issues**:
- ClamAV timeout (file too large)
- Scan script permission denied
- Temp directory full

### High latency

**1. Check scan duration**:
```promql
rate(content_scanner_scan_duration_seconds_sum[5m]) / rate(content_scanner_scan_duration_seconds_count[5m])
```

**2. Check cache hit ratio**:
```promql
rate(content_scanner_cache_hits_total[5m]) / rate(content_scanner_scans_total[5m])
```

**Solutions**:
- Increase cache TTL (longer than )
- Use Redis for shared cache (instead of in-memory)
- Increase ClamAV resources
- Scale Content Scanner horizontally

### HTTP 403 for clean files

**1. Test file with ClamAV directly**:
```bash
kubectl exec -it -n matrix <clamav-pod> -c clamd -- \
  clamdscan /tmp/test.txt
```

**2. Check scan script exit codes**:
```bash
kubectl exec -it -n matrix <content-scanner-pod> -c content-scanner -- \
  bash -x /app/scan.sh /tmp/test.txt

# Exit code 0 = clean
# Exit code 1 = infected
# Exit code 2 = error
```

**3. Check ClamAV virus definitions**:
```bash
kubectl exec -n matrix <clamav-pod> -c freshclam -- \
  freshclam --version
```

**Common issues**:
- Outdated virus definitions (false positives)
- Scan script bug (incorrect exit code)
- File format not supported by ClamAV

## Performance Optimization

### Use Redis for Shared Cache

Replace in-memory cache with Redis:

```yaml
# Deploy Redis (if not already present)
# Then update config.yaml:
result_cache:
  type: redis
  redis_url: redis://redis.matrix.svc.cluster.local:6379/1
  ttl: 7200  # 
```

**Benefits**:
- Shared cache across all Content Scanner replicas
- Persistent cache (survives pod restarts)
- Higher cache hit ratio

### Increase Cache TTL

For rarely-changing media:

```yaml
result_cache:
  ttl: 86400  #  instead of 
```

### Adjust Max File Size

Skip scanning very large files:

```yaml
scan:
  max_size: 52428800  # 50MB instead of 100MB
```

**Note**: Files larger than `max_size` are **not scanned** and served directly.

## Security Considerations

### File Size Limits

**Default**: 100MB max scan size

**Risk**: Very large files may cause:
- High memory usage
- Scan timeout
- DoS (multiple large files)

**Mitigation**: Set appropriate `max_size` based on expected media types.

### Metadata Removal

**Enabled by default**: `remove_metadata: true`

**Purpose**: Remove EXIF data from images for privacy

**Trade-off**: May break some image features (orientation, geolocation)

### Error Handling

**On scan error**: Content Scanner returns HTTP 500 by default

**Options**:
1. **Fail-safe** (default): Serve file on error (prioritize availability)
2. **Fail-closed**: Block file on error (prioritize security)

Configure via `scan_on_error` setting.

## Upgrade

### Update Content Scanner Version

```bash
# Edit deployment.yaml
# Change image version: vectorim/matrix-content-scanner:v2.1.0 → v2.2.0

# Apply update
kubectl apply -f deployment.yaml

# Verify rolling update
kubectl rollout status deployment/content-scanner -n matrix
```

**Note**: Deployment uses `RollingUpdate` strategy with zero downtime.

## References

- [matrix-content-scanner-python GitHub](https://github.com/element-hq/matrix-content-scanner-python)
- [Matrix Content Scanner Protocol](https://github.com/matrix-org/matrix-spec-proposals/issues/1453)
- [ClamAV Integration](https://docs.clamav.net/)
- [Synapse Media Repository](https://matrix-org.github.io/synapse/latest/media_repository.html)
