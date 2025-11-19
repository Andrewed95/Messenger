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
- ✅ Media sync via rclone (every )
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
│  │   (Real-time DB)     │   │  (Every )   │  │
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

**Access**: https://matrix-li.example.com

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

**Access**: https://element-li.matrix.example.com

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

**Access**: https://admin-li.matrix.example.com

### 4. Sync System (04-sync-system/)

**Bridge between main and LI** for data replication.

**Components**:
- **PostgreSQL Logical Replication**: Real-time database sync
- **rclone Media Sync**: Periodic media file sync (every hour)
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

## DNS Configuration

**CRITICAL**: The LI instance and main instance share the SAME `server_name` but use DIFFERENT domains for access.

### Domain Configuration

**Main Instance:**
- `server_name`: `matrix.example.com` (in homeserver.yaml)
- `public_baseurl`: `https://matrix.example.com`
- DNS: `matrix.example.com` → Points to main Synapse Ingress IP
- Users see: `@username:matrix.example.com`

**LI Instance:**
- `server_name`: `matrix.example.com` (**MUST match main**)
- `public_baseurl`: `https://matrix-li.example.com` (different URL)
- DNS: `matrix-li.example.com` → Points to LI Synapse Ingress IP
- Users see: Same `@username:matrix.example.com` (database compatibility)

### Why This Configuration?

1. **Same `server_name`**: Ensures users, rooms, and events in the LI database are compatible with the main instance
2. **Different `public_baseurl`**: Allows separate access points for main vs LI interfaces
3. **Separate DNS entries**: Route traffic to different Kubernetes Ingress endpoints

### DNS Setup

Configure these DNS A records:

```bash
# Main instance (production users)
matrix.example.com          → <main-ingress-external-ip>
element.example.com         → <main-ingress-external-ip>

# LI instance (law enforcement only)
matrix-li.example.com       → <main-ingress-external-ip>  # Same Ingress, different routing
element-li.example.com      → <main-ingress-external-ip>
admin-li.example.com        → <main-ingress-external-ip>
```

### How Traffic Routing Works

All domains point to the **same Kubernetes Ingress**, but NGINX routes based on `Host` header:

```yaml
# Ingress rules automatically route:
Host: matrix.example.com     → synapse-main service
Host: matrix-li.example.com  → synapse-li service
Host: element.example.com    → element-web service
Host: element-li.example.com → element-web-li service
```

**No special DNS tricks needed** - just standard A records pointing to your Ingress external IP.

### Getting Your Ingress IP

```bash
# Find your Ingress external IP
kubectl get svc -n ingress-nginx ingress-nginx-controller

# Output example:
# NAME                       TYPE           EXTERNAL-IP      PORT(S)
# ingress-nginx-controller   LoadBalancer   203.0.113.10     80:30080/TCP,443:30443/TCP
```

Use `203.0.113.10` (example) as your DNS target for ALL domains above.

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

```bash
# Test Synapse LI API
curl https://matrix-li.example.com/_matrix/client/versions

# Test Element Web LI (should show watermark)
open https://element-li.matrix.example.com

# Test Synapse Admin LI (should require auth)
curl -u admin:password https://admin-li.matrix.example.com

# Login to LI instance (users synced from main)
# Use same credentials as main instance
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

**rclone sync** (every ):
1. CronJob triggers rclone
2. rclone compares `synapse-media` and `synapse-media-li` buckets
3. New/changed files copied from main to LI
4. **Lag**: Up to  for new media

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

## Compliance & Auditing

### Access Logs

All LI access is logged by:
1. **NGINX Ingress**: Request logs with source IPs
2. **Synapse LI**: API access logs
3. **Synapse Admin**: Admin action logs

```bash
# View access logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx | grep matrix-li
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
