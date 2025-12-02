# Matrix Lawful Intercept (LI) Instance

⭐ **CRITICAL COMPLIANCE COMPONENT** ⭐

Complete read-only Matrix instance for law enforcement access with E2EE recovery capabilities.

## Overview

The LI instance is a **completely independent, isolated Matrix homeserver** that receives data from the main instance but cannot modify it. The `key_vault` service is located within the LI network (per CLAUDE.md requirements), storing encrypted E2EE recovery keys.

**Key Features**:
- ✅ **Operational independence** - LI has own database, Redis, and reverse proxy
- ✅ **Own reverse proxy** - Dedicated nginx-li handles all LI traffic
- ✅ **Shared MinIO** - Uses main MinIO for media (read-only access)
- ✅ Read-only database (enforced at PostgreSQL level)
- ✅ Infinite message retention (including soft-deleted messages)
- ✅ Isolated from federation network
- ✅ **key_vault in LI network** - stores encrypted E2EE recovery keys
- ✅ Real-time data replication via PostgreSQL logical replication
- ✅ Real-time media access via S3 API to main MinIO (no sync lag)
- ✅ Separate web interfaces (Element, Synapse Admin)
- ✅ Network isolation (organization's responsibility)

**⚠️ CRITICAL WARNING FOR LI ADMINISTRATORS**:
- Media files are stored in **main MinIO** (shared with main instance)
- LI admins **must NOT delete or modify media files**
- Any media changes in MinIO will affect the main instance
- Media quarantine/deletion must be done through main Synapse Admin

**Independence Guarantee**:
- If the main instance goes down, LI continues to function for core operations
- LI admins can still browse, log in, and perform lawful intercept
- Message history and user data remain accessible (in LI database)
- Media may be temporarily unavailable if main MinIO is also down
- New data will not sync until main recovers

**key_vault Access Model** (per CLAUDE.md section 3.3):
- **Synapse main (main network)**: Can STORE recovery keys when users set up E2EE
- **LI admin (LI network)**: Can RETRIEVE recovery keys for lawful intercept
- **All other access**: BLOCKED by NetworkPolicy

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    MAIN INSTANCE                        │
│  ┌──────────────┐   ┌──────────────┐                   │
│  │  PostgreSQL  │───│  Synapse     │                   │
│  │    Main      │   │    Main      │────────┐          │
│  └──────┬───────┘   └──────────────┘        │          │
│         │                                    │          │
│         │ PostgreSQL Logical Replication     │ Store    │
└─────────┼────────────────────────────────────┼──────────┘
          │                                    │ Recovery
          │                                    │ Keys
          ▼                                    ▼
┌─────────────────────────────────────────────────────────┐
│                   SYNC SYSTEM                           │
│  ┌──────────────────────────────────────────────────┐  │
│  │      PostgreSQL Logical Replication               │  │
│  │         (Real-time database sync)                 │  │
│  └──────────────────────┬───────────────────────────┘  │
│                         │                              │
│  Media: LI accesses main MinIO directly (shared bucket) │
└─────────────────────────┼──────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────┐
│                    LI INSTANCE (Independent)            │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │               NGINX-LI (Reverse Proxy)            │  │
│  │     LoadBalancer: Handles all HTTPS traffic       │  │
│  │     Routes to: synapse-li, element-web-li,        │  │
│  │                synapse-admin-li, key_vault        │  │
│  └──────────────────────────────────────────────────┘  │
│                          │                              │
│         ┌────────────────┼────────────────┐            │
│         ▼                ▼                ▼            │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────┐     │
│  │   Synapse    │ │  Element     │ │  Synapse   │     │
│  │      LI      │ │  Web LI      │ │  Admin LI  │     │
│  │  (read-only) │ │              │ │            │     │
│  └──────┬───────┘ └──────────────┘ └────────────┘     │
│         │                                              │
│  ┌──────┴───────┐                   ┌────────────┐     │
│  │  PostgreSQL  │                   │ key_vault  │     │
│  │      LI      │ ───S3 API───▶     │  (E2EE     │     │
│  │  (read-only) │   Main MinIO      │  Recovery) │     │
│  └──────────────┘                   └────────────┘     │
│                                                         │
│  ⭐ LI works independently even if main is down ⭐     │
└─────────────────────────────────────────────────────────┘

LI Admin Access Flow:
1. Admin configures DNS to point homeserver URL to LI LoadBalancer IP
2. Admin browses to chat-li.example.com (via nginx-li)
3. Element Web LI connects to Synapse LI (same homeserver URL as main)
4. Admin can view all messages, including deleted ones
```

## Components

### 0. NGINX-LI Reverse Proxy (06-nginx-li/) - CRITICAL

**Dedicated reverse proxy** for complete LI independence.

**Why nginx-li instead of shared Ingress Controller?**
- LI must work **independently** even if main instance is down
- Shared ingress controller creates dependency on main infrastructure
- Dedicated nginx ensures LI has its own entry point

**Features**:
- TLS termination for all LI domains
- Routes to synapse-li, element-web-li, synapse-admin-li, key_vault
- LoadBalancer service for external access
- Operates independently of main cluster ingress

**Deployment**:

**WHERE:** Run from your **management node**

```bash
# First, create TLS certificate secrets (see TLS section below)
# Then deploy nginx-li
kubectl apply -f 06-nginx-li/deployment.yaml

# Verify nginx-li is running
kubectl get pods -n matrix -l app.kubernetes.io/name=nginx,app.kubernetes.io/instance=li

# Get LoadBalancer IP (use this for DNS configuration)
kubectl get svc nginx-li -n matrix
```

**Access**: All LI services accessible via nginx-li LoadBalancer IP

### 1. Synapse LI (01-synapse-li/)

**Read-only Synapse homeserver** synchronized from main instance.

**Configuration**:
- Database: `matrix-postgresql-li-rw.matrix.svc.cluster.local`
- Database name: `matrix_li`
- MinIO endpoint: `minio.matrix.svc.cluster.local:9000` (Main MinIO - shared)
- MinIO bucket: `synapse-media` (Same as main instance)
- **No federation**: `federation_domain_whitelist: []`
- **No registration**: Users synced from main
- **Infinite retention**: `redaction_retention_period: null`

**⚠️ Media Warning**: LI uses main MinIO. Do NOT modify/delete media files from LI.

**Deployment**:

**WHERE:** Run from your **management node**

```bash
kubectl apply -f 01-synapse-li/deployment.yaml
```

**Access**: https://matrix.example.com (from LI network - SAME as main)

### 2. Element Web LI (02-element-web-li/)

**Custom-built web client** showing deleted messages with original content.

**IMPORTANT**: Requires custom image built from `element-web-li/`

**Features** (via React components in custom image):
- Displays deleted messages with **original content** (LIRedactedBody)
- Fetches redacted events from Synapse admin API (LIRedactedEventsStore)
- Visual styling distinguishing deleted messages (light red background)

**Deployment**:

**WHERE:** Run from your **management node**

```bash
kubectl apply -f 02-element-web-li/deployment.yaml
```

**Access**: https://chat-li.example.com (DIFFERENT domain from main)

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

**Access**: https://admin-li.example.com (DIFFERENT domain from main)

### 4. Sync System (04-sync-system/)

**Bridge between main and LI** for data replication.

**Components**:
- **PostgreSQL Logical Replication**: Real-time database sync (main → LI PostgreSQL)
- **Setup Job**: One-time configuration of replication

**Data Flow**:
- **Database**: Main PostgreSQL → (logical replication) → LI PostgreSQL
- **Media**: LI Synapse → (S3 API) → Main MinIO (synapse-media) - no sync needed

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

### 5. key_vault (05-key-vault/)

**E2EE Recovery Key Storage** - stores encrypted recovery keys for lawful intercept.

**Location**: key_vault is in the LI network per CLAUDE.md section 3.3:
> "From the main environment, only: Main Synapse may access `key_vault` in the LI network, and only for: Storing recovery keys."

**Database**: SQLite (local file storage)
- Low I/O requirements (only stores recovery keys, ~1KB each)
- Simple deployment (no external database dependency)
- Data persisted on PVC (1Gi, supports millions of keys)

**Access Model** (enforced by NetworkPolicy):

| Actor | Action | Allowed |
|-------|--------|---------|
| Synapse main (main network) | STORE recovery keys | ✅ Yes |
| LI admin (LI network) | RETRIEVE recovery keys | ✅ Yes |
| Synapse LI | Access key_vault | ❌ No |
| Main users | Access key_vault | ❌ No |

**Workflow for E2EE Recovery**:
1. User sets up E2EE in Element → Synapse main stores encrypted recovery key in key_vault
2. LI admin changes user's password via Synapse Admin LI
3. LI admin retrieves encrypted recovery key from key_vault
4. LI admin decrypts recovery key using RSA private key
5. LI admin logs into Element LI as user, enters recovery key
6. LI admin can now view all E2EE messages for that user

**Security**:
- Recovery keys encrypted with RSA 2048-bit before storage
- RSA private key stored as Kubernetes Secret
- NetworkPolicy strictly limits access
- SQLite database on persistent volume with fsGroup security

**Deployment**:

**WHERE:** Run from your **management node**

```bash
kubectl apply -f 05-key-vault/deployment.yaml
```

**Access**: https://keyvault.example.com (Django admin panel - from LI network)

**Creating Django Admin User**:

After deployment, create a superuser to access the Django admin panel:

```bash
# Create Django superuser for key_vault
kubectl exec -it -n matrix key-vault-0 -- \
  python manage.py createsuperuser \
  --username keyvault-admin \
  --email admin@example.com

# You will be prompted to enter a password interactively
```

**Note:** Django automatically creates the SQLite database file if it doesn't exist. No manual database initialization is required.

**Accessing key_vault Admin Panel**:
1. Navigate to `https://keyvault.example.com/admin` (from LI network)
2. Login with the superuser credentials you created
3. You can view and manage E2EE recovery keys

**Verification**:
```bash
# Check pod is running
kubectl get pods -n matrix -l app.kubernetes.io/name=key-vault

# Check PVC is bound
kubectl get pvc key-vault-data -n matrix

# Test health endpoint
kubectl exec -n matrix key-vault-0 -- curl -s http://localhost:8000/health

# Check Ingress is configured
kubectl get ingress key-vault-ingress -n matrix
```

---

## Domain Configuration

### Complete Domain Reference for LI Instance

| Service | Domain | Same as Main? | Purpose |
|---------|--------|---------------|---------|
| Synapse LI | `matrix.example.com` | **YES** | Homeserver (required for user auth) |
| Element Web LI | `chat-li.example.com` | **NO** | LI admin web client |
| Synapse Admin LI | `admin-li.example.com` | **NO** | LI forensics interface |
| key_vault | `keyvault.example.com` | **NO** | Django admin for E2EE keys |

**Important:**
- **Synapse homeserver** must use the SAME domain as main (`matrix.example.com`)
- **Element Web, Synapse Admin, key_vault** use DIFFERENT domains
- DNS resolution controls which instance receives traffic (main vs LI network)

---

## Network Isolation

### Domain Strategy

**The LI instance uses a MIX of same and different domains:**

| Service | Domain Strategy | Reason |
|---------|----------------|--------|
| Synapse homeserver | **SAME** (`matrix.example.com`) | Required for Matrix protocol - user IDs, signatures, tokens reference this domain |
| Element Web LI | **DIFFERENT** (`chat-li.example.com`) | Separate UI accessible only from LI network |
| Synapse Admin LI | **DIFFERENT** (`admin-li.example.com`) | Separate admin interface for LI only |
| key_vault | **DIFFERENT** (`keyvault.example.com`) | Django admin for E2EE key recovery |

### Why Synapse Must Use Same Hostname

Matrix protocol requires that:
1. `server_name` MUST be identical (`matrix.example.com`)
2. `public_baseurl` MUST be identical (`https://matrix.example.com`)

**Reasons:**
- LI uses replicated data from main instance
- User IDs, event signatures, tokens all reference `matrix.example.com`
- Different server_name would break authentication and event verification
- Matrix clients validate server signatures against the `server_name`

### Configuration

**Synapse (both Main and LI):**
```yaml
server_name: "matrix.example.com"  # MUST be same
public_baseurl: "https://matrix.example.com"  # MUST be same
```

**Element Web LI:**
```json
"m.homeserver": {
    "base_url": "https://matrix.example.com",  // Points to Synapse LI (via LI network DNS)
    "server_name": "matrix.example.com"
}
```

### How LI Access Works

Access to LI is controlled via **nginx-li reverse proxy, network isolation, and DNS**:

```
┌─────────────────────────────────────────────────────────────────┐
│                    ORGANIZATION NETWORK                          │
│                                                                  │
│  ┌──────────────────────┐      ┌───────────────────────────┐   │
│  │    MAIN NETWORK      │      │      LI NETWORK           │   │
│  │                      │      │    (Restricted Access)     │   │
│  │  DNS:                │      │                            │   │
│  │  matrix.example.com  │      │  DNS (or /etc/hosts):      │   │
│  │    → Main Ingress IP │      │  matrix.example.com        │   │
│  │  chat.example.com    │      │    → nginx-li LoadBalancer │   │
│  │    → Main Ingress IP │      │  chat-li.example.com       │   │
│  │                      │      │    → nginx-li LoadBalancer │   │
│  │  Regular users       │      │  admin-li.example.com      │   │
│  │  access main only    │      │    → nginx-li LoadBalancer │   │
│  │                      │      │  keyvault.example.com      │   │
│  │                      │      │    → nginx-li LoadBalancer │   │
│  │                      │      │                            │   │
│  │                      │      │  LI admins only            │   │
│  └──────────────────────┘      └───────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

⭐ nginx-li handles all LI traffic independently ⭐
⭐ LI works even if main instance is completely down ⭐
```

### LI Admin Access Procedure

**For LI administrators to access the LI instance:**

1. **Network Access**: Admin must be on the LI network OR configure local DNS
2. **DNS Configuration**: Admin's DNS must resolve domains to nginx-li LoadBalancer IP
3. **Browser Access**: Admin opens `https://chat-li.example.com`
4. **Traffic Flow**: DNS → nginx-li (LoadBalancer) → Element Web LI → Synapse LI

**LI Admin URLs:**
- Element Web LI: `https://chat-li.example.com`
- Synapse Admin LI: `https://admin-li.example.com`
- key_vault Admin: `https://keyvault.example.com/admin`

### LI Admin DNS Configuration (CRITICAL)

**LI admins MUST configure their DNS to point to the nginx-li LoadBalancer IP.**

Get the nginx-li LoadBalancer IP:
```bash
kubectl get svc nginx-li -n matrix
# Note the EXTERNAL-IP column - this is the nginx-li LoadBalancer IP
```

**Option 1: Local /etc/hosts file (simplest for individual admins)**

Add to `/etc/hosts` (Linux/Mac) or `C:\Windows\System32\drivers\etc\hosts` (Windows):
```
<nginx-li-LoadBalancer-IP>  matrix.example.com
<nginx-li-LoadBalancer-IP>  chat-li.example.com
<nginx-li-LoadBalancer-IP>  admin-li.example.com
<nginx-li-LoadBalancer-IP>  keyvault.example.com
```

**Option 2: LI Network DNS Server (for organization-wide LI access)**

Configure a DNS server in the LI network that resolves:
```
matrix.example.com     A    <nginx-li-LoadBalancer-IP>
chat-li.example.com    A    <nginx-li-LoadBalancer-IP>
admin-li.example.com   A    <nginx-li-LoadBalancer-IP>
keyvault.example.com   A    <nginx-li-LoadBalancer-IP>
```

**Option 3: Split-horizon DNS (enterprise solution)**

Configure organization DNS to return different IPs based on requesting network:
- Main network → Main Ingress IP
- LI network → nginx-li LoadBalancer IP

### Organization Requirements for LI Network

**The organization MUST configure:**

1. **Network Isolation** (organization responsibility):
   - Physically or logically isolated network segment
   - Only authorized LI administrators can access
   - VPN, firewall rules, or physical access control
   - Audit trail for network access

2. **DNS for LI Admins** (choose one):
   - Local `/etc/hosts` on admin workstations
   - Dedicated DNS server in LI network
   - Split-horizon DNS at organization level

3. **TLS Certificates**:
   - Provide certificates for nginx-li domains
   - Self-signed certificates acceptable for isolated LI network
   - See "TLS Certificates for nginx-li" section below

### TLS Certificates for nginx-li

nginx-li requires TLS certificates for all LI domains. Create these as Kubernetes secrets.

**Required TLS Secrets:**

| Secret Name | Domain | Purpose |
|------------|--------|---------|
| `nginx-li-synapse-tls` | `matrix.example.com` | Synapse LI homeserver |
| `nginx-li-element-tls` | `chat-li.example.com` | Element Web LI |
| `nginx-li-admin-tls` | `admin-li.example.com` | Synapse Admin LI |
| `nginx-li-keyvault-tls` | `keyvault.example.com` | key_vault Django admin |

**Option 1: Self-signed certificates (recommended for isolated LI network)**

```bash
# Generate and create all TLS secrets
cd /tmp

# Synapse LI (homeserver - same domain as main)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout synapse-li.key -out synapse-li.crt \
  -subj "/CN=matrix.example.com"
kubectl create secret tls nginx-li-synapse-tls \
  --cert=synapse-li.crt --key=synapse-li.key -n matrix

# Element Web LI
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout element-li.key -out element-li.crt \
  -subj "/CN=chat-li.example.com"
kubectl create secret tls nginx-li-element-tls \
  --cert=element-li.crt --key=element-li.key -n matrix

# Synapse Admin LI
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout admin-li.key -out admin-li.crt \
  -subj "/CN=admin-li.example.com"
kubectl create secret tls nginx-li-admin-tls \
  --cert=admin-li.crt --key=admin-li.key -n matrix

# key_vault
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout keyvault.key -out keyvault.crt \
  -subj "/CN=keyvault.example.com"
kubectl create secret tls nginx-li-keyvault-tls \
  --cert=keyvault.crt --key=keyvault.key -n matrix

# Cleanup temp files
rm -f *.key *.crt
```

**Option 2: Organization-provided certificates**

If your organization provides certificates:
```bash
kubectl create secret tls nginx-li-synapse-tls \
  --cert=/path/to/matrix.example.com.crt \
  --key=/path/to/matrix.example.com.key -n matrix

# Repeat for each domain
```

**Option 3: Wildcard certificate**

If you have a wildcard certificate for `*.example.com`:
```bash
# Create a single secret
kubectl create secret tls nginx-li-wildcard-tls \
  --cert=/path/to/wildcard.crt \
  --key=/path/to/wildcard.key -n matrix

# Then update 06-nginx-li/deployment.yaml to use this single secret
# for all volume mounts
```

**Note:** Self-signed certificates are acceptable for LI because:
- LI network is isolated and private
- Only trusted LI administrators access LI services
- Admins can accept self-signed cert warnings or add CA to trust store

---

## Security & Isolation

### NetworkPolicies (Phase 1)

Three critical policies enforce LI isolation:

**1. key-vault-access**:
- **Ingress**: From Synapse main (STORE keys) AND LI admin (RETRIEVE keys)
- **Effect**: Synapse main can store keys, LI admin can retrieve keys for E2EE recovery
- **File**: `infrastructure/04-networking/networkpolicies.yaml`

**2. li-instance-isolation**:
- **Applies to**: All pods with `matrix.instance: li`
- **Egress**: LI PostgreSQL, **main MinIO** (shared), Redis LI, DNS
- **Effect**: LI **CANNOT** access main PostgreSQL or main Redis
- **Effect**: LI **CAN** access main MinIO for media (read-only in practice)
- **File**: `infrastructure/04-networking/networkpolicies.yaml`

**3. sync-system-access**:
- **Applies to**: Pods with `app.kubernetes.io/name: sync-system`
- **Egress**: Access to **BOTH** main and LI PostgreSQL
- **Effect**: Sync system handles database replication only (no media sync)
- **File**: `infrastructure/04-networking/sync-system-networkpolicy.yaml`

### Network-Level Access Control

**IMPORTANT**: LI access control is enforced at the **network level**, not via IP whitelisting annotations.

**How it works:**
- **nginx-li LoadBalancer** is only accessible from the LI network
- The organization configures their network infrastructure to restrict access to the LI network
- Only authorized LI administrators can reach the nginx-li LoadBalancer IP
- This is more secure than IP whitelisting because it operates at the network layer

**nginx-li NetworkPolicies** (automatically applied):
- `nginx-li-egress`: Allows nginx-li to reach LI services
- `allow-from-nginx-li`: Allows LI services to receive traffic from nginx-li

See: `infrastructure/04-networking/networkpolicies.yaml` (policies #17 and #18)

### Authentication

**LI authentication relies on two layers:**

1. **Network-level isolation**: Only LI network users can reach nginx-li
2. **Synapse authentication**: LI admins log in with Matrix accounts (same credentials as main)

**Optional: Add basic auth to nginx-li**

If additional authentication is required before accessing LI services, you can add htpasswd to nginx-li:

```bash
# Generate htpasswd file
htpasswd -c auth li-admin

# Create secret
kubectl create secret generic nginx-li-auth \
  --from-file=auth \
  -n matrix

# Then update nginx-li deployment to mount this secret and configure basic_auth
# See nginx documentation for basic_auth directive
```

**Note:** Since LI is only accessible from the isolated LI network, network-level access control is usually sufficient.

## LI Node Requirements

### Node Labeling (CRITICAL)

**Per CLAUDE.md Section 7.1**: All LI services must run on a **single server** (the LI node).

**Before deploying LI components**, you MUST label your LI node:

```bash
# Identify your LI node
kubectl get nodes

# Label the LI node (replace <li-node-name> with your node name)
kubectl label node <li-node-name> node-role.kubernetes.io/li=true

# Optionally, add a taint to prevent non-LI workloads (recommended for dedicated LI servers)
kubectl taint nodes <li-node-name> dedicated=li:NoSchedule
```

**Verify the label:**
```bash
kubectl get nodes -l node-role.kubernetes.io/li=true
```

All LI components (Redis LI, PostgreSQL LI, Synapse LI, Element Web LI, Synapse Admin LI, nginx-li, key_vault, sync-system) are configured with:
- `nodeSelector: node-role.kubernetes.io/li: "true"` - ensures scheduling on LI node
- `tolerations` for `dedicated=li:NoSchedule` - allows running on tainted LI node

**Important**: If you don't label a node, LI pods will remain in `Pending` state.

---

## Deployment Order

**WHERE:** Run all commands from your **management node**

**WORKING DIRECTORY:** `deployment/li-instance/`

Deploy in this order to ensure dependencies:

```bash
# 0. PREREQUISITE: Label the LI node (see "LI Node Requirements" section above)
kubectl label node <li-node-name> node-role.kubernetes.io/li=true

# 1. Ensure Phase 1 infrastructure is running
kubectl get cluster -n matrix matrix-postgresql-li
kubectl get tenant -n matrix matrix-minio  # Main MinIO for sync source

# 2. Deploy sync system NetworkPolicy
kubectl apply -f ../infrastructure/04-networking/sync-system-networkpolicy.yaml

# 3. Deploy Redis LI (required for Synapse LI cache)
kubectl apply -f 00-redis-li/deployment.yaml

# Wait for Redis LI to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=redis,app.kubernetes.io/instance=li -n matrix --timeout=120s

# 4. Verify main MinIO is accessible (LI uses main MinIO for media)
# Main MinIO should already be deployed in Phase 1
kubectl get pods -n matrix -l v1.min.io/tenant=matrix-minio

# 5. Deploy sync system (syncs DB only - media uses main MinIO directly)
kubectl apply -f 04-sync-system/deployment.yaml

# 6. Run replication setup job (CRITICAL - must run once)
# Store job name in variable to use consistently
JOB_NAME="sync-setup-$(date +%s)"

# Create the job
kubectl create job --from=job/sync-system-setup-replication \
  $JOB_NAME -n matrix

# Wait for job to complete (using same job name)
kubectl wait --for=condition=complete job/$JOB_NAME -n matrix --timeout=300s

# Check replication status (using same job name)
kubectl logs job/$JOB_NAME -n matrix

# 7. Deploy Synapse LI
kubectl apply -f 01-synapse-li/deployment.yaml

# Wait for Synapse LI to be ready
kubectl wait --for=condition=ready pod/synapse-li-0 -n matrix --timeout=300s

# 8. Deploy Element Web LI
kubectl apply -f 02-element-web-li/deployment.yaml

# 9. Deploy Synapse Admin LI
kubectl apply -f 03-synapse-admin-li/deployment.yaml

# 10. Deploy key_vault (E2EE recovery key storage)
kubectl apply -f 05-key-vault/deployment.yaml

# Wait for key_vault to be ready
kubectl wait --for=condition=ready pod/key-vault-0 -n matrix --timeout=300s

# 11. Create TLS certificate secrets for nginx-li (REQUIRED)
# See "TLS Certificates for nginx-li" section below for options
# Example using self-signed certificates:
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout synapse-li-tls.key -out synapse-li-tls.crt \
  -subj "/CN=matrix.example.com"
kubectl create secret tls nginx-li-synapse-tls \
  --cert=synapse-li-tls.crt --key=synapse-li-tls.key -n matrix

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout element-li-tls.key -out element-li-tls.crt \
  -subj "/CN=chat-li.example.com"
kubectl create secret tls nginx-li-element-tls \
  --cert=element-li-tls.crt --key=element-li-tls.key -n matrix

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout admin-li-tls.key -out admin-li-tls.crt \
  -subj "/CN=admin-li.example.com"
kubectl create secret tls nginx-li-admin-tls \
  --cert=admin-li-tls.crt --key=admin-li-tls.key -n matrix

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout keyvault-tls.key -out keyvault-tls.crt \
  -subj "/CN=keyvault.example.com"
kubectl create secret tls nginx-li-keyvault-tls \
  --cert=keyvault-tls.crt --key=keyvault-tls.key -n matrix

# 12. Deploy nginx-li (LI reverse proxy - CRITICAL for independence)
kubectl apply -f 06-nginx-li/deployment.yaml

# Wait for nginx-li to be ready
kubectl wait --for=condition=available deployment/nginx-li -n matrix --timeout=120s

# Get the nginx-li LoadBalancer IP (use for DNS configuration)
kubectl get svc nginx-li -n matrix

# 13. Create Django superuser for key_vault
kubectl exec -it -n matrix key-vault-0 -- \
  python manage.py createsuperuser \
  --username keyvault-admin \
  --email admin@example.com
# (You will be prompted to enter a password interactively)

# 14. Verify all components
kubectl get pods -n matrix -l matrix.instance=li
kubectl get svc nginx-li -n matrix
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

### Test LI Access

**Note**: All tests must be run from the LI network where DNS resolves to LI Ingress IP.

```bash
# Test Synapse LI API (from LI network)
curl https://matrix.example.com/_matrix/client/versions

# Test Element Web LI (from LI network - should show watermark)
# Open in browser: https://chat-li.example.com

# Test Synapse Admin LI (from LI network - should require auth)
curl -u admin:password https://admin-li.example.com

# Test key_vault admin (from LI network)
# Open in browser: https://keyvault.example.com/admin

# Login to LI instance (users synced from main)
# Use same Matrix credentials as main instance
# Access Element Web LI at https://chat-li.example.com
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

### Media Access

**Direct S3 API** - LI uses main MinIO directly:
1. LI Synapse connects to main MinIO (`minio.matrix.svc.cluster.local:9000`)
2. LI Synapse reads from same bucket as main Synapse (`synapse-media`)
3. **Lag**: None - real-time access via S3 API
4. **Benefit**: Simpler architecture, reduced storage on LI server

**Data Flow**:
```
LI Synapse → S3 API → Main MinIO (synapse-media)
```

**⚠️ CRITICAL WARNING**:
- Media is shared with main instance
- LI admins **must NOT** modify or delete media files
- Any changes affect the main instance
- Media quarantine/deletion must be done through main Synapse Admin

## Monitoring

### Metrics

Both Synapse LI and sync system expose Prometheus metrics:

```promql
# Synapse LI health
up{job="synapse-li"}

# Replication lag (bytes)
pg_replication_lag{cluster="matrix-postgresql-li"}

# MinIO health (main MinIO used by LI)
up{job="minio"}

# LI Synapse S3 request latency (if instrumented)
synapse_s3_request_duration_seconds{instance="synapse-li"}
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

### Media access issues (LI uses main MinIO)

```bash
# Check main MinIO is accessible from LI Synapse
kubectl exec -n matrix synapse-li-0 -- \
  curl -s http://minio.matrix.svc.cluster.local:9000/minio/health/live

# Check S3 credentials are configured correctly
kubectl get secret synapse-li-secrets -n matrix -o yaml | grep S3_

# Check main MinIO bucket has files
kubectl exec -n matrix -it \
  $(kubectl get pods -n matrix -l v1.min.io/tenant=matrix-minio -o name | head -1) -- \
  mc ls minio/synapse-media --summarize

# Check NetworkPolicy allows LI access to main MinIO
kubectl get networkpolicy minio-access -n matrix -o yaml | grep -A10 "matrix.instance: li"
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

**Cause**: Signing key not accessible or replication not complete.

```bash
# Verify signing key secret exists (Synapse LI uses MAIN signing key)
# This is the cleanest solution - no copying needed, automatically in sync
kubectl get secret synapse-secrets -n matrix -o yaml | grep signing.key
# Should return the signing key

# Check that Synapse LI pod can access the signing key volume
kubectl describe pod synapse-li-0 -n matrix | grep -A5 "signing-key"
# Should show volume mounted from synapse-secrets

# Check users table is replicated
kubectl exec -n matrix matrix-postgresql-li-1-0 -- \
  psql -U synapse_li -d matrix_li -c \
  "SELECT COUNT(*) FROM users;"
# Should match main instance user count
```

**Note**: Synapse LI is configured to use the main Synapse's signing key directly (from `synapse-secrets`). This eliminates the need for manual key copying and ensures authentication always works.

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

## Storage Capacity Planning

### ⚠️ CRITICAL: Infinite Retention Storage Requirements

The LI instance has **infinite retention** (`redaction_retention_period: null`), meaning data **NEVER** expires. Storage requirements grow continuously and must be carefully planned.

### Storage Components

**1. PostgreSQL Database Storage** (LI server)
- Database: `matrix_li`
- Contains: All messages, events, users, rooms, media metadata
- Growth rate: Depends on active users and message frequency
- **Never shrinks** - only grows
- **Stored on LI server** - requires storage planning

**2. MinIO Media Storage** (MAIN server - shared)
- LI uses **main MinIO** directly (no separate LI MinIO)
- Bucket: `synapse-media` (same as main instance)
- **No additional storage needed on LI server** for media
- **Read-only access** - LI must not modify media
- Media storage planning is done for main instance only (see main infrastructure docs)

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

### Media Storage (Main MinIO - No LI Planning Required)

LI instance uses **main MinIO directly** for media storage. This means:

- **No separate media storage required on LI server**
- **No MinIO capacity planning needed for LI** - all media storage is handled by main infrastructure
- **Reduced LI server requirements** - only PostgreSQL storage needs to be planned
- For media storage planning, see: `deployment/infrastructure/03-minio/README.md`

**Benefit**: Simpler LI deployment with significantly reduced storage costs.

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

#### MinIO Media Storage (Main Instance)

LI uses main MinIO directly. For MinIO monitoring and expansion, see: `deployment/infrastructure/03-minio/README.md`

**LI-specific check - verify connectivity to main MinIO:**
```bash
# Check LI Synapse can reach main MinIO
kubectl exec -n matrix synapse-li-0 -- \
  curl -s http://minio.matrix.svc.cluster.local:9000/minio/health/live

# Check main MinIO synapse-media bucket (from main MinIO pod)
kubectl exec -n matrix -it \
  $(kubectl get pods -n matrix -l v1.min.io/tenant=matrix-minio -o name | head -1) -- \
  mc ls minio/synapse-media --summarize
```

### Storage Growth Rate Monitoring

**Calculate actual growth rate (PostgreSQL only - media is on main MinIO):**

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
```

**Automated Monitoring (Prometheus):**

```promql
# PostgreSQL growth rate (bytes per day)
rate(pg_database_size_bytes{datname="synapse_li"}[7d]) * 86400

# Projected days until 85% full
(
  (pg_stat_database_size_bytes * 0.85) - pg_database_size_bytes
) / (rate(pg_database_size_bytes[30d]) * 86400)

# For MinIO monitoring, see main infrastructure monitoring
# LI uses main MinIO, so no separate LI media monitoring needed
```

### Capacity Planning Checklist

Before deployment:
- [ ] Calculate expected CCU and active user percentage
- [ ] Estimate daily message volume
- [ ] Provision PostgreSQL storage for 3 years minimum
- [ ] Verify main MinIO has sufficient capacity (media is shared)
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

**Note:** MinIO storage optimization is managed at the main infrastructure level since LI uses main MinIO.

**3. Deduplication**

- **PostgreSQL**: Event deduplication already handled by Synapse

### Disaster Recovery Implications

**Infinite retention increases backup requirements:**

**LI Backup Storage Requirements:**
- PostgreSQL backups: Same growth rate as LI database
- Point-in-time recovery (PITR): WAL archiving storage (see infrastructure/01-postgresql/README.md)
- **Note:** Media backups are handled at main infrastructure level (LI uses main MinIO)

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

# View nginx-li access logs (LI's independent reverse proxy)
kubectl logs -n matrix -l app.kubernetes.io/name=nginx,app.kubernetes.io/instance=li --tail=100
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
- [Synapse Admin](https://github.com/Awesome-Technologies/synapse-admin)
- [Matrix Specification](https://spec.matrix.org/)
