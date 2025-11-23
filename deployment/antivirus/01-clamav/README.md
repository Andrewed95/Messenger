# ClamAV Antivirus DaemonSet

ClamAV antivirus daemon deployment for scanning Matrix media files.

## Overview

ClamAV is deployed as a **DaemonSet**, running one instance on every node in the cluster. This ensures:
- **Low latency**: Media files scanned on the same node
- **High availability**: Multiple ClamAV instances for redundancy
- **Load distribution**: Scanning load spread across all nodes

**Components**:
- **clamd**: Antivirus scanning daemon (port 3310)
- **freshclam**: Virus definition updater (updates every 6 hours)

## Architecture

```
┌────────────────────────────────────────────────────────┐
│                   KUBERNETES CLUSTER                   │
│                                                        │
│  Node 1                Node 2                Node 3    │
│  ┌──────────┐         ┌──────────┐         ┌────────┐ │
│  │  ClamAV  │         │  ClamAV  │         │ ClamAV │ │
│  │  Pod     │         │  Pod     │         │  Pod   │ │
│  │          │         │          │         │        │ │
│  │ clamd    │         │ clamd    │         │ clamd  │ │
│  │ :3310    │         │ :3310    │         │ :3310  │ │
│  │          │         │          │         │        │ │
│  │freshclam │         │freshclam │         │freshcl │ │
│  └────┬─────┘         └────┬─────┘         └───┬────┘ │
│       │                    │                   │      │
│       └────────────────────┴───────────────────┘      │
│                            │                          │
│                            ▼                          │
│                    ┌───────────────┐                  │
│                    │  Service:     │                  │
│                    │  clamav:3310  │                  │
│                    └───────────────┘                  │
│                            │                          │
│                            ▼                          │
│                  ┌──────────────────┐                 │
│                  │ Content Scanner  │                 │
│                  │   (calls clamd)  │                 │
│                  └──────────────────┘                 │
└────────────────────────────────────────────────────────┘
```

## Resource Requirements

### Per Node

**clamd**:
- CPU: 500m (request), 2000m (limit)
- Memory: 1Gi (request), 2Gi (limit)
- Storage: 2Gi (virus database + temp files)

**freshclam**:
- CPU: 200m (request), 1000m (limit)
- Memory: 512Mi (request), 1Gi (limit)

**Total per node**: ~1.5Gi memory, 700m CPU (idle)

### Cluster-wide

For a 3-node cluster:
- **Total Memory**: ~4.5Gi
- **Total CPU**: ~2.1 cores (request)
- **Total Storage**: ~6Gi (virus database replicated per node)

## Installation

### 1. Deploy ClamAV DaemonSet

```bash
# Apply ClamAV configuration and DaemonSet
kubectl apply -f deployment.yaml

# Verify DaemonSet is running on all nodes
kubectl get daemonset clamav -n matrix

# Check pods (should be 1 per node)
kubectl get pods -n matrix -l app.kubernetes.io/name=clamav -o wide

# Expected output:
# NAME            READY   STATUS    RESTARTS   AGE   NODE
# clamav-abcd1    2/2     Running   0          5m    node-1
# clamav-efgh2    2/2     Running   0          5m    node-2
# clamav-ijkl3    2/2     Running   0          5m    node-3
```

### 2. Verify Virus Definitions Downloaded

```bash
# Check init container logs (virus DB download)
kubectl logs -n matrix <clamav-pod> -c init-freshclam

# Expected output:
# Updating ClamAV virus definitions...
# ...
# Virus definitions updated successfully

# Check clamd container logs
kubectl logs -n matrix <clamav-pod> -c clamd

# Expected output:
# ...
# Listening daemon: PID: 1
# ...
# Protecting against 8000000+ viruses and malware
```

### 3. Test ClamAV Scanning

```bash
# Connect to a ClamAV pod
kubectl exec -it -n matrix <clamav-pod> -c clamd -- sh

# Test scan (inside pod)
echo "X5O!P%@AP[4\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*" > /tmp/eicar.txt
clamdscan --fdpass /tmp/eicar.txt

# Expected output:
# /tmp/eicar.txt: Eicar-Signature FOUND
# Infected files: 1
```

### 4. Verify Service

```bash
# Check ClusterIP service
kubectl get svc clamav -n matrix

# Test connectivity from another pod
kubectl run -it --rm --restart=Never test-clamav --image=busybox -n matrix -- nc -zv clamav.matrix.svc.cluster.local 3310

# Expected output:
# clamav.matrix.svc.cluster.local (10.x.x.x:3310) open
```

## Configuration

### ClamAV Daemon (clamd.conf)

Key settings:

```ini
# Listening
TCPSocket 3310
TCPAddr 0.0.0.0

# File size limits
MaxScanSize 500M    # Maximum scan size
MaxFileSize 100M    # Maximum file size
MaxRecursion 20     # Archive recursion depth

# Scanning options
ScanPDF yes         # Scan PDF files
ScanSWF yes         # Scan Flash files
ScanArchive yes     # Scan archives (zip, tar, etc.)

# Database directory
DatabaseDirectory /var/lib/clamav
```

### FreshClam (freshclam.conf)

Key settings:

```ini
# Database directory
DatabaseDirectory /var/lib/clamav

# Update frequency
Checks 4            # 4 times per day = every 6 hours

# Database mirror
DatabaseMirror database.clamav.net
```

## Virus Definition Updates

### Automatic Updates

FreshClam runs as a sidecar container and updates virus definitions every 6 hours:

```bash
# Check freshclam logs
kubectl logs -n matrix <clamav-pod> -c freshclam

# Expected output:
# FreshClam daemon started
# ...
# Database updated from database.clamav.net
# ...
```

### Manual Update

```bash
# Force virus definition update
kubectl exec -n matrix <clamav-pod> -c freshclam -- \
  freshclam --config-file=/etc/clamav/freshclam.conf --no-daemon

# Restart clamd to reload definitions (optional)
kubectl delete pod <clamav-pod> -n matrix
```

### Virus Database Size

- **Initial download**: ~200-300MB
- **Daily updates**: ~10-50MB
- **Total storage**: 2Gi allocated per node

## Security

### Port Exposure

**CRITICAL**: Port 3310 is NOT exposed externally for security reasons.

- ClamAV does **not** authenticate clients
- Exposing port 3310 would allow anyone to scan files
- **Only accessible via**:
  - ClusterIP Service (internal cluster traffic)
  - Localhost (pod network)

### Network Policies

ClamAV is subject to the `antivirus-access` NetworkPolicy:

```yaml
# Allows:
- Content Scanner → ClamAV (port 3310)
- ClamAV → internet (virus DB updates)

# Denies:
- External traffic → ClamAV
- ClamAV → other Matrix services
```

### Container Security

- **Non-root user**: Runs as UID 100, GID 101
- **Read-only root filesystem**: False (needs temp files)
- **No privilege escalation**
- **Capabilities dropped**: ALL
- **Seccomp profile**: RuntimeDefault

## Monitoring

### Health Checks

**Liveness Probe**:
- Type: TCP socket
- Port: 3310
- Initial delay: 60s
- Period: 30s

**Readiness Probe**:
- Type: TCP socket
- Port: 3310
- Initial delay: 30s
- Period: 10s

### Metrics

ClamAV doesn't expose Prometheus metrics natively. To monitor:

1. **Option 1**: Add `clamav_exporter` sidecar
2. **Option 2**: Monitor via logs (Loki)
3. **Option 3**: Monitor pod health (kube-state-metrics)

**Key metrics to track**:
- Virus database version and update time
- Scan count and duration
- Infected files detected
- Resource usage (CPU, memory)

### Logs

```bash
# View clamd logs
kubectl logs -n matrix <clamav-pod> -c clamd -f

# View freshclam logs
kubectl logs -n matrix <clamav-pod> -c freshclam -f

# Search logs via Loki
{namespace="matrix", app_kubernetes_io_name="clamav"} |= "FOUND"
```

## Troubleshooting

### ClamAV pod not starting

**1. Check pod status**:
```bash
kubectl describe pod <clamav-pod> -n matrix
```

**2. Check init container logs**:
```bash
kubectl logs <clamav-pod> -n matrix -c init-freshclam
```

**Common issues**:
- Virus DB download failed (network issue)
- Insufficient storage for virus DB
- Node resource constraints (memory)

### Virus definitions not updating

**1. Check freshclam logs**:
```bash
kubectl logs <clamav-pod> -n matrix -c freshclam
```

**2. Test manual update**:
```bash
kubectl exec -n matrix <clamav-pod> -c freshclam -- \
  freshclam --config-file=/etc/clamav/freshclam.conf --no-daemon
```

**Common issues**:
- DNS resolution failure
- Firewall blocking database.clamav.net
- Rate limiting (too frequent updates)

### Scans timing out

**1. Check clamd resources**:
```bash
kubectl top pod <clamav-pod> -n matrix
```

**2. Increase timeout in clamd.conf**:
```yaml
data:
  clamd.conf: |
    ReadTimeout 1200  # Increase to 
```

**3. Increase resource limits**:
```yaml
resources:
  limits:
    memory: 4Gi    # Increase from 2Gi
    cpu: 4000m     # Increase from 2000m
```

### High memory usage

**Cause**: ClamAV loads entire virus database into memory.

**Solutions**:
1. **Accept it**: ~1GB is normal for ClamAV
2. **Reduce MaxFileSize**: Limit scan size
3. **Disable features**: Turn off PDF/archive scanning if not needed

### Connection refused errors

**1. Check clamd is listening**:
```bash
kubectl exec -n matrix <clamav-pod> -c clamd -- netstat -tlnp | grep 3310
```

**2. Test from content-scanner pod**:
```bash
kubectl exec -it -n matrix <content-scanner-pod> -- nc -zv clamav.matrix.svc.cluster.local 3310
```

**3. Check Service endpoints**:
```bash
kubectl get endpoints clamav -n matrix
```

## Performance Tuning

### For High-Volume Scanning

**1. Increase MaxThreads**:
```yaml
data:
  clamd.conf: |
    MaxThreads 24  # Increase from 12
```

**2. Increase resources**:
```yaml
resources:
  requests:
    cpu: 1000m
    memory: 2Gi
  limits:
    cpu: 4000m
    memory: 4Gi
```

**3. Use node selector** (scan on high-memory nodes):
```yaml
spec:
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: "true"
        memory-size: large
```

### For Low-Volume Scanning

**1. Reduce resources**:
```yaml
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```

**2. Reduce update frequency**:
```yaml
data:
  freshclam.conf: |
    Checks 2  # Reduce to 2 times per day
```

## Scaling

ClamAV DaemonSet scales automatically with cluster nodes:

- **Add node** → ClamAV pod automatically scheduled
- **Remove node** → ClamAV pod automatically terminated

No manual scaling required.

## Upgrade

### Update ClamAV Version

```bash
# Edit deployment.yaml
# Change image version: clamav/clamav:1.4.1 → clamav/clamav:1.5.0

# Apply update
kubectl apply -f deployment.yaml

# Verify rolling update
kubectl rollout status daemonset/clamav -n matrix
```

**Note**: DaemonSet uses `RollingUpdate` strategy with `maxUnavailable: 1`, so nodes are updated one at a time.

## References

- [ClamAV Documentation](https://docs.clamav.net/)
- [ClamAV Docker Image](https://hub.docker.com/r/clamav/clamav)
- [clamd Configuration](https://docs.clamav.net/manual/Usage/Configuration.html#clamdconf)
- [FreshClam Configuration](https://docs.clamav.net/manual/Usage/Configuration.html#freshclamconf)
- [ClamAV Signatures](https://docs.clamav.net/manual/Signatures.html)
