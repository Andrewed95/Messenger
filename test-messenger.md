# Test Deployment Context: Matrix/Synapse Messenger

This document contains metadata about the test deployment environment. Use this when starting a new session with Claude to provide context.

---

## Organization & Infrastructure Provider

- **Provider**: Friend's company
- **Domain**: nilva.dev
- **Gateway Static IP**: 93.114.108.72
- **Internal DNS Server**: 192.168.10.1
- **Internal Network**: 192.168.10.0/24

---

## Server Inventory

17 virtual machines provided for the test deployment:

| # | K8s Hostname | IP Address | Role | vCPU | RAM | Disk |
|---|--------------|------------|------|------|-----|------|
| 1 | k8s-cp-01 | 192.168.10.231 | Control Plane | 2 | 4 GB | 13 GB |
| 2 | k8s-cp-02 | 192.168.10.232 | Control Plane | 2 | 4 GB | 13 GB |
| 3 | k8s-cp-03 | 192.168.10.233 | Control Plane | 2 | 4 GB | 13 GB |
| 4 | k8s-app-01 | 192.168.10.234 | Application | 2 | 5 GB | 18 GB |
| 5 | k8s-app-02 | 192.168.10.235 | Application | 2 | 5 GB | 18 GB |
| 6 | k8s-app-03 | 192.168.10.236 | Application | 2 | 5 GB | 18 GB |
| 7 | k8s-db-01 | 192.168.10.237 | Database | 2 | 3 GB | 12 GB |
| 8 | k8s-db-02 | 192.168.10.238 | Database | 2 | 3 GB | 12 GB |
| 9 | k8s-db-03 | 192.168.10.239 | Database | 2 | 3 GB | 12 GB |
| 10 | k8s-storage-01 | 192.168.10.240 | Storage | 2 | 3 GB | 15 GB |
| 11 | k8s-storage-02 | 192.168.10.241 | Storage | 2 | 3 GB | 15 GB |
| 12 | k8s-storage-03 | 192.168.10.242 | Storage | 2 | 3 GB | 15 GB |
| 13 | k8s-storage-04 | 192.168.10.243 | Storage | 2 | 3 GB | 15 GB |
| 14 | k8s-call-01 | 192.168.10.244 | Call Server | 2 | 3 GB | 10 GB |
| 15 | k8s-call-02 | 192.168.10.245 | Call Server | 2 | 3 GB | 10 GB |
| 16 | k8s-li-01 | 192.168.10.246 | LI Server | 2 | 4 GB | 15 GB |
| 17 | k8s-mon-01 | 192.168.10.247 | Monitoring | 2 | 5 GB | 25 GB |

**Total Resources**: 17 VMs, 34 vCPU, ~62 GB RAM, ~256 GB Disk

---

## Access Information

- **SSH User**: nilva
- **SSH Access**: Via OpenVPN from management node
- **Sudo**: Passwordless sudo (NOPASSWD:ALL)
- **Management Node**: Debian VM running on user's laptop (NOT the laptop itself)
- **Deployment Files**: `~/Messenger` on management node
- **Claude Code runs on**: User's laptop (local environment) - NOT the management node

**IMPORTANT**: All kubectl/helm commands must be executed on the management VM, not locally. Claude Code cannot run deployment commands directly.

---

## Network Architecture

```
                     INTERNET
                         │
                         ▼
              ┌──────────────────────┐
              │   Gateway nginx      │
              │   93.114.108.72      │
              │   (Static IP)        │
              │   Domain: nilva.dev  │
              └──────────┬───────────┘
                         │
                         │ (Reverse Proxy)
                         ▼
              ┌──────────────────────┐
              │   Internal Network   │
              │   192.168.10.0/24    │
              │                      │
              │   DNS: 192.168.10.1  │
              └──────────┬───────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│ Control     │ │ Application │ │ Database    │
│ Plane       │ │ Nodes       │ │ Nodes       │
│ .231-.233   │ │ .234-.236   │ │ .237-.239   │
└─────────────┘ └─────────────┘ └─────────────┘
         │               │               │
         ▼               ▼               ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│ Storage     │ │ Call        │ │ LI + Mon    │
│ Nodes       │ │ Servers     │ │ Servers     │
│ .240-.243   │ │ .244-.245   │ │ .246-.247   │
└─────────────┘ └─────────────┘ └─────────────┘
```

---

## Domain Configuration

**Base Domain**: nilva.dev

| Service | Domain | Target IP | Environment |
|---------|--------|-----------|-------------|
| Synapse (homeserver) | matrix.nilva.dev | 192.168.10.190 | Main |
| Element Web | chat.nilva.dev | 192.168.10.190 | Main |
| TURN Server | turn.nilva.dev | 192.168.10.244 | Main |
| Grafana | grafana.nilva.dev | 192.168.10.190 | Monitoring |
| Element Web LI | chat-li.nilva.dev | 192.168.10.191 | LI |
| Synapse Admin LI | admin-li.nilva.dev | 192.168.10.191 | LI |
| key_vault | keyvault.nilva.dev | 192.168.10.191 | LI |

---

## MetalLB IP Allocation

Reserved IP range: 192.168.10.190-200 (11 IPs)

| IP | Allocation | Purpose |
|----|------------|---------|
| 192.168.10.190 | Main Ingress | Synapse, Element Web, Grafana |
| 192.168.10.191 | LI Ingress | LI services (nginx-li) |
| 192.168.10.192-200 | Reserved | Future use |

---

## Kubernetes Node Labels

| Node(s) | Labels |
|---------|--------|
| k8s-cp-01/02/03 | node-role.kubernetes.io/control-plane |
| k8s-app-01/02/03 | node-role=application |
| k8s-db-01/02/03 | node-role=database |
| k8s-storage-01/02/03/04 | node-role=storage |
| k8s-call-01/02 | node-role=call-server, livekit=true, coturn=true |
| k8s-li-01 | node-role=li |
| k8s-mon-01 | node-role=monitoring, monitoring=true |

---

## Kubernetes Cluster Configuration

- **Version**: Kubernetes 1.28.15
- **CNI**: Calico
- **Load Balancer**: MetalLB (L2 mode)
- **Storage**: local-path-provisioner (default StorageClass)
- **Ingress**: NGINX Ingress Controller
- **Pod CIDR**: 10.244.0.0/16
- **Service CIDR**: 10.96.0.0/12
- **API Server**: 192.168.10.231:6443

---

## Deployment Scale

- **Target**: ~10 Concurrent Users (CCU)
- **Purpose**: Testing and validation
- **Load**: Very low (personal use by friends)
- **HA**: Full deployment with all services (not simplified)

---

## Gateway nginx Requirements

The gateway at 93.114.108.72 needs to:

1. **Reverse proxy HTTPS** for all 7 domains to internal IPs
2. **Forward TURN ports**: 3478 (TCP/UDP), 5349 (TCP), 49152-65535 (UDP)
3. **TLS termination** with Let's Encrypt or wildcard certificate

---

## Firewall Ports Required

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 80 | TCP | Inbound | HTTP redirect |
| 443 | TCP | Inbound | HTTPS (all services) |
| 3478 | TCP/UDP | Inbound | TURN signaling |
| 5349 | TCP | Inbound | TURNS (TLS) |
| 49152-65535 | UDP | Inbound | TURN media relay |

---

## Important Constraints

1. **No static IPs on VMs**: IPs assumed stable during test period
2. **No direct DNS access**: Friend manages nilva.dev DNS
3. **No gateway access**: Friend manages gateway nginx
4. **Limited resources**: Cannot increase VM specs
5. **SSH only**: Only access method to VMs is SSH via OpenVPN

---

## What Friend Needs to Configure

Before deployment can complete:

1. **DNS Records**: 7 A records on nilva.dev → 93.114.108.72
2. **Internal DNS**: Resolve domains to internal MetalLB IPs (optional)
3. **Gateway nginx**: Reverse proxy configuration for all domains
4. **TURN forwarding**: Port forwarding for 3478, 5349, 49152-65535
5. **Firewall**: Open ports 80, 443, 3478, 5349, 49152-65535
6. **TLS Certificates**: Let's Encrypt or wildcard for *.nilva.dev

---

## Contact Points

- **Infrastructure/Network**: Friend (controls gateway, DNS, firewall)
- **Deployment/Configuration**: User (SSH access to VMs)

---

## Generated Credentials

Stored in `~/Messenger/deployment/config.env` on management node.

Key values for reference:
- **Grafana Admin Password**: `AhBGZZ4P9pNilTsc2YKUFZ5i`
- **Kube-DNS IP**: `10.96.0.10`

---

## Reference Documentation

All paths relative to `~/Messenger` on management node:

- Main deployment guide: `deployment/README.md`
- Architecture overview: `deployment/BIGPICTURE.md`
- Scaling guide: `deployment/docs/SCALING-GUIDE.md`
- Kubernetes installation: `deployment/docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`
- Workstation setup: `deployment/docs/00-WORKSTATION-SETUP.md`
- LI implementation: `LI_IMPLEMENTATION.md`
- Project guidelines: `CLAUDE.md`
