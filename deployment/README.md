# Matrix/Synapse Kubernetes Production Deployment
## Version 2.0 - Validated & Corrected Architecture

**Target Capacity:** 20,000 Concurrent Users
**Architecture:** High Availability, Zero Single Points of Failure
**Deployment Method:** Kubernetes with Helm Charts and Manifests

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Highlights](#architecture-highlights)
3. [Prerequisites](#prerequisites)
4. [Quick Start](#quick-start)
5. [Directory Structure](#directory-structure)
6. [Configuration](#configuration)
7. [Deployment Steps](#deployment-steps)
8. [Post-Deployment](#post-deployment)
9. [Validation & Testing](#validation--testing)
10. [Scaling](#scaling)
11. [Troubleshooting](#troubleshooting)
12. [Maintenance](#maintenance)

---

## Overview

This deployment package provides a **production-ready, highly-available Matrix/Synapse installation** designed to support 20,000 concurrent users with complete redundancy and automatic failover.

### What's Included

- **Synapse Homeserver** with specialized workers (sync, generic, federation, event persisters)
- **PostgreSQL HA Cluster** (CloudNativePG with synchronous replication)
- **Dual Redis Sentinel** (separate instances for Synapse and LiveKit)
- **MinIO Object Storage** (S3-compatible with erasure coding EC:4)
- **LiveKit SFU** for group video calls (Element Call backend)
- **coturn** TURN/STUN servers for NAT traversal
- **Element Web** client interface
- **Synapse Admin** web UI
- **Complete monitoring** (Prometheus + Grafana + Loki)
- **Automated deployment scripts**
- **TLS certificate management** (cert-manager)

### Key Corrections from v1.0

This version includes **critical fixes** validated through independent architectural review:

1. ✅ **Separate Redis instances** for Synapse and LiveKit (isolated failure domains)
2. ✅ **Fixed PostgreSQL switchoverDelay** (was 463 days, now 5 minutes)
3. ✅ **Element Web as Deployment** (not StatefulSet)
4. ✅ **NGINX Ingress IP preservation** (externalTrafficPolicy: Local)
5. ✅ **Automated S3 local cleanup** (CronJob with s3_media_upload --delete)
6. ✅ **CloudNativePG v1.25+ API** with explicit dataDurability

---

## Architecture Highlights

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                     INGRESS LAYER                           │
│  NGINX Ingress (MetalLB LoadBalancer, externalTrafficPolicy: Local) │
│  Ports: 80, 443, 8448 (federation)                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   APPLICATION LAYER                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Synapse Main Process (1 replica)                   │  │
│  │  + Workers: 8 sync, 4 generic, 4 federation, 2 persist │
│  │  + Internal Router (HAProxy pattern)                │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Element Web (Deployment, 2 replicas)               │  │
│  │  Synapse Admin (IP-restricted)                      │  │
│  │  lk-jwt-service (LiveKit auth bridge)              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
            │                    │                    │
            ▼                    ▼                    ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│ PostgreSQL       │  │ Redis (Synapse)  │  │ Redis (LiveKit)  │
│ CNPG Cluster     │  │ Sentinel (3 rep) │  │ Sentinel (3 rep) │
│ 3 instances      │  │ Stable Service   │  │ Native Support   │
│ Sync repl ANY 1  │  └──────────────────┘  └──────────────────┘
│ switchoverDelay: │
│ 300 seconds      │
└──────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────────────────┐
│                    STORAGE & WEBRTC                           │
│  MinIO (4 nodes, EC:4)    coturn (2 nodes)    LiveKit (4 nodes) │
│  S3 media storage         TURN/STUN            Group video   │
└──────────────────────────────────────────────────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────────────────┐
│                     MONITORING                                 │
│  Prometheus + Grafana + Loki (no Alertmanager)              │
└──────────────────────────────────────────────────────────────┘
```

### Resource Requirements

**Total Nodes:** 21 (3 control plane + 18 workers)
**Total vCPU:** 340 cores
**Total RAM:** 936 GiB
**Total Storage:** 15.2 TiB

See [ARCHITECTURE_FINAL_V2.md](../ARCHITECTURE_FINAL_V2.md) for detailed resource allocation.

---

## Prerequisites

### Required Tools

- **Kubernetes cluster** (v1.26+) with 21 nodes
  - 3 control plane nodes
  - 18 worker nodes (various roles)
- **kubectl** (v1.26+) configured to access your cluster
- **Helm** (v3.12+) for package management
- **bash** for running deployment scripts

### Cluster Requirements

1. **Storage Classes** configured:
   - General storage (for most workloads)
   - Fast storage for databases (NVMe/SSD preferred)
   - Large storage for MinIO (object storage)

2. **Node Labels** (will be applied during deployment):
   - 4 nodes for LiveKit: `livekit=true`
   - 2 nodes for coturn: `coturn=true`

3. **Network Requirements**:
   - L2 network for MetalLB (or BGP-capable router)
   - IP range available for LoadBalancer services (10-20 IPs)
   - Nodes can communicate with each other
   - Optional: External access for clients (if not air-gapped)

4. **Firewall/Security**:
   - Kubernetes API accessible from deployment machine
   - Inter-node communication allowed (all ports)
   - External access to LoadBalancer IPs (for clients)

### Knowledge Requirements

- Basic Kubernetes concepts (pods, services, deployments)
- Basic Helm usage
- Basic Matrix/Synapse administration
- Optional: PostgreSQL, Redis, S3 storage concepts

---

## Quick Start

### 1. Clone and Prepare

```bash
# Navigate to deployment directory
cd deployment/

# Copy example configuration
cp config/deployment.env.example config/deployment.env

# Edit configuration with your values
nano config/deployment.env
# OR
vim config/deployment.env
```

### 2. Review Architecture

```bash
# Read the architecture document
less ../ARCHITECTURE_FINAL_V2.md

# Understand what will be deployed
ls -la values/    # Helm values files
ls -la manifests/ # Kubernetes manifests
```

### 3. Deploy

```bash
# Run complete deployment (automated)
./scripts/deploy-all.sh

# OR deploy manually step-by-step (see Deployment Steps section)
```

### 4. Verify

```bash
# Check all pods are running
kubectl get pods -A

# Check services
kubectl get svc -A | grep LoadBalancer

# Get LoadBalancer IP
kubectl get svc nginx-ingress-ingress-nginx-controller -n ingress-nginx
```

### 5. Create Admin User

```bash
# Find Synapse main pod
SYNAPSE_POD=$(kubectl get pod -n matrix -l component=main -o jsonpath='{.items[0].metadata.name}')

# Create admin user
kubectl exec -n matrix $SYNAPSE_POD -- \
  register_new_matrix_user \
  -c /config/homeserver.yaml \
  -u admin \
  -p <your-secure-password> \
  -a \
  http://localhost:8008
```

### 6. Access

```bash
# Add DNS record pointing your domain to LoadBalancer IP
# Example: chat.z3r0d3v.com → 192.168.1.240

# Access Element Web
https://chat.z3r0d3v.com

# Access Grafana (port-forward)
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open: http://localhost:3000 (admin / <GRAFANA_ADMIN_PASSWORD>)
```

---

## Directory Structure

```
deployment/
├── README.md                          # This file
├── config/
│   ├── deployment.env.example         # Configuration template
│   └── deployment.env                 # Your configuration (gitignored)
├── values/                            # Helm values files
│   ├── cert-manager-values.yaml
│   ├── cloudnativepg-values.yaml
│   ├── livekit-values.yaml
│   ├── loki-values.yaml
│   ├── metallb-values.yaml
│   ├── minio-operator-values.yaml
│   ├── nginx-ingress-values.yaml
│   ├── prometheus-stack-values.yaml
│   ├── redis-livekit-values.yaml
│   └── redis-synapse-values.yaml
├── manifests/                         # Kubernetes manifests
│   ├── 00-namespaces.yaml
│   ├── 01-postgresql-cluster.yaml
│   ├── 02-minio-tenant.yaml
│   ├── 03-metallb-config.yaml
│   ├── 04-coturn.yaml
│   └── 05-synapse-main.yaml
└── scripts/                           # Deployment scripts
    └── deploy-all.sh                  # Main deployment script
```

---

## Configuration

### Required Configuration Steps

1. **Copy configuration template:**
   ```bash
   cp config/deployment.env.example config/deployment.env
   ```

2. **Edit deployment.env and fill in ALL values:**

   **Critical values to change:**
   - `MATRIX_DOMAIN`: Your Matrix server domain (e.g., chat.z3r0d3v.com)
   - `STORAGE_CLASS_*`: Your Kubernetes storage class names
   - `METALLB_IP_RANGE`: Available IP range for LoadBalancer services
   - `POSTGRES_PASSWORD`: Strong password for PostgreSQL
   - `MINIO_ROOT_PASSWORD`: Strong password for MinIO admin
   - `SYNAPSE_*_SECRET`: Generate random secrets (use `openssl rand -base64 32`)
   - `COTURN_SHARED_SECRET`: Shared secret for TURN auth
   - `COTURN_NODE*_IP`: IP addresses of nodes where coturn will run
   - `LIVEKIT_API_KEY/SECRET`: Generate random API credentials
   - `GRAFANA_ADMIN_PASSWORD`: Strong password for Grafana
   - `ADMIN_IP_WHITELIST`: IP ranges allowed to access admin interfaces

3. **Validate configuration:**
   ```bash
   # Source the config to check for errors
   source config/deployment.env

   # Verify critical variables
   echo "Domain: $MATRIX_DOMAIN"
   echo "Storage Class: $STORAGE_CLASS_GENERAL"
   ```

### Generating Secrets

```bash
# Generate random secrets
openssl rand -base64 32

# Generate Synapse signing key
docker run -it --rm -v $(pwd):/data matrixdotorg/synapse:latest generate

# Generate LiveKit API key/secret
openssl rand -hex 16  # API key
openssl rand -base64 32  # API secret
```

---

## Deployment Steps

### Automated Deployment (Recommended)

```bash
./scripts/deploy-all.sh
```

This script will:
1. Check prerequisites
2. Load and validate configuration
3. Deploy all components in correct order
4. Wait for readiness checks
5. Provide post-deployment instructions

### Manual Deployment (Step-by-Step)

If you prefer manual control:

#### 1. Create Namespaces
```bash
kubectl apply -f manifests/00-namespaces.yaml
```

#### 2. Add Helm Repositories
```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add minio-operator https://operator.min.io
helm repo add metallb https://metallb.github.io/metallb
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add livekit https://helm.livekit.io
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

#### 3. Install cert-manager
```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --values values/cert-manager-values.yaml \
  --wait
```

#### 4. Install MetalLB
```bash
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --values values/metallb-values.yaml \
  --wait

# Configure IP pool
kubectl apply -f manifests/03-metallb-config.yaml
```

#### 5. Install NGINX Ingress
```bash
helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values values/nginx-ingress-values.yaml \
  --wait
```

#### 6. Install PostgreSQL
```bash
helm upgrade --install cloudnativepg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --values values/cloudnativepg-values.yaml \
  --wait

kubectl apply -f manifests/01-postgresql-cluster.yaml
```

#### 7. Install Redis (Synapse + LiveKit)
```bash
helm upgrade --install redis-synapse bitnami/redis \
  --namespace redis-synapse \
  --values values/redis-synapse-values.yaml \
  --wait

helm upgrade --install redis-livekit bitnami/redis \
  --namespace redis-livekit \
  --values values/redis-livekit-values.yaml \
  --wait
```

#### 8. Install MinIO
```bash
helm upgrade --install minio-operator minio-operator/operator \
  --namespace minio-operator \
  --values values/minio-operator-values.yaml \
  --wait

kubectl apply -f manifests/02-minio-tenant.yaml
```

#### 9. Deploy coturn
```bash
# Label nodes
kubectl label node <node1> coturn=true
kubectl label node <node2> coturn=true

# Deploy
kubectl apply -f manifests/04-coturn.yaml
```

#### 10. Deploy LiveKit
```bash
# Label nodes
kubectl label node <node1> livekit=true
kubectl label node <node2> livekit=true
kubectl label node <node3> livekit=true
kubectl label node <node4> livekit=true

# Deploy
helm upgrade --install livekit livekit/livekit-server \
  --namespace livekit \
  --values values/livekit-values.yaml \
  --set kind=DaemonSet \
  --wait
```

#### 11. Install Monitoring
```bash
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values/prometheus-stack-values.yaml \
  --wait

helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --values values/loki-values.yaml \
  --wait
```

#### 12. Deploy Synapse
```bash
kubectl apply -f manifests/05-synapse-main.yaml
```

---

## Post-Deployment

### 1. Verify All Services

```bash
# Check all pods are running
kubectl get pods -A

# Check services
kubectl get svc -A

# Check persistent volume claims
kubectl get pvc -A

# Check ingress
kubectl get ingress -A
```

### 2. Get LoadBalancer IP

```bash
INGRESS_IP=$(kubectl get svc nginx-ingress-ingress-nginx-controller \
  -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "LoadBalancer IP: $INGRESS_IP"
```

### 3. Configure DNS

Add DNS A record:
```
chat.z3r0d3v.com  →  <LOADBALANCER_IP>
```

### 4. Verify TLS Certificates

```bash
# Check certificate status
kubectl get certificate -A

# Describe certificate
kubectl describe certificate matrix-tls -n matrix
```

### 5. Create Admin User

```bash
SYNAPSE_POD=$(kubectl get pod -n matrix -l component=main -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n matrix $SYNAPSE_POD -- \
  register_new_matrix_user \
  -c /config/homeserver.yaml \
  -u admin \
  -p <secure-password> \
  -a \
  http://localhost:8008
```

### 6. Access Grafana

```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Open browser: http://localhost:3000
# Login: admin / <GRAFANA_ADMIN_PASSWORD from deployment.env>
```

### 7. Import Synapse Dashboard

1. In Grafana, go to Dashboards → Import
2. Download Synapse dashboard from: https://github.com/element-hq/synapse/tree/develop/contrib/grafana
3. Import JSON
4. Select Prometheus datasource

---

## Validation & Testing

### Health Checks

```bash
# Synapse health
kubectl exec -n matrix <synapse-pod> -- curl -s http://localhost:8008/health

# PostgreSQL status
kubectl get cluster -n matrix

# Redis status
kubectl get pods -n redis-synapse
kubectl get pods -n redis-livekit

# MinIO status
kubectl get tenant -n minio
```

### Functional Tests

1. **User Login:**
   - Access https://chat.z3r0d3v.com
   - Login with admin credentials
   - Verify successful login

2. **Create Room:**
   - Create a new room
   - Send messages
   - Verify messages appear

3. **Upload File:**
   - Upload an image/file
   - Verify upload succeeds
   - Verify file displays correctly

4. **VoIP Call (1:1):**
   - Start 1:1 voice/video call
   - Verify call establishes (uses coturn)
   - Check for audio/video

5. **Group Video (Element Call):**
   - Create room with Element Call widget
   - Start group call with 3+ participants
   - Verify video works (uses LiveKit)

### Monitoring Checks

```bash
# Check Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open: http://localhost:9090/targets
# Verify all targets are UP

# View Synapse metrics
curl -s http://synapse-main.matrix.svc.cluster.local:9000/_synapse/metrics
```

---

## Scaling

### Vertical Scaling (More Resources)

Edit values files or manifests to increase CPU/memory:

```bash
# Edit PostgreSQL resources
kubectl edit cluster synapse-postgres -n matrix

# Edit Synapse resources
kubectl edit deployment synapse-main -n matrix
```

### Horizontal Scaling (More Replicas)

#### Add More Workers
```bash
# Edit worker counts in Synapse configuration
# Deploy additional worker deployments
```

#### Add More PostgreSQL Replicas
```bash
kubectl cnpg scale synapse-postgres --replicas=5 -n matrix
```

#### Add More MinIO Servers
```bash
kubectl edit tenant synapse-media -n minio
# Increase servers count in pool
```

#### Add More coturn Instances
```bash
# Label additional nodes
kubectl label node <new-node> coturn=true

# coturn DaemonSet will automatically deploy to new node
```

#### Add More LiveKit Instances
```bash
# Label additional nodes
kubectl label node <new-node> livekit=true

# LiveKit DaemonSet will automatically deploy
```

---

## Troubleshooting

### Common Issues

#### 1. Pods Stuck in Pending

**Check:**
```bash
kubectl describe pod <pod-name> -n <namespace>
```

**Common causes:**
- Insufficient resources
- Storage class not available
- Node selector not matching

**Fix:**
- Scale up cluster
- Create/fix storage class
- Label nodes correctly

#### 2. LoadBalancer IP Stuck in Pending

**Check:**
```bash
kubectl describe svc nginx-ingress-ingress-nginx-controller -n ingress-nginx
```

**Common causes:**
- MetalLB not installed
- IP pool not configured
- IP range conflicts with network

**Fix:**
```bash
kubectl apply -f manifests/03-metallb-config.yaml
# Verify IP range is correct and available
```

#### 3. TLS Certificate Not Issuing

**Check:**
```bash
kubectl get certificaterequest -A
kubectl describe certificate matrix-tls -n matrix
```

**Common causes:**
- DNS not pointing to LoadBalancer
- Let's Encrypt rate limit
- HTTP-01 challenge failing

**Fix:**
- Verify DNS: `nslookup chat.z3r0d3v.com`
- Check ingress is accessible
- Use staging issuer first

#### 4. Synapse Cannot Connect to PostgreSQL

**Check:**
```bash
kubectl logs -n matrix <synapse-pod>
kubectl get cluster synapse-postgres -n matrix
```

**Common causes:**
- PostgreSQL not ready
- Wrong credentials
- Network policy blocking

**Fix:**
- Wait for PostgreSQL cluster to be ready
- Verify credentials in secrets
- Check network policies

#### 5. coturn/LiveKit Not Working

**Check:**
```bash
kubectl logs -n coturn <coturn-pod>
kubectl logs -n livekit <livekit-pod>
```

**Common causes:**
- Node not labeled
- hostNetwork conflicts
- Firewall blocking UDP

**Fix:**
- Label nodes: `kubectl label node <node> coturn=true`
- Check node firewall rules
- Verify UDP ports are open

### Logs

```bash
# View logs for any component
kubectl logs -n <namespace> <pod-name>

# Follow logs
kubectl logs -n <namespace> <pod-name> -f

# View logs from all replicas
kubectl logs -n <namespace> -l app=<label>

# View Loki logs via Grafana Explore
```

### Debugging

```bash
# Execute shell in pod
kubectl exec -it -n <namespace> <pod-name> -- /bin/bash

# Port-forward to service
kubectl port-forward -n <namespace> svc/<service-name> <local-port>:<service-port>

# View events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Describe resource
kubectl describe <resource-type> <resource-name> -n <namespace>
```

---

## Maintenance

### Regular Tasks

#### Weekly

- Review Grafana dashboards for anomalies
- Check disk usage on all PVCs
- Review error logs in Loki

#### Monthly

- Update Synapse and workers to latest stable version
- Review and rotate credentials
- Test backup restore procedure
- Review and update firewall rules

#### Quarterly

- Perform disaster recovery drill
- Review and optimize resource allocations
- Audit user permissions
- Update all Helm charts to latest versions

### Updates

#### Update Synapse

```bash
# Edit deployment to use new image
kubectl set image deployment/synapse-main \
  synapse=matrixdotorg/synapse:v1.103.0 \
  -n matrix

# Rollout status
kubectl rollout status deployment/synapse-main -n matrix
```

#### Update Helm Charts

```bash
# Update Helm repos
helm repo update

# Upgrade chart
helm upgrade <release-name> <chart> \
  --namespace <namespace> \
  --values values/<values-file>.yaml
```

### Backups

#### PostgreSQL Backups

Backups are automated via CloudNativePG:

```bash
# View backup schedule
kubectl get scheduledbackup -n matrix

# Trigger manual backup
kubectl cnpg backup synapse-postgres -n matrix

# List backups
kubectl get backup -n matrix
```

#### Restore from Backup

```bash
# See CloudNativePG documentation for restore procedures
kubectl cnpg restore --help
```

### Monitoring Alerts

Configure alerts in Prometheus/Grafana:

- Pod restarts
- High CPU/memory usage
- Database replication lag
- Storage capacity warnings
- Certificate expiry warnings

---

## Support & Resources

### Documentation

- Complete architecture: [ARCHITECTURE_FINAL_V2.md](../ARCHITECTURE_FINAL_V2.md)
- Original architecture: [FINAL_ARCHITECTURE.md](../FINAL_ARCHITECTURE.md)
- Synapse docs: https://matrix-org.github.io/synapse/latest/
- Element docs: https://element.io/docs
- CloudNativePG docs: https://cloudnative-pg.io/documentation/
- LiveKit docs: https://docs.livekit.io/

### Community

- Matrix Community: https://matrix.to/#/#synapse:matrix.org
- Kubernetes Community: https://kubernetes.io/community/
- Reddit: /r/matrix, /r/kubernetes

### Troubleshooting Help

1. Check logs first: `kubectl logs -n <namespace> <pod>`
2. Review architecture document for configuration details
3. Search GitHub issues for similar problems
4. Ask in Matrix community rooms

---

## License

See main repository LICENSE file.

---

## Version History

- **v2.0** (Current): Validated architecture with critical fixes
- **v1.0**: Initial architecture (contained critical errors)

---

**Deployment Package Version:** 2.0
**Last Updated:** November 10, 2025
**Architecture Validation:** Complete ✓
