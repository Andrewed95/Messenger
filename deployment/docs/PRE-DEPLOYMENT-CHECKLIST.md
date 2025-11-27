# Pre-Deployment Checklist for Matrix/Synapse Production

## Overview
This checklist ensures all components are properly configured and ready for deployment.

---

## 🏢 Organization Prerequisites (MUST BE PROVIDED EXTERNALLY)

**This section lists requirements the organization MUST fulfill BEFORE deployment can begin.**

The deployer has SSH access to servers and handles all configuration and deployment. However, the following items **cannot be done via SSH** and must be provided/configured by the organization's IT infrastructure team.

### 1. Server Provisioning

**The organization MUST provide:**

| Item | Minimum Requirement | Description |
|------|---------------------|-------------|
| **Servers** | See SCALING-GUIDE.md | Debian 11/12 servers (physical or VM) |
| **Root/Sudo SSH Access** | All servers | Deployer needs root access via SSH |
| **Internal Network** | 1 Gbps+ | All servers can communicate internally |
| **Internet Access (initial)** | Temporary | For installing packages and pulling images |

**Server Types Required:**
- **Control Plane Nodes**: 3 servers minimum (Kubernetes masters)
- **Worker Nodes**: Varies by scale (see SCALING-GUIDE.md)
- **Storage Nodes**: For PostgreSQL, MinIO (can be worker nodes)
- **LI Server(s)**: 1+ servers for LI instance (separate network)
- **Monitoring Server**: 1 server for Prometheus/Grafana

### 2. External DNS Records

**The organization's DNS administrator MUST create:**

**Main Instance DNS (Public):**
| Record Type | Name | Points To | Purpose |
|-------------|------|-----------|---------|
| A | `matrix.example.com` | Main Ingress External IP | Synapse homeserver |
| A | `chat.example.com` | Main Ingress External IP | Element Web client |
| A | `turn.example.com` | TURN Server External IP | TURN/STUN for WebRTC |

**LI Instance DNS (Internal LI Network Only):**
| Record Type | Name | Points To | Purpose |
|-------------|------|-----------|---------|
| A | `matrix.example.com` | LI Ingress IP | Synapse LI (SAME hostname) |
| A | `chat-li.example.com` | LI Ingress IP | Element Web LI (DIFFERENT) |
| A | `admin-li.example.com` | LI Ingress IP | Synapse Admin LI (DIFFERENT) |
| A | `keyvault.example.com` | LI Ingress IP | key_vault Django admin (DIFFERENT) |

**Notes:**
- Replace `example.com` with your actual domain
- External IP is provided AFTER Kubernetes cluster is deployed
- Deployer will provide the IP addresses once cluster is ready
- LI DNS records should only be resolvable from the LI network

### 3. Network/Firewall Configuration

**The organization's network team MUST configure the ports listed below.**

**IMPORTANT**:
- EXTERNAL firewall rules are configured on the organization's network perimeter (routers, firewalls)
- Host-level firewall rules (ufw) on individual servers are handled by the deployer via SSH
- Internal ports are between servers within the cluster (typically already allowed on internal network)

---

#### 3.1 External Ports (Internet-Facing)

**These ports must be open on the organization's external firewall/router.**

| Port | Protocol | Direction | Server Type | Purpose |
|------|----------|-----------|-------------|---------|
| **443** | TCP | Inbound | Ingress Node(s) | HTTPS - All web traffic (Synapse, Element, Admin) |
| **80** | TCP | Inbound | Ingress Node(s) | HTTP - cert-manager ACME validation only |
| **3478** | TCP | Inbound | TURN Server | TURN/STUN signaling (NAT traversal) |
| **3478** | UDP | Inbound | TURN Server | TURN/STUN signaling (NAT traversal) |
| **5349** | TCP | Inbound | TURN Server | TURN over TLS (secure NAT traversal) |
| **49152-65535** | UDP | Inbound | TURN Server | TURN media relay (voice/video streams) |
| **7881** | TCP | Inbound | LiveKit Server | WebRTC signaling (if LiveKit exposed externally) |
| **7882** | UDP | Inbound | LiveKit Server | WebRTC UDP (if LiveKit exposed externally) |

**NAT/Port Forwarding Required:**
- Port 443/80 → Ingress Controller external IP
- Ports 3478, 5349, 49152-65535 → TURN server external IP
- Ports 7881-7882 → LiveKit server external IP (if external access required)

---

#### 3.2 Kubernetes Cluster Ports (Inter-Node)

**These ports must be open between ALL Kubernetes nodes (Control Plane + Worker + Storage).**

| Port | Protocol | Direction | From → To | Purpose |
|------|----------|-----------|-----------|---------|
| **6443** | TCP | Both | All nodes ↔ Control plane | Kubernetes API server |
| **2379-2380** | TCP | Both | Control plane ↔ Control plane | etcd server/client |
| **10250** | TCP | Both | All nodes ↔ All nodes | Kubelet API |
| **10259** | TCP | Both | Control plane ↔ Control plane | kube-scheduler |
| **10257** | TCP | Both | Control plane ↔ Control plane | kube-controller-manager |
| **30000-32767** | TCP | Both | All nodes ↔ All nodes | NodePort Services |
| **30000-32767** | UDP | Both | All nodes ↔ All nodes | NodePort Services (UDP) |
| **179** | TCP | Both | All nodes ↔ All nodes | Calico BGP (if using Calico CNI) |
| **4789** | UDP | Both | All nodes ↔ All nodes | VXLAN overlay (Flannel/Calico) |
| **8472** | UDP | Both | All nodes ↔ All nodes | VXLAN (Flannel) |
| **51820** | UDP | Both | All nodes ↔ All nodes | WireGuard (Calico encryption) |
| **51821** | UDP | Both | All nodes ↔ All nodes | WireGuard (Calico encryption) |

---

#### 3.3 Application Service Ports (Internal Kubernetes)

**These ports are used between services WITHIN the Kubernetes cluster. They typically do NOT need external firewall rules unless pods are scheduled across different network segments.**

| Port | Protocol | Service | From → To | Purpose |
|------|----------|---------|-----------|---------|
| **5432** | TCP | PostgreSQL | Synapse, sync → PostgreSQL | Database connections |
| **6379** | TCP | Redis | Synapse workers → Redis | Cache/session storage |
| **26379** | TCP | Redis Sentinel | Synapse workers → Redis | Sentinel for HA failover |
| **9000** | TCP | MinIO | Synapse, sync → MinIO | S3 API (media storage) |
| **9001** | TCP | MinIO | Admin → MinIO | Console UI |
| **8008** | TCP | Synapse | HAProxy → Synapse | Client API |
| **8083** | TCP | Synapse | HAProxy → Workers | Replication endpoint |
| **9093** | TCP | Synapse | Workers ↔ Workers | Worker internal communication |
| **8080** | TCP | Content Scanner | Synapse → Scanner | Antivirus scanning |
| **3310** | TCP | ClamAV | Scanner → ClamAV | ClamAV daemon |
| **8000** | TCP | key_vault | Synapse Main (store), LI Admin (retrieve) → key_vault (LI network) | E2EE recovery key storage |
| **7880** | TCP | LiveKit | Clients → LiveKit | HTTP API |
| **7881** | TCP | LiveKit | Clients → LiveKit | WebRTC signaling |
| **50000-60000** | UDP | LiveKit | Clients → LiveKit | WebRTC media |
| **3000** | TCP | Grafana | Monitoring → Grafana | Dashboard UI |
| **9090** | TCP | Prometheus | Monitoring → Prometheus | Metrics UI/API |
| **9090** | TCP | Synapse metrics | Prometheus → Synapse | Scrape metrics |
| **9121** | TCP | Redis exporter | Prometheus → Redis | Scrape Redis metrics |
| **9187** | TCP | PostgreSQL exporter | Prometheus → PostgreSQL | Scrape DB metrics |
| **3100** | TCP | Loki | Promtail → Loki | Log ingestion |

---

#### 3.4 Port Requirements by Server Type

**Control Plane Nodes (3 servers):**
| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22 | TCP | Inbound | SSH (management) |
| 6443 | TCP | Inbound | Kubernetes API |
| 2379-2380 | TCP | Inbound | etcd cluster |
| 10250 | TCP | Inbound | Kubelet |
| 10259 | TCP | Inbound | kube-scheduler |
| 10257 | TCP | Inbound | kube-controller-manager |

**Application/Worker Nodes (3+ servers):**
| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22 | TCP | Inbound | SSH (management) |
| 10250 | TCP | Inbound | Kubelet |
| 30000-32767 | TCP/UDP | Both | NodePort services |
| 4789/8472 | UDP | Both | CNI overlay network |

**Database Nodes (3 servers):**
| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22 | TCP | Inbound | SSH (management) |
| 10250 | TCP | Inbound | Kubelet |
| 5432 | TCP | Inbound | PostgreSQL (from app nodes) |

**Storage Nodes (4 servers):**
| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22 | TCP | Inbound | SSH (management) |
| 10250 | TCP | Inbound | Kubelet |
| 9000 | TCP | Inbound | MinIO S3 API |
| 9001 | TCP | Inbound | MinIO Console |

**Call Servers (2+ servers):**
| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22 | TCP | Inbound | SSH (management) |
| 10250 | TCP | Inbound | Kubelet |
| 3478 | TCP/UDP | Inbound (external) | TURN signaling |
| 5349 | TCP | Inbound (external) | TURN TLS |
| 49152-65535 | UDP | Inbound (external) | TURN media relay |
| 7880-7882 | TCP/UDP | Inbound | LiveKit |
| 50000-60000 | UDP | Inbound | LiveKit media |

**LI Server (1 server):**
| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22 | TCP | Inbound | SSH (management) |
| 10250 | TCP | Inbound | Kubelet |
| 443 | TCP | Inbound (LI network only) | HTTPS to LI services |
| 80 | TCP | Inbound (LI network only) | HTTP redirect |
| 8000 | TCP | Inbound (from main Synapse) | key_vault API (cross-network) |

**Monitoring Server (1 server):**
| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22 | TCP | Inbound | SSH (management) |
| 10250 | TCP | Inbound | Kubelet |
| 9090 | TCP | Inbound (internal) | Prometheus |
| 3000 | TCP | Inbound (internal) | Grafana |
| 3100 | TCP | Inbound (internal) | Loki |

---

#### 3.5 Outbound Requirements

**From ALL servers (internet access during installation):**
| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Registry (docker.io, quay.io, etc.) | 443 | TCP | Pull container images |
| apt/package repos | 443, 80 | TCP | OS package installation |
| Helm chart repos | 443 | TCP | Helm chart downloads |

**After installation (air-gapped operation):**
- No outbound internet required
- All traffic is internal between servers

---

#### 3.6 Network Summary Diagram

```
INTERNET
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  EXTERNAL FIREWALL                                   │
│  Open: 443, 80 → Ingress                            │
│  Open: 3478, 5349, 49152-65535 → TURN               │
└─────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  MAIN NETWORK                                        │
│                                                      │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐             │
│  │Control  │  │Control  │  │Control  │             │
│  │Plane 1  │──│Plane 2  │──│Plane 3  │             │
│  │6443,2379│  │6443,2379│  │6443,2379│             │
│  └────┬────┘  └────┬────┘  └────┬────┘             │
│       │           │           │                     │
│  ┌────┴───────────┴───────────┴────┐               │
│  │        Kubernetes API            │               │
│  └─────────────────────────────────┘               │
│       │                                             │
│       ▼                                             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐             │
│  │App Node │  │App Node │  │App Node │ (Synapse,   │
│  │  8008   │──│  8008   │──│  8008   │  Element,   │
│  │ Workers │  │ Workers │  │ Workers │  HAProxy)   │
│  └────┬────┘  └────┬────┘  └────┬────┘             │
│       │           │           │                     │
│  ┌────┴───────────┴───────────┴────┐               │
│  │                                  │               │
│  ▼                                  ▼               │
│  ┌─────────────────┐  ┌─────────────────┐          │
│  │ Database Nodes  │  │  Storage Nodes  │          │
│  │ PostgreSQL 5432 │  │  MinIO 9000     │          │
│  └─────────────────┘  └─────────────────┘          │
│                                                      │
│  ┌─────────────────┐  ┌─────────────────┐          │
│  │ Call Servers    │  │ Monitoring      │          │
│  │ TURN 3478       │  │ Prometheus 9090 │          │
│  │ LiveKit 7881    │  │ Grafana 3000    │          │
│  └─────────────────┘  └─────────────────┘          │
└─────────────────────────────────────────────────────┘
                    │
                    │ (Sync System only)
                    ▼
┌─────────────────────────────────────────────────────┐
│  LI NETWORK (Isolated)                               │
│                                                      │
│  ┌─────────────────┐                                │
│  │ LI Server       │                                │
│  │ Synapse LI 8008 │                                │
│  │ Element LI 80   │                                │
│  │ Admin LI 80     │                                │
│  └─────────────────┘                                │
│                                                      │
│  Access: LI network DNS → LI Ingress (443)          │
└─────────────────────────────────────────────────────┘
```

### 4. LI Network Isolation (Organization Responsibility)

**For Lawful Intercept functionality, the organization MUST provide:**

| Requirement | Description |
|-------------|-------------|
| **Separate LI Network** | Physically or logically isolated network segment |
| **LI DNS Server** | DNS that resolves LI domains to LI Ingress IP (see below) |
| **Access Control** | VPN, firewall, or physical access restriction |
| **LI Server(s)** | 1+ servers in the LI network segment |

**LI Domain Strategy:**
- **Synapse LI** uses **SAME** hostname as main (`matrix.example.com`) - required for Matrix protocol
- **Element Web LI, Synapse Admin LI, key_vault** use **DIFFERENT** hostnames from main

| Service | Domain | Same as Main? |
|---------|--------|---------------|
| Synapse LI | `matrix.example.com` | YES (required) |
| Element Web LI | `chat-li.example.com` | NO |
| Synapse Admin LI | `admin-li.example.com` | NO |
| key_vault | `keyvault.example.com` | NO |

**How LI Access Works:**
- LI admin connects to LI network → LI DNS resolves to LI Ingress
- Access Element Web LI at `https://chat-li.example.com`
- Access Synapse Admin LI at `https://admin-li.example.com`
- Access key_vault admin at `https://keyvault.example.com/admin`

**Required DNS Configuration:**

```
# Main DNS (regular users)
matrix.example.com    →  10.0.1.100  (Main Ingress)
chat.example.com      →  10.0.1.100  (Main Ingress)

# LI DNS (LI network only)
matrix.example.com    →  10.0.2.100  (LI Ingress - Synapse LI)
chat-li.example.com   →  10.0.2.100  (LI Ingress - Element Web LI)
admin-li.example.com  →  10.0.2.100  (LI Ingress - Synapse Admin LI)
keyvault.example.com  →  10.0.2.100  (LI Ingress - key_vault)
```

### 5. TLS Certificates

**The organization MUST provide ONE of:**

| Option | Description | Best For |
|--------|-------------|----------|
| **Wildcard Certificate** | `*.example.com` cert + private key | Simplest, air-gapped |
| **DNS Provider API Access** | API credentials for DNS-01 challenge | Automatic renewal |
| **Manual Certificates** | Individual certs for each hostname | Full control |

**If providing certificates manually:**
- Certificate file (PEM format)
- Private key file (PEM format)
- CA chain if not publicly trusted

**If using cert-manager with DNS-01:**
- DNS provider API key/token
- Access to create DNS TXT records

### 6. Optional External Services

**If the organization wants these features:**

| Feature | External Requirement |
|---------|---------------------|
| **Push Notifications** | Apple/Google push credentials (requires internet) |
| **Federation** | External DNS SRV records, open port 8448 |
| **SMTP Notifications** | SMTP server credentials |

**Note**: These are disabled by default for air-gapped deployments.

---

## 🔧 Deployer Responsibilities (Handled via SSH)

**The deployer handles ALL of the following via SSH access:**

| Category | Tasks |
|----------|-------|
| **OS Configuration** | Package installation, kernel tuning, service configuration |
| **Host Firewall** | ufw rules on individual servers |
| **Kubernetes** | Cluster installation, configuration, networking |
| **Application Deployment** | All Kubernetes manifests, secrets, configurations |
| **Internal DNS** | CoreDNS configuration within cluster |
| **Storage** | Local storage provisioning, PV/PVC configuration |
| **Monitoring** | Prometheus, Grafana, alerting setup |
| **Backups** | Backup job configuration, scheduling |
| **Security** | NetworkPolicies, RBAC, pod security |

---

## ✅ Pre-Deployment Information Gathering

**Before starting deployment, collect this information from the organization:**

### From Organization IT Team:

```
[ ] Primary domain name: _________________________ (e.g., example.com)
[ ] Number of expected concurrent users (CCU): _____
[ ] Air-gapped deployment? Yes / No
[ ] Federation enabled? Yes / No

Server Information:
[ ] Control plane nodes: (list IPs)
    1. _____________
    2. _____________
    3. _____________
[ ] Worker nodes: (list IPs)
    1. _____________
    2. _____________
    ... (continue as needed)
[ ] LI network servers: (list IPs)
    1. _____________

Network Information:
[ ] External IP for main Ingress: _____________
[ ] External IP for TURN server: _____________
[ ] External IP for LI Ingress (if separate): _____________
[ ] Internal network CIDR: _____________ (e.g., 10.0.0.0/16)
[ ] Pod network CIDR: _____________ (default: 10.244.0.0/16)
[ ] Service network CIDR: _____________ (default: 10.96.0.0/12)

TLS Certificates:
[ ] Certificate provisioning method:
    [ ] Organization provides wildcard cert
    [ ] Organization provides individual certs
    [ ] cert-manager with DNS-01 (provide API credentials)
    [ ] cert-manager with HTTP-01 (requires port 80 open)
    [ ] Self-signed (for testing only)

LI Network:
[ ] LI DNS server IP: _____________
[ ] LI network CIDR: _____________ (e.g., 10.0.2.0/24)
[ ] How LI admins access LI network: VPN / Physical / Other: _______
```

### Deployer Generates:

The deployer generates all secrets and credentials during deployment using the provided scripts. The organization does NOT need to provide:
- Database passwords
- API keys
- Encryption keys
- Redis passwords
- MinIO credentials

---

## ✅ Phase 1: Infrastructure Components

### 1. PostgreSQL (CloudNativePG)
- [ ] **Verify cluster configurations exist:**
  - [ ] `infrastructure/01-postgresql/cluster.yaml` - Main cluster
  - [ ] `infrastructure/01-postgresql/cluster-li.yaml` - LI cluster
- [ ] **Check secrets are defined:**
  - [ ] Main cluster superuser secret: `matrix-postgresql-superuser`
  - [ ] LI cluster superuser secret: `matrix-postgresql-li-superuser`
- [ ] **Validate resource allocations match scaling guide:**
  - [ ] 100 CCU: 2Gi memory, 1 CPU, 50Gi storage
  - [ ] Scaling increments properly defined

### 2. Redis Sentinel
- [ ] **Verify Redis password secret exists:**
  ```yaml
  # infrastructure/02-redis/redis-statefulset.yaml
  kind: Secret
  name: redis-password
  data:
    password: <base64-encoded-password>
  ```
- [ ] **Check runtime configuration:**
  - [ ] Init container properly substitutes password
  - [ ] Sentinel configuration uses secret reference
  - [ ] All 3 sentinel replicas configured

### 3. MinIO Storage
- [ ] **Validate erasure coding configuration:**
  - [ ] EC:4 properly configured (4 data + 4 parity)
  - [ ] 8 total drives (2 per server × 4 servers)
  - [ ] Storage calculations: 50% efficiency confirmed
- [ ] **Check secrets format:**
  - [ ] Dual-format secret for CloudNativePG compatibility
  - [ ] Both `access-key`/`secret-key` and `CONSOLE_ACCESS_KEY`/`CONSOLE_SECRET_KEY`

### 4. Networking
- [ ] **NetworkPolicy namespace selectors fixed:**
  ```yaml
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["kube-system"]  # or ["ingress-nginx"]
  ```
- [ ] **Verify all 13 NetworkPolicies:**
  - [ ] DNS access (`allow-dns`)
  - [ ] Database access policies
  - [ ] key_vault isolation
  - [ ] LI instance isolation
  - [ ] Ingress access

## ✅ Phase 2: Main Instance Components

### 1. Synapse Main Process
- [ ] **S3 storage provider installation verified:**
  ```yaml
  # main-instance/01-synapse/main-statefulset.yaml
  - name: install-s3-provider
    command:
      - pip install --user synapse-s3-storage-provider==1.4.0
  ```
- [ ] **Volume mounts include Python packages:**
  ```yaml
  - name: python-packages
    mountPath: /usr/local/lib/python3.11/site-packages
  ```

### 2. HAProxy Load Balancer
- [ ] **ServiceMonitor metrics path corrected:**
  ```yaml
  # monitoring/01-prometheus/servicemonitors.yaml
  endpoints:
    - port: stats
      path: /stats;csv  # Not /metrics
  ```
- [ ] **Worker routing maps verified:**
  - [ ] All worker types properly mapped
  - [ ] Health check endpoints configured

### 3. key_vault Application (LI Network)
- [ ] **Django application structure created:**
  - [ ] Init container runs migrations
  - [ ] Models and views properly defined
- [ ] **SQLite database:**
  - [ ] Uses local SQLite file (no external database)
  - [ ] Data persisted on PVC (1Gi)
  - [ ] Automatic migrations on startup
- [ ] **Network access controlled (NetworkPolicy):**
  - [ ] Synapse main can STORE keys (cross-network access)
  - [ ] LI admin can RETRIEVE keys (within LI network)
  - [ ] All other access blocked
- [ ] **Deployed on LI Server:**
  - [ ] key_vault runs on LI server nodes (nodeSelector)
  - [ ] Located in `li-instance/05-key-vault/`

### 4. LiveKit SFU
- [ ] **Configuration substitution implemented:**
  ```yaml
  # main-instance/04-livekit/deployment.yaml
  initContainers:
    - name: generate-config
      command:
        - sed -i "s/API_KEY_PLACEHOLDER/${API_KEY}/g"
  ```
- [ ] **Redis connection verified:**
  - [ ] Password properly injected
  - [ ] Using separate DB (db: 1)

## ✅ Phase 3: LI Instance Components

### 1. Sync System
- [ ] **PostgreSQL replication fixed:**
  - [ ] Uses existing `synapse` user (not creating new)
  - [ ] Publication created with superuser privileges
  - [ ] Subscription properly configured
- [ ] **Credentials properly set:**
  ```yaml
  # Using postgres superuser for replication (required for CREATE SUBSCRIPTION)
  MAIN_DB_USER: "postgres"
  MAIN_DB_PASSWORD: <postgres-superuser-password>
  ```

### 2. LI Synapse Instance
- [ ] **Read-only configuration:**
  - [ ] `enable_registration: false`
  - [ ] `enable_room_list_search: false`
  - [ ] Database configured for LI cluster

## ✅ Phase 4: Auxiliary Services

### 1. Antivirus (ClamAV)
- [ ] **Content scanner configuration:**
  ```bash
  # Uses Python socket with zINSTREAM command to scan files
  # Configured in antivirus/02-scan-workers/deployment.yaml
  # ClamAV endpoint: clamav.matrix.svc.cluster.local:3310
  ```
- [ ] **Init container waits for ClamAV:**
  - [ ] Uses netcat to check port 3310 availability before starting
  - [ ] Scanner uses Python socket for actual scanning (zINSTREAM protocol)

### 2. Element Web
- [ ] **Configuration properly mounted:**
  - [ ] config.json with correct homeserver URL
  - [ ] PodDisruptionBudget configured

### 3. TURN Server (coturn)
- [ ] **Credentials match Synapse configuration:**
  - [ ] Shared secret consistent
  - [ ] Port ranges configured

## ✅ Phase 5: Monitoring

### 1. ServiceMonitors
- [ ] **All components have ServiceMonitors:**
  - [ ] Synapse workers
  - [ ] PostgreSQL (PodMonitors)
  - [ ] MinIO
  - [ ] HAProxy (correct path)
  - [ ] LiveKit
  - [ ] NGINX Ingress

### 2. Grafana Dashboards
- [ ] **Dashboard ConfigMaps exist:**
  - [ ] Synapse metrics
  - [ ] PostgreSQL metrics
  - [ ] System overview

## 🔧 Pre-Deployment Actions

### 1. Replace All Placeholder Values
Run this command to find all placeholders:
```bash
grep -r "CHANGEME" deployment/ --include="*.yaml" | grep -v "^#"
```

Required replacements:
- [ ] Database passwords (PostgreSQL, Redis)
- [ ] S3/MinIO credentials
- [ ] Django secret key for key_vault
- [ ] RSA private key for key_vault
- [ ] API keys (LiveKit, key_vault)
- [ ] JWT secrets
- [ ] Domain names (matrix.example.com)

### 2. Generate Secure Credentials

This section provides exact commands to generate all required secrets for the deployment.

#### 2.1 PostgreSQL Secrets

**Main Cluster Superuser Password:**
```bash
# Generate password
POSTGRES_PASSWORD=$(openssl rand -base64 32)
echo "Generated PostgreSQL password: $POSTGRES_PASSWORD"

# Base64 encode for Kubernetes secret
echo -n "$POSTGRES_PASSWORD" | base64
```

**Update in:** `infrastructure/01-postgresql/cluster.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: matrix-postgresql-superuser
stringData:
  username: postgres
  password: <paste-generated-password-here>  # Plain text, Kubernetes will encode
```

**LI Cluster Superuser Password:**
```bash
# Generate separate password for LI cluster
POSTGRES_LI_PASSWORD=$(openssl rand -base64 32)
echo "Generated PostgreSQL LI password: $POSTGRES_LI_PASSWORD"
```

**Update in:** `infrastructure/01-postgresql/cluster-li.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: matrix-postgresql-li-superuser
stringData:
  username: postgres
  password: <paste-generated-password-here>
```

**Application User Passwords (Auto-Generated):**
- CloudNativePG automatically creates these secrets:
  - `matrix-postgresql-app` (main Synapse database user)
  - `matrix-postgresql-li-app` (LI Synapse database user)
- **No action required** - operator handles these

#### 2.2 Redis Password

**Generate Password:**
```bash
REDIS_PASSWORD=$(openssl rand -base64 32)
echo "Generated Redis password: $REDIS_PASSWORD"

# Base64 encode
echo -n "$REDIS_PASSWORD" | base64
```

**Update in:** `infrastructure/02-redis/redis-statefulset.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: redis-password
data:
  password: <paste-base64-encoded-password-here>
```

#### 2.3 MinIO Credentials

**Generate Access and Secret Keys:**
```bash
# MinIO root user (20-40 characters, alphanumeric)
MINIO_ROOT_USER="admin$(openssl rand -hex 8)"
echo "MinIO root user: $MINIO_ROOT_USER"

# MinIO root password (minimum 8 characters)
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)
echo "MinIO root password: $MINIO_ROOT_PASSWORD"

# Application access credentials
MINIO_ACCESS_KEY="synapse-$(openssl rand -hex 8)"
MINIO_SECRET_KEY=$(openssl rand -base64 32)
echo "MinIO access key: $MINIO_ACCESS_KEY"
echo "MinIO secret key: $MINIO_SECRET_KEY"
```

**Update in:** `infrastructure/03-minio/secrets.yaml`
```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-config
  namespace: matrix
stringData:
  config.env: |
    export MINIO_ROOT_USER="<paste-MINIO_ROOT_USER>"
    export MINIO_ROOT_PASSWORD="<paste-MINIO_ROOT_PASSWORD>"
    export MINIO_STORAGE_CLASS_STANDARD="EC:4"

---
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: matrix
stringData:
  access-key: "<paste-MINIO_ACCESS_KEY>"
  secret-key: "<paste-MINIO_SECRET_KEY>"
  CONSOLE_ACCESS_KEY: "<paste-MINIO_ACCESS_KEY>"
  CONSOLE_SECRET_KEY: "<paste-MINIO_SECRET_KEY>"
```

#### 2.4 Synapse Configuration Secrets

**Registration Shared Secret:**
```bash
SYNAPSE_REGISTRATION_SECRET=$(openssl rand -base64 32)
echo "Synapse registration secret: $SYNAPSE_REGISTRATION_SECRET"
```

**Macaroon Secret Key:**
```bash
SYNAPSE_MACAROON_KEY=$(openssl rand -base64 32)
echo "Synapse macaroon key: $SYNAPSE_MACAROON_KEY"
```

**Form Secret:**
```bash
SYNAPSE_FORM_SECRET=$(openssl rand -base64 32)
echo "Synapse form secret: $SYNAPSE_FORM_SECRET"
```

**Worker Replication Secret:**
```bash
WORKER_REPLICATION_SECRET=$(openssl rand -base64 32)
echo "Worker replication secret: $WORKER_REPLICATION_SECRET"
```

**Update in:** `main-instance/01-synapse/configmap.yaml`
```yaml
# In homeserver.yaml section
registration_shared_secret: "<paste-SYNAPSE_REGISTRATION_SECRET>"
macaroon_secret_key: "<paste-SYNAPSE_MACAROON_KEY>"
form_secret: "<paste-SYNAPSE_FORM_SECRET>"
worker_replication_secret: "<paste-WORKER_REPLICATION_SECRET>"
```

**Signing Key (Generated by Synapse on first run):**
- Synapse automatically generates `signing.key` if not present
- Backed up in persistent volume
- **No manual action required**

#### 2.5 key_vault Application Secrets

**Django Secret Key:**
```bash
# Requires Django installed
python3 -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'

# Alternative without Django (50+ random characters):
openssl rand -base64 50
```

**RSA Private Key for Encryption:**
```bash
# Generate 2048-bit RSA key
openssl genrsa -out key_vault_private.pem 2048

# View the key (copy this into your secret)
cat key_vault_private.pem
```

**API Key for key_vault Access:**
```bash
KEY_VAULT_API_KEY=$(openssl rand -hex 32)
echo "key_vault API key: $KEY_VAULT_API_KEY"
```

**Update in:** `li-instance/05-key-vault/deployment.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: key-vault-secrets
stringData:
  DJANGO_SECRET_KEY: "<paste-django-secret-key>"
  RSA_PRIVATE_KEY: |
    <paste-entire-private-key-including-BEGIN-END-lines>
  API_KEY: "<paste-KEY_VAULT_API_KEY>"
  # NOTE: key_vault uses SQLite - no database credentials needed
```

**Update Synapse configuration with API key:**
`main-instance/01-synapse/configmap.yaml`
```yaml
# In homeserver.yaml, modules section
modules:
  - module: key_vault_integration.KeyVaultModule
    config:
      api_url: "http://key-vault.matrix.svc.cluster.local:8000"
      api_key: "<paste-KEY_VAULT_API_KEY>"
```

#### 2.6 LiveKit Secrets

**API Key and Secret:**
```bash
# API Key (alphanumeric, 16+ characters)
LIVEKIT_API_KEY="APIkey$(openssl rand -hex 12)"
echo "LiveKit API key: $LIVEKIT_API_KEY"

# API Secret (32+ characters)
LIVEKIT_API_SECRET=$(openssl rand -base64 32)
echo "LiveKit API secret: $LIVEKIT_API_SECRET"
```

**Update in:** `main-instance/04-livekit/secret.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: livekit-secret
stringData:
  API_KEY: "<paste-LIVEKIT_API_KEY>"
  API_SECRET: "<paste-LIVEKIT_API_SECRET>"
```

**Also update in:** `main-instance/01-synapse/configmap.yaml`
```yaml
# In homeserver.yaml, experimental_features section
experimental_features:
  msc3266_enabled: true  # LiveKit integration
  msc3266_livekit_url: "wss://livekit.example.com"
  msc3266_livekit_api_key: "<paste-LIVEKIT_API_KEY>"
  msc3266_livekit_api_secret: "<paste-LIVEKIT_API_SECRET>"
```

#### 2.7 coturn TURN Server Secret

**Shared Secret:**
```bash
COTURN_SECRET=$(openssl rand -base64 32)
echo "coturn shared secret: $COTURN_SECRET"
```

**Update in:** `main-instance/06-coturn/deployment.yaml` (in the Secret section)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: coturn-secret
stringData:
  shared-secret: "<paste-COTURN_SECRET>"
```

**Also update in:** `main-instance/01-synapse/configmap.yaml`
```yaml
# In homeserver.yaml
turn_shared_secret: "<paste-COTURN_SECRET>"
turn_uris:
  - "turn:turn.example.com:3478?transport=udp"
  - "turn:turn.example.com:3478?transport=tcp"
```

#### 2.8 TLS Certificates

**Option A: Let's Encrypt (Production - Recommended)**

**Update in:** `infrastructure/04-networking/cert-manager-install.yaml`
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com  # ⚠️ UPDATE THIS
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
```

**No manual certificate generation required** - cert-manager handles this automatically.

**Option B: Self-Signed (Air-Gapped/Development)**

```bash
# Generate self-signed certificate
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
  -nodes -keyout tls.key -out tls.crt \
  -subj "/CN=matrix.example.com" \
  -addext "subjectAltName=DNS:matrix.example.com,DNS:*.matrix.example.com"

# Create Kubernetes secret
kubectl create secret tls matrix-tls \
  --cert=tls.crt \
  --key=tls.key \
  -n matrix
```

#### 2.9 Complete Secret Generation Script

**Save this as `generate-secrets.sh`:**

```bash
#!/bin/bash
set -e

echo "=== Matrix/Synapse Secret Generation ==="
echo ""

# PostgreSQL
echo "## PostgreSQL Secrets"
POSTGRES_PASSWORD=$(openssl rand -base64 32)
POSTGRES_LI_PASSWORD=$(openssl rand -base64 32)
echo "Main PostgreSQL password: $POSTGRES_PASSWORD"
echo "LI PostgreSQL password: $POSTGRES_LI_PASSWORD"
echo ""

# Redis
echo "## Redis Secret"
REDIS_PASSWORD=$(openssl rand -base64 32)
echo "Redis password: $REDIS_PASSWORD"
echo "Base64 encoded: $(echo -n "$REDIS_PASSWORD" | base64)"
echo ""

# MinIO
echo "## MinIO Secrets"
MINIO_ROOT_USER="admin$(openssl rand -hex 8)"
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)
MINIO_ACCESS_KEY="synapse-$(openssl rand -hex 8)"
MINIO_SECRET_KEY=$(openssl rand -base64 32)
echo "MinIO root user: $MINIO_ROOT_USER"
echo "MinIO root password: $MINIO_ROOT_PASSWORD"
echo "MinIO access key: $MINIO_ACCESS_KEY"
echo "MinIO secret key: $MINIO_SECRET_KEY"
echo ""

# Synapse
echo "## Synapse Secrets"
SYNAPSE_REGISTRATION_SECRET=$(openssl rand -base64 32)
SYNAPSE_MACAROON_KEY=$(openssl rand -base64 32)
SYNAPSE_FORM_SECRET=$(openssl rand -base64 32)
WORKER_REPLICATION_SECRET=$(openssl rand -base64 32)
echo "Registration secret: $SYNAPSE_REGISTRATION_SECRET"
echo "Macaroon key: $SYNAPSE_MACAROON_KEY"
echo "Form secret: $SYNAPSE_FORM_SECRET"
echo "Worker replication secret: $WORKER_REPLICATION_SECRET"
echo ""

# key_vault
echo "## key_vault Secrets"
DJANGO_SECRET=$(openssl rand -base64 50)
KEY_VAULT_API_KEY=$(openssl rand -hex 32)
echo "Django secret: $DJANGO_SECRET"
echo "key_vault API key: $KEY_VAULT_API_KEY"
echo "Generating RSA key..."
openssl genrsa -out key_vault_private.pem 2048
echo "RSA key saved to: key_vault_private.pem"
echo ""

# LiveKit
echo "## LiveKit Secrets"
LIVEKIT_API_KEY="APIkey$(openssl rand -hex 12)"
LIVEKIT_API_SECRET=$(openssl rand -base64 32)
echo "LiveKit API key: $LIVEKIT_API_KEY"
echo "LiveKit API secret: $LIVEKIT_API_SECRET"
echo ""

# coturn
echo "## coturn Secret"
COTURN_SECRET=$(openssl rand -base64 32)
echo "coturn shared secret: $COTURN_SECRET"
echo ""

echo "=== Generation Complete ==="
echo ""
echo "⚠️  IMPORTANT: Save these secrets securely!"
echo "⚠️  Store in password manager or encrypted vault"
echo "⚠️  Do NOT commit secrets to git"
echo ""
echo "Next steps:"
echo "1. Update all YAML files with generated secrets"
echo "2. Search for 'CHANGEME' placeholders: grep -r CHANGEME deployment/"
echo "3. Verify all secrets are replaced before deployment"
```

**Make executable and run:**
```bash
chmod +x generate-secrets.sh
./generate-secrets.sh > secrets-$(date +%Y%m%d).txt

# Store securely
gpg -c secrets-$(date +%Y%m%d).txt
rm secrets-$(date +%Y%m%d).txt
```

#### 2.10 Secret Management Best Practices

**DO:**
- ✅ Generate unique secrets for each component
- ✅ Use cryptographically secure random generators (openssl, /dev/urandom)
- ✅ Store secrets in password manager or encrypted vault
- ✅ Use different secrets for main and LI instances
- ✅ Rotate secrets periodically (every 90 days recommended)
- ✅ Document where each secret is used
- ✅ Backup secrets before cluster upgrades

**DON'T:**
- ❌ Commit secrets to git repositories
- ❌ Reuse secrets across different components
- ❌ Use weak passwords (minimum 24 characters for production)
- ❌ Share secrets via unencrypted communication
- ❌ Store secrets in plain text files without encryption
- ❌ Use default or example passwords in production

**Secret Rotation Procedure:**
1. Generate new secret
2. Update Kubernetes secret: `kubectl edit secret <name> -n matrix`
3. Restart affected pods: `kubectl rollout restart deployment/<name> -n matrix`
4. Verify connectivity and functionality
5. Document rotation date and next rotation deadline

### 3. Update Domain Names
Replace `matrix.example.com` with your actual domain in:
- [ ] Ingress resources
- [ ] Synapse configuration
- [ ] Element Web configuration
- [ ] Certificate configurations

### 4. Verify Kubernetes Prerequisites
- [ ] Kubernetes cluster version ≥ 1.27
- [ ] cert-manager installed
- [ ] NGINX Ingress Controller installed
- [ ] Prometheus Operator installed (if using monitoring)
- [ ] MinIO Operator installed

## 🚀 Deployment Order

Execute deployment in this specific order:

### Phase 1: Infrastructure
```bash
# 1. PostgreSQL clusters
kubectl apply -f infrastructure/01-postgresql/

# 2. Redis Sentinel
kubectl apply -f infrastructure/02-redis/

# 3. MinIO storage
kubectl apply -f infrastructure/03-minio/

# 4. Networking policies
kubectl apply -f infrastructure/04-networking/networkpolicies.yaml
```

### Phase 2: Core Services
```bash
# 5. Main Synapse instance
kubectl apply -f main-instance/01-synapse/

# 6. Synapse workers
kubectl apply -f main-instance/02-workers/

# 7. HAProxy load balancer
kubectl apply -f main-instance/03-haproxy/

# 8. Element Web
kubectl apply -f main-instance/02-element-web/
```

### Phase 3: Auxiliary Services
```bash
# 9. ClamAV antivirus
kubectl apply -f antivirus/01-clamav/

# 10. Content scanner (after ClamAV is ready)
kubectl apply -f antivirus/02-scan-workers/

# 11. LiveKit SFU
kubectl apply -f main-instance/04-livekit/

# 12. TURN server
kubectl apply -f main-instance/06-coturn/
```

### Phase 4: LI Instance
```bash
# 13. LI Redis (isolated)
kubectl apply -f li-instance/00-redis-li/

# 14. Sync system (replication)
kubectl apply -f li-instance/04-sync-system/

# 15. LI Synapse instance
kubectl apply -f li-instance/01-synapse-li/

# 16. LI Element Web
kubectl apply -f li-instance/02-element-web-li/

# 17. LI Synapse Admin
kubectl apply -f li-instance/03-synapse-admin-li/

# 18. key_vault (E2EE recovery - in LI network)
kubectl apply -f li-instance/05-key-vault/
```

### Phase 5: Monitoring
```bash
# 17. Prometheus configuration
kubectl apply -f monitoring/01-prometheus/

# 18. Grafana dashboards
kubectl apply -f monitoring/02-grafana/
```

## ✅ Post-Deployment Validation

### 1. Component Health Checks
```bash
# Check all pods are running
kubectl get pods -n matrix

# Verify no CrashLoopBackOff
kubectl get pods -n matrix | grep -v Running | grep -v Completed

# Check services
kubectl get svc -n matrix
```

### 2. Connectivity Tests
```bash
# Test PostgreSQL connectivity
kubectl exec -it matrix-postgresql-1 -n matrix -- psql -U postgres -c "\l"

# Test Redis connectivity
kubectl exec -it redis-0 -n matrix -- redis-cli -a $REDIS_PASSWORD ping

# Test MinIO connectivity
kubectl exec -it deployment/test-pod -n matrix -- curl http://minio:9000/minio/health/live
```

### 3. Synapse Health
```bash
# Check main Synapse
curl https://matrix.example.com/_matrix/federation/v1/version

# Check worker health
for worker in synchrotron generic media; do
  kubectl exec -it synapse-$worker-0 -n matrix -- curl localhost:8008/health
done
```

### 4. Replication Status and Validation

#### 4.1 Verify Replication Configuration

**Check Publication on Main Cluster:**
```bash
# Verify publication exists
kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U postgres -d synapse -c \
  "SELECT pubname, schemaname, tablename
   FROM pg_publication_tables
   WHERE pubname = 'synapse_publication';"

# Should show all Synapse tables listed
# If empty, publication not created correctly
```

**Check Subscription on LI Cluster:**
```bash
# Verify subscription exists and is active
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U postgres -d synapse_li -c \
  "SELECT subname, subenabled, pid IS NOT NULL as active,
          latest_end_lsn, received_lsn
   FROM pg_stat_subscription;"

# Expected output:
#      subname        | subenabled | active | latest_end_lsn | received_lsn
# --------------------+------------+--------+----------------+--------------
#  synapse_subscription |     t     |   t    |   0/3A5F2E8   |  0/3A5F2E8
#
# subenabled: Should be 't' (true)
# active: Should be 't' (worker process running)
# LSN values: Should be present and advancing
```

#### 4.2 Validate Replication Credentials

**Critical: Verify Correct User is Used**

The sync-system **must** use the existing `synapse` user created by CloudNativePG, NOT create a new user.

**Check Main Cluster User:**
```bash
# List database users
kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U postgres -c "\du"

# Should see:
#                                    List of roles
#  Role name |                         Attributes
# -----------+------------------------------------------------------------
#  postgres  | Superuser, Create role, Create DB, Replication, Bypass RLS
#  streaming_replica | Replication
#  synapse   |

# Verify synapse user password matches app secret
kubectl get secret matrix-postgresql-app -n matrix -o jsonpath='{.data.password}' | base64 -d
echo ""
```

**Verify Replication Connection String:**
```bash
# Check sync-system job uses correct credentials
kubectl get job sync-system-setup-replication -n matrix -o yaml | \
  grep -A 5 "MAIN_DB"

# Should see:
# MAIN_DB_USER: synapse
# MAIN_DB_PASSWORD: <from-matrix-postgresql-app-secret>
# MAIN_DB_HOST: matrix-postgresql-rw.matrix.svc.cluster.local
# MAIN_DB_NAME: synapse
```

**Test Replication Connection from LI to Main:**
```bash
# Get synapse user password
MAIN_PG_PASSWORD=$(kubectl get secret matrix-postgresql-app -n matrix \
  -o jsonpath='{.data.password}' | base64 -d)

# Test connection from LI cluster to main cluster
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql "postgresql://synapse:${MAIN_PG_PASSWORD}@matrix-postgresql-rw.matrix.svc.cluster.local:5432/synapse" \
  -c "SELECT current_user, current_database();"

# Expected output:
#  current_user | current_database
# --------------+------------------
#  synapse      | synapse
```

#### 4.3 Check Replication Lag

**Monitor Replication Lag:**
```bash
# Detailed replication status
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U postgres -d synapse_li -c "
SELECT
  subname,
  pid,
  pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, received_lsn)) AS receive_lag,
  pg_size_pretty(pg_wal_lsn_diff(received_lsn, last_msg_send_time)) AS apply_lag,
  last_msg_send_time,
  last_msg_receipt_time
FROM pg_stat_subscription;"
```

**Expected Replication Lag:**
- **Healthy:** receive_lag < 1MB, apply_lag < 1 second
- **Warning:** receive_lag 1-10MB, apply_lag 1-5 seconds
- **Critical:** receive_lag > 10MB, apply_lag > 10 seconds

**Common Lag Causes:**
1. Network issues between main and LI clusters
2. High write load on main cluster
3. Insufficient resources on LI cluster
4. Replication slot not advancing (check `pg_replication_slots`)

#### 4.4 Validate Data Replication

**Test Data Sync:**
```bash
# Count users on main cluster
MAIN_USER_COUNT=$(kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U synapse -d synapse -t -c "SELECT COUNT(*) FROM users;")

# Count users on LI cluster (should match after initial sync)
LI_USER_COUNT=$(kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U synapse_li -d synapse_li -t -c "SELECT COUNT(*) FROM users;")

echo "Main cluster users: $MAIN_USER_COUNT"
echo "LI cluster users: $LI_USER_COUNT"

# Difference should be 0 or very small (new users during check)
```

**Check Recent Events are Replicated:**
```bash
# Get latest event on main
kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U synapse -d synapse -c \
  "SELECT event_id, received_ts, room_id FROM events
   ORDER BY received_ts DESC LIMIT 5;"

# Check same events exist on LI (wait a few seconds for replication)
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U synapse_li -d synapse_li -c \
  "SELECT event_id, received_ts, room_id FROM events
   ORDER BY received_ts DESC LIMIT 5;"

# Event IDs should match
```

#### 4.5 Replication Error Troubleshooting

**Check for Replication Errors:**
```bash
# Check subscription worker errors
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U postgres -d synapse_li -c \
  "SELECT * FROM pg_stat_subscription WHERE pid IS NULL;"

# If any rows returned, subscription worker is not running
```

**Check PostgreSQL Logs for Replication Issues:**
```bash
# Main cluster logs (publication side)
kubectl logs matrix-postgresql-1 -n matrix | grep -i "publication\|replication"

# LI cluster logs (subscription side)
kubectl logs matrix-postgresql-li-1 -n matrix | grep -i "subscription\|replication"
```

**Common Error: "password authentication failed for user"**
```
Solution: Verify sync-system uses matrix-postgresql-app secret:

kubectl get job sync-system-setup-replication -n matrix -o yaml | \
  grep -A 2 "MAIN_DB_PASSWORD"

Should reference:
  valueFrom:
    secretKeyRef:
      name: matrix-postgresql-app
      key: password
```

**Common Error: "publication does not exist"**
```
Solution: Create publication manually:

kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U postgres -d synapse -c \
  "CREATE PUBLICATION synapse_publication FOR ALL TABLES;"
```

**Common Error: "could not create replication slot"**
```
Solution: Check max_replication_slots:

kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U postgres -c "SHOW max_replication_slots;"

# Should be >= 10
# If not, increase in PostgreSQL configuration
```

#### 4.6 Replication Health Checklist

Before considering replication healthy:

- [ ] Publication exists on main cluster with all Synapse tables
- [ ] Subscription exists on LI cluster and is enabled
- [ ] Subscription worker process is running (pid IS NOT NULL)
- [ ] Replication lag < 1MB receive lag, < 1 second apply lag
- [ ] User counts match between main and LI (within acceptable delta)
- [ ] Recent events are visible on both clusters
- [ ] No authentication errors in logs
- [ ] Replication slot is active on main cluster
- [ ] Network connectivity between clusters is stable

**Check Replication Slot:**
```bash
kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U postgres -c \
  "SELECT slot_name, slot_type, active, restart_lsn
   FROM pg_replication_slots;"

# Should show:
#      slot_name       | slot_type | active | restart_lsn
# ---------------------+-----------+--------+-------------
#  synapse_subscription | logical   |   t    | 0/3A5F000
#
# active should be 't' (true)
```

## 🐛 Troubleshooting

### Common Issues After Deployment

1. **Pods in CrashLoopBackOff**
   - Check logs: `kubectl logs <pod> -n matrix --previous`
   - Verify secrets are created
   - Check init containers completed

2. **NetworkPolicy blocking traffic**
   - Verify namespace labels: `kubectl get ns kube-system --show-labels`
   - Check policy matches: `kubectl describe networkpolicy -n matrix`

3. **Database connection failures**
   - Verify PostgreSQL clusters are ready
   - Check credentials in secrets
   - Test connectivity from pods

4. **S3/MinIO errors**
   - Verify MinIO tenant is healthy
   - Check bucket creation
   - Validate credentials format

5. **LI replication not working**
   - Check publication exists on main
   - Verify subscription on LI
   - Check network connectivity between clusters

## 📋 Final Checklist

Before considering deployment complete:

- [ ] All pods running and healthy
- [ ] No errors in pod logs
- [ ] Synapse federation tester passes
- [ ] Element Web accessible and functional
- [ ] Media upload/download working
- [ ] PostgreSQL replication active (if using LI)
- [ ] Monitoring dashboards showing metrics
- [ ] Backup procedures tested
- [ ] Security scan completed
- [ ] Load testing performed (optional)
- [ ] Documentation updated with actual values

## 🎉 Deployment Complete!

Once all checks pass, your Matrix/Synapse deployment is operational with:
- High availability across all components
- Lawful intercept capability
- Antivirus protection
- Video/voice calling via LiveKit
- Comprehensive monitoring
- Automatic scaling
- Disaster recovery via backups

Remember to:
1. Document all customizations
2. Set up regular backup schedules
3. Configure alerting rules
4. Plan maintenance windows
5. Monitor resource usage trends