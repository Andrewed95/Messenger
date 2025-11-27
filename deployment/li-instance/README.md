# Matrix Lawful Intercept (LI) Instance

⭐ **CRITICAL COMPLIANCE COMPONENT** ⭐

Complete read-only Matrix instance for law enforcement access with E2EE recovery capabilities.

## Overview

The LI instance is a **separate, isolated Matrix homeserver** that receives data from the main instance but cannot modify it or access sensitive components like `key_vault`.

**Key Features**:
- ✅ Read-only database (enforced at PostgreSQL level)
- ✅ Infinite message retention (including soft-deleted messages)
- ✅ Isolated from federation network
- ✅ Cannot access `key_vault` (NetworkPolicy enforced)
- ✅ Real-time data replication via PostgreSQL logical replication
- ✅ Media sync via rclone (every 15 minutes)
- ✅ Separate web interfaces (Element, Synapse Admin)
- ✅ IP whitelisting for authorized access only

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    MAIN INSTANCE                        │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────┐ │
│  │  PostgreSQL  │───│  Synapse     │───│ key_vault  │ │
│  │    Main      │   │    Main      │   │  (E2EE)    │ │
│  └──────┬───────┘   └──────────────┘   └────────────┘ │
│         │                                               │
│         │ PostgreSQL Logical Replication                │
└─────────┼───────────────────────────────────────────────┘
          │
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│                   SYNC SYSTEM                           │
│  ┌──────────────────────┐   ┌───────────────────────┐  │
│  │ Logical Replication  │   │  rclone Media Sync    │  │
│  │   (Real-time DB)     │   │  (Every 15 minutes)   │  │
│  └──────────┬───────────┘   └───────────┬───────────┘  │
└─────────────┼───────────────────────────┼───────────────┘
              │                           │
              ▼                           ▼
┌─────────────────────────────────────────────────────────┐
│                    LI INSTANCE                          │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────┐ │
│  │  PostgreSQL  │   │   Synapse    │   │  Element   │ │
│  │      LI      │───│      LI      │───│  Web LI    │ │
│  │  (read-only) │   │  (read-only) │   │            │ │
│  └──────────────┘   └──────────────┘   └────────────┘ │
│  ┌──────────────┐   ┌──────────────┐                  │
│  │    MinIO     │   │   Synapse    │                  │
│  │ synapse-     │───│   Admin LI   │                  │
│  │  media-li    │   │              │                  │
│  └──────────────┘   └──────────────┘                  │
└─────────────────────────────────────────────────────────┘
```

## Components

### 1. Synapse LI (01-synapse-li/)

**Read-only Synapse homeserver** synchronized from main instance.

**Configuration**:
- Database: `matrix-postgresql-li-rw.matrix.svc.cluster.local`
- Database name: `matrix_li`
- MinIO bucket: `synapse-media-li`
- **No federation**: `federation_domain_whitelist: []`
- **No registration**: Users synced from main
- **Infinite retention**: `redaction_retention_period: null`

**Deployment**:

**WHERE:** Run from your **management node**

```bash
kubectl apply -f 01-synapse-li/deployment.yaml
```

**Access**: https://matrix.example.com (from LI network)

### 2. Element Web LI (02-element-web-li/)

**Modified web client** showing deleted messages with special formatting.

**Features**:
- Displays redacted messages with `[DELETED]` badge
- Strikethrough formatting for deleted content
- Read-only composer (no message sending)
- "LAWFUL INTERCEPT" watermark on all pages
- Custom CSS injection via nginx

**Deployment**:

**WHERE:** Run from your **management node**

```bash
kubectl apply -f 02-element-web-li/deployment.yaml
```

**Access**: https://element.example.com (from LI network)

### 3. Synapse Admin LI (03-synapse-admin-li/)

**Admin interface** for forensics and statistics.

**Features**:
- User and room management (read-only)
- Statistics and analytics
- Room browsing and message search
- Sync system monitoring
- Basic authentication (htpasswd)

**Deployment**:

**WHERE:** Run from your **management node**

```bash
kubectl apply -f 03-synapse-admin-li/deployment.yaml
```

**Access**: https://admin.example.com (from LI network)

### 4. Sync System (04-sync-system/)

**Bridge between main and LI** for data replication.

**Components**:
- **PostgreSQL Logical Replication**: Real-time database sync
- **rclone Media Sync**: Periodic media file sync (every 15 minutes)
- **Setup Job**: One-time configuration of replication
- **CronJob**: Automated media synchronization

**Deployment**:

**WHERE:** Run from your **management node**

```bash
# Apply NetworkPolicy first
kubectl apply -f ../infrastructure/04-networking/sync-system-networkpolicy.yaml

# Deploy sync system
kubectl apply -f 04-sync-system/deployment.yaml

# Run setup job (one time)
kubectl create job --from=job/sync-system-setup-replication sync-setup-$(date +%s) -n matrix
```

---

## DNS Configuration & Network Isolation

**CRITICAL**: The LI instance uses the **SAME hostnames** as the main instance. Access control is via **network isolation**, NOT different domains.

### Why Same Hostnames?

Matrix protocol requires that:
1. `server_name` MUST be identical (`matrix.example.com`)
2. `public_baseurl` MUST be identical (`https://matrix.example.com`)

**Reasons:**
- LI uses replicated data from main instance
- User IDs, event signatures, tokens all reference `matrix.example.com`
- Different URLs would break authentication and event verification
- Matrix clients validate server signatures against the `server_name`

### Configuration

**Both Main and LI instances use:**
```yaml
server_name: "matrix.example.com"
public_baseurl: "https://matrix.example.com"
```

**Element Web (both main and LI):**
```json
"m.homeserver": {
    "base_url": "https://matrix.example.com",
    "server_name": "matrix.example.com"
}
```

### How LI Access Works

Access to LI is controlled via **network isolation and DNS**, NOT different hostnames:

```
┌─────────────────────────────────────────────────────────────────┐
│                    ORGANIZATION NETWORK                          │
│                                                                  │
│  ┌──────────────────────┐      ┌───────────────────────────┐   │
│  │    MAIN NETWORK      │      │      LI NETWORK           │   │
│  │                      │      │    (Restricted Access)     │   │
│  │  DNS:                │      │                            │   │
│  │  matrix.example.com  │      │  DNS:                      │   │
│  │    → Main Ingress IP │      │  matrix.example.com        │   │
│  │                      │      │    → LI Ingress IP         │   │
│  │  element.example.com │      │                            │   │
│  │    → Main Ingress IP │      │  element.example.com       │   │
│  │                      │      │    → LI Ingress IP         │   │
│  │  Regular users       │      │                            │   │
│  │  access main         │      │  LI admins only            │   │
│  └──────────────────────┘      └───────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### LI Admin Access Procedure

**For LI administrators to access the LI instance:**

1. **Network Access**: Admin must be on the LI network (org responsibility)
2. **DNS Resolution**: LI network DNS resolves hostnames to LI Ingress IP
3. **Browser Access**: Admin opens `https://element.example.com`
4. **Traffic Flow**: DNS resolves to LI Ingress → routes to Element Web LI → connects to Synapse LI

**To switch back to main instance:**
- Admin switches to main network (or changes DNS)
- Same hostname now resolves to main Ingress IP

### Organization Requirements for LI Network

**The organization MUST configure:**

1. **Separate LI Network**:
   - Physically or logically isolated network segment
   - Only authorized LI administrators can access
   - Contains LI Kubernetes nodes or has routes to LI services

2. **LI DNS Server**:
   - Resolves `matrix.example.com` → LI Ingress IP
   - Resolves `element.example.com` → LI Ingress IP
   - Can be internal DNS server, hosts file, or split-horizon DNS

3. **Access Control**:
   - VPN, firewall rules, or physical access control
   - Only authorized personnel can reach LI network
   - Audit trail for network access

**Example Split-Horizon DNS:**
```
# Main DNS server (used by regular users)
matrix.example.com     A    10.0.1.100  # Main Ingress
element.example.com    A    10.0.1.100  # Main Ingress

# LI DNS server (used by LI network only)
matrix.example.com     A    10.0.2.100  # LI Ingress
element.example.com    A    10.0.2.100  # LI Ingress
```

### LI Ingress Configuration

The LI Ingress uses the **same hostnames** as main:

```yaml
# Synapse LI Ingress
spec:
  rules:
    - host: matrix.example.com  # Same as main
      http:
        paths:
          - backend:
              service:
                name: synapse-li-client  # Routes to LI service

# Element Web LI Ingress
spec:
  rules:
    - host: element.example.com  # Same as main
      http:
        paths:
          - backend:
              service:
                name: element-web-li  # Routes to LI service
```

**The routing works because:**
- Main Ingress runs on main network (main Ingress IP)
- LI Ingress runs on LI network (LI Ingress IP)
- DNS determines which Ingress receives traffic

### TLS Certificates

Both main and LI need valid TLS certificates for the same hostnames.

**Option 1: Shared Wildcard Certificate**
- Use `*.example.com` wildcard cert
- Copy to both main and LI clusters

**Option 2: Separate Certificates**
- Use cert-manager with same hostnames
- Each cluster generates its own cert
- Requires DNS-01 challenge (recommended for LI)

**Important**: The org must provide TLS certificates or configure cert-manager appropriately.

---

## Security & Isolation

### NetworkPolicies (Phase 1)

Three critical policies enforce LI isolation:

**1. key-vault-isolation**:
- **Ingress**: ONLY from Synapse main (`matrix.instance: main`)
- **Effect**: LI instance **CANNOT** access E2EE recovery keys
- **File**: `infrastructure/04-networking/networkpolicies.yaml`

**2. li-instance-isolation**:
- **Applies to**: All pods with `matrix.instance: li`
- **Egress**: ONLY to LI PostgreSQL, MinIO, DNS
- **Effect**: LI **CANNOT** access main PostgreSQL or main resources
- **File**: `infrastructure/04-networking/networkpolicies.yaml`

**3. sync-system-access**:
- **Applies to**: Pods with `app.kubernetes.io/name: sync-system`
- **Egress**: Access to **BOTH** main and LI PostgreSQL, MinIO
- **Effect**: Sync system is the **ONLY** bridge between instances
- **File**: `infrastructure/04-networking/sync-system-networkpolicy.yaml`

### IP Whitelisting

**CRITICAL**: Configure IP whitelisting on all LI Ingresses:

```yaml
annotations:
  nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8,192.168.1.100/32"
```

Locations:
- `01-synapse-li/deployment.yaml` (Synapse LI Ingress)
- `02-element-web-li/deployment.yaml` (Element Web LI Ingress)
- `03-synapse-admin-li/deployment.yaml` (Synapse Admin LI Ingress)

### Authentication

**WHERE:** Run from your **management node**

**Synapse Admin LI** uses basic auth (htpasswd):

```bash
# Generate htpasswd
htpasswd -c auth admin

# Create secret
kubectl create secret generic synapse-admin-auth \
  --from-file=auth \
  -n matrix
```

## Deployment Order

**WHERE:** Run all commands from your **management node**

**WORKING DIRECTORY:** `deployment/li-instance/`

Deploy in this order to ensure dependencies:

```bash
# 1. Ensure Phase 1 infrastructure is running
kubectl get cluster -n matrix matrix-postgresql-li
kubectl get tenant -n matrix matrix-minio  # Contains synapse-media-li bucket

# 2. Deploy sync system NetworkPolicy
kubectl apply -f ../infrastructure/04-networking/sync-system-networkpolicy.yaml

# 3. Deploy sync system
kubectl apply -f 04-sync-system/deployment.yaml

# 4. Run replication setup job (CRITICAL - must run once)
# Store job name in variable to use consistently
JOB_NAME="sync-setup-$(date +%s)"

# Create the job
kubectl create job --from=job/sync-system-setup-replication \
  $JOB_NAME -n matrix

# Wait for job to complete (using same job name)
kubectl wait --for=condition=complete job/$JOB_NAME -n matrix --timeout=300s

# Check replication status (using same job name)
kubectl logs job/$JOB_NAME -n matrix

# 5. Deploy Synapse LI
kubectl apply -f 01-synapse-li/deployment.yaml

# Wait for Synapse LI to be ready
kubectl wait --for=condition=ready pod/synapse-li-0 -n matrix --timeout=300s

# 6. Deploy Element Web LI
kubectl apply -f 02-element-web-li/deployment.yaml

# 7. Deploy Synapse Admin LI
kubectl apply -f 03-synapse-admin-li/deployment.yaml

# 8. Verify all components
kubectl get pods -n matrix -l matrix.instance=li
kubectl get ingress -n matrix | grep li
```

## Verification

**WHERE:** Run all verification commands from your **management node**

### Check PostgreSQL Replication

**Note:** These commands execute SQL queries on PostgreSQL pods to verify replication status

```bash
# Check replication on main
kubectl exec -n matrix matrix-postgresql-1-0 -- \
  psql -U postgres -d matrix -c \
  "SELECT * FROM pg_publication;"

# Check subscription on LI
kubectl exec -n matrix matrix-postgresql-li-1-0 -- \
  psql -U postgres -d matrix_li -c \
  "SELECT subname, subenabled, subslotname FROM pg_subscription;"

# Check replication lag
kubectl exec -n matrix matrix-postgresql-li-1-0 -- \
  psql -U postgres -d matrix_li -c \
  "SELECT
    subname,
    pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, received_lsn)) AS lag
  FROM pg_subscription_rel
  JOIN pg_subscription ON subrelid = srrelid;"
```

### Check Media Sync

```bash
# Check last sync job
kubectl get cronjob -n matrix sync-system-media

# Check job history
kubectl get jobs -n matrix | grep sync-system-media

# Check latest sync logs
kubectl logs -n matrix $(kubectl get pods -n matrix -l app.kubernetes.io/component=media-sync --sort-by=.metadata.creationTimestamp -o name | tail -1)

# Manually trigger sync
kubectl create job --from=cronjob/sync-system-media sync-manual-$(date +%s) -n matrix
```

### Test LI Access

**Note**: All tests must be run from the LI network where DNS resolves to LI Ingress IP.

```bash
# Test Synapse LI API (from LI network)
curl https://matrix.example.com/_matrix/client/versions

# Test Element Web LI (from LI network - should show watermark)
# Open in browser: https://element.example.com

# Test Synapse Admin LI (from LI network - should require auth)
curl -u admin:password https://admin.example.com

# Login to LI instance (users synced from main)
# Use same credentials as main instance
# DNS must resolve to LI Ingress for authentication to work
```

## Data Flow

### Database Replication

**PostgreSQL Logical Replication** (real-time):
1. Main writes to `matrix` database
2. PostgreSQL creates WAL records
3. Logical replication streams changes to LI
4. LI applies changes to `matrix_li` database
5. **Lag**: < 1 second under normal load

**Tables Replicated**:
- `events` - All messages (including deleted)
- `users` - User accounts
- `rooms` - Room metadata
- `room_memberships` - User-room relationships
- ALL other Synapse tables

### Media Replication

**rclone sync** (every 15 minutes):
1. CronJob triggers rclone
2. rclone compares `synapse-media` and `synapse-media-li` buckets
3. New/changed files copied from main to LI
4. **Lag**: Up to 15 minutes for new media

**Optimization**:
- `--fast-list`: Quick directory listing
- `--checksum`: Verify file integrity
- `--no-update-modtime`: Preserve original timestamps
- `--transfers 10`: Parallel uploads

## Monitoring

### Metrics

Both Synapse LI and sync system expose Prometheus metrics:

```promql
# Synapse LI health
up{job="synapse-li"}

# Replication lag (bytes)
pg_replication_lag{cluster="matrix-postgresql-li"}

# Media sync job success rate
kube_job_status_succeeded{job_name=~"sync-system-media.*"}

# Media sync duration
kube_job_status_completion_time{job_name=~"sync-system-media.*"}
```

### Logs

```bash
# Synapse LI logs
kubectl logs -n matrix synapse-li-0 -f

# Sync system logs (latest job)
kubectl logs -n matrix -l app.kubernetes.io/component=media-sync --tail=100

# PostgreSQL replication logs
kubectl logs -n matrix matrix-postgresql-li-1-0 | grep replication
```

## Troubleshooting

### PostgreSQL replication not working

```bash
# Check publication on main
kubectl exec -n matrix matrix-postgresql-1-0 -- \
  psql -U postgres -d matrix -c \
  "SELECT * FROM pg_publication WHERE pubname = 'matrix_li_publication';"

# Check subscription on LI
kubectl exec -n matrix matrix-postgresql-li-1-0 -- \
  psql -U postgres -d matrix_li -c \
  "SELECT * FROM pg_subscription WHERE subname = 'matrix_li_subscription';"

# Check replication slot
kubectl exec -n matrix matrix-postgresql-1-0 -- \
  psql -U postgres -d matrix -c \
  "SELECT * FROM pg_replication_slots;"

# Reset subscription (if needed)
kubectl exec -n matrix matrix-postgresql-li-1-0 -- \
  psql -U postgres -d matrix_li -c \
  "DROP SUBSCRIPTION IF EXISTS matrix_li_subscription;"

# Re-run setup job
kubectl create job --from=job/sync-system-setup-replication sync-reset-$(date +%s) -n matrix
```

### Media sync failing

```bash
# Check rclone configuration
kubectl exec -n matrix -it \
  $(kubectl get pods -n matrix -l app.kubernetes.io/component=media-sync -o name | tail -1) -- \
  rclone listremotes

# Test S3 connectivity
kubectl exec -n matrix -it \
  $(kubectl get pods -n matrix -l app.kubernetes.io/component=media-sync -o name | tail -1) -- \
  rclone ls minio-main:synapse-media --max-depth 1

# Check MinIO bucket access
kubectl exec -n matrix -it \
  $(kubectl get pods -n matrix -l v1.min.io/tenant=matrix-minio -o name | head -1) -- \
  mc ls minio/synapse-media-li
```

### LI instance can't access key_vault (expected)

This is **correct behavior**. LI instance should **NEVER** access key_vault.

```bash
# Verify NetworkPolicy blocks access
kubectl exec -n matrix synapse-li-0 -- \
  curl -v http://key-vault.matrix.svc.cluster.local:8000/health
# Should fail with connection timeout or refused
```

### Users can't login to LI

**Cause**: Signing key mismatch or replication not complete.

```bash
# Check signing key matches main
kubectl get secret synapse-li-secrets -n matrix -o yaml | grep signing.key
kubectl get secret synapse-secrets -n matrix -o yaml | grep signing.key
# Should be IDENTICAL

# Check users table is replicated
kubectl exec -n matrix matrix-postgresql-li-1-0 -- \
  psql -U synapse_li -d matrix_li -c \
  "SELECT COUNT(*) FROM users;"
# Should match main instance user count
```

## Scaling

### LI Instance Resources

**Synapse LI** (read-only workload):
- **Small (100-1K CCU)**: 1Gi memory, 500m CPU
- **Medium (1K-5K CCU)**: 2Gi memory, 1 CPU
- **Large (5K-20K CCU)**: 4Gi memory, 2 CPU

**Sync System** (batch processing):
- **Small**: 256Mi memory, 250m CPU
- **Medium**: 512Mi memory, 500m CPU
- **Large**: 1Gi memory, 1 CPU

### Sync Frequency

Adjust CronJob schedule based on requirements:

```yaml
spec:
  schedule: "*/15 * * * *"  # Every  (default)
  # schedule: "*/5 * * * *"   # Every  (low latency)
  # schedule: "0 * * * *"     # Every hour (low priority)
```

## Storage Capacity Planning

### ⚠️ CRITICAL: Infinite Retention Storage Requirements

The LI instance has **infinite retention** (`redaction_retention_period: null`), meaning data **NEVER** expires. Storage requirements grow continuously and must be carefully planned.

### Storage Components

**1. PostgreSQL Database Storage**
- Main database: `matrix_li`
- Contains: All messages, events, users, rooms, media metadata
- Growth rate: Depends on active users and message frequency
- **Never shrinks** - only grows

**2. MinIO Media Storage**
- Bucket: `synapse-media-li`
- Contains: Images, videos, files, voice messages
- Synced from main instance via rclone
- **Retention: Permanent** (no cleanup)

### PostgreSQL Storage Growth Model

#### Formula

```
Annual DB Growth = (CCU × Active% × Avg Messages/Day × Avg Message Size × 365 days)
                 + (CCU × Active% × Avg Rooms × Room Metadata)
                 + (Media Metadata × Avg Metadata Size)
```

#### Realistic Growth Estimates

**Assumptions:**
- Active users: 70% of CCU send messages daily
- Average messages: 50 messages per active user per day
- Average message size: 512 bytes (text + metadata)
- Room state events: ~2KB per room per day
- Media metadata: ~500 bytes per file

| CCU Scale | Active Users | Daily Messages | Daily Data | Monthly Growth | Annual Growth | 3-Year Total |
|-----------|-------------|----------------|------------|----------------|---------------|--------------|
| **100** | 70 | 3,500 | 1.75 MB | 52.5 MB | 630 MB | 1.9 GB |
| **1,000** | 700 | 35,000 | 17.5 MB | 525 MB | 6.3 GB | 19 GB |
| **5,000** | 3,500 | 175,000 | 87.5 MB | 2.6 GB | 31.5 GB | 95 GB |
| **10,000** | 7,000 | 350,000 | 175 MB | 5.25 GB | 63 GB | 190 GB |
| **20,000** | 14,000 | 700,000 | 350 MB | 10.5 GB | 126 GB | 380 GB |

**Additional Factors Increasing Growth:**
- **Deleted messages** retained forever (add 10-20% for redactions)
- **Room state events** (joins, leaves, name changes): Add 15-25%
- **Federation overhead** (if enabled): Add 30-50%
- **Presence updates** (if tracked): Add 5-10%

#### Recommended PostgreSQL Storage Allocation

| Scale | Year 1 | Year 2 | Year 3 | Initial Provision | Expansion Plan |
|-------|--------|--------|--------|-------------------|----------------|
| **100 CCU** | 2 GB | 4 GB | 6 GB | 50 GB SSD | Every 2 years |
| **1K CCU** | 20 GB | 40 GB | 60 GB | 100 GB SSD | Yearly |
| **5K CCU** | 100 GB | 200 GB | 300 GB | 500 GB NVMe | Every 6 months |
| **10K CCU** | 200 GB | 400 GB | 600 GB | 1 TB NVMe | Quarterly |
| **20K CCU** | 400 GB | 800 GB | 1.2 TB | 2 TB NVMe | Quarterly |

**Update in:** `deployment/infrastructure/01-postgresql/cluster-li.yaml`

```yaml
spec:
  instances: 3
  storage:
    size: 100Gi  # Adjust based on table above
    storageClass: local-nvme  # Use fast NVMe for performance
```

### MinIO Media Storage Growth Model

#### Formula

```
Annual Media Growth = (CCU × Upload% × Files/Day × Avg File Size × 365 days)
```

#### Realistic Growth Estimates

**Assumptions:**
- Upload percentage: 10% of CCU upload files daily
- Files per uploader: 5 files per day
- Average file size breakdown:
  - 70% images: 500 KB average
  - 20% documents: 2 MB average
  - 10% videos: 20 MB average
  - Weighted average: ~3 MB per file

| CCU Scale | Daily Uploaders | Daily Files | Daily Data | Monthly Growth | Annual Growth | 3-Year Total |
|-----------|----------------|-------------|------------|----------------|---------------|--------------|
| **100** | 10 | 50 | 150 MB | 4.5 GB | 54 GB | 162 GB |
| **1,000** | 100 | 500 | 1.5 GB | 45 GB | 540 GB | 1.6 TB |
| **5,000** | 500 | 2,500 | 7.5 GB | 225 GB | 2.7 TB | 8.1 TB |
| **10,000** | 1,000 | 5,000 | 15 GB | 450 GB | 5.4 TB | 16.2 TB |
| **20,000** | 2,000 | 10,000 | 30 GB | 900 GB | 10.8 TB | 32.4 TB |

**Notes:**
- **Duplicates**: MinIO stores unique files only (deduplication not enabled)
- **Thumbnails**: Synapse generates thumbnails (add 20% overhead)
- **rclone overhead**: Metadata storage (add 1-2%)

#### Recommended MinIO Storage Allocation

Remember: MinIO EC:4 has **50% storage efficiency** (usable = raw × 50%)

| Scale | Year 1 Usage | Year 3 Usage | Raw Required | Initial Provision (EC:4) | Pools Needed | Expansion Timeline |
|-------|-------------|--------------|--------------|-------------------------|--------------|-------------------|
| **100 CCU** | 54 GB | 162 GB | 324 GB | 1 pool (1 TB usable) | 1 pool | Year 3 |
| **1K CCU** | 540 GB | 1.6 TB | 3.2 TB | 2 pools (2 TB usable) | 2-3 pools | Yearly |
| **5K CCU** | 2.7 TB | 8.1 TB | 16.2 TB | 4 pools (4 TB usable) | 4-8 pools | Every 6 months |
| **10K CCU** | 5.4 TB | 16.2 TB | 32.4 TB | 8 pools (8 TB usable) | 8-16 pools | Quarterly |
| **20K CCU** | 10.8 TB | 32.4 TB | 64.8 TB | 12 pools (12 TB usable) | 12-32 pools | Quarterly |

**Pool Configuration (from infrastructure/03-minio/tenant.yaml):**
```
1 pool = 4 nodes × 2 volumes × 1 TB = 8 TB raw = 4 TB usable (EC:4)
```

**Update in:** `deployment/infrastructure/03-minio/tenant.yaml`

```yaml
pools:
  - servers: 4
    name: pool-1
    volumesPerServer: 2
    volumeClaimTemplate:
      spec:
        storageClassName: local-storage
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Ti  # Per volume, 8 volumes total
  # Add pools as needed:
  - servers: 4
    name: pool-2  # Add when pool-1 reaches 70% capacity
    volumesPerServer: 2
    volumeClaimTemplate:
      spec:
        storageClassName: local-storage
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Ti
```

### Storage Monitoring Thresholds

#### PostgreSQL Database

**Monitor using:**
```bash
# Check database size
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U postgres -d synapse_li -c \
  "SELECT pg_database.datname,
          pg_size_pretty(pg_database_size(pg_database.datname)) AS size
   FROM pg_database
   WHERE datname = 'synapse_li';"

# Check table sizes (top 10)
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U postgres -d synapse_li -c \
  "SELECT schemaname, tablename,
          pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
   FROM pg_tables
   WHERE schemaname = 'public'
   ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
   LIMIT 10;"
```

**Alert Thresholds:**
- **Warning**: Storage > 70% full
- **Critical**: Storage > 85% full
- **Emergency**: Storage > 95% full

**Actions:**
```bash
# When reaching 70% full:
# 1. Review growth rate
# 2. Plan storage expansion within 30 days
# 3. Order new storage hardware if needed

# When reaching 85% full:
# 1. URGENT: Expand storage within 7 days
# 2. Consider temporary cleanup (if compliance allows)
# 3. Review retention policies (if compliance changes)

# When reaching 95% full:
# 1. EMERGENCY: Expand storage immediately
# 2. Contact infrastructure team
# 3. Prepare for potential read-only mode
```

#### MinIO Media Storage

**Monitor using:**
```bash
# Check bucket size
kubectl exec -it deployment/matrix-minio-pool-1-0 -n matrix -- \
  mc du minio/synapse-media-li

# Check pool capacity
kubectl exec -it deployment/matrix-minio-pool-1-0 -n matrix -- \
  mc admin info minio

# Check via Prometheus (if monitoring enabled)
# Metric: minio_bucket_usage_total_bytes{bucket="synapse-media-li"}
```

**Alert Thresholds:**
- **Warning**: Usable capacity > 70% full
- **Critical**: Usable capacity > 85% full
- **Add Pool**: When any pool > 70% full

**Expansion Procedure:**
```bash
# Add new pool to MinIO tenant
kubectl edit tenant matrix-minio -n matrix

# Add pool configuration:
# - name: pool-N
#   servers: 4
#   volumesPerServer: 2
#   volumeClaimTemplate: <same as pool-1>

# MinIO automatically redistributes data across pools
# No downtime required
```

### Storage Growth Rate Monitoring

**Calculate actual growth rate:**

```bash
# PostgreSQL - Compare sizes over time
# Run weekly, store results
DATE=$(date +%Y%m%d)
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U postgres -d synapse_li -t -c \
  "SELECT pg_database_size('synapse_li');" > db_size_$DATE.txt

# Calculate weekly growth
LAST_WEEK=$(cat db_size_$(date -d '7 days ago' +%Y%m%d).txt)
THIS_WEEK=$(cat db_size_$DATE.txt)
GROWTH=$((THIS_WEEK - LAST_WEEK))
echo "Weekly growth: $(numfmt --to=iec $GROWTH)"

# MinIO - Check bucket size
kubectl exec -it deployment/matrix-minio-pool-1-0 -n matrix -- \
  mc du --json minio/synapse-media-li | \
  jq -r '.size' > media_size_$DATE.txt
```

**Automated Monitoring (Prometheus):**

```promql
# PostgreSQL growth rate (bytes per day)
rate(pg_database_size_bytes{datname="synapse_li"}[7d]) * 86400

# MinIO bucket growth rate (bytes per day)
rate(minio_bucket_usage_total_bytes{bucket="synapse-media-li"}[7d]) * 86400

# Projected days until 85% full
(
  (pg_stat_database_size_bytes * 0.85) - pg_database_size_bytes
) / (rate(pg_database_size_bytes[30d]) * 86400)
```

### Capacity Planning Checklist

Before deployment:
- [ ] Calculate expected CCU and active user percentage
- [ ] Estimate daily message volume and file uploads
- [ ] Provision PostgreSQL storage for 3 years minimum
- [ ] Provision MinIO storage for 2 years minimum (easier to expand)
- [ ] Set up automated monitoring and alerts
- [ ] Document expected growth rates
- [ ] Plan quarterly capacity reviews

During operations:
- [ ] Monitor storage usage weekly
- [ ] Compare actual vs projected growth monthly
- [ ] Review capacity quarterly
- [ ] Order new hardware when reaching 70% capacity
- [ ] Test expansion procedures in staging
- [ ] Document all capacity changes

### Cost Optimization Strategies

**1. Storage Tiering (Future Enhancement)**

For extremely large deployments, consider:
- Hot storage (SSD/NVMe): Last 90 days
- Warm storage (HDD): 90 days - 1 year
- Cold storage (Object storage): > 1 year

**Not implemented in current deployment** - requires custom Synapse modifications

**2. Compression**

PostgreSQL:
- Already using TOAST compression for large values
- No additional tuning needed

MinIO:
- EC:4 erasure coding provides redundancy, not compression
- Consider enabling S3 object compression if client-side supported

**3. Deduplication**

- **PostgreSQL**: Event deduplication already handled by Synapse
- **MinIO**: No built-in deduplication (files stored as-is)
- Manual deduplication: Not recommended (breaks media references)

### Disaster Recovery Implications

**Infinite retention increases backup requirements:**

**Backup Storage Requirements:**
- PostgreSQL backups: Same growth rate as database
- MinIO backups: Same growth rate as media bucket
- Point-in-time recovery (PITR): WAL archiving storage (see infrastructure/01-postgresql/README.md)

**Backup Retention:**
```yaml
# Recommended for LI instance
Full backups: Monthly (keep all)
Incremental backups: Daily (keep 90 days)
WAL archives: Keep all (compliance requirement)
```

**Storage calculation:**
```
Total Backup Storage = Database Size + (Daily Growth × 90) + WAL Archives
```

Example for 5K CCU after 1 year:
```
Database: 100 GB
Daily growth: 2.6 GB
90-day incremental: 234 GB
WAL archives: ~50 GB
Total: ~384 GB backup storage required
```

## Compliance & Auditing

### Access Logs

All LI access is logged by:
1. **NGINX Ingress (LI network)**: Request logs with source IPs
2. **Synapse LI**: API access logs
3. **Synapse Admin**: Admin action logs

```bash
# View LI Synapse access logs (LI pods have label matrix.instance=li)
kubectl logs -n matrix -l matrix.instance=li,app.kubernetes.io/name=synapse --tail=100

# View LI Ingress access logs (from LI network's Ingress controller)
# Note: LI uses same hostnames as main, so filter by LI Ingress controller
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx | grep "synapse-li-client"
```

### Data Retention

- **Database**: Infinite (`redaction_retention_period: null`)
- **Media**: Persistent (synced indefinitely)
- **Logs**: Configurable via Loki (Phase 4)

### Audit Trail

Enable PostgreSQL audit logging on LI cluster:

```yaml
# In li-cluster.yaml
postgresql:
  parameters:
    log_statement: 'all'
    log_connections: 'on'
    log_disconnections: 'on'
```

## Security Best Practices

1. **IP Whitelisting**: Configure on ALL LI Ingresses
2. **Authentication**: Enable htpasswd on Synapse Admin
3. **TLS**: Use Let's Encrypt certificates (automatic)
4. **Network Isolation**: Verify NetworkPolicies are applied
5. **Read-Only**: Verify PostgreSQL `default_transaction_read_only: on`
6. **Key Isolation**: Verify LI cannot access key_vault
7. **Monitoring**: Set up alerts for replication lag
8. **Backups**: Enable CloudNativePG backups for LI cluster

## References

- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/16/logical-replication.html)
- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [rclone Documentation](https://rclone.org/docs/)
- [Synapse Admin](https://github.com/Awesome-Technologies/synapse-admin)
- [Matrix Specification](https://spec.matrix.org/)
