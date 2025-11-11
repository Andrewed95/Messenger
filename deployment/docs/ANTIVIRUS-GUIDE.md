# Antivirus Implementation Guide
## Complete Guide for Matrix/Synapse at 20K CCU Scale

**Last Updated:** November 11, 2025
**Document Version:** 2.0

---

## Table of Contents

1. [Executive Summary & Decision Framework](#1-executive-summary--decision-framework)
2. [Option A: Implementing Antivirus (Async Scanning)](#2-option-a-implementing-antivirus-async-scanning)
3. [Option B: Deploying Without Antivirus](#3-option-b-deploying-without-antivirus)
4. [Operational Considerations](#4-operational-considerations)
5. [Migration Between Options](#5-migration-between-options)

---

## 1. Executive Summary & Decision Framework

### 1.1 The Core Question

**Should you implement antivirus scanning for your Matrix/Synapse deployment?**

The answer depends on your specific deployment context, risk tolerance, and resources.

### 1.2 Quick Decision Matrix

Use this matrix to determine the right approach:

| Criterion | Deploy With AV | Deploy Without AV |
|-----------|---------------|-------------------|
| **User Base** | >100 users or external users | <100 trusted internal users |
| **Budget** | >$200/month available | Limited (<$200/month for AV) |
| **Risk Tolerance** | Low (must prevent malware) | High (can accept malware risk) |
| **Operational Capacity** | Have ops team | Limited (no dedicated team) |
| **Compliance** | HIPAA, PCI-DSS, or similar | No regulatory requirements |
| **File Types** | Executables, archives allowed | Mostly text/images |
| **User Trust** | Public, unknown users | Employees only, educated |
| **Liability** | Customer data, legal exposure | Internal risk acceptable |

**Scoring:**
- **6-8 "Deploy With AV":** Antivirus is **strongly recommended**
- **3-5 mixed:** **Re-evaluate trade-offs** carefully with your team
- **6-8 "Deploy Without AV":** Deploying without AV is **reasonable**

### 1.3 Hard Requirements for Each Option

**MUST IMPLEMENT ANTIVIRUS IF:**
- ❌ Public-facing deployment (unknown users)
- ❌ Healthcare / Medical data (HIPAA compliance)
- ❌ Financial services (PCI-DSS requirements)
- ❌ Customer-facing SaaS (legal liability)
- ❌ Government / Defense (classified data)
- ❌ Large enterprise (>1000 users)

**CAN SKIP ANTIVIRUS IF:**
- ✅ Internal company deployment (<100 employees)
- ✅ Proof-of-concept / Staging environment
- ✅ Development / Testing environment only
- ✅ Budget-constrained non-profit / education (with strict file policies)
- ✅ You implement comprehensive alternative security measures (Section 3)

### 1.4 Cost-Benefit Analysis

**Cost of Running Antivirus:**
- Infrastructure: $150-250/month (10-20 vCPU, 24Gi RAM)
- Operational: 2-4 hours/month (monitoring, updates, incident response)
- Complexity: Moderate (queue management, ClamAV updates, false positives)
- Development: Included in deployment package

**Cost of Malware Incident:**
- Data Breach: $50,000 - $500,000+ (IBM average: $4.24M)
- Downtime: $5,000 - $50,000/hour
- Reputation: Difficult to quantify, potentially severe
- Legal: Fines, lawsuits, regulatory penalties
- Recovery: 100+ hours of emergency work

**ROI Calculation:**
```
Annual AV Cost = $250/month × 12 = $3,000
Break-even = 1 prevented incident worth >$3,000

Even ONE prevented malware incident per year justifies the cost.
```

### 1.5 Critical Technical Constraint

**⚠️ IMPORTANT:** At 20K CCU scale, **synchronous antivirus scanning is NOT viable**.

If you implement antivirus, you **MUST** use asynchronous background scanning (detailed in Section 2).

**Why Synchronous Scanning Fails:**
- 200 concurrent uploads during peak hour
- 10-200 seconds scan time per file
- Would require 100+ CPU cores for acceptable latency
- Cost: $1000+/month just for AV infrastructure
- User experience: 3+ minute wait for upload completion

**Solution:** Asynchronous scanning (files are available for 30-60 seconds before scan completes).

---

## 2. Option A: Implementing Antivirus (Async Scanning)

**Choose this option if your decision matrix indicated "Deploy With AV".**

### 2.1 Architecture Overview

**High-Level Design:**

```
┌─────────────────────────────────────────────────────────────┐
│                     Upload Flow                              │
│  User → Element Client → Synapse → Store Immediately → OK   │
│          (2 seconds total, no scan delay)                    │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ File metadata → Redis Queue
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Background Scanning                        │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌─────────────┐  │
│  │ Scan Worker  │    │ Scan Worker  │    │ Scan Worker │  │
│  │   (Pod 1)    │    │   (Pod 2)    │ ...│  (Pod N)    │  │
│  └──────────────┘    └──────────────┘    └─────────────┘  │
│         │                    │                    │         │
│         └────────────────────┴────────────────────┘         │
│                              │                               │
│                       ┌──────▼──────┐                       │
│                       │ ClamAV Pool │                       │
│                       │ (Deployment) │                       │
│                       │  10 pods     │                       │
│                       │  20 threads  │                       │
│                       └──────┬──────┘                       │
│                              │                               │
│                    ┌─────────▼─────────┐                    │
│                    │  Scan Result      │                    │
│                    └─────────┬─────────┘                    │
│                              │                               │
│               ┌──────────────┴──────────────┐               │
│               │                             │               │
│           Clean                         Infected            │
│               │                             │               │
│      Mark in database              Quarantine via           │
│      (no action)                   Synapse Admin API        │
│                                           │                  │
│                                    Notify admin             │
│                                    Optionally notify user   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Performance Characteristics

**ClamAV Scanning Performance:**
- Small files (1MB): ~2 seconds
- Medium files (10MB): ~20 seconds
- Large files (50MB): ~100 seconds
- Max file (100MB limit): ~200 seconds
- CPU: 100% of 1 core during scan (CPU-bound)
- RAM: ~50-100MB per concurrent scan thread

**20K CCU Upload Pattern Assumptions:**
- Total users: 20,000 concurrent
- Active uploaders: 5% (1,000 users might upload during peak hour)
- Upload rate: 1 file per user per hour average
- Average file size: 5MB (images, documents, small videos)
- Peak upload burst: 1% of users upload simultaneously (200 concurrent uploads)

**Scaling Calculation:**

With 10 ClamAV pods × 2 threads each = 20 concurrent scans:
- Average scan time: 10 seconds (for 5MB)
- Throughput: 20 scans / 10 seconds = **120 scans/minute**
- Queue depth at 200 uploads: 200 / 20 = 10 iterations
- Time to clear burst: 10 iterations × 10 seconds = **100 seconds**

**Result:** ~60-second average scan latency, which is acceptable for async model.

### 2.3 Component Implementation

#### Component A: Synapse Spam-Checker Module

**Purpose:** Accept uploads immediately, queue for scanning
**Performance:** <100ms overhead
**Location:** `/deployment/config/synapse_async_av_checker.py`

**Implementation:**

```python
# synapse_async_av_checker.py

import asyncio
import redis
import hashlib
import json
import time
from synapse.module_api import ModuleApi
from synapse.module_api.errors import Codes

class AsyncAVChecker:
    """
    Asynchronous antivirus checker for Synapse uploads.

    Strategy:
    1. Calculate SHA-256 hash of uploaded file
    2. Check Redis cache for previous scan result
    3. If cached and clean: allow immediately
    4. If cached and infected: reject immediately
    5. If not cached: allow upload, queue for background scanning
    """

    def __init__(self, config: dict, api: ModuleApi):
        self.api = api
        self.redis_client = redis.Redis(
            host=config.get("redis_host", "redis-synapse-master.redis-synapse.svc.cluster.local"),
            port=config.get("redis_port", 6379),
            db=config.get("redis_db", 1),  # Separate DB for AV
            decode_responses=True
        )
        self.scan_queue = config.get("scan_queue", "av:scan:queue")
        self.results_hash = config.get("results_hash", "av:scan:results")

    async def check_media_file_for_spam(self, file_wrapper, file_info):
        """
        Called when media is uploaded to Synapse.
        """
        # Read file content for hashing
        file_content = file_wrapper.read()
        file_wrapper.seek(0)  # Reset for actual storage

        # Calculate hash (fast, <50ms for 5MB)
        file_hash = hashlib.sha256(file_content).hexdigest()

        # Check cache (instant if cached)
        cached_result = self.redis_client.hget(self.results_hash, file_hash)

        if cached_result:
            result_data = json.loads(cached_result)
            if result_data["status"] == "clean":
                # Cache hit: file already scanned and clean
                self.api.logger.info(f"Cache hit (clean): {file_hash}")
                return Codes.NOT_SPAM
            elif result_data["status"] == "infected":
                # Cache hit: file already scanned and infected
                self.api.logger.warn(f"Blocked cached infected file: {file_hash}")
                return Codes.FORBIDDEN

        # Not in cache: queue for scanning
        scan_job = {
            "file_hash": file_hash,
            "media_id": file_info.get("media_id"),
            "upload_name": file_info.get("upload_name"),
            "file_size": len(file_content),
            "timestamp": int(time.time())
        }

        # Push to scan queue (Redis list)
        self.redis_client.lpush(self.scan_queue, json.dumps(scan_job))

        # Allow upload (will be scanned in background)
        self.api.logger.info(f"Queued for scanning: {file_hash} ({file_info.get('upload_name')})")
        return Codes.NOT_SPAM


# Module registration
def parse_config(config: dict) -> dict:
    return config


def create_module(config: dict, api: ModuleApi):
    return AsyncAVChecker(config, api)
```

**Configuration in homeserver.yaml:**

```yaml
modules:
  - module: synapse_async_av_checker.AsyncAVChecker
    config:
      redis_host: "redis-synapse-master.redis-synapse.svc.cluster.local"
      redis_port: 6379
      redis_db: 1
      scan_queue: "av:scan:queue"
      results_hash: "av:scan:results"
```

**What This Does:**
1. Hashes uploaded file with SHA-256 (fast, <50ms for 5MB)
2. Checks Redis cache for previous scan result (instant if cached)
3. If not cached: Queues file metadata for scanning, allows upload
4. Returns immediately to user (<100ms total overhead)

**Critical Note:** File content is NOT sent over network during upload path - only metadata is queued.

#### Component B: Background Scan Worker

**Purpose:** Process scan queue, coordinate with ClamAV
**Performance:** Process files at steady rate
**Deployment:** Kubernetes Deployment, auto-scaled
**Location:** `/deployment/config/av_scan_worker.py`

**Implementation:**

```python
# av_scan_worker.py

import redis
import requests
import json
import time
import os
from clamd import ClamdNetworkSocket

class AVScanWorker:
    """
    Background worker that processes the scan queue.

    Workflow:
    1. Poll Redis queue for files to scan (blocking wait)
    2. Fetch file from Synapse media repository
    3. Scan with ClamAV via INSTREAM protocol
    4. If infected: Quarantine via Synapse Admin API
    5. Cache result in Redis by file hash
    """

    def __init__(self):
        self.redis = redis.Redis(
            host=os.getenv("REDIS_HOST", "redis-synapse-master.redis-synapse.svc.cluster.local"),
            port=int(os.getenv("REDIS_PORT", "6379")),
            db=int(os.getenv("REDIS_DB", "1")),
            decode_responses=True
        )
        self.clamd = ClamdNetworkSocket(
            host=os.getenv("CLAMAV_HOST", "clamav.antivirus.svc.cluster.local"),
            port=int(os.getenv("CLAMAV_PORT", "3310"))
        )
        self.synapse_admin_url = os.getenv("SYNAPSE_ADMIN_URL", "http://synapse-main.matrix.svc.cluster.local:8008")
        self.admin_token = os.getenv("SYNAPSE_ADMIN_TOKEN")
        self.matrix_domain = os.getenv("MATRIX_DOMAIN")

    def process_queue(self):
        """Main loop: process scan queue."""
        print("AV Scan Worker started")

        while True:
            try:
                # Block until job available (BRPOP = blocking right pop)
                job_data = self.redis.brpop("av:scan:queue", timeout=5)

                if not job_data:
                    time.sleep(1)
                    continue

                queue_name, job_json = job_data
                job = json.loads(job_json)

                print(f"Processing scan job: {job['file_hash']}")
                self.scan_file(job)

            except Exception as e:
                print(f"Error processing queue: {e}")
                time.sleep(5)

    def scan_file(self, job):
        """Scan a single file."""
        file_hash = job["file_hash"]
        media_id = job["media_id"]

        try:
            # Fetch file from Synapse media repo
            media_url = f"{self.synapse_admin_url}/_matrix/media/r0/download/{self.matrix_domain}/{media_id}"
            response = requests.get(
                media_url,
                headers={"Authorization": f"Bearer {self.admin_token}"},
                timeout=30
            )

            if response.status_code != 200:
                print(f"Failed to fetch media {media_id}: HTTP {response.status_code}")
                return

            file_content = response.content

            # Scan with ClamAV using INSTREAM
            scan_result = self.clamd.instream(file_content)

            # Parse result
            is_infected = scan_result["stream"][0] != "OK"

            if is_infected:
                virus_name = scan_result["stream"][1]
                print(f"⚠️  INFECTED: {media_id} - {virus_name}")
                self.handle_infected_file(media_id, file_hash, virus_name)
                result_status = "infected"
            else:
                print(f"✓ Clean: {media_id}")
                result_status = "clean"

            # Cache result in Redis
            result_data = {
                "status": result_status,
                "scanned_at": int(time.time()),
                "virus_name": virus_name if is_infected else None
            }
            self.redis.hset("av:scan:results", file_hash, json.dumps(result_data))

        except Exception as e:
            print(f"Error scanning file {media_id}: {e}")

    def handle_infected_file(self, media_id, file_hash, virus_name):
        """Quarantine infected file via Synapse Admin API."""
        quarantine_url = f"{self.synapse_admin_url}/_synapse/admin/v1/media/quarantine/{self.matrix_domain}/{media_id}"

        try:
            response = requests.post(
                quarantine_url,
                headers={"Authorization": f"Bearer {self.admin_token}"},
                json={"reason": f"Infected with {virus_name}"},
                timeout=10
            )

            if response.status_code == 200:
                print(f"✓ Quarantined: {media_id} ({virus_name})")
            else:
                print(f"✗ Failed to quarantine {media_id}: HTTP {response.status_code} - {response.text}")

        except Exception as e:
            print(f"✗ Error quarantining {media_id}: {e}")


if __name__ == "__main__":
    worker = AVScanWorker()
    worker.process_queue()
```

**Deployment Manifest:**

```yaml
# deployment/manifests/11-antivirus.yaml

apiVersion: apps/v1
kind: Deployment
metadata:
  name: av-scan-worker
  namespace: matrix
  labels:
    app: antivirus
    component: scan-worker
spec:
  replicas: 5  # Scale based on queue depth
  selector:
    matchLabels:
      app: antivirus
      component: scan-worker
  template:
    metadata:
      labels:
        app: antivirus
        component: scan-worker
    spec:
      containers:
      - name: worker
        image: YOUR_REGISTRY/av-scan-worker:latest
        env:
        - name: REDIS_HOST
          value: "redis-synapse-master.redis-synapse.svc.cluster.local"
        - name: REDIS_PORT
          value: "6379"
        - name: REDIS_DB
          value: "1"
        - name: CLAMAV_HOST
          value: "clamav.antivirus.svc.cluster.local"
        - name: CLAMAV_PORT
          value: "3310"
        - name: SYNAPSE_ADMIN_URL
          value: "http://synapse-main.matrix.svc.cluster.local:8008"
        - name: SYNAPSE_ADMIN_TOKEN
          valueFrom:
            secretKeyRef:
              name: synapse-admin-token
              key: token
        - name: MATRIX_DOMAIN
          valueFrom:
            configMapKeyRef:
              name: matrix-config
              key: domain
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 1Gi
```

#### Component C: ClamAV Deployment

**Purpose:** Actual virus scanning engine
**Performance:** 10 pods × 2 threads each = 20 concurrent scans
**Scaling:** Horizontal pod autoscaling based on CPU

**Deployment Manifest:**

```yaml
---
# Namespace for antivirus components
apiVersion: v1
kind: Namespace
metadata:
  name: antivirus

---
# PersistentVolumeClaim for ClamAV virus signatures
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: clamav-signatures
  namespace: antivirus
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: ${STORAGE_CLASS_GENERAL}

---
# ConfigMap for ClamAV configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: clamav-config
  namespace: antivirus
data:
  clamd.conf: |
    # Network
    TCPSocket 3310
    TCPAddr 0.0.0.0

    # Performance
    MaxThreads 2              # 2 threads per pod = 20 total with 10 pods
    MaxQueue 4                # 2× MaxThreads
    MaxConnectionQueueLength 30

    # Limits
    StreamMaxLength 100M      # Max file size to scan
    MaxScanSize 100M
    MaxFileSize 100M

    # Timeouts
    ReadTimeout 300           # 5 minutes max per scan
    CommandReadTimeout 30

    # Logging
    LogFile /dev/stdout
    LogTime yes
    LogFileMaxSize 0          # Unlimited (let Kubernetes handle rotation)
    LogVerbose no

    # Signatures
    DatabaseDirectory /var/lib/clamav

    # Performance
    OfficialDatabaseOnly no

---
# ClamAV Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clamav
  namespace: antivirus
  labels:
    app: clamav
spec:
  replicas: 10
  selector:
    matchLabels:
      app: clamav
  template:
    metadata:
      labels:
        app: clamav
    spec:
      containers:
      - name: clamd
        image: clamav/clamav:latest
        ports:
        - containerPort: 3310
          name: clamd
        resources:
          requests:
            cpu: 1000m      # 1 CPU core
            memory: 2Gi
          limits:
            cpu: 2000m      # 2 CPU cores max
            memory: 4Gi
        volumeMounts:
        - name: config
          mountPath: /etc/clamav/clamd.conf
          subPath: clamd.conf
        - name: signatures
          mountPath: /var/lib/clamav
        livenessProbe:
          tcpSocket:
            port: 3310
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          exec:
            command:
            - /usr/local/bin/clamdscan
            - --ping
            - "5"
          initialDelaySeconds: 120
          periodSeconds: 10
      volumes:
      - name: config
        configMap:
          name: clamav-config
      - name: signatures
        persistentVolumeClaim:
          claimName: clamav-signatures

---
# ClamAV Service
apiVersion: v1
kind: Service
metadata:
  name: clamav
  namespace: antivirus
spec:
  selector:
    app: clamav
  ports:
  - port: 3310
    targetPort: 3310
  type: ClusterIP

---
# HorizontalPodAutoscaler for ClamAV
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: clamav-hpa
  namespace: antivirus
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: clamav
  minReplicas: 5
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
```

**ClamAV Signature Updates (CronJob):**

```yaml
---
# CronJob for ClamAV signature updates
apiVersion: batch/v1
kind: CronJob
metadata:
  name: clamav-freshclam
  namespace: antivirus
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: freshclam
            image: clamav/clamav:latest
            command:
            - freshclam
            - --config-file=/etc/clamav/freshclam.conf
            - --datadir=/var/lib/clamav
            - --foreground
            volumeMounts:
            - name: signatures
              mountPath: /var/lib/clamav
            resources:
              requests:
                cpu: 100m
                memory: 256Mi
              limits:
                cpu: 500m
                memory: 1Gi
          volumes:
          - name: signatures
            persistentVolumeClaim:
              claimName: clamav-signatures
```

### 2.4 Deployment Steps

**Step 1: Create Antivirus Namespace and Storage**

```bash
# WHERE: On your kubectl-configured workstation
# WHEN: Before deploying any AV components
# WHY: Isolate AV components in separate namespace, prepare storage for virus signatures
# HOW:

kubectl create namespace antivirus

# Apply PVC for ClamAV signatures
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: clamav-signatures
  namespace: antivirus
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: ${STORAGE_CLASS_GENERAL}
EOF

# Verify PVC is bound
kubectl get pvc -n antivirus clamav-signatures
# Expected output: STATUS should be "Bound"
```

**Step 2: Deploy ClamAV**

```bash
# WHERE: On your kubectl-configured workstation
# WHEN: After namespace and PVC are created
# WHY: Deploy virus scanning engine
# HOW:

# Replace variables in manifest
export STORAGE_CLASS_GENERAL="your-storage-class"  # e.g., "longhorn", "ceph-fs"

# Apply ClamAV deployment
envsubst < deployment/manifests/11-antivirus.yaml | kubectl apply -f -

# Wait for ClamAV pods to be ready (takes 2-5 minutes for first signature download)
kubectl wait --for=condition=ready pod -l app=clamav -n antivirus --timeout=600s

# Verify ClamAV is running
kubectl get pods -n antivirus
# Expected: 10 clamav pods in Running state

# Check ClamAV logs to ensure signatures loaded
kubectl logs -n antivirus deployment/clamav --tail=50 | grep -i "database"
# Expected output should show "Database loaded" or similar
```

**Step 3: Deploy Scan Workers**

```bash
# WHERE: On your kubectl-configured workstation
# WHEN: After ClamAV is running
# WHY: Deploy background workers to process scan queue
# HOW:

# Build and push scan worker Docker image
cd deployment/config/
docker build -t your-registry/av-scan-worker:latest -f Dockerfile.av-worker .
docker push your-registry/av-scan-worker:latest

# Update manifest with your image
sed -i 's|YOUR_REGISTRY/av-scan-worker:latest|your-registry/av-scan-worker:latest|g' \
  ../manifests/11-antivirus.yaml

# Apply scan worker deployment
kubectl apply -f ../manifests/11-antivirus.yaml

# Verify workers are running
kubectl get pods -n matrix -l component=scan-worker
# Expected: 5 av-scan-worker pods in Running state

# Check worker logs
kubectl logs -n matrix -l component=scan-worker --tail=20
# Expected: "AV Scan Worker started" message
```

**Step 4: Configure Synapse Spam-Checker Module**

```bash
# WHERE: On your kubectl-configured workstation
# WHEN: After scan workers are deployed
# WHY: Enable AV checking on file uploads
# HOW:

# Create ConfigMap with spam-checker module
kubectl create configmap synapse-custom-modules \
  --from-file=synapse_async_av_checker.py=deployment/config/synapse_async_av_checker.py \
  -n matrix \
  --dry-run=client -o yaml | kubectl apply -f -

# Update Synapse ConfigMap to load the module
kubectl edit configmap synapse-config -n matrix

# Add to homeserver.yaml section:
# modules:
#   - module: synapse_async_av_checker.AsyncAVChecker
#     config:
#       redis_host: "redis-synapse-master.redis-synapse.svc.cluster.local"
#       redis_port: 6379
#       redis_db: 1
#       scan_queue: "av:scan:queue"
#       results_hash: "av:scan:results"

# Restart Synapse to load module
kubectl rollout restart deployment/synapse-main -n matrix
kubectl rollout restart statefulset/synapse-sync-worker -n matrix
kubectl rollout restart statefulset/synapse-generic-worker -n matrix

# Wait for restart to complete
kubectl rollout status deployment/synapse-main -n matrix
```

**Step 5: Verify End-to-End Functionality**

```bash
# Test 1: Upload clean file
# WHERE: Element Web client
# WHEN: After all components deployed
# WHY: Verify normal uploads work
# HOW:
# 1. Log into Element Web
# 2. Upload a test image (e.g., test.jpg)
# Expected: Upload completes immediately (<2 seconds)

# Check scan queue
kubectl exec -it deployment/synapse-main -n matrix -- \
  redis-cli -h redis-synapse-master.redis-synapse.svc.cluster.local -p 6379 -n 1 LLEN av:scan:queue
# Expected: Should show 1 (or more if multiple uploads)

# Wait 30-60 seconds for scan to complete

# Check scan results cache
kubectl exec -it deployment/synapse-main -n matrix -- \
  redis-cli -h redis-synapse-master.redis-synapse.svc.cluster.local -p 6379 -n 1 HGETALL av:scan:results
# Expected: Should show file hash with status "clean"

# Test 2: Upload EICAR test file
# EICAR is a safe test file that all AV engines detect as "malware"

# Create EICAR test file on your local machine
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > eicar.txt

# Upload via Element Web
# Expected: Upload completes immediately

# Wait 30-60 seconds, then check Synapse logs for quarantine action
kubectl logs -n matrix deployment/synapse-main --tail=50 | grep -i quarantine
# Expected: Log entry showing file was quarantined

# Check scan worker logs
kubectl logs -n matrix -l component=scan-worker --tail=50 | grep -i infected
# Expected: "⚠️  INFECTED: ... - Win.Test.EICAR_HDB-1"

# Try to access the file via Element Web
# Expected: File should be inaccessible (404 or "quarantined" error)
```

### 2.5 Resource Planning

**For 20K CCU with async scanning:**

| Component | Replicas | CPU/pod | RAM/pod | Total CPU | Total RAM |
|-----------|----------|---------|---------|-----------|-----------|
| ClamAV | 10 | 1 core | 2Gi | 10 cores | 20Gi |
| Scan Workers | 5 | 0.5 core | 512Mi | 2.5 cores | 2.5Gi |
| Redis Cache | 1 | 0.5 core | 2Gi | 0.5 cores | 2Gi |
| **TOTAL** | - | - | - | **13 cores** | **24.5Gi** |

**Cost Estimate (AWS example):**
- 13 vCPUs + 24.5Gi RAM ≈ 2-3 m5.xlarge instances
- Cost: ~$150-250/month

### 2.6 Monitoring and Alerting

**Key Metrics to Track:**

1. **Queue Depth:** `LLEN av:scan:queue`
   - Alert if >1000 (backlog building)

2. **Scan Rate:** Count scans completed per minute
   - Should match upload rate in steady state

3. **ClamAV CPU:** Should be 80-100% during scanning
   - If <50%, over-provisioned
   - If maxed out + queue growing, under-provisioned

4. **Cache Hit Rate:** Ratio of cached results to total checks
   - Good: >50% (many duplicate files)
   - Poor: <10% (mostly unique files)

5. **Infected File Count:** Quarantine actions per day
   - Baseline for your user community

**Prometheus Metrics (requires custom exporter):**

```yaml
# Example metrics
av_scan_queue_depth
av_scan_rate_per_minute
av_infected_files_total
av_scan_duration_seconds
clamav_cpu_usage
clamav_memory_usage
```

**Alert Rules:**

```yaml
# deployment/manifests/11-antivirus.yaml (add to file)

---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: antivirus-alerts
  namespace: antivirus
  labels:
    app: antivirus
spec:
  groups:
    - name: antivirus
      interval: 1m
      rules:
        # Alert if queue backlog growing
        - alert: AVQueueBacklog
          expr: av_scan_queue_depth > 1000
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "AV scan queue backlog growing"
            description: "Queue depth {{ $value }} exceeds threshold"

        # Alert if scan worker down
        - alert: AVScannerDown
          expr: up{job="av-scan-worker"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "AV scan worker pod down"

        # Alert if ClamAV at max CPU
        - alert: ClamAVHighCPU
          expr: rate(container_cpu_usage_seconds_total{pod=~"clamav-.*"}[5m]) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "ClamAV at max CPU, consider scaling"
```

---

## 3. Option B: Deploying Without Antivirus

**Choose this option if your decision matrix indicated "Deploy Without AV".**

### 3.1 When This Is Acceptable

**✅ Acceptable Use Cases:**

1. **Internal Company Deployment (<100 employees)**
   - Rationale: Trusted user base, controlled environment
   - Mitigations: User education, endpoint antivirus on devices
   - Risk Level: Low

2. **Proof-of-Concept / Staging Environment**
   - Rationale: Non-production, temporary deployment
   - Mitigations: Network isolation, no sensitive data
   - Risk Level: Minimal

3. **Development / Testing Environment**
   - Rationale: No real users, test data only
   - Mitigations: Isolated network, no production data
   - Risk Level: Minimal

4. **Budget-Constrained Non-Profit / Education**
   - Rationale: Limited budget, non-critical use
   - Mitigations: Strict file policies, user training
   - Risk Level: Medium (accepted trade-off)

**❌ Unacceptable Use Cases:**

- Public-facing deployment (unknown users)
- Healthcare / Medical data (HIPAA)
- Financial services (PCI-DSS)
- Customer-facing SaaS (legal liability)
- Government / Defense (classified data)
- Large enterprise (>1000 users)

### 3.2 Risks and Trade-offs

**Security Risks:**

| Risk | Threat | Impact | Likelihood | Mitigation |
|------|--------|--------|-----------|-----------|
| **Malware Propagation** | User uploads infected file | Other users download and execute | Medium | Endpoint AV, file type restrictions, user education |
| **Ransomware** | Encrypted malware spreads | Systems encrypted, data held for ransom | Low | Backups, network segmentation, user education |
| **Data Exfiltration** | Trojan disguised as legitimate file | Stolen credentials, corporate espionage | Medium | DLP tools, network monitoring, least privilege |
| **Legal Liability** | Server used to distribute malware | Lawsuits, regulatory fines | Low | Terms of Service disclaimer, logging, audit trail |
| **Storage Abuse** | Malware uses storage space | Storage quota exhausted | Low | Storage quotas, monitoring, cleanup policies |

**Comparison Table:**

| Aspect | With Antivirus | Without Antivirus |
|--------|---------------|-------------------|
| **Security Level** | High (90-95% detection) | Low (0% automated detection) |
| **Cost** | $150-250/month | $0 extra |
| **Complexity** | High | Low |
| **Upload UX** | Fast (async scanning) | Fast |
| **False Positives** | Yes (rare, ~0.1%) | No |
| **Zero-Day Protection** | No (signature-based) | No |
| **Compliance** | Better | May fail audits |
| **Operational Burden** | Medium | Low |
| **Legal Liability** | Lower | Higher |
| **User Education Required** | Moderate | High |

### 3.3 Mandatory Alternative Security Measures

**If you deploy without antivirus, you MUST implement these compensating controls:**

#### A. File Type Whitelist (MANDATORY)

**Concept:** Only allow safe file types

**Implementation: Synapse Spam-Checker Module**

```python
# file_type_whitelist_checker.py

import mimetypes
from synapse.module_api import ModuleApi
from synapse.module_api.errors import Codes

ALLOWED_MIME_TYPES = {
    # Images
    'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/svg+xml',
    # Documents
    'application/pdf', 'text/plain', 'text/markdown',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',  # docx
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',  # xlsx
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',  # pptx
    'application/vnd.oasis.opendocument.text',  # odt
    'application/vnd.oasis.opendocument.spreadsheet',  # ods
    # Audio/Video
    'audio/mpeg', 'audio/ogg', 'audio/wav',
    'video/mp4', 'video/webm', 'video/ogg',
    # Archives (RISKY - consider disabling)
    # 'application/zip', 'application/x-tar', 'application/gzip',
}

BLOCKED_EXTENSIONS = {
    # Executables
    '.exe', '.bat', '.cmd', '.com', '.msi', '.scr',
    # Scripts
    '.sh', '.bash', '.ps1', '.vbs', '.js',
    # Mobile
    '.apk', '.ipa',
    # Mac
    '.app', '.dmg', '.pkg',
    # Linux
    '.deb', '.rpm', '.run',
    # Other dangerous
    '.dll', '.so', '.dylib',
}

class FileTypeWhitelistChecker:
    """
    Spam-checker module that enforces file type whitelist.
    Blocks executables, scripts, and other dangerous file types.
    """

    def __init__(self, config: dict, api: ModuleApi):
        self.api = api
        self.logger = api.logger

    async def check_media_file_for_spam(self, file_wrapper, file_info):
        """
        Check if uploaded file type is allowed.
        """
        upload_name = file_info.get("upload_name", "")
        content_type = file_info.get("content_type", "")

        # Check extension
        if any(upload_name.lower().endswith(ext) for ext in BLOCKED_EXTENSIONS):
            self.logger.warn(f"Blocked file with dangerous extension: {upload_name}")
            return Codes.FORBIDDEN

        # Check MIME type
        if content_type and content_type not in ALLOWED_MIME_TYPES:
            # Try to guess MIME type from filename
            guessed_type, _ = mimetypes.guess_type(upload_name)
            if guessed_type not in ALLOWED_MIME_TYPES:
                self.logger.warn(f"Blocked file with disallowed MIME type: {content_type} ({upload_name})")
                return Codes.FORBIDDEN

        # File type is allowed
        return Codes.NOT_SPAM


def parse_config(config: dict) -> dict:
    return config


def create_module(config: dict, api: ModuleApi):
    return FileTypeWhitelistChecker(config, api)
```

**Configuration in homeserver.yaml:**

```yaml
modules:
  - module: file_type_whitelist_checker.FileTypeWhitelistChecker
    config: {}
```

**User Impact:**
- ✅ Blocks executables, scripts, dangerous files
- ⚠️ May block legitimate files (e.g., software distributions)
- ℹ️ Users see "Upload failed - file type not allowed"

#### B. File Size Limits (MANDATORY)

**Configuration in homeserver.yaml:**

```yaml
# Limit uploaded file size
max_upload_size: "100M"  # 100 megabytes maximum
```

**Rationale:**
- Limits storage abuse
- Reduces risk of large malware payloads
- Improves performance

#### C. Upload Rate Limiting (HIGHLY RECOMMENDED)

**Custom Module for Media Rate Limiting:**

```python
# media_rate_limiter.py

import time
from collections import defaultdict
from synapse.module_api import ModuleApi
from synapse.module_api.errors import Codes

class MediaRateLimiter:
    """
    Rate limiter for media uploads.
    Prevents abuse and spam by limiting upload frequency.
    """

    def __init__(self, config: dict, api: ModuleApi):
        self.api = api
        self.uploads_per_user = defaultdict(list)
        self.uploads_per_second = config.get("uploads_per_second", 0.5)  # 1 per 2 seconds
        self.burst_count = config.get("burst_count", 5)

    async def check_media_file_for_spam(self, file_wrapper, file_info):
        user_id = file_info.get("user_id")
        now = time.time()

        # Clean old uploads (older than burst window)
        self.uploads_per_user[user_id] = [
            ts for ts in self.uploads_per_user[user_id]
            if now - ts < self.burst_count / self.uploads_per_second
        ]

        # Check burst limit
        if len(self.uploads_per_user[user_id]) >= self.burst_count:
            return Codes.LIMIT_EXCEEDED

        # Record this upload
        self.uploads_per_user[user_id].append(now)

        return Codes.NOT_SPAM


def parse_config(config: dict) -> dict:
    return config


def create_module(config: dict, api: ModuleApi):
    return MediaRateLimiter(config, api)
```

**Configuration:**

```yaml
modules:
  - module: media_rate_limiter.MediaRateLimiter
    config:
      uploads_per_second: 0.5  # 1 upload per 2 seconds
      burst_count: 5  # Can burst 5 files quickly
```

#### D. User Education (MANDATORY)

**Training Topics:**

1. **Don't Execute Unknown Files**
   - "Don't run .exe files from chat"
   - "Verify sender before opening attachments"

2. **Use Endpoint Antivirus**
   - "Ensure your device has antivirus"
   - "Keep Windows Defender / ClamAV / etc. updated"

3. **Report Suspicious Content**
   - "See a suspicious file? Report it"
   - "Admins will investigate"

4. **Phishing Awareness**
   - "Don't click suspicious links"
   - "Verify URLs before visiting"

**Delivery Methods:**
- Onboarding training
- Monthly security reminders
- In-app notifications
- Poster / email campaigns

#### E. Endpoint Protection (RECOMMENDED)

**Strategy:** Protect user devices instead of server

**Tools:**
- **Windows:** Windows Defender (built-in), Symantec, CrowdStrike
- **macOS:** XProtect (built-in), Malwarebytes
- **Linux:** ClamAV, ESET
- **Mobile:** Android Play Protect, iOS built-in protections

**MDM (Mobile Device Management):**
- Enforce antivirus on company devices
- Block downloads from non-approved sources
- Remote wipe if device infected

### 3.4 Deployment Steps

**Step 1: Edit Configuration**

```bash
# WHERE: On your deployment workstation
# WHEN: Before running deployment
# WHY: Disable antivirus deployment
# HOW:

cd deployment/
cp config/deployment.env.example config/deployment.env
vim config/deployment.env

# Add/modify:
ENABLE_ANTIVIRUS="false"

# Alternative Security Settings
ENABLE_FILE_TYPE_WHITELIST="true"      # Strongly recommended
MAX_UPLOAD_SIZE="100M"                  # Limit file size
ENABLE_UPLOAD_RATE_LIMITING="true"     # Prevent abuse
```

**Step 2: Deploy File Type Whitelist Module**

```bash
# WHERE: On your kubectl-configured workstation
# WHEN: During deployment process
# WHY: Block dangerous file types
# HOW:

# Create ConfigMap with custom modules
kubectl create configmap synapse-custom-modules \
  --from-file=file_type_whitelist_checker.py=deployment/config/file_type_whitelist_checker.py \
  --from-file=media_rate_limiter.py=deployment/config/media_rate_limiter.py \
  -n matrix \
  --dry-run=client -o yaml | kubectl apply -f -

# Update Synapse ConfigMap to load modules
kubectl edit configmap synapse-config -n matrix

# Add to homeserver.yaml section:
# modules:
#   - module: file_type_whitelist_checker.FileTypeWhitelistChecker
#     config: {}
#   - module: media_rate_limiter.MediaRateLimiter
#     config:
#       uploads_per_second: 0.5
#       burst_count: 5
#
# max_upload_size: "100M"

# Restart Synapse
kubectl rollout restart deployment/synapse-main -n matrix
```

**Step 3: Verify Security Measures**

```bash
# Test File Type Restrictions:
# WHERE: Element Web client
# WHEN: After deployment
# WHY: Verify dangerous files are blocked
# HOW:
# 1. Create test.exe file (any content)
# 2. Try to upload via Element Web
# Expected: "Upload failed - file type not allowed"

# Test allowed file types
# 1. Upload test.jpg
# Expected: Success

# Test Upload Size Limit:
# WHERE: Your local machine and Element Web
# WHEN: After deployment
# WHY: Verify size limits are enforced
# HOW:

# Create large file
dd if=/dev/zero of=large.bin bs=1M count=150

# Try to upload via Element Web
# Expected: "File too large" error

# Test Rate Limiting:
# WHERE: Element Web client
# WHEN: After deployment
# WHY: Verify rate limiting prevents abuse
# HOW:
# 1. Rapidly upload 10 small files
# Expected: First 5 succeed, then "Too many uploads - please wait"
```

**Step 4: User Education**

```bash
# WHERE: Organization-wide
# WHEN: Before making deployment available to users
# WHY: Users must understand security responsibilities
# HOW:

# 1. Send announcement email:
Subject: Important: File Security on Matrix Chat

Our Matrix chat system does not automatically scan uploaded files for viruses.

IMPORTANT SECURITY GUIDELINES:
- Only download files from trusted users
- DO NOT open executable files (.exe, .bat, etc.) from chat
- Ensure your device has antivirus software installed and updated
- Report suspicious files to IT immediately

While we block dangerous file types, you are responsible for your own device security.

# 2. Add warning to Element Web welcome screen
# Edit Element Web config.json:
{
  "welcomeUserId": "@notice:your-server.com",
  "roomDirectory": {
    "servers": ["your-server.com"]
  }
}

# Create "notice" user and send welcome message to all new users:
"⚠️ Security Notice: Files are not automatically scanned. Use caution when downloading."
```

### 3.5 Ongoing Monitoring

**Manual Review Process:**

```bash
# WHERE: Admin workstation with kubectl access
# WHEN: Monthly or after user reports
# WHY: Detect malware that bypassed file type restrictions
# HOW:

# 1. Get list of recent uploads
kubectl exec -it deployment/synapse-postgres-1 -n matrix -- \
  psql -U synapse -c "
    SELECT
      media_id,
      upload_name,
      created_ts,
      user_id,
      media_length
    FROM local_media_repository
    WHERE created_ts > extract(epoch from now() - interval '30 days') * 1000
    ORDER BY created_ts DESC
    LIMIT 100;
  "

# 2. Download suspicious files to isolated VM
# 3. Scan with VirusTotal or multiple AV engines
# 4. Quarantine if infected:

MEDIA_ID="suspicious_file_id"
SERVER_NAME="chat.example.com"

curl -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://chat.example.com/_synapse/admin/v1/media/quarantine/$SERVER_NAME/$MEDIA_ID" \
  -d '{"reason": "Malware detected during manual review"}'
```

### 3.6 Legal Protections

**Terms of Service Update:**

Add this clause to your Terms of Service:

```
File Uploads and Security:

This service does not perform automatic antivirus scanning of uploaded files.
Users are responsible for ensuring files they upload are safe and do not contain
malware or viruses.

By uploading files, you represent and warrant that:
- Files are free from viruses, trojans, worms, or other malicious code
- Files do not infringe on third-party intellectual property
- Files do not contain illegal content

We reserve the right to remove any content at our discretion. Users who upload
malicious content may have their accounts suspended.

UPLOADED FILES ARE NOT SCANNED. DOWNLOAD AND OPEN FILES AT YOUR OWN RISK.
USE ANTIVIRUS SOFTWARE ON YOUR DEVICE.
```

---

## 4. Operational Considerations

**These apply to both options (with or without AV):**

### 4.1 ClamAV Signature Updates (If Using Option A)

**CRITICAL:** ClamAV effectiveness depends on up-to-date virus signatures.

**Update Strategy:**

CronJob updates signatures every 6 hours (already included in Section 2.3).

**Verification:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: After deployment and periodically
# WHY: Ensure virus signatures are up to date
# HOW:

# Check last update time
kubectl exec -n antivirus deployment/clamav -- \
  ls -lh /var/lib/clamav/

# Expected: Files modified within last 6 hours

# Check signature count
kubectl exec -n antivirus deployment/clamav -- \
  clamdscan --version

# Expected: Shows signature database version and count
```

**Air-Gapped Environments:**

If deployment goes air-gapped after initial setup:

```bash
# WHERE: Internet-connected machine, before cutover
# WHEN: Before air-gapping the environment
# WHY: Ensure you have latest signatures before losing internet access
# HOW:

# Download signatures
docker run --rm -v clamav-sigs:/var/lib/clamav clamav/clamav:latest freshclam

# Export volume to tarball
docker run --rm -v clamav-sigs:/data -v $(pwd):/backup ubuntu \
  tar czf /backup/clamav-signatures.tar.gz /data

# Copy tarball to air-gapped environment
# Import in air-gapped cluster:
kubectl cp clamav-signatures.tar.gz antivirus/clamav-pod:/tmp/
kubectl exec -n antivirus clamav-pod -- \
  tar xzf /tmp/clamav-signatures.tar.gz -C /var/lib/clamav/
```

### 4.2 Incident Response

**Scenario: Malware Detected**

**Step 1: Contain**

```bash
# WHERE: kubectl-configured workstation or admin dashboard
# WHEN: Immediately upon detection
# WHY: Prevent further downloads
# HOW:

# Quarantine the file via Synapse Admin API
MEDIA_ID="XYZ123"
SERVER_NAME="chat.example.com"
ADMIN_TOKEN="your-admin-token"

curl -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://chat.example.com/_synapse/admin/v1/media/quarantine/$SERVER_NAME/$MEDIA_ID" \
  -d '{"reason": "Malware detected"}'

# Verify quarantine
curl -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://chat.example.com/_synapse/admin/v1/media/quarantine/$SERVER_NAME/$MEDIA_ID"
```

**Step 2: Identify Affected Users**

```bash
# WHERE: kubectl-configured workstation
# WHEN: After containment
# WHY: Determine who may have downloaded the file
# HOW:

# Query PostgreSQL for media access logs
kubectl exec -it deployment/synapse-postgres-1 -n matrix -- \
  psql -U synapse -c "
    SELECT DISTINCT user_id, event_json->>'origin_server_ts' as access_time
    FROM events
    WHERE content LIKE '%$MEDIA_ID%'
    ORDER BY access_time DESC;
  "

# Expected: List of users who accessed the file
```

**Step 3: Notify Affected Users**

```bash
# WHERE: Admin account or bot
# WHEN: After identifying affected users
# WHY: Warn users about potential malware exposure
# HOW:

# Send admin notice to affected rooms (use Synapse Admin API or bot)
# Message template:
"⚠️ SECURITY ALERT: A file uploaded to this room was detected as malware.
The file has been removed. If you downloaded it, DO NOT OPEN IT.
Please scan your device with antivirus immediately.
Contact IT support if you opened the file."
```

**Step 4: Investigate Source**

```bash
# Determine who uploaded the file
kubectl exec -it deployment/synapse-postgres-1 -n matrix -- \
  psql -U synapse -c "
    SELECT user_id, created_ts, upload_name
    FROM local_media_repository
    WHERE media_id = '$MEDIA_ID';
  "

# Check if account was compromised:
# - Review recent login attempts
# - Check for unusual activity patterns
# - Force password reset if suspicious
```

**Step 5: Remediate**

- Suspend user account if compromised or malicious intent suspected
- Review uploader's other files for additional malware
- Consider reimaging affected devices
- Update security training based on lessons learned

### 4.3 Compliance and Logging

**Audit Log Requirements:**

Track:
- All uploads (timestamp, user, file hash, size)
- All scan results (timestamp, file hash, verdict)
- All quarantine actions (timestamp, file, reason, admin)

**Implementation:**

```python
# In scan worker or as separate logging service
audit_log = {
    "timestamp": time.time(),
    "file_hash": file_hash,
    "media_id": media_id,
    "verdict": "infected" if is_infected else "clean",
    "virus_name": virus_name if is_infected else None,
    "quarantined": is_infected
}

# Write to audit log (database or file)
with open("/var/log/av-audit.jsonl", "a") as f:
    f.write(json.dumps(audit_log) + "\n")
```

Ship logs to Loki/Elasticsearch for retention and search.

---

## 5. Migration Between Options

### 5.1 Enabling Antivirus Later (Option B → Option A)

**When to Enable:**
- Malware incident occurred
- User base grew significantly
- Compliance requirements changed
- Budget became available
- Risk tolerance decreased

**Migration Steps:**

**Step 1: Deploy Antivirus Components**

```bash
# WHERE: kubectl-configured workstation
# WHEN: During planned maintenance window
# WHY: Add AV protection to existing deployment
# HOW:

# Follow steps from Section 2.4 (Deployment Steps)
# All components can be added without disrupting existing service
```

**Step 2: Historical File Scanning (Optional)**

```python
# Scan all existing files in media repository
# This is OPTIONAL but recommended

import os
import clamd

clamd_client = clamd.ClamdNetworkSocket(host="clamav.antivirus.svc.cluster.local", port=3310)
media_dir = "/data/media"

for root, dirs, files in os.walk(media_dir):
    for file in files:
        file_path = os.path.join(root, file)
        try:
            with open(file_path, "rb") as f:
                result = clamd_client.instream(f)
                if result["stream"][0] != "OK":
                    print(f"Infected: {file_path} - {result['stream'][1]}")
                    # Quarantine via API
        except Exception as e:
            print(f"Error scanning {file_path}: {e}")
```

Estimated Time: 10-50 hours (depending on media volume)

**Step 3: Remove File Type Whitelist (Optional)**

Once AV is active, you may choose to relax file type restrictions since AV provides protection.

However, keeping both provides defense in depth.

### 5.2 Disabling Antivirus (Option A → Option B)

**When to Disable:**
- Deployment scale reduced significantly
- Budget constraints
- Moving to development/staging environment
- Implementing alternative security architecture

**Migration Steps:**

```bash
# WHERE: kubectl-configured workstation
# WHEN: During planned maintenance window
# WHY: Remove AV to reduce costs/complexity
# HOW:

# 1. Implement alternative security measures first (Section 3.3)
kubectl apply -f deployment/config/file_type_whitelist.yaml

# 2. Remove Synapse AV module
kubectl edit configmap synapse-config -n matrix
# Remove "modules:" section with AsyncAVChecker

# 3. Restart Synapse
kubectl rollout restart deployment/synapse-main -n matrix

# 4. Delete AV components
kubectl delete namespace antivirus
kubectl delete deployment av-scan-worker -n matrix

# 5. Update Terms of Service (Section 3.6)
```

---

## Summary

### Option A: With Antivirus
**Choose if:** Public deployment, compliance requirements, >100 users, low risk tolerance
**Cost:** $150-250/month infrastructure, 2-4 hours/month ops
**Protection:** 90-95% malware detection
**Trade-off:** ~60 second scan delay (async), operational complexity

### Option B: Without Antivirus
**Choose if:** Internal deployment, <100 trusted users, budget constraints, high risk tolerance
**Cost:** $0 extra
**Protection:** 0% automated detection (relies on alternatives)
**Trade-off:** Higher security risk, requires vigilance and user education

### Both Options Require:
- Regular monitoring
- Incident response procedures
- User education
- Documented security policies
- Compliance consideration

**Final Recommendation:** If budget allows (~$200/month), implement Option A (asynchronous antivirus scanning). The risk reduction is worth the cost for most production deployments.

---

**Document Version:** 2.0
**Last Updated:** November 11, 2025
**Maintained By:** Matrix/Synapse Production Deployment Team
