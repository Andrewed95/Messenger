# Complete Architecture Design - Matrix/Synapse Deployment

> **Complete rebuild architecture for 100-20K CCU with full LI capabilities**

## Design Principles

1. **No single points of failure** - Every component has redundancy
2. **Elastic scaling** - Can scale from 100 to 20K CCU with same architecture
3. **Clear separation** - Main and LI instances are logically isolated
4. **Centralized configuration** - All configs in `deployment/config/`
5. **Air-gapped capable** - Works after initial deployment without internet
6. **Security hardened** - NetworkPolicies, RBAC, secrets management

---

## Directory Structure

```
deployment/
├── namespace.yaml                     # Namespace definition
├── rbac/                             # RBAC for operators and services
│   ├── cloudnative-pg-rbac.yaml
│   ├── minio-operator-rbac.yaml
│   └── cert-manager-rbac.yaml
├── config/                           # Centralized configuration
│   ├── postgresql/
│   │   ├── main-cluster.yaml
│   │   └── li-cluster.yaml
│   ├── redis/
│   │   └── sentinel-values.yaml
│   ├── minio/
│   │   ├── main-tenant.yaml
│   │   └── li-tenant.yaml
│   ├── synapse/
│   │   ├── homeserver.yaml
│   │   ├── workers/
│   │   │   ├── synchrotron.yaml
│   │   │   ├── event-persister.yaml
│   │   │   ├── client-reader.yaml
│   │   │   ├── federation-sender.yaml
│   │   │   ├── media-repository.yaml
│   │   │   └── ... (all 22 worker types)
│   │   └── log-config.yaml
│   ├── synapse-li/
│   │   ├── homeserver.yaml
│   │   └── log-config.yaml
│   ├── element-web/
│   │   └── config.json
│   ├── element-web-li/
│   │   ├── config.json
│   │   └── custom-theme.json
│   ├── synapse-admin-li/
│   │   └── config.json
│   ├── key-vault/
│   │   ├── settings.yaml
│   │   └── env-config.yaml
│   ├── livekit/
│   │   └── config.yaml
│   ├── lk-jwt-service/
│   │   └── config.yaml
│   ├── coturn/
│   │   └── turnserver.conf
│   ├── haproxy/
│   │   └── haproxy.cfg
│   ├── antivirus/
│   │   ├── clamd.conf
│   │   └── scan-worker-config.yaml
│   ├── sync-system/
│   │   └── celery-config.yaml
│   └── monitoring/
│       ├── prometheus.yaml
│       ├── grafana-datasources.yaml
│       ├── grafana-dashboards.yaml
│       └── alertmanager.yaml
├── infrastructure/                   # Core infrastructure components
│   ├── 01-postgresql/
│   │   ├── main-cluster.yaml         # CloudNativePG cluster (main)
│   │   ├── li-cluster.yaml           # CloudNativePG cluster (LI)
│   │   └── backup-config.yaml        # Backup configuration
│   ├── 02-redis/
│   │   ├── sentinel-statefulset.yaml # Redis Sentinel cluster
│   │   ├── sentinel-service.yaml
│   │   └── sentinel-configmap.yaml
│   ├── 03-minio/
│   │   ├── operator.yaml             # MinIO operator
│   │   ├── main-tenant.yaml          # Main tenant
│   │   ├── li-tenant.yaml            # LI tenant
│   │   └── buckets.yaml              # Bucket definitions
│   └── 04-networking/
│       ├── networkpolicies.yaml      # All NetworkPolicies
│       ├── ingress-controller.yaml   # NGINX ingress controller
│       └── cert-manager.yaml         # Certificate management
├── main-instance/                    # Main production instance
│   ├── 01-synapse/
│   │   ├── configmap.yaml            # Synapse config
│   │   ├── secrets.yaml              # Synapse secrets
│   │   ├── main-deployment.yaml      # Main Synapse process
│   │   ├── workers/
│   │   │   ├── synchrotron.yaml      # 22 worker deployments
│   │   │   ├── event-persister.yaml
│   │   │   └── ... (all types)
│   │   ├── services.yaml             # All Synapse services
│   │   ├── pdb.yaml                  # PodDisruptionBudgets
│   │   └── hpa.yaml                  # HorizontalPodAutoscaler
│   ├── 02-element-web/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── 03-haproxy/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── 04-livekit/
│   │   ├── configmap.yaml
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── 05-lk-jwt-service/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── 06-coturn/
│   │   ├── configmap.yaml
│   │   ├── daemonset.yaml            # DaemonSet with hostNetwork
│   │   └── service.yaml
│   ├── 07-sygnal/
│   │   ├── configmap.yaml
│   │   ├── secrets.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   └── 08-key-vault/
│       ├── configmap.yaml
│       ├── secrets.yaml
│       ├── deployment.yaml
│       ├── service.yaml              # Internal only
│       ├── migration-job.yaml        # Django migrations
│       └── networkpolicy.yaml        # Strict isolation
├── li-instance/                      # Lawful Intercept instance
│   ├── 01-synapse-li/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── 02-element-web-li/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── 03-synapse-admin-li/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   └── 04-sync-system/
│       ├── configmap.yaml
│       ├── celery-deployment.yaml    # Celery workers
│       ├── celery-beat.yaml          # Scheduled tasks
│       ├── checkpoint-pvc.yaml       # Persistent checkpoints
│       └── service.yaml
├── antivirus/                        # Antivirus system
│   ├── 01-clamav/
│   │   ├── configmap.yaml
│   │   ├── daemonset.yaml            # ClamAV on every node
│   │   └── freshclam-cronjob.yaml    # Virus DB updates
│   ├── 02-scan-workers/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml           # Multiple replicas
│   │   └── service.yaml
│   └── 03-synapse-spam-checker/
│       └── configmap.yaml            # Spam checker module config
├── monitoring/                       # Monitoring stack
│   ├── 01-prometheus/
│   │   ├── configmap.yaml
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   ├── servicemonitors.yaml      # All ServiceMonitors
│   │   └── rules.yaml                # Alert rules
│   ├── 02-grafana/
│   │   ├── configmap.yaml
│   │   ├── secrets.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml
│   │   └── dashboards/
│   │       ├── system-overview.json
│   │       ├── synapse-performance.json
│   │       ├── postgresql-health.json
│   │       ├── redis-health.json
│   │       ├── minio-health.json
│   │       ├── federation-health.json
│   │       └── livekit-health.json
│   ├── 03-loki/
│   │   ├── configmap.yaml
│   │   ├── statefulset.yaml
│   │   └── service.yaml
│   └── 04-alertmanager/
│       ├── configmap.yaml
│       ├── deployment.yaml
│       └── service.yaml
├── scaling-profiles/                 # Pre-configured scaling profiles
│   ├── 100-ccu.yaml                  # 100 CCU configuration
│   ├── 1000-ccu.yaml                 # 1K CCU configuration
│   ├── 5000-ccu.yaml                 # 5K CCU configuration
│   ├── 10000-ccu.yaml                # 10K CCU configuration
│   └── 20000-ccu.yaml                # 20K CCU configuration
└── docs/                             # Deployment documentation
    ├── 01-DEPLOYMENT-GUIDE.md        # Complete deployment guide
    ├── 02-SCALING-GUIDE.md           # Scaling procedures
    ├── 03-OPERATIONS-GUIDE.md        # Day-to-day operations
    ├── 04-TROUBLESHOOTING.md         # Common issues
    ├── 05-BACKUP-RESTORE.md          # Backup and recovery
    ├── 06-AIR-GAPPED-SETUP.md        # Air-gapped deployment
    └── 07-LI-OPERATIONS.md           # LI-specific operations
```

---

## Component Inventory

### Phase 1: Core Infrastructure (33 manifests)

**PostgreSQL (CloudNativePG) - 3 manifests:**
- main-cluster.yaml (1 primary + 2 replicas)
- li-cluster.yaml (1 primary + 1 replica)
- backup-config.yaml (PITR, base backups)

**Redis Sentinel - 3 manifests:**
- sentinel-statefulset.yaml (3 nodes minimum)
- sentinel-service.yaml
- sentinel-configmap.yaml

**MinIO - 4 manifests:**
- operator.yaml
- main-tenant.yaml (4-node distributed minimum)
- li-tenant.yaml (4-node distributed)
- buckets.yaml (bucket definitions, policies)

**Networking - 3 manifests:**
- networkpolicies.yaml (all NetworkPolicies)
- ingress-controller.yaml (NGINX or Traefik)
- cert-manager.yaml (TLS management)

**ConfigMaps - 20 manifests:**
- All configuration files from config/ directory

### Phase 2: Main Instance (45 manifests)

**Synapse - 29 manifests:**
- configmap.yaml (homeserver.yaml)
- secrets.yaml (macaroon, registration, form secrets)
- main-deployment.yaml (main Synapse process)
- 22 worker deployments (synchrotron, event-persister, etc.)
- services.yaml (all services)
- pdb.yaml (PodDisruptionBudgets)
- hpa.yaml (HorizontalPodAutoscaler)
- ingress.yaml (external access)

**Element Web - 4 manifests:**
- configmap.yaml
- deployment.yaml
- service.yaml
- ingress.yaml

**HAProxy - 3 manifests:**
- configmap.yaml
- deployment.yaml
- service.yaml

**LiveKit - 4 manifests:**
- configmap.yaml
- statefulset.yaml (3 replicas in distributed mode)
- service.yaml
- ingress.yaml

**lk-jwt-service - 4 manifests:**
- configmap.yaml
- deployment.yaml (2 replicas)
- service.yaml
- ingress.yaml

**coturn - 3 manifests:**
- configmap.yaml
- daemonset.yaml (hostNetwork)
- service.yaml (NodePort)

**Sygnal - 4 manifests:**
- configmap.yaml
- secrets.yaml (APNS/FCM credentials)
- deployment.yaml
- service.yaml

**key_vault - 6 manifests:**
- configmap.yaml
- secrets.yaml (Django secret, DB password, RSA keys)
- deployment.yaml
- service.yaml (ClusterIP, internal only)
- migration-job.yaml (Django migrations)
- networkpolicy.yaml (only accessible from Synapse)

### Phase 3: LI Instance (13 manifests)

**synapse-li - 4 manifests:**
- configmap.yaml (with redaction_retention_period: null)
- deployment.yaml (read-only replica)
- service.yaml
- ingress.yaml (restricted access)

**element-web-li - 4 manifests:**
- configmap.yaml (with custom theme)
- deployment.yaml
- service.yaml
- ingress.yaml (restricted access)

**synapse-admin-li - 4 manifests:**
- configmap.yaml
- deployment.yaml
- service.yaml
- ingress.yaml (restricted access)

**Sync System - 5 manifests:**
- configmap.yaml (Celery configuration)
- celery-deployment.yaml (multiple workers)
- celery-beat.yaml (scheduled sync)
- checkpoint-pvc.yaml (persistent checkpoints)
- service.yaml

### Phase 4: Monitoring Stack (20 manifests)

**Prometheus - 5 manifests:**
- configmap.yaml (scrape configs)
- statefulset.yaml (persistent metrics)
- service.yaml
- servicemonitors.yaml (all components)
- rules.yaml (alert rules)

**Grafana - 12 manifests:**
- configmap.yaml
- secrets.yaml (admin password)
- deployment.yaml
- service.yaml
- ingress.yaml
- 7 dashboard JSON files

**Loki - 3 manifests:**
- configmap.yaml
- statefulset.yaml
- service.yaml

**Alertmanager - 3 manifests:**
- configmap.yaml (routing, receivers)
- deployment.yaml
- service.yaml

### Phase 5: Antivirus System (8 manifests)

**ClamAV - 3 manifests:**
- configmap.yaml (clamd configuration)
- daemonset.yaml (one per node, shared socket)
- freshclam-cronjob.yaml (virus DB updates)

**Scan Workers - 3 manifests:**
- configmap.yaml
- deployment.yaml (multiple replicas)
- service.yaml (HTTP API for spam checker)

**Synapse Spam Checker - 2 manifests:**
- configmap.yaml (spam checker module config)
- secrets.yaml (bearer token for scan workers)

### Total Manifest Count: **119 manifests**

---

## Scaling Profiles

### Profile: 100 CCU (Minimal HA)

```yaml
# scaling-profiles/100-ccu.yaml

postgresql:
  instances: 2  # 1 primary + 1 replica

redis:
  replicas: 3  # Minimum for Sentinel

minio:
  nodes: 4  # Minimum for EC:4

synapse:
  workers:
    synchrotron: 1
    event_persister: 1
    client_reader: 1
    federation_sender: 1
    media_repository: 1
    # All others: 1

livekit:
  replicas: 1

resources:
  total_cpu: 8
  total_memory: 16Gi
  storage: 500Gi
```

### Profile: 1,000 CCU (Moderate Scale)

```yaml
# scaling-profiles/1000-ccu.yaml

postgresql:
  instances: 3  # 1 primary + 2 replicas

redis:
  replicas: 3

minio:
  nodes: 4

synapse:
  workers:
    synchrotron: 2
    event_persister: 2
    client_reader: 2
    federation_sender: 2
    media_repository: 2
    # Others scale to 1-2

livekit:
  replicas: 2

resources:
  total_cpu: 16
  total_memory: 32Gi
  storage: 1Ti
```

### Profile: 5,000 CCU (Production Scale)

```yaml
# scaling-profiles/5000-ccu.yaml

postgresql:
  instances: 3

redis:
  replicas: 3

minio:
  nodes: 6

synapse:
  workers:
    synchrotron: 4
    event_persister: 2
    client_reader: 4
    federation_sender: 2
    media_repository: 2
    federation_reader: 2

livekit:
  replicas: 3

resources:
  total_cpu: 32
  total_memory: 64Gi
  storage: 2Ti
```

### Profile: 10,000 CCU (Large Scale)

```yaml
# scaling-profiles/10000-ccu.yaml

postgresql:
  instances: 3

redis:
  replicas: 5

minio:
  nodes: 8

synapse:
  workers:
    synchrotron: 8
    event_persister: 4
    client_reader: 8
    federation_sender: 4
    media_repository: 4
    federation_reader: 4

livekit:
  replicas: 5

resources:
  total_cpu: 64
  total_memory: 128Gi
  storage: 4Ti
```

### Profile: 20,000 CCU (Massive Scale)

```yaml
# scaling-profiles/20000-ccu.yaml

postgresql:
  instances: 4  # 1 primary + 3 replicas

redis:
  replicas: 5

minio:
  nodes: 12

synapse:
  workers:
    synchrotron: 16
    event_persister: 8
    client_reader: 16
    federation_sender: 8
    media_repository: 8
    federation_reader: 8

livekit:
  replicas: 7

resources:
  total_cpu: 128
  total_memory: 256Gi
  storage: 8Ti
```

---

## Network Architecture

### Network Policies

**1. key_vault Isolation:**
```yaml
# Only accessible from Synapse pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: key-vault-isolation
spec:
  podSelector:
    matchLabels:
      app: key-vault
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: synapse
      ports:
        - protocol: TCP
          port: 8000
```

**2. LI Instance Isolation:**
```yaml
# LI instance cannot access main instance resources
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: li-instance-isolation
spec:
  podSelector:
    matchLabels:
      instance: li
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: admin  # Only admin access
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgresql-li
    - to:
        - podSelector:
            matchLabels:
              app: minio-li
```

**3. Database Access Control:**
```yaml
# Only authorized apps can access PostgreSQL
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgresql-access
spec:
  podSelector:
    matchLabels:
      app: postgresql
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              database-client: "true"
      ports:
        - protocol: TCP
          port: 5432
```

---

## Deployment Sequence

### Initial Deployment Order:

1. **Namespace and RBAC** (1 min)
2. **Core Infrastructure** (10-15 min)
   - PostgreSQL operators and clusters
   - Redis Sentinel
   - MinIO operator and tenants
   - Networking (ingress, cert-manager)
3. **Main Instance** (15-20 min)
   - Synapse main + workers
   - Element Web
   - HAProxy
   - LiveKit + lk-jwt-service
   - coturn
   - Sygnal
   - key_vault
4. **LI Instance** (10 min)
   - synapse-li
   - element-web-li
   - synapse-admin-li
   - Sync system
5. **Antivirus** (5 min)
   - ClamAV DaemonSet
   - Scan workers
6. **Monitoring** (10 min)
   - Prometheus
   - Grafana + dashboards
   - Loki
   - Alertmanager

**Total Deployment Time: ~50-60 minutes**

### Scaling Operations:

**Scale Up Procedure:**
1. Apply new scaling profile: `kubectl apply -f scaling-profiles/5000-ccu.yaml`
2. Workers scale automatically via HPA or manually via `kubectl scale`
3. Verify metrics in Grafana
4. Run load test to validate

**Scale Down Procedure:**
1. Reduce worker replicas gradually
2. Monitor queue depths
3. Wait for graceful shutdown (30s-2min)
4. Verify no dropped connections

---

## Configuration Management

### ConfigMap Strategy

All configuration centralized in `deployment/config/`:

```yaml
# Example: synapse configmap
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-config
  namespace: matrix
data:
  homeserver.yaml: |
    {{ file "config/synapse/homeserver.yaml" | indent 4 }}
  log.yaml: |
    {{ file "config/synapse/log-config.yaml" | indent 4 }}
```

### Secret Strategy

Secrets generated during deployment or provided externally:

```yaml
# Example: synapse secrets
apiVersion: v1
kind: Secret
metadata:
  name: synapse-secrets
  namespace: matrix
type: Opaque
stringData:
  registration_shared_secret: {{ randAlphaNum 32 }}
  macaroon_secret_key: {{ randAlphaNum 32 }}
  form_secret: {{ randAlphaNum 32 }}
```

### Helm Values Strategy

Each scaling profile is a Helm values file:

```yaml
# Example: 1000-ccu.yaml
global:
  domain: example.com
  serverName: matrix.example.com

postgresql:
  instances: 3

synapse:
  workers:
    synchrotron:
      replicas: 2
    event_persister:
      replicas: 2
```

---

## Air-Gapped Deployment Considerations

### Pre-Deployment Checklist:

1. **Container Images:**
   - Pull all images to local registry
   - Document image list in `air-gapped-images.txt`
   - Create pull script

2. **Helm Charts:**
   - Download all charts offline
   - Package as tarballs
   - Include in deployment bundle

3. **Dependencies:**
   - ClamAV virus database
   - Python pip wheels
   - Node npm packages
   - Go modules

4. **Certificates:**
   - Generate all TLS certs
   - 5-year validity minimum
   - Include CA bundle

5. **Documentation:**
   - Complete offline docs
   - Include troubleshooting
   - Emergency procedures

---

## High Availability Guarantees

### Component HA Summary:

| Component | HA Method | Min Replicas | Failover Time |
|-----------|-----------|--------------|---------------|
| PostgreSQL | Synchronous replication | 2 (1+1) | 30-60 seconds |
| Redis | Sentinel automatic failover | 3 | 5-10 seconds |
| MinIO | Distributed erasure coding | 4 | Immediate |
| Synapse Workers | Multiple replicas + HAProxy | 2+ | Immediate |
| LiveKit | Distributed mode + Redis | 3 | Immediate |
| Grafana | StatefulSet | 1* | Manual |
| Prometheus | StatefulSet | 1* | Manual |

\* Can be increased to 2+ with shared storage

### PodDisruptionBudgets:

```yaml
# Ensure minimum availability during updates
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: synapse-synchrotron-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: synapse
      worker: synchrotron
```

---

## Monitoring and Alerting

### Key Metrics:

1. **System Health:**
   - CPU usage per node
   - Memory usage per node
   - Disk usage per node
   - Network throughput

2. **Synapse Health:**
   - Requests per second
   - Response latency (p50, p95, p99)
   - Worker queue depth
   - Federation send lag

3. **Database Health:**
   - Replication lag
   - Connection pool usage
   - Query latency
   - Deadlocks

4. **Storage Health:**
   - MinIO bandwidth
   - Object count growth
   - Error rates

5. **Video Call Health:**
   - Active participants
   - Rooms count
   - Bandwidth per room

### Alert Rules:

```yaml
groups:
  - name: critical
    rules:
      - alert: DatabaseReplicationLag
        expr: pg_replication_lag_seconds > 5
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL replication lag high"

      - alert: WorkerQueueBacklog
        expr: synapse_worker_queue_depth > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Worker queue depth high"
```

---

## End of Architecture Design

This architecture design provides the complete blueprint for building the production-grade Matrix/Synapse deployment with full LI capabilities, HA, antivirus, and support for 100-20K CCU.

**Next Steps:**
1. Build Phase 1: Core Infrastructure
2. Build Phase 2: Main Instance
3. Build Phase 3: LI Instance
4. Build Phase 4: Monitoring
5. Build Phase 5: Antivirus
6. Documentation
7. Validation
