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
| **80** | TCP | Inbound | Ingress Node(s) | HTTP - redirect to HTTPS |
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

**After installation:**
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

**This deployment uses Let's Encrypt for automatic TLS certificate provisioning.**

| Component | Description |
|-----------|-------------|
| **cert-manager** | Installed in cluster, manages certificates automatically |
| **Let's Encrypt** | Free, trusted certificates via ACME protocol |
| **ClusterIssuer** | `letsencrypt-prod` (default) or `letsencrypt-staging` (testing) |

**Requirements:**
- Port 80 must be accessible from internet (HTTP-01 challenge)
- Valid DNS records pointing to your ingress IP
- Valid email address for Let's Encrypt notifications

**Certificate Renewal:**
Per CLAUDE.md 4.5: Initial deployment uses Let's Encrypt with internet access.
Certificate renewal (every 90 days) is the organization's responsibility
and is out of scope for this deployment solution.

**Alternative (if organization provides certificates):**
- Import pre-signed certificates as Kubernetes TLS secrets
- Certificate file (PEM format)
- Private key file (PEM format)

### 6. Optional External Services

**If the organization wants these features:**

| Feature | External Requirement |
|---------|---------------------|
| **Push Notifications** | Apple/Google push credentials (requires internet) |
| **Federation** | External DNS SRV records, open port 8448 |
| **SMTP Notifications** | SMTP server credentials |

**Note**: These are disabled by default (per CLAUDE.md Rule 4.3: No external services).

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
    [x] Let's Encrypt (default - requires initial internet access)
    [ ] Organization provides pre-signed certificates

    NOTE: Let's Encrypt used for initial setup. Renewal (90 days) is org's responsibility.

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
- [ ] **Ingress controller configured:**
  - [ ] NGINX Ingress installed and running
  - [ ] IngressClass configured
- [ ] **TLS certificates:**
  - [ ] cert-manager installed
  - [ ] ClusterIssuer configured (letsencrypt-prod)
  - [ ] Certificates generated for domains
- [ ] **Network isolation (organization's responsibility per CLAUDE.md 7.4):**
  - [ ] LI network isolated from main network
  - [ ] key_vault accessible only from authorized sources
  - [ ] Firewall/network policies configured by organization

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
- [ ] **Network access controlled (organization's responsibility per CLAUDE.md 7.4):**
  - [ ] Synapse main can STORE keys (cross-network access)
  - [ ] LI admin can RETRIEVE keys (within LI network)
  - [ ] Organization configures network isolation
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
  - [ ] Publication created with superuser privileges on main
  - [ ] Subscription properly configured on LI
  - [ ] Uses CloudNativePG-managed superuser secrets
- [ ] **Credentials properly configured:**
  ```yaml
  # Sync system uses CloudNativePG-managed superuser secrets:
  # - matrix-postgresql-superuser (main cluster)
  # - matrix-postgresql-li-superuser (LI cluster)
  # These are auto-created by CloudNativePG with enableSuperuserAccess: true

  # sync-system-secrets only contains connection info (not passwords):
  # MAIN_DB_HOST, MAIN_DB_PORT, MAIN_DB_NAME
  # LI_DB_HOST, LI_DB_PORT, LI_DB_NAME
  # S3_ACCESS_KEY, S3_SECRET_KEY
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

**Default: Let's Encrypt (Automatic)**

This deployment uses Let's Encrypt via cert-manager for automatic TLS certificates.
Certificates are automatically issued when Ingress resources are created.

Per CLAUDE.md 4.5: Initial deployment uses Let's Encrypt with internet access.
Certificate renewal (every 90 days) is the organization's responsibility.

**Requirements for Let's Encrypt:**
- Port 80 accessible from internet (HTTP-01 challenge)
- Valid DNS records pointing to ingress IP
- Valid email configured in cert-manager ClusterIssuer

**Alternative: Organization-Provided Certificates**

If the organization prefers to provide their own certificates:
```bash
# Create Kubernetes secret from organization-provided certs
kubectl create secret tls matrix-tls \
  --cert=/path/to/org-provided-cert.crt \
  --key=/path/to/org-provided-key.key \
  -n matrix
```

Then update Ingress annotations to use the pre-created secret instead of cert-manager.

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

### 5. Storage Class Configuration (CRITICAL)
**The deployment requires a storage class to exist in your cluster.**

```bash
# Check available storage classes
kubectl get storageclass

# Expected output example:
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# standard (default)   kubernetes.io/gce-pd    Delete          Immediate
# local-storage        kubernetes.io/no-prov   Delete          WaitForFirstConsumer
```

**IMPORTANT:**
- Set `STORAGE_CLASS` in `config.env` to match an existing storage class
- If no storage class exists, create one before deployment
- The deploy-all.sh script will FAIL if the storage class doesn't exist

**For bare-metal clusters (no cloud provisioner):**
```bash
# Option 1: Use local-path-provisioner (simplest)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# Option 2: Create manual local storage class
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
```

### 6. Node Labeling Requirements (CRITICAL)

**Monitoring Server Node:**
Per CLAUDE.md Section 6.2, monitoring must run on a DEDICATED server.
```bash
# Label the monitoring server node
kubectl label node <monitoring-node-name> monitoring=true

# Optional: Add taint to prevent other workloads
kubectl taint nodes <monitoring-node-name> monitoring=true:NoSchedule

# Verify labeling
kubectl get nodes -l monitoring=true
```

**LiveKit Nodes (if using group video calls):**
```bash
# Label nodes designated for LiveKit (4 recommended for 20K CCU)
kubectl label node <livekit-node-1> livekit=true
kubectl label node <livekit-node-2> livekit=true
kubectl label node <livekit-node-3> livekit=true
kubectl label node <livekit-node-4> livekit=true

# Verify labeling
kubectl get nodes -l livekit=true
```

**Summary of Required Node Labels:**
| Label | Purpose | Minimum Nodes |
|-------|---------|---------------|
| `monitoring=true` | Prometheus, Grafana, Loki | 1 |
| `livekit=true` | LiveKit SFU instances | 2-4 (if using LiveKit) |

### 7. LiveKit / Element Call Setup (For Group Video Calls)

**If you want group video/voice calls, you MUST deploy LiveKit:**

1. **Deploy LiveKit SFU:**
   ```bash
   helm repo add livekit https://helm.livekit.io
   helm install livekit livekit/livekit-server \
     --namespace livekit --create-namespace \
     --values values/livekit-values.yaml
   ```

2. **Update Element Web config:**
   - Element Web config.json includes `element_call` section
   - Set `element_call.url` to your LiveKit JWT service URL
   - See `main-instance/02-element-web/deployment.yaml` for configuration

3. **Configure Synapse for LiveKit:**
   - Update homeserver.yaml with LiveKit API credentials
   - See CONFIGURATION-REFERENCE.md for details

**Without LiveKit:**
- 1-on-1 voice/video calls still work (direct WebRTC via coturn)
- Group calls will be disabled

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

### 4. Database Sync Status and Validation

**Note:** LI database sync uses **pg_dump/pg_restore** (not PostgreSQL logical replication).
Per CLAUDE.md section 3.3 and 7.2:
- Uses pg_dump/pg_restore for full database synchronization
- Each sync completely overwrites the LI database with a fresh copy from main
- Sync interval configurable via CronJob (default: 6 hours)
- Manual sync trigger available via Synapse Admin LI

#### 4.1 Verify Sync Status

**Check Sync Checkpoint:**
```bash
# Check sync status from synapse-li pod
kubectl exec -n matrix synapse-li-0 -- python3 /sync/sync_task.py --status

# Or check checkpoint file directly
kubectl exec -n matrix synapse-li-0 -- cat /var/lib/synapse-li/sync_checkpoint.json

# Expected output:
# {
#   "last_sync_at": "2025-01-15T10:30:00",
#   "last_sync_status": "success",
#   "last_dump_size_mb": 1234.56,
#   "last_duration_seconds": 180.5,
#   "total_syncs": 42,
#   "failed_syncs": 0
# }
```

#### 4.2 Verify Database Connectivity

**Check Main PostgreSQL Connectivity from Synapse LI:**
```bash
# Test connection to main database
kubectl exec -n matrix synapse-li-0 -- \
  psql -h matrix-postgresql-rw.matrix.svc.cluster.local \
       -U synapse -d matrix -c "SELECT 1;"

# Should return:
#  ?column?
# ----------
#         1
```

**Check LI PostgreSQL Connectivity:**
```bash
# Test connection to LI database
kubectl exec -n matrix synapse-li-0 -- \
  psql -h matrix-postgresql-li-rw.matrix.svc.cluster.local \
       -U synapse_li -d matrix_li -c "SELECT 1;"

# Should return:
#  ?column?
# ----------
#         1
```
#### 4.3 Validate Data Sync

**Test Data Counts Match:**
```bash
# Count users on main cluster
MAIN_USER_COUNT=$(kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U synapse -d matrix -t -c "SELECT COUNT(*) FROM users;")

# Count users on LI cluster (should match after sync)
LI_USER_COUNT=$(kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U synapse_li -d matrix_li -t -c "SELECT COUNT(*) FROM users;")

echo "Main cluster users: $MAIN_USER_COUNT"
echo "LI cluster users: $LI_USER_COUNT"

# Counts should match exactly after sync completes
```

**Check Recent Events are Synced:**
```bash
# Get latest event on main
kubectl exec -it matrix-postgresql-1 -n matrix -- \
  psql -U synapse -d matrix -c \
  "SELECT event_id, received_ts FROM events ORDER BY received_ts DESC LIMIT 5;"

# Check same events exist on LI (after sync)
kubectl exec -it matrix-postgresql-li-1 -n matrix -- \
  psql -U synapse_li -d matrix_li -c \
  "SELECT event_id, received_ts FROM events ORDER BY received_ts DESC LIMIT 5;"

# Event IDs should match after sync completes
```

#### 4.4 Sync Error Troubleshooting

**Check for Sync Errors:**
```bash
# Check sync status
kubectl exec -n matrix synapse-li-0 -- python3 /sync/sync_task.py --status

# Check for stuck lock file
kubectl exec -n matrix synapse-li-0 -- ls -la /var/lib/synapse-li/sync.lock

# If lock exists but no sync is running, remove it:
kubectl exec -n matrix synapse-li-0 -- rm -f /var/lib/synapse-li/sync.lock
```

**Common Error: "pg_dump failed"**
```
Solution: Check connectivity to main PostgreSQL:

kubectl exec -n matrix synapse-li-0 -- \
  psql -h matrix-postgresql-rw.matrix.svc.cluster.local \
       -U synapse -d matrix -c "SELECT 1;"

Verify credentials are correct in sync configuration.
```

**Common Error: "pg_restore failed"**
```
Solution: Check LI PostgreSQL is accessible:

kubectl exec -n matrix synapse-li-0 -- \
  psql -h matrix-postgresql-li-rw.matrix.svc.cluster.local \
       -U synapse_li -d matrix_li -c "SELECT 1;"

Check disk space on LI PostgreSQL PV.
```

**Manually Trigger Sync:**
```bash
kubectl exec -n matrix synapse-li-0 -- python3 /sync/sync_task.py
```

#### 4.5 Sync Health Checklist

Before considering sync healthy:

- [ ] Sync checkpoint shows `last_sync_status: success`
- [ ] No sync lock file when sync is not running
- [ ] User counts match between main and LI
- [ ] Events are visible on LI after sync
- [ ] Sync duration is reasonable (< 30 minutes for typical DBs)
- [ ] No pg_dump/pg_restore errors in logs
- [ ] CronJob is scheduled (if using automatic sync)

## 🐛 Troubleshooting

### Common Issues After Deployment

1. **Pods in CrashLoopBackOff**
   - Check logs: `kubectl logs <pod> -n matrix --previous`
   - Verify secrets are created
   - Check init containers completed

2. **Network connectivity issues**
   - Network isolation is organization's responsibility (CLAUDE.md 7.4)
   - Verify services can reach each other within cluster
   - Check firewall rules if using external databases

3. **Database connection failures**
   - Verify PostgreSQL clusters are ready
   - Check credentials in secrets
   - Test connectivity from pods

4. **S3/MinIO errors**
   - Verify MinIO tenant is healthy
   - Check bucket creation
   - Validate credentials format

5. **LI sync not working**
   - Check pg_dump connectivity to main database
   - Verify pg_restore can write to LI database
   - Check sync checkpoint file for errors
   - Manually trigger sync to test

## 📋 Final Checklist

Before considering deployment complete:

- [ ] All pods running and healthy
- [ ] No errors in pod logs
- [ ] Synapse federation tester passes
- [ ] Element Web accessible and functional
- [ ] Media upload/download working
- [ ] LI database sync working (if using LI)
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