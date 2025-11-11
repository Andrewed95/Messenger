# Matrix Synapse Kubernetes Deployment Guide

Complete production deployment of Matrix Synapse homeserver on Kubernetes, designed for enterprise use with 20,000 concurrent users and full high availability.

---

## What You'll Get

This deployment provides a complete, production-ready Matrix homeserver with:

**Core Messaging Platform:**
- Synapse homeserver with 18 workers for horizontal scaling
- Element Web client for browser access
- Synapse Admin interface for user/room management
- Full high availability with zero single points of failure

**Infrastructure Components:**
- PostgreSQL database cluster (3 nodes, synchronous replication)
- Redis caching (2 separate instances for different services)
- MinIO object storage (4 nodes, erasure coded)
- Complete monitoring stack (Prometheus, Grafana, Loki)

**Communication Features:**
- 1:1 voice/video calls (coturn TURN/STUN servers)
- Group video calls (LiveKit SFU)
- File sharing and media storage
- End-to-end encryption support
- Optional federation with other Matrix servers

**Operational Features:**
- Automated TLS certificate management
- Automated backups (PostgreSQL, object storage)
- Automated maintenance tasks (media cleanup, database optimization)
- Load balancing with session affinity
- Horizontal and vertical scaling capabilities

---

## Before You Begin

### What You Need

**Infrastructure:**
- 21 servers (virtual or physical) running Debian 12
  - 3 servers for Kubernetes control plane (4 vCPU, 8GB RAM each)
  - 18 servers for Kubernetes workers (8 vCPU, 32GB RAM each)
- Network connectivity between all servers
- IP address range for load balancers (10-20 addresses)
- Domain name for your Matrix server (e.g., `chat.example.com`)

**Technical Knowledge:**
- Basic Linux system administration
- Basic understanding of Kubernetes concepts
- Comfortable with command-line tools

**On Your Local Machine:**
- `kubectl` installed and configured
- `helm` installed (version 3.12+)
- SSH access to your servers
- Text editor (vim, nano, or VS Code)

### Time Required

- **Kubernetes Installation**: 2-4 hours (if starting from scratch)
- **Matrix Deployment**: 1-2 hours
- **Testing and Validation**: 1 hour

Total: Approximately 4-7 hours for first-time deployment.

---

## Understanding the Architecture

Before deploying, it helps to understand how components connect:

```
                                Internet
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │   Domain Name (DNS)  │
                        │  chat.example.com    │
                        └──────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────┐
│                     KUBERNETES CLUSTER                          │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐   │
│  │              Load Balancer (MetalLB)                   │   │
│  │          Assigns real IP to Ingress                    │   │
│  └────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌────────────────────────────────────────────────────────┐   │
│  │           NGINX Ingress Controller                      │   │
│  │  Routes traffic based on URL path:                     │   │
│  │  • / → Element Web (client interface)                  │   │
│  │  • /_matrix/* → Synapse (API endpoints)                │   │
│  │  • /admin → Synapse Admin (management interface)       │   │
│  └────────────────────────────────────────────────────────┘   │
│           │                  │                  │               │
│           ▼                  ▼                  ▼               │
│  ┌──────────────┐  ┌────────────────┐  ┌──────────────┐      │
│  │ Element Web  │  │    Synapse     │  │Synapse Admin │      │
│  │  (3 pods)    │  │  Main + Workers│  │   (2 pods)   │      │
│  └──────────────┘  └────────────────┘  └──────────────┘      │
│                            │                                    │
│                            ▼                                    │
│         ┌──────────────────┴───────────────────┐              │
│         │                                        │              │
│         ▼                                        ▼              │
│  ┌────────────────┐                    ┌───────────────┐      │
│  │  PostgreSQL    │                    │  Redis Cache  │      │
│  │  (3 replicas)  │                    │  (3 replicas) │      │
│  │   Primary +    │                    │   Sentinel    │      │
│  │  2 Standby     │                    │      HA       │      │
│  └────────────────┘                    └───────────────┘      │
│         │                                                       │
│         └──────────┐                                           │
│                    ▼                                            │
│           ┌────────────────┐                                   │
│           │     MinIO      │                                   │
│           │  Object Storage│                                   │
│           │   (4 nodes)    │                                   │
│           │   Erasure Code │                                   │
│           └────────────────┘                                   │
│                                                                  │
│  Additional Components:                                         │
│  • coturn (TURN/STUN) - 2 nodes for voice/video NAT traversal │
│  • LiveKit (SFU) - 4 nodes for group video calls              │
│  • Monitoring (Prometheus, Grafana, Loki)                      │
└────────────────────────────────────────────────────────────────┘
```

**Key High Availability Features:**

1. **PostgreSQL**: 3 replicas with automatic failover
   - 1 primary (handles writes)
   - 2 standby replicas (handle reads)
   - Automatic promotion if primary fails (5 minute timeout)
   - Connection pooling via PgBouncer

2. **Synapse**: Main process + 18 workers
   - Main process coordinates workers
   - Workers handle specific tasks (sync, API calls, federation)
   - If worker dies, Kubernetes restarts it automatically
   - Load distributed across workers

3. **Redis**: 3 replicas with Sentinel
   - 1 master (active)
   - 2 replicas (standby)
   - Sentinel monitors health, promotes replica if master fails

4. **MinIO**: 4 nodes with erasure coding
   - Data split across 4 nodes
   - Can lose 1 node without data loss
   - Automatic healing when node returns

---

## Directory Structure

Here's where everything is located:

```
deployment/
│
├── README.md                          ← You are here
│
├── docs/                              ← Detailed documentation
│   ├── 00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md
│   │                                  ← Step-by-step Kubernetes installation
│   │
│   ├── DEPLOYMENT-GUIDE.md            ← Detailed deployment walkthrough
│   │
│   ├── CONFIGURATION-REFERENCE.md     ← All configuration options explained
│   │
│   ├── OPERATIONS-UPDATE-GUIDE.md     ← Update, scale, and maintain services
│   │
│   ├── HA-ROUTING-GUIDE.md            ← How HA and routing works
│   │
│   ├── CONTAINER-IMAGES-AND-CUSTOMIZATION.md
│   │                                  ← Image sources and customization
│   │
│   └── ANTIVIRUS-GUIDE.md             ← Complete antivirus implementation guide
│                                      (both with and without AV options)
│
├── config/                            ← Configuration files
│   ├── deployment.env.example         ← Template with all settings
│   └── deployment.env                 ← Your actual config (create this)
│
├── values/                            ← Helm chart values
│   ├── cert-manager-values.yaml       ← TLS certificate automation
│   ├── cloudnativepg-values.yaml      ← PostgreSQL operator
│   ├── redis-synapse-values.yaml      ← Redis for Synapse
│   ├── redis-livekit-values.yaml      ← Redis for LiveKit
│   ├── minio-operator-values.yaml     ← Object storage operator
│   ├── metallb-values.yaml            ← Load balancer
│   ├── nginx-ingress-values.yaml      ← Ingress controller
│   ├── prometheus-stack-values.yaml   ← Monitoring stack
│   ├── loki-values.yaml               ← Log aggregation
│   └── livekit-values.yaml            ← Video call server
│
├── manifests/                         ← Kubernetes resource definitions
│   ├── 00-namespaces.yaml             ← Creates Kubernetes namespaces
│   ├── 01-postgresql-cluster.yaml     ← PostgreSQL HA cluster
│   ├── 02-minio-tenant.yaml           ← Object storage deployment
│   ├── 03-metallb-config.yaml         ← Load balancer IP pool
│   ├── 04-coturn.yaml                 ← TURN/STUN servers
│   ├── 05-synapse-main.yaml           ← Synapse main process
│   ├── 06-synapse-workers.yaml        ← Synapse workers (18 workers)
│   ├── 07-element-web.yaml            ← Web client interface
│   ├── 08-synapse-admin.yaml          ← Admin web interface
│   ├── 09-ingress.yaml                ← Routing and TLS
│   └── 10-operational-automation.yaml ← Maintenance tasks
│
└── scripts/                           ← Automation scripts
    └── deploy-all.sh                  ← Automated deployment script
```

---

## Deployment Overview

The deployment process follows these main steps:

### Phase 1: Infrastructure Preparation

**If you don't have Kubernetes yet:**
1. Follow [`docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`](docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md)
   - Install Kubernetes on your 21 Debian servers
   - Configure networking, storage, and container runtime
   - Verify cluster is healthy

**If you already have Kubernetes:**
- Verify it meets requirements (v1.26+, storage classes configured)
- Ensure you have `kubectl` access with cluster-admin permissions

### Phase 2: Configuration

1. Copy configuration template:
   ```bash
   cd deployment/
   cp config/deployment.env.example config/deployment.env
   ```

2. Edit `config/deployment.env` with your values:
   - Domain name
   - Storage classes
   - IP addresses
   - Passwords and secrets

   **See:** [`docs/CONFIGURATION-REFERENCE.md`](docs/CONFIGURATION-REFERENCE.md) for detailed explanation of every option.

3. Generate required secrets:
   ```bash
   # PostgreSQL password
   openssl rand -base64 32

   # Synapse signing key
   docker run -it --rm matrixdotorg/synapse:latest generate

   # Other secrets
   openssl rand -base64 32  # Run for each secret needed
   ```

### Phase 3: Deployment

**Automated (Recommended):**
```bash
./scripts/deploy-all.sh
```
The script will:
- Validate prerequisites
- Deploy all components in correct order
- Wait for each component to be ready
- Provide next steps

**Manual:**
Follow [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md) for step-by-step manual deployment with detailed explanations of what each step does.

### Phase 4: Post-Deployment

1. Configure DNS to point your domain to the load balancer IP
2. Wait for TLS certificate to be issued (2-5 minutes)
3. Create admin user
4. Access web interface and test

**See Post-Deployment section below for detailed steps.**

### Phase 5: Validation

1. Test user registration and login
2. Test messaging
3. Test file upload
4. Test voice/video calls
5. Review monitoring dashboards

---

## Quick Start (For Experienced Users)

If you're familiar with Kubernetes and just want to get started quickly:

```bash
# 1. Prepare configuration
cd deployment/
cp config/deployment.env.example config/deployment.env
nano config/deployment.env  # Edit all CHANGE_TO_* values

# 2. Deploy everything
./scripts/deploy-all.sh

# 3. Wait for deployment (10-15 minutes)
watch kubectl get pods -A

# 4. Get load balancer IP
kubectl get svc -n ingress-nginx nginx-ingress-ingress-nginx-controller

# 5. Configure DNS
# Point your domain to the EXTERNAL-IP from step 4

# 6. Create admin user
SYNAPSE_POD=$(kubectl get pod -n matrix -l app=synapse,component=main -o name | head -1)
kubectl exec -n matrix $SYNAPSE_POD -- \
  register_new_matrix_user -c /config/homeserver.yaml \
  -u admin -p YOUR_PASSWORD -a http://localhost:8008

# 7. Access
# Open https://your-domain.com in browser
```

---

## Configuration

All configuration is managed through `config/deployment.env`. This file controls:

- **Domain and Networking**: Your domain name, IP ranges for load balancers
- **Storage**: Which Kubernetes storage classes to use for different workloads
- **Credentials**: Passwords, API keys, secrets for all components
- **Features**: Enable/disable optional features (federation, antivirus)
- **Resource Limits**: CPU and memory allocations
- **Scaling**: Number of replicas, worker counts

### Configuration Workflow

1. **Copy the template:**
   ```bash
   cp config/deployment.env.example config/deployment.env
   ```

2. **Edit with your values:**
   ```bash
   nano config/deployment.env
   ```

3. **Understand what you're changing:**
   - Each setting has comments explaining what it does
   - For detailed explanation of any setting, see [`docs/CONFIGURATION-REFERENCE.md`](docs/CONFIGURATION-REFERENCE.md)
   - Critical settings are marked with `# REQUIRED`
   - Optional settings are marked with `# OPTIONAL`

4. **Validate before deployment:**
   ```bash
   # Source the file to check for syntax errors
   bash -n config/deployment.env

   # The deployment script will also validate before deploying
   ./scripts/deploy-all.sh --validate-only
   ```

### Example: Understanding a Configuration Section

In `config/deployment.env`, you'll see sections like this:

```bash
# ============================================================================
# POSTGRESQL CONFIGURATION
# ============================================================================
# PostgreSQL is the main database for Synapse. It stores all messages, users,
# rooms, and state information. We deploy it as a 3-node cluster for high
# availability with automatic failover.

# Password for the 'synapse' database user
# REQUIRED: Generate with: openssl rand -base64 32
# This password is used by Synapse to connect to PostgreSQL
POSTGRES_PASSWORD="CHANGE_TO_SECURE_PASSWORD"

# Storage class for PostgreSQL data volumes
# REQUIRED: Must support ReadWriteOnce access mode
# Recommendation: Use fast storage (NVMe/SSD) for best performance
# Example: "local-path", "ceph-block", "longhorn"
POSTGRES_STORAGE_CLASS="CHANGE_TO_YOUR_STORAGE_CLASS"

# Storage size for each PostgreSQL instance
# Default: 500Gi (500 gigabytes)
# Estimate: ~1GB per 1000 users, plus message history
# For 20K users with 6 months history: 500GB recommended
POSTGRES_STORAGE_SIZE="500Gi"
```

For complete documentation of every setting, see [`docs/CONFIGURATION-REFERENCE.md`](docs/CONFIGURATION-REFERENCE.md).

---

## Deployment

### Automated Deployment

The automated deployment script handles everything for you:

```bash
./scripts/deploy-all.sh
```

**What it does:**

1. **Validates** prerequisites (kubectl, helm, config file)
2. **Checks** Kubernetes cluster connectivity
3. **Adds** Helm repositories
4. **Deploys** infrastructure layer:
   - cert-manager (TLS certificates)
   - MetalLB (load balancer)
   - NGINX Ingress (routing)
5. **Deploys** data layer:
   - CloudNativePG + PostgreSQL cluster
   - Redis (2 instances)
   - MinIO object storage
6. **Deploys** application layer:
   - coturn (TURN/STUN)
   - Synapse (main + workers)
   - Element Web
   - Synapse Admin
   - LiveKit
7. **Deploys** monitoring layer:
   - Prometheus, Grafana, Loki
8. **Configures** routing and TLS
9. **Validates** deployment
10. **Provides** next steps

**Script options:**

```bash
# Validate configuration only (don't deploy)
./scripts/deploy-all.sh --validate-only

# Deploy specific component only
./scripts/deploy-all.sh --component postgresql

# Skip component
./scripts/deploy-all.sh --skip monitoring

# Verbose output
./scripts/deploy-all.sh --verbose
```

### Manual Deployment

For complete control, deploy manually following [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md).

The manual guide explains:
- What each component does
- Why it's configured a specific way
- How components interact
- What to verify at each step
- How to troubleshoot issues

---

## Post-Deployment Steps

After deployment completes, follow these steps to make your Matrix server accessible:

### 1. Get Load Balancer IP Address

```bash
kubectl get svc -n ingress-nginx nginx-ingress-ingress-nginx-controller
```

Look for the `EXTERNAL-IP` column. Example output:
```
NAME                                    TYPE           EXTERNAL-IP      PORT(S)
nginx-ingress-ingress-nginx-controller  LoadBalancer   192.168.1.240    80:31234/TCP,443:31235/TCP
```

The IP `192.168.1.240` is your load balancer IP.

### 2. Configure DNS

Add a DNS A record pointing your domain to the load balancer IP:

```
chat.example.com.  300  IN  A  192.168.1.240
```

**Verify DNS resolution:**
```bash
nslookup chat.example.com
# Should return 192.168.1.240
```

### 3. Wait for TLS Certificate

The system automatically requests a TLS certificate from Let's Encrypt:

```bash
# Check certificate status
kubectl get certificate -n matrix

# Should show:
# NAME         READY   SECRET            AGE
# matrix-tls   True    matrix-tls-secret 2m
```

If `READY` shows `False`, wait 2-5 minutes. Let's Encrypt needs to verify domain ownership.

**Troubleshoot certificate issues:**
```bash
# Check certificate request details
kubectl describe certificate matrix-tls -n matrix

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager
```

### 4. Create Admin User

Create your first Matrix user with admin privileges:

```bash
# Find Synapse main pod name
SYNAPSE_POD=$(kubectl get pod -n matrix -l app=synapse,component=main -o jsonpath='{.items[0].metadata.name}')

# Create admin user
kubectl exec -n matrix $SYNAPSE_POD -- \
  register_new_matrix_user \
  -c /config/homeserver.yaml \
  -u admin \
  -p "YOUR_SECURE_PASSWORD" \
  -a \
  http://localhost:8008
```

**Important:**
- Replace `YOUR_SECURE_PASSWORD` with a strong password
- The `-a` flag grants admin privileges
- Remember these credentials - you'll need them to log in

### 5. Access Web Interface

Open your browser and navigate to:
```
https://chat.example.com
```

You should see the Element Web login page.

**Login with:**
- Homeserver: `https://chat.example.com`
- Username: `admin`
- Password: `YOUR_SECURE_PASSWORD` (from step 4)

### 6. Access Admin Interface

Navigate to:
```
https://chat.example.com/admin
```

**Login with the same credentials:**
- Homeserver: `https://chat.example.com`
- Username: `admin`
- Password: `YOUR_SECURE_PASSWORD`

From here you can:
- Create/manage users
- View/manage rooms
- Monitor server statistics
- Quarantine media
- Configure server settings

### 7. Access Monitoring

View system metrics and logs:

```bash
# Port-forward Grafana to your local machine
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

Open browser to: `http://localhost:3000`

**Default Grafana login:**
- Username: `admin`
- Password: (from `GRAFANA_ADMIN_PASSWORD` in `config/deployment.env`)

**Recommended dashboards to import:**
1. Synapse dashboard: https://github.com/element-hq/synapse/tree/develop/contrib/grafana
2. PostgreSQL dashboard: ID `9628` from grafana.com
3. Redis dashboard: ID `11835` from grafana.com

---

## Operational Guide

### Daily Operations

**Check system health:**
```bash
# All pods running
kubectl get pods -A | grep -v Running

# Check for pod restarts
kubectl get pods -A --field-selector status.phase=Running \
  --sort-by=.status.containerStatuses[0].restartCount

# View recent events
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

**Monitor resource usage:**
```bash
# Node resource usage
kubectl top nodes

# Pod resource usage
kubectl top pods -A --sort-by=memory
```

### Regular Maintenance

**Weekly Tasks:**
- Review Grafana dashboards for anomalies
- Check disk usage: `kubectl get pvc -A`
- Review error logs in Grafana Loki

**Monthly Tasks:**
- Update Synapse to latest stable version
- Review and rotate credentials
- Test backup restore procedure
- Clean up old media (automatic via CronJob)

**Automated Maintenance:**

The system includes automated maintenance tasks (see `manifests/10-operational-automation.yaml`):

1. **S3 Media Cleanup** (Daily at 2 AM)
   - Removes local media files already uploaded to MinIO
   - Prevents local storage exhaustion

2. **Database Maintenance** (Weekly on Sunday at 4 AM)
   - Runs VACUUM ANALYZE on PostgreSQL
   - Monitors table bloat
   - Reports statistics

3. **Worker Restart** (Weekly on Sunday at 3 AM)
   - Rolling restart of Synapse workers
   - Mitigates known memory leak in Synapse workers

**View maintenance job status:**
```bash
# List CronJobs
kubectl get cronjobs -n matrix

# View last execution
kubectl get jobs -n matrix --sort-by=.status.startTime

# View logs from last run
kubectl logs -n matrix job/synapse-s3-cleanup-<timestamp>
```

### Scaling

**Add more Synapse workers:**
```bash
# Edit worker StatefulSet
kubectl scale statefulset synapse-sync-worker --replicas=12 -n matrix
```

**Add more PostgreSQL replicas:**
```bash
# Scale PostgreSQL cluster
kubectl patch cluster synapse-postgres -n matrix \
  --type='json' -p='[{"op": "replace", "path": "/spec/instances", "value":5}]'
```

**Add more storage to PostgreSQL:**
```bash
# Resize PVC (if storage class supports it)
kubectl patch pvc postgres-synapse-postgres-1 -n matrix \
  -p '{"spec":{"resources":{"requests":{"storage":"1Ti"}}}}'
```

For detailed scaling procedures, see [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md) → Scaling section.

---

## Optional Features

### Federation (Connecting to Other Matrix Servers)

By default, federation is disabled. To enable:

1. Edit `config/deployment.env`:
   ```bash
   ENABLE_FEDERATION="true"
   ```

2. Configure DNS SRV records:
   ```
   _matrix._tcp.example.com. 300 IN SRV 10 0 8448 chat.example.com.
   ```

3. Redeploy Synapse:
   ```bash
   kubectl apply -f manifests/05-synapse-main.yaml
   kubectl rollout restart deployment/synapse-main -n matrix
   ```

4. Test federation:
   - Visit: https://federationtester.matrix.org/
   - Enter your domain

**See:** [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md) → Federation section for complete guide.

### Antivirus Scanning

Optionally scan uploaded files for malware using ClamAV.

**Trade-offs:**
- **Pros**: Protection against malware, ransomware
- **Cons**: Additional CPU usage, slight upload delay, operational complexity

**Complete antivirus guide:**

See [`docs/ANTIVIRUS-GUIDE.md`](docs/ANTIVIRUS-GUIDE.md) for:
- Decision framework (should you enable/disable?)
- Option A: Asynchronous scanning implementation (if enabling)
- Option B: Alternative security measures (if disabling)
- Complete deployment steps for both options

---

## Troubleshooting

### Common Issues

#### Pods Not Starting

**Symptom:** Pods stuck in `Pending` state

**Check:**
```bash
kubectl describe pod <pod-name> -n <namespace>
```

**Common causes:**
- Insufficient node resources
- Storage class not found
- Node selector/affinity not matching

**Solutions:**
- Add more nodes or resize existing nodes
- Verify storage class exists: `kubectl get storageclass`
- Check node labels: `kubectl get nodes --show-labels`

#### Can't Access Web Interface

**Symptom:** Browser shows "Connection refused" or "This site can't be reached"

**Check:**
1. Load balancer has IP:
   ```bash
   kubectl get svc -n ingress-nginx nginx-ingress-ingress-nginx-controller
   ```

2. DNS resolves correctly:
   ```bash
   nslookup chat.example.com
   ```

3. TLS certificate is ready:
   ```bash
   kubectl get certificate -n matrix
   ```

4. Ingress is configured:
   ```bash
   kubectl get ingress -A
   ```

#### Database Connection Errors

**Symptom:** Synapse logs show "could not connect to server"

**Check:**
```bash
# PostgreSQL cluster status
kubectl get cluster -n matrix

# Should show 3 instances, 1 primary, 2 replicas
kubectl get pods -n matrix -l cnpg.io/cluster=synapse-postgres
```

**Common causes:**
- PostgreSQL not ready yet (wait 2-3 minutes)
- Wrong credentials in secret
- Network policy blocking connection

**Solutions:**
- Wait for cluster to be ready
- Verify secret: `kubectl get secret synapse-postgres-credentials -n matrix -o yaml`
- Check logs: `kubectl logs -n matrix synapse-postgres-1`

### Getting Help

1. **Check logs:**
   ```bash
   # Component logs
   kubectl logs -n <namespace> <pod-name>

   # Follow logs
   kubectl logs -n <namespace> <pod-name> -f

   # Previous crashed container
   kubectl logs -n <namespace> <pod-name> --previous
   ```

2. **Check events:**
   ```bash
   kubectl get events -n <namespace> --sort-by='.lastTimestamp'
   ```

3. **Check resource status:**
   ```bash
   kubectl get all -n <namespace>
   kubectl describe <resource-type> <resource-name> -n <namespace>
   ```

4. **Review architecture documentation:**
   - [`docs/HA-ROUTING-GUIDE.md`](docs/HA-ROUTING-GUIDE.md) - How components connect
   - [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md) - Detailed deployment steps

5. **Community resources:**
   - Matrix community: https://matrix.to/#/#synapse:matrix.org
   - Synapse documentation: https://matrix-org.github.io/synapse/latest/

---

## Next Steps

Now that you've read this overview:

1. **If you don't have Kubernetes:**
   → Go to [`docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`](docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md)

2. **If you have Kubernetes:**
   → Go to [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md)

3. **To understand configuration options:**
   → Go to [`docs/CONFIGURATION-REFERENCE.md`](docs/CONFIGURATION-REFERENCE.md)

4. **To understand how HA works:**
   → Go to [`docs/HA-ROUTING-GUIDE.md`](docs/HA-ROUTING-GUIDE.md)

5. **Ready to deploy?**
   ```bash
   cd deployment/
   cp config/deployment.env.example config/deployment.env
   nano config/deployment.env  # Edit all values
   ./scripts/deploy-all.sh
   ```

---

## Documentation Index

| Document | Purpose | When to Read |
|----------|---------|--------------|
| [`00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`](docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md) | Install Kubernetes from scratch | Before deployment, if you don't have Kubernetes |
| [`DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md) | Step-by-step deployment walkthrough | During deployment, for detailed explanations |
| [`CONFIGURATION-REFERENCE.md`](docs/CONFIGURATION-REFERENCE.md) | Complete configuration options | When customizing settings |
| [`OPERATIONS-UPDATE-GUIDE.md`](docs/OPERATIONS-UPDATE-GUIDE.md) | Update, scale, and maintain services | After deployment, for ongoing operations |
| [`HA-ROUTING-GUIDE.md`](docs/HA-ROUTING-GUIDE.md) | How HA and routing works | To understand architecture and troubleshoot |
| [`CONTAINER-IMAGES-AND-CUSTOMIZATION.md`](docs/CONTAINER-IMAGES-AND-CUSTOMIZATION.md) | Image sources, custom builds | When using custom Synapse versions |
| [`ANTIVIRUS-GUIDE.md`](docs/ANTIVIRUS-GUIDE.md) | Complete antivirus guide | If implementing or skipping antivirus |

---

**Questions?** Start with the [Troubleshooting](#troubleshooting) section, then check [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md) for detailed explanations.

**Ready to begin?** Proceed to the documentation that matches your situation above.
