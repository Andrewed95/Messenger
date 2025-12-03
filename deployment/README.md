# Matrix/Synapse Production Deployment

Complete production-grade Matrix Synapse homeserver deployment on Kubernetes, supporting 100-20,000+ concurrent users with high availability, lawful intercept, and antivirus protection.

## ⚠️ IMPORTANT: Image Management Assumption

**This solution assumes all container images are pre-built and available.**

- ✅ **What this solution DOES**: Configures all services (Synapse settings, database parameters, Redis config, etc.)
- ❌ **What this solution DOES NOT**: Build, create, or update container images
- 📦 **Your responsibility**: Provide pre-built images for all services
- 🔧 **Configuration**: All image URLs are configurable in `values/images.yaml`

## 🌐 Intranet Deployment Model

**This solution is designed for intranet operation after initial setup.**

### Deployment Phases:

| Phase | Internet Required | Description |
|-------|-------------------|-------------|
| Initial Setup | ✅ Yes | Pull container images, install Helm charts, get TLS certificates |
| Configuration | ✅ Yes | Apply Kubernetes manifests, wait for pods to stabilize |
| Verification | ✅ Yes | Test end-to-end functionality, verify all services |
| Production | ❌ No | Internet can be cut - messenger runs fully within intranet |

### What Your Organization Must Provide:

**Before Deployment (with internet access):**
1. **Container Images**: Pre-pull all images to private registry or nodes
2. **TLS Certificates**: Either use Let's Encrypt during setup, or provide your own certificates
3. **DNS Configuration**: Internal DNS resolving all service domains

## 🎯 What This Deployment Provides

### Core Features
- ✅ **Scalable**: 100 CCU → 20,000+ CCU with horizontal scaling
- ✅ **High Availability**: Zero single points of failure
- ✅ **Lawful Intercept**: Complete LI instance with E2EE recovery
- ✅ **Antivirus**: Real-time ClamAV scanning of all media
- ✅ **Monitoring**: Prometheus + Grafana + Loki observability
- ✅ **Intranet Ready**: Operates fully within internal network after initial setup

### Architecture Highlights
- **Worker-based Synapse**: 9 worker types with intelligent HAProxy routing
- **HA Database**: CloudNativePG with synchronous replication
- **Distributed Storage**: MinIO with EC:4 erasure coding
- **Redis Sentinel**: Automatic failover for caching
- **Group Calls**: LiveKit SFU + coturn for video/voice

---

## 📁 Directory Structure

```
deployment/
├── README.md                    ← ⭐ YOU ARE HERE (start here!)
├── namespace.yaml               ← Kubernetes namespace definition
│
├── infrastructure/              ← Phase 1: Core Infrastructure
│   ├── 01-postgresql/           # CloudNativePG (main + LI clusters)
│   ├── 02-redis/                # Redis Sentinel (HA caching)
│   ├── 03-minio/                # MinIO distributed object storage
│   └── 04-networking/           # Ingress, TLS
│
├── main-instance/               ← Phase 2: Main Matrix Instance
│   ├── 01-synapse/              # Synapse main process
│   ├── 02-element-web/          # Web client interface
│   ├── 02-workers/              # 9 worker types (synchrotron, generic, media, event-persister, etc.)
│   ├── 03-haproxy/              # Intelligent load balancer
│   ├── 04-livekit/              # Video/voice calling (Helm reference)
│   └── 06-coturn/               # TURN/STUN NAT traversal (peer-to-peer calls)
│
├── li-instance/                 ← Phase 3: Lawful Intercept
│   ├── 00-redis-li/             # Isolated Redis for LI (no HA required)
│   ├── 01-synapse-li/           # Writable Synapse instance (for password resets)
│   ├── 02-element-web-li/       # LI web client (shows deleted messages)
│   ├── 03-synapse-admin-li/     # Admin interface for forensics + sync trigger
│   ├── 04-sync-system/          # Sync documentation (sync built into synapse-li)
│   ├── 05-key-vault/            # E2EE recovery key storage (SQLite)
│   └── 06-nginx-li/             # ⭐ Independent reverse proxy (works when main is down)
│
├── monitoring/                  ← Phase 4: Observability Stack
│   ├── 01-prometheus/           # ServiceMonitors
│   ├── 02-grafana/              # Dashboards (Synapse, PostgreSQL, LI)
│   └── 03-loki/                 # Log aggregation (30-day retention)
│
├── antivirus/                   ← Phase 5: ClamAV Protection
│   ├── 01-clamav/               # ClamAV DaemonSet (virus scanner)
│   └── 02-scan-workers/         # Content Scanner (media proxy)
│
├── values/                      ← Helm Chart Values
│   ├── prometheus-stack-values.yaml
│   ├── loki-values.yaml
│   ├── cloudnativepg-values.yaml
│   ├── minio-operator-values.yaml
│   ├── metallb-values.yaml
│   ├── nginx-ingress-values.yaml
│   ├── cert-manager-values.yaml
│   ├── redis-synapse-values.yaml
│   ├── redis-livekit-values.yaml
│   └── livekit-values.yaml
│
└── docs/                        ← Reference Guides
    ├── 00-WORKSTATION-SETUP.md           (REQUIRED: Setup management node)
    ├── 00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md  (REQUIRED: Setup K8s cluster)
    ├── SCALING-GUIDE.md                  (REQUIRED: Determine resources)
    ├── CONFIGURATION-REFERENCE.md        (Optional: Parameter details)
    ├── OPERATIONS-UPDATE-GUIDE.md        (Post-deployment operations)
    ├── SECRETS-MANAGEMENT.md             (Optional: Advanced secrets)
    ├── HAPROXY-ARCHITECTURE.md           (Optional: Routing details)
    └── MATRIX-AUTHENTICATION-SERVICE.md  (Optional: Enterprise SSO)
```

---

## 🚀 Quick Start Guide

### Prerequisites

**Infrastructure (Organization Must Provide):**
- Kubernetes cluster (1.28+) - see `docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`
- Storage class for PVCs (verify: `kubectl get storageclass`) - **CRITICAL: deployment will fail without this**
- Domain names for services (matrix.example.com, chat.example.com, etc.)
- Internal DNS resolving all domain names to cluster ingress
- `kubectl` and `helm` installed on management workstation
- **Dedicated monitoring server** (label with: `kubectl label node <node> monitoring=true`)

**Minimum Server Requirements (per scale):**
| Scale | Control Plane | Worker Nodes | Total RAM | Total CPU |
|-------|--------------|--------------|-----------|-----------|
| 100 CCU | 3 × 4CPU/8GB | 6 × 8CPU/32GB | 216 GB | 60 cores |
| 1K CCU | 3 × 4CPU/8GB | 12 × 8CPU/32GB | 408 GB | 108 cores |
| 5K CCU | 3 × 8CPU/16GB | 20 × 16CPU/64GB | 1.3 TB | 344 cores |

See `docs/SCALING-GUIDE.md` for detailed requirements.

**Network Requirements:**
- All nodes must communicate on internal network
- Ports: 6443 (K8s API), 443 (HTTPS), 5349 (TURN/TLS)
- LI instance requires separate network isolation (if compliance required)

### Before You Begin - Documentation Guide

**📖 REQUIRED Reading (follow in order):**

1. **`BIGPICTURE.md`** ← Understand what you're building and how components fit together
2. **`docs/SCALING-GUIDE.md`** ← Determine resource requirements for your scale (100 CCU to 20K CCU)
3. **`docs/00-WORKSTATION-SETUP.md`** ← Set up kubectl, helm, and required tools on your workstation
4. **`docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`** ← Set up Kubernetes cluster (assumes VMs are provided)
5. **THIS README** ← Complete all deployment phases below

**📚 OPTIONAL Reference (read as needed):**
- `docs/CONFIGURATION-REFERENCE.md` - Deep dive into all configuration parameters (if you need more details than Step 6 above)
- `docs/SECRETS-MANAGEMENT.md` - Advanced secret management strategies (Vault, external secret managers)
- Component-specific `README.md` files in each directory - Additional technical details for troubleshooting

**After deployment is complete:**
- `docs/OPERATIONS-UPDATE-GUIDE.md` - How to update and maintain your deployment

---

## ⚙️ CONFIGURATION (Complete BEFORE Deployment)

**CRITICAL: You MUST configure all values before running any deployment commands.**

This section guides you through ALL configuration that must be done FIRST.

### Step 1: Generate All Secrets

Every `CHANGEME` value must be replaced with secure random strings.

**WHERE:** Run these commands on your **management node** (the machine where kubectl is installed)

**Generate secrets:**
```bash
# Helper function to generate secure random strings
generate_secret() {
    openssl rand -base64 32 | tr -d /=+ | cut -c1-${1:-32}
}

# Generate all required secrets (save these securely!)
echo "POSTGRES_PASSWORD=$(generate_secret)"
echo "REDIS_PASSWORD=$(generate_secret)"
echo "LI_REDIS_PASSWORD=$(generate_secret)"
echo "MINIO_ROOT_PASSWORD=$(generate_secret)"
echo "SYNAPSE_MACAROON_SECRET=$(generate_secret)"
echo "SYNAPSE_REGISTRATION_SECRET=$(generate_secret)"
echo "SYNAPSE_FORM_SECRET=$(generate_secret)"
echo "REPLICATION_SECRET=$(generate_secret)"
echo "TURN_SECRET=$(generate_secret)"
echo "KEY_VAULT_API_KEY=$(generate_secret)"
echo "KEY_VAULT_DJANGO_SECRET=$(generate_secret 50)"
echo "KEY_VAULT_ENCRYPTION_KEY=$(generate_secret 32)"
echo "CONTENT_SCANNER_PICKLE_KEY=$(generate_secret 32)"
```

**Save these values!** You'll need them in the next step.

### Step 2: Update All Secret Files

Replace ALL `CHANGEME` placeholders with the secrets you generated.

**WHERE:** On your **management node**, in the `deployment/` directory (root of this repository)

**WHAT:** You need to edit 7 YAML files to replace CHANGEME values with your generated secrets

**Files to update:**
```bash
# First, find all files with CHANGEME values
# Run from the deployment directory:
grep -r "CHANGEME" . --include="*.yaml" | cut -d: -f1 | sort -u

# Key files that MUST be updated (paths relative to deployment/):
main-instance/01-synapse/secrets.yaml              # 12 secrets
li-instance/01-synapse-li/deployment.yaml          # 7 secrets
li-instance/05-key-vault/deployment.yaml           # 3 secrets (DJANGO_SECRET_KEY, API_KEY, RSA_PRIVATE_KEY)
main-instance/06-coturn/deployment.yaml            # 2 secrets
infrastructure/03-minio/secrets.yaml               # 2 secrets
# NOTE: Sync system is built into synapse-li - no additional secrets needed
```

**HOW TO EDIT each file:**
1. Open with text editor (from deployment directory):
   ```bash
   nano main-instance/01-synapse/secrets.yaml
   ```
2. Find each `CHANGEME_*` placeholder and replace with the corresponding secret from Step 1
3. Save (Ctrl+O, Enter) and close (Ctrl+X)
4. Repeat for all 7 files above

### Step 3: Configure Domains

Replace example domains with your actual domains.

**Complete Domain Reference:**

| Instance | Service | Example Domain | Purpose |
|----------|---------|----------------|---------|
| **Main** | Synapse homeserver | `matrix.example.com` | Matrix server_name (user IDs: @user:matrix.example.com) |
| **Main** | Element Web | `chat.example.com` | Main web client |
| **Main** | coturn | `turn.example.com` | TURN/STUN server for calls |
| **Main** | Grafana monitoring | `grafana.example.com` | Monitoring dashboards |
| **LI** | Synapse LI | `matrix.example.com` | **SAME as main** (required for user login) |
| **LI** | Element Web LI | `chat-li.example.com` | **DIFFERENT** - LI admin web client |
| **LI** | Synapse Admin LI | `admin-li.example.com` | **DIFFERENT** - LI forensics interface |
| **LI** | key_vault | `keyvault.example.com` | **DIFFERENT** - Django admin for E2EE keys |

**Note:** Main instance admin API is accessed via HAProxy routing (`/_synapse/admin/*`) through `matrix.example.com`. Synapse Admin UI is only deployed for LI instance.

**IMPORTANT - Domain Rules:**
- **Synapse homeserver** (server_name): MUST be the **SAME** for main and LI
  - Users log in as `@user:matrix.example.com` on both instances
  - LI needs same server_name to authenticate users from main
- **Element Web, Synapse Admin, key_vault**: Use **DIFFERENT** domains for LI
  - LI admin accesses separate UI at different URLs
  - Network isolation controls who can reach LI domains

**Files to update:**

```bash
# Main instance
main-instance/01-synapse/configmap.yaml         # server_name, public_baseurl
main-instance/02-element-web/deployment.yaml    # Element Web config + Ingress
main-instance/06-coturn/deployment.yaml         # TURN realm

# LI instance (DIFFERENT domains except homeserver)
li-instance/01-synapse-li/deployment.yaml       # server_name (SAME as main)
li-instance/02-element-web-li/deployment.yaml   # chat-li domain (DIFFERENT)
li-instance/03-synapse-admin-li/deployment.yaml # admin-li domain (DIFFERENT)
li-instance/05-key-vault/deployment.yaml        # keyvault domain (DIFFERENT)

# Infrastructure
infrastructure/04-networking/cert-manager-install.yaml  # TLS certificates
```

**HOW TO UPDATE:**
```bash
# Run from the deployment directory:

# Main instance domains
find . -path "./main-instance/*" -name "*.yaml" -exec sed -i 's/matrix\.example\.com/YOUR-MATRIX-DOMAIN/g' {} +
find . -path "./main-instance/*" -name "*.yaml" -exec sed -i 's/chat\.example\.com/YOUR-CHAT-DOMAIN/g' {} +
find . -path "./main-instance/*" -name "*.yaml" -exec sed -i 's/turn\.example\.com/YOUR-TURN-DOMAIN/g' {} +

# LI instance domains (homeserver SAME, others DIFFERENT)
find . -path "./li-instance/*" -name "*.yaml" -exec sed -i 's/matrix\.example\.com/YOUR-MATRIX-DOMAIN/g' {} +
find . -path "./li-instance/*" -name "*.yaml" -exec sed -i 's/chat-li\.example\.com/YOUR-CHAT-LI-DOMAIN/g' {} +
find . -path "./li-instance/*" -name "*.yaml" -exec sed -i 's/admin-li\.example\.com/YOUR-ADMIN-LI-DOMAIN/g' {} +
find . -path "./li-instance/*" -name "*.yaml" -exec sed -i 's/keyvault\.example\.com/YOUR-KEYVAULT-DOMAIN/g' {} +
```

### Step 4: Verify Storage Class

Check your Kubernetes storage class exists.

**WHERE:** Run from your **management node**

**WHAT:** Check which storage class your cluster uses for persistent volumes

```bash
# List available storage classes
kubectl get storageclass

# Look for a default storage class (marked with "(default)")
# Common names: standard, local-path, gp2, fast-ssd, longhorn
```

**If your cluster uses a non-"standard" storage class name**, you must update these files:

**WHERE TO EDIT:** On your **management node**, in the deployment directory, edit these 4 files:

1. `infrastructure/01-postgresql/main-cluster.yaml` (line 33)
2. `infrastructure/01-postgresql/li-cluster.yaml` (line 32)
3. `infrastructure/02-redis/redis-statefulset.yaml` (line 312)
4. `main-instance/01-synapse/main-statefulset.yaml` (line 35)

**WHAT TO CHANGE:**
```yaml
# Find this line in each file:
storageClassName: standard

# Replace "standard" with your actual storage class name:
storageClassName: YOUR-STORAGE-CLASS-NAME
```

**HOW TO EDIT:** Use nano to edit each file, find the line, replace "standard", save and exit.

### Step 5: Generate Synapse Signing Key

Synapse requires a unique signing key for federation.

**WHERE:** Run on your **management node** (or any machine with Docker installed)

**WHAT:** Generate a unique ed25519 signing key for your homeserver

```bash
# Generate signing key using Docker
docker run --rm matrixdotorg/synapse:v1.119.0 generate_signing_key

# Or if you have Synapse installed locally:
python -m synapse.app.homeserver \
    --config-path=/dev/null \
    --generate-keys
```

**The output will look like:**
```
ed25519 a_long ed25519_key_string_here
```

**Copy the entire output** (starts with `ed25519`) and update these 2 files:

**WHERE TO UPDATE:** On your **management node**, in the deployment directory, edit:

1. `main-instance/01-synapse/secrets.yaml`
   - Find the `signing.key` field
   - Replace the value with your generated key

2. `li-instance/01-synapse-li/deployment.yaml`
   - Find `SYNAPSE_SIGNING_KEY` environment variable
   - Replace the value with your generated key (same key for both)

### Step 6: Review Configuration Parameters

**Key parameters to verify** (in `deployment/main-instance/01-synapse/configmap.yaml`, under the `homeserver.yaml:` section):

| Parameter | Default | Your Value | Notes |
|-----------|---------|------------|-------|
| `max_upload_size` | `100M` | _______ | Maximum file upload size |
| `media_retention_period` | `7d` | _______ | How long to keep remote media (e.g., "7d" = 7 days, "null" = forever) |
| `enable_registration` | `false` | _______ | Allow open registration? (recommend: false) |
| `url_preview_enabled` | `true` | _______ | Generate link previews? |
| `redaction_retention_period` | `null` | _______ | Keep deleted messages? (null = forever, "7d" = 7 days) |

**For detailed parameter explanations**, see `docs/CONFIGURATION-REFERENCE.md` (optional reference).

### Step 7: Configure Resource Sizes (Based on Scale)

**From `docs/SCALING-GUIDE.md`, determine your scale:**

| Scale | Users | Resource Profile |
|-------|-------|------------------|
| 100 CCU | ~500 total users | Small (default configs work) |
| 1K CCU | ~5K total users | Medium (increase PostgreSQL, Redis) |
| 5K CCU | ~25K total users | Large (increase workers, storage) |
| 10K+ CCU | 50K+ total users | Enterprise (scale all components) |

**If > 100 CCU**, update resource requests/limits in deployment files.
**See:** `docs/SCALING-GUIDE.md` for exact values per component.

### Step 8: DNS Configuration (Before Deployment)

**IMPORTANT: Configure DNS A records BEFORE deploying** (so cert-manager can get TLS certificates):

**Main Instance DNS Records:**
```bash
# Point to main Kubernetes Ingress external IP
# (You'll get this IP after deploying Ingress in Phase 1)

matrix.example.com         → <main-ingress-external-ip>  # Synapse homeserver
chat.example.com           → <main-ingress-external-ip>  # Element Web (main)
turn.example.com           → <turn-external-ip>           # TURN server
grafana.example.com        → <main-ingress-external-ip>  # Monitoring dashboard
```

**LI Instance DNS Records:**
```bash
# Point to LI Kubernetes Ingress IP (in LI network)
# LI network is isolated - only authorized admins can reach these

matrix.example.com         → <li-ingress-ip>              # SAME homeserver (in LI network DNS)
chat-li.example.com        → <li-ingress-ip>              # Element Web LI (DIFFERENT domain)
admin-li.example.com       → <li-ingress-ip>              # Synapse Admin LI (DIFFERENT domain)
keyvault.example.com       → <li-ingress-ip>              # key_vault Django admin
```

**LI Network Isolation:**
- LI services run on isolated network (organization configures this)
- LI DNS resolves `matrix.example.com` to LI Ingress (not main Ingress)
- Element Web LI and Synapse Admin LI use different domain names
- Only authorized LI admins can reach the LI network
- See `li-instance/README.md` for complete LI setup details

**Note:** You can configure DNS after Phase 1 (Infrastructure) is complete.

---

### ✅ Configuration Checklist

Before proceeding to deployment, verify:

- [ ] All secrets generated and CHANGEME values replaced (45 occurrences in YAML files)
- [ ] All domains updated from example.com to your actual domains (62 occurrences in YAML files)
- [ ] Storage class verified and configured
- [ ] Synapse signing key generated and configured
- [ ] Resource sizes reviewed (if > 100 CCU)
- [ ] DNS records ready (can configure after Phase 1)
- [ ] Configuration files saved

**If all checkboxes are complete, you're ready to deploy!**

---

## 📋 Deployment Steps (Execute After Configuration Above)

**⚠️ IMPORTANT:** ALL commands below must be run from your **management node** (where kubectl and helm are installed)

### Option A: Automated Deployment (Recommended)

Use the automated deployment script for a streamlined experience:

```bash
# 1. Copy and configure environment file
cp config.env.example config.env
nano config.env  # Edit all values for your organization

# 2. Run automated deployment
./scripts/deploy-all.sh

# 3. For specific phase only:
./scripts/deploy-all.sh --phase 1  # Infrastructure only
./scripts/deploy-all.sh --phase 4  # Monitoring only

# 4. Dry run (shows what would be deployed):
./scripts/deploy-all.sh --dry-run
```

**Features of deploy-all.sh:**
- ✅ Verifies storage class exists before deployment
- ✅ Checks for monitoring node label
- ✅ Validates all CHANGEME placeholders are replaced
- ✅ Safe to re-run (idempotent - won't break previous deployment)
- ✅ Detailed error output with debugging commands

### Option B: Manual Deployment

Follow the phase-by-phase commands below for manual control:

---

### **Phase 1: Core Infrastructure** (HA Database, Storage, Networking)

**WHERE:** Run ALL commands in this phase from your **management node**

**WORKING DIRECTORY:** `deployment/` (root of this repository)

**Step 0: Create Namespace** (MUST do first)
```bash
# Create the matrix namespace before any other resources
kubectl apply -f namespace.yaml

# Verify namespace was created
kubectl get namespace matrix
```

**Deploy PostgreSQL Clusters:**
```bash
# Run from the deployment directory:
# Main cluster (3 instances, HA)
kubectl apply -f infrastructure/01-postgresql/main-cluster.yaml

# LI cluster (2 instances, read-only)
kubectl apply -f infrastructure/01-postgresql/li-cluster.yaml

# Wait for clusters to be ready
kubectl wait --for=condition=Ready cluster/matrix-postgresql -n matrix --timeout=600s
kubectl wait --for=condition=Ready cluster/matrix-postgresql-li -n matrix --timeout=600s
```

**Deploy Redis Sentinel:**
```bash
# Run from your management node in the deployment directory:
kubectl apply -f infrastructure/02-redis/redis-statefulset.yaml

# Wait for Redis to be ready
kubectl wait --for=condition=Ready pod/redis-0 -n matrix --timeout=300s
```

**Deploy MinIO:**
```bash
# Install MinIO Operator (if not already installed)
helm repo add minio-operator https://operator.min.io
helm install minio-operator minio-operator/operator \
  --namespace minio-operator --create-namespace \
  --values values/minio-operator-values.yaml

# Deploy MinIO Tenant
kubectl apply -f infrastructure/03-minio/tenant.yaml

# Wait for MinIO to be ready
kubectl wait --for=condition=Ready tenant/matrix-minio -n matrix --timeout=600s
```

**Deploy Networking:**
```bash
# NGINX Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --values values/nginx-ingress-values.yaml

# cert-manager (TLS automation)
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true \
  --values values/cert-manager-values.yaml

kubectl apply -f infrastructure/04-networking/cert-manager-install.yaml
```

**✅ Verification:**
```bash
# Check all Phase 1 components
kubectl get cluster -n matrix                    # PostgreSQL clusters
kubectl get statefulset redis -n matrix          # Redis
kubectl get tenant matrix-minio -n matrix        # MinIO
kubectl get pods -n ingress-nginx                # Ingress controller
kubectl get clusterissuer                        # TLS certificate issuers
```

---

### **Phase 2: Main Instance** (Synapse, Workers, Clients)

**WHERE:** Run ALL commands in this phase from your **management node**

**WORKING DIRECTORY:** `deployment/` (root of this repository)

**1. Deploy Synapse Main Process:**
```bash
# Run from your management node in the deployment directory:
# Deploy configuration and secrets
kubectl apply -f main-instance/01-synapse/configmap.yaml
kubectl apply -f main-instance/01-synapse/secrets.yaml
kubectl apply -f main-instance/01-synapse/main-statefulset.yaml
kubectl apply -f main-instance/01-synapse/services.yaml

# Wait for Synapse main to be ready
kubectl wait --for=condition=Ready pod/synapse-main-0 -n matrix --timeout=600s
```

**2. Deploy Workers:**
```bash
kubectl apply -f main-instance/02-workers/synchrotron-deployment.yaml
kubectl apply -f main-instance/02-workers/generic-worker-deployment.yaml
kubectl apply -f main-instance/02-workers/media-repository-statefulset.yaml
kubectl apply -f main-instance/02-workers/event-persister-deployment.yaml
kubectl apply -f main-instance/02-workers/federation-sender-deployment.yaml
kubectl apply -f main-instance/02-workers/typing-writer-deployment.yaml
kubectl apply -f main-instance/02-workers/todevice-writer-deployment.yaml
kubectl apply -f main-instance/02-workers/receipts-writer-deployment.yaml
kubectl apply -f main-instance/02-workers/presence-writer-deployment.yaml

# Wait for workers to be ready
kubectl wait --for=condition=Available deployment -l app.kubernetes.io/component=worker -n matrix --timeout=600s
```

**3. Deploy HAProxy (Load Balancer):**
```bash
kubectl apply -f main-instance/03-haproxy/deployment.yaml

# Wait for HAProxy to be ready
kubectl wait --for=condition=Available deployment/haproxy -n matrix --timeout=300s
```

**4. Deploy Clients:**
```bash
# Element Web
kubectl apply -f main-instance/02-element-web/deployment.yaml

# coturn (TURN/STUN for peer-to-peer calls)
kubectl apply -f main-instance/06-coturn/deployment.yaml

# NOTE: key_vault is deployed in Phase 3 (LI Instance) - it resides in LI network
```

**5. Deploy LiveKit (Group Video/Voice Calls):**
```bash
helm repo add livekit https://helm.livekit.io
helm install livekit livekit/livekit-stack \
  --namespace matrix \
  --values values/livekit-values.yaml
```

**✅ Verification:**
```bash
# Check all Phase 2 components
kubectl get pods -n matrix -l app.kubernetes.io/name=synapse
kubectl get svc -n matrix | grep synapse
kubectl get ingress -n matrix

# Test Synapse health
kubectl exec -n matrix synapse-main-0 -- curl http://localhost:8008/health
```

---

### **Phase 3: LI Instance** (Lawful Intercept)

**WHERE:** Run ALL commands in this phase from your **management node**

**WORKING DIRECTORY:** `deployment/` (root of this repository)

**⭐ LI Instance Independence:**
- LI operates **completely independently** from main instance
- Uses dedicated **nginx-li** reverse proxy (not shared ingress controller)
- Works even if main instance is down (only sync stops)
- See `li-instance/README.md` for complete LI architecture details

**1. Sync System (built into synapse-li):**

The sync system is built into the synapse-li application. No separate deployment needed.

- **Periodic sync**: Configured in synapse-li settings (default: every 6 hours)
- **Manual sync**: Use the "Sync Now" button in Synapse Admin LI interface
- **Sync method**: pg_dump/pg_restore for full database synchronization

After deploying synapse-li in step 2, verify sync is working via Synapse Admin LI.

**2. Deploy Synapse LI:**
```bash
kubectl apply -f li-instance/01-synapse-li/deployment.yaml

# Wait for Synapse LI to be ready
kubectl wait --for=condition=Ready pod/synapse-li-0 -n matrix --timeout=600s
```

**3. Deploy Element Web LI:**
```bash
kubectl apply -f li-instance/02-element-web-li/deployment.yaml
```

**4. Deploy Synapse Admin LI:**
```bash
kubectl apply -f li-instance/03-synapse-admin-li/deployment.yaml
```

**5. Deploy key_vault (E2EE Recovery Key Storage):**
```bash
# key_vault stores encrypted recovery keys for E2EE messages
# Synapse main (main network) can STORE keys
# LI admin (LI network) can RETRIEVE keys
kubectl apply -f li-instance/05-key-vault/deployment.yaml

# Wait for key_vault to be ready
kubectl wait --for=condition=Ready pod/key-vault-0 -n matrix --timeout=300s
```

**6. Create TLS Certificates for nginx-li:**
```bash
# nginx-li needs TLS certs for all LI domains
# Example using self-signed certificates (recommended for isolated LI):
cd /tmp

# Synapse LI (homeserver - SAME domain as main)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout synapse-li.key -out synapse-li.crt \
  -subj "/CN=matrix.example.com"
kubectl create secret tls nginx-li-synapse-tls \
  --cert=synapse-li.crt --key=synapse-li.key -n matrix

# Element Web LI (DIFFERENT domain)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout element-li.key -out element-li.crt \
  -subj "/CN=chat-li.example.com"
kubectl create secret tls nginx-li-element-tls \
  --cert=element-li.crt --key=element-li.key -n matrix

# Synapse Admin LI (DIFFERENT domain)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout admin-li.key -out admin-li.crt \
  -subj "/CN=admin-li.example.com"
kubectl create secret tls nginx-li-admin-tls \
  --cert=admin-li.crt --key=admin-li.key -n matrix

# key_vault (DIFFERENT domain)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout keyvault.key -out keyvault.crt \
  -subj "/CN=keyvault.example.com"
kubectl create secret tls nginx-li-keyvault-tls \
  --cert=keyvault.crt --key=keyvault.key -n matrix

# Cleanup temp files
rm -f *.key *.crt
```

**7. Deploy nginx-li (LI Reverse Proxy - CRITICAL for independence):**
```bash
# nginx-li handles all LI traffic independently
kubectl apply -f li-instance/06-nginx-li/deployment.yaml

# Wait for nginx-li to be ready
kubectl wait --for=condition=available deployment/nginx-li -n matrix --timeout=120s

# Get the LoadBalancer IP (use for LI admin DNS configuration)
kubectl get svc nginx-li -n matrix
# Note the EXTERNAL-IP - LI admins must configure DNS to point to this IP
```

**✅ Verification:**
```bash
# Check all LI components
kubectl get pods -n matrix -l matrix.instance=li
kubectl get pods -n matrix -l app.kubernetes.io/name=key-vault

# Check nginx-li LoadBalancer service
kubectl get svc nginx-li -n matrix

# Check key_vault is responding
kubectl exec -n matrix key-vault-0 -- python -c "import socket; s=socket.socket(); s.settimeout(3); s.connect(('localhost', 8000)); print('OK'); s.close()"

# Check sync status via Synapse Admin LI interface
# Navigate to admin-li.example.com and check the sync status page
```

**📝 LI Admin DNS Configuration:**
After deployment, LI admins must configure their DNS to resolve domains to the nginx-li LoadBalancer IP:
- `matrix.example.com` → nginx-li IP (same homeserver URL as main)
- `chat-li.example.com` → nginx-li IP
- `admin-li.example.com` → nginx-li IP
- `keyvault.example.com` → nginx-li IP

See `li-instance/README.md` for detailed DNS configuration options.

---

### **Phase 4: Monitoring Stack** (Prometheus, Grafana, Loki)

**WHERE:** Run ALL commands in this phase from your **management node**

**WORKING DIRECTORY:** `deployment/` (root of this repository)

**1. Install Prometheus + Grafana:**
```bash
# Run from your management node:
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values/prometheus-stack-values.yaml \
  --version 67.0.0
```

**2. Install Loki:**
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki-stack \
  --namespace monitoring \
  --values values/loki-values.yaml \
  --version 2.10.0
```

**3. Deploy ServiceMonitors:**
```bash
# ServiceMonitors (auto-discovery of metrics)
kubectl apply -f monitoring/01-prometheus/servicemonitors.yaml

# Grafana Dashboards
kubectl apply -f monitoring/02-grafana/dashboards-configmap.yaml
```

**4. Enable CloudNativePG Monitoring:**
```bash
# Enable PodMonitor for PostgreSQL clusters
kubectl patch cluster matrix-postgresql -n matrix --type=merge -p '
{
  "spec": {
    "monitoring": {
      "enablePodMonitor": true
    }
  }
}'

kubectl patch cluster matrix-postgresql-li -n matrix --type=merge -p '
{
  "spec": {
    "monitoring": {
      "enablePodMonitor": true
    }
  }
}'
```

**✅ Verification:**
```bash
# Check monitoring pods
kubectl get pods -n monitoring

# Access Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open: http://localhost:9090

# Access Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open: http://localhost:3000
# Username: admin
# Password: See values/prometheus-stack-values.yaml

# Check targets are being scraped
# Navigate to: http://localhost:9090/targets
```

---

### **Phase 5: Antivirus System** (ClamAV + Content Scanner)

**WHERE:** Run ALL commands in this phase from your **management node**

**WORKING DIRECTORY:** `deployment/` (root of this repository)

**1. Deploy ClamAV DaemonSet:**
```bash
# Run from the deployment directory:
kubectl apply -f antivirus/01-clamav/deployment.yaml

# Wait for ClamAV to download virus definitions
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=clamav -n matrix --timeout=600s

# Verify virus definitions downloaded
kubectl logs -n matrix <clamav-pod> -c init-freshclam
```

**2. Deploy Content Scanner:**
```bash
kubectl apply -f antivirus/02-scan-workers/deployment.yaml

# Wait for Content Scanner to be ready
kubectl wait --for=condition=Available deployment/content-scanner -n matrix --timeout=300s
```

**3. Configure Media Routing (Choose ONE method):**

**Method A: HAProxy (Recommended)**

Edit `main-instance/03-haproxy/haproxy.cfg`:
```haproxy
# Add media scanning backend
backend content_scanner
    balance roundrobin
    server scanner1 content-scanner.matrix.svc.cluster.local:8080 check

# Route media downloads through scanner
frontend matrix_client
    acl is_media_download path_beg /_matrix/media/r0/download
    acl is_media_download path_beg /_matrix/media/r0/thumbnail
    use_backend content_scanner if is_media_download
```

Then redeploy HAProxy:
```bash
kubectl apply -f main-instance/03-haproxy/deployment.yaml
kubectl rollout restart deployment/haproxy -n matrix
```

**Method B: NGINX Ingress Annotation**

Add to Synapse Ingress annotations:
```yaml
nginx.ingress.kubernetes.io/configuration-snippet: |
  location ~ ^/_matrix/media/r0/(download|thumbnail)/ {
    proxy_pass http://content-scanner.matrix.svc.cluster.local:8080;
  }
```

**✅ Verification:**
```bash
# Check ClamAV is running on all nodes
kubectl get daemonset clamav -n matrix

# Check Content Scanner
kubectl get deployment content-scanner -n matrix
kubectl get pods -n matrix -l app.kubernetes.io/name=content-scanner

# Test ClamAV (EICAR test virus)
kubectl exec -it -n matrix <clamav-pod> -c clamd -- sh
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.txt
clamdscan /tmp/eicar.txt
# Expected: Eicar-Signature FOUND

# Check Content Scanner logs
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner
```

---

## 🔒 Security Checklist

Before going to production:

### **1. Update All Secrets**
```bash
# Change ALL instances of CHANGEME_* in:
grep -r "CHANGEME" deployment/
```

**Critical secrets to update:**
- PostgreSQL passwords (main + LI)
- Redis passwords
- MinIO credentials
- Synapse secrets (macaroon, registration, form)
- Signing keys (generate with `generate_signing_key.py`)
- key_vault encryption keys

### **2. Network Isolation for LI (Organization Responsibility)**

LI access is controlled via **network isolation**, not IP whitelisting:

- **LI Network**: Deploy LI instance on a separate private network
- **Access Control**: Only authorized LI administrators have network access to the LI network
- **Your Network Team**: Configure firewalls, VLANs, or VPN to restrict who can reach the LI network
- **DNS**: LI network DNS resolves `matrix.example.com` to LI Ingress IP (same server_name, different IP)

This approach is:
- More secure (defense at network layer, not application layer)
- Simpler to maintain (no IP lists to update in Kubernetes)
- Standard for sensitive systems (law enforcement, forensics)

**NOTE:** IP whitelisting at the Ingress level is NOT recommended because if someone can't reach the LI network, they can't access the Ingress anyway. If they CAN reach the network, they're already authorized by network access control.

### **3. Enable Authentication**

For Synapse Admin LI, generate htpasswd:
```bash
htpasswd -c auth admin
kubectl create secret generic synapse-admin-auth \
  --from-file=auth -n matrix
```

### **4. Update Domain Names**

Replace `example.com` with your actual domain in:
- All Ingress manifests
- `main-instance/01-synapse/configmap.yaml` (homeserver.yaml section)
- `main-instance/02-element-web/deployment.yaml`
- `li-instance/02-element-web-li/deployment.yaml`

---

## 📊 Resource Requirements

### 100 CCU - Small Deployment

**VM/Server Requirements:**

| Role | Count | CPU | RAM | Storage | Purpose |
|------|-------|-----|-----|---------|---------|
| **Control Plane** | 3 | 4 vCPU | 8GB | 100GB SSD | Kubernetes masters |
| **Application Nodes** | 3 | 8 vCPU | 16GB | 200GB SSD | Synapse, Element Web, workers |
| **Database Nodes** | 3 | 4 vCPU | 16GB | 500GB NVMe | PostgreSQL (1 primary + 2 replicas) |
| **Storage Nodes** | 4 | 4 vCPU | 8GB | 1TB HDD | MinIO (media files, EC:4) |
| **Call Servers** | 2 | 4 vCPU | 8GB | 50GB SSD | LiveKit + coturn |
| **LI Server** | 1 | 4 vCPU | 8GB | 100GB SSD | Synapse LI, Element LI, Admin LI, key_vault |
| **Monitoring Server** | 1 | 4 vCPU | 16GB | 200GB SSD | Prometheus, Grafana, Loki |
| **Total VMs** | **17** | **100 vCPU** | **204GB RAM** | **5.7TB** | |

**Where Services Run:**
- **Application Nodes**: Synapse main, Synapse workers, Element Web, HAProxy, Synapse Admin, Content Scanner
- **Database Nodes**: PostgreSQL main cluster (CloudNativePG), PostgreSQL LI cluster
- **Storage Nodes**: MinIO distributed storage (S3-compatible media storage)
- **Call Servers**: LiveKit (SFU for video/voice), coturn (TURN/STUN for NAT traversal)
- **LI Server**: Synapse LI, Element Web LI, Synapse Admin LI, key_vault (isolated network)
- **Monitoring Server**: Prometheus, Grafana, Loki, Promtail

**Component Breakdown:**
- **Synapse**: 1 main + 8 workers (2 sync, 2 generic, 2 event-persister, 2 federation)
- **PostgreSQL**: 3 instances (main) + 2 instances (LI)
- **Redis**: 3 instances (Sentinel HA)
- **MinIO**: 4 nodes (EC:4 erasure coding, 1TB usable)
- **ClamAV**: DaemonSet (1 pod per app node)
- **Monitoring**: Prometheus + Grafana + Loki (dedicated server)
- **LI Instance**: Synapse LI + Element LI + Admin LI (dedicated server)

**Expected Capacity:**
- **Users**: 100 concurrent users
- **Messages**: 140-400 messages/min at peak
- **Media uploads**: 10-20 files/hour
- **Concurrent calls**: 5-10 users
- **Rooms**: 50-100 active rooms

---

### 20K CCU - Large Enterprise Deployment

**VM/Server Requirements:**

| Role | Count | CPU | RAM | Storage | Purpose |
|------|-------|-----|-----|---------|---------|
| **Control Plane** | 3 | 8 vCPU | 16GB | 200GB SSD | Kubernetes masters |
| **Application Nodes** | 21 | 32 vCPU | 128GB | 2TB SSD | Synapse, Element Web, workers |
| **Database Nodes** | 5 | 32 vCPU | 128GB | 4TB NVMe | PostgreSQL (1 primary + 4 replicas) |
| **Storage Nodes** | 12 | 16 vCPU | 32GB | 4TB HDD | MinIO (3 pools of 4 nodes, EC:4) |
| **Call Servers** | 10 | 16 vCPU | 32GB | 200GB SSD | LiveKit (5) + coturn (5) |
| **LI Server** | 1 | 16 vCPU | 64GB | 1TB SSD | Synapse LI, Element LI, Admin LI, key_vault |
| **Monitoring Server** | 1 | 16 vCPU | 64GB | 1TB SSD | Prometheus, Grafana, Loki |
| **Total VMs** | **53** | **1056 vCPU** | **3.8TB RAM** | **65.6TB** | |

**Where Services Run:**
- **Application Nodes**: Synapse main, Synapse workers, Element Web, HAProxy, Synapse Admin, Content Scanner
- **Database Nodes**: PostgreSQL main cluster (CloudNativePG), PostgreSQL LI cluster
- **Storage Nodes**: MinIO distributed storage (S3-compatible media storage)
- **Call Servers**: LiveKit (SFU for video/voice), coturn (TURN/STUN for NAT traversal)
- **LI Server**: Synapse LI, Element Web LI, Synapse Admin LI, key_vault (isolated network)
- **Monitoring Server**: Prometheus, Grafana, Loki, Promtail

**Component Breakdown:**
- **Synapse**: 1 main + 38 workers (18 sync, 8 generic, 4 event-persister, 8 federation)
- **PostgreSQL**: 5 instances (main) + 2 instances (LI)
- **Redis**: 6 instances (3 for Synapse, 3 for LiveKit)
- **MinIO**: 12 nodes (3 pools × 4 nodes, EC:4, ~12TB usable)
- **LiveKit**: 5 instances (HA + performance)
- **coturn**: 5 instances (HA + performance)
- **ClamAV**: DaemonSet (1 pod per app node = 21 pods)
- **Monitoring**: Prometheus + Grafana + Loki (dedicated server)
- **LI Instance**: Synapse LI + Element LI + Admin LI (dedicated server)

**Expected Capacity:**
- **Users**: 20,000 concurrent users
- **Messages**: 28,000-80,000 messages/min at peak
- **Media uploads**: 2,000-4,000 files/hour
- **Concurrent calls**: 1,000-2,000 users
- **Rooms**: 10,000-20,000 active rooms

---

### Quick Reference

| Scale | VMs | Total vCPU | Total RAM | Storage | Users (CCU) |
|-------|-----|------------|-----------|---------|-------------|
| **Small** | 17 | 100 | 204GB | 5.7TB | 100 |
| **Medium** | 21 | 240 | 516GB | 12.2TB | 1,000 |
| **Large** | 53 | 1056 | 3.8TB | 65.6TB | 20,000 |

**Note:** All scales include dedicated LI server and Monitoring server. LI is mandatory for compliance.

**📘 For detailed sizing (including 1K, 5K, 10K CCU), see `docs/SCALING-GUIDE.md`**

---

## 🔍 Verification & Testing

### **Complete System Check:**
```bash
# All pods should be Running
kubectl get pods -n matrix
kubectl get pods -n monitoring
kubectl get pods -n ingress-nginx

# All services should have endpoints
kubectl get svc -n matrix
kubectl get endpoints -n matrix

# Check Ingress has IP address
kubectl get ingress -n matrix
```

### **Functional Tests:**

**1. Synapse Health:**
```bash
curl https://matrix.example.com/_matrix/client/versions
```

**2. Element Web:**
```bash
open https://chat.example.com
```

**3. LI Instance:**
```bash
# Only accessible from LI network (organization's responsibility to isolate)
# From LI network, DNS resolves matrix.example.com to LI Ingress IP
curl https://matrix.example.com/_matrix/client/versions
```

**5. Monitoring:**
```bash
# Grafana: View dashboards
https://grafana.example.com

# Or via port-forward if Ingress not configured:
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open: http://localhost:3000
```

**6. Antivirus:**
```bash
# Upload and download a file via Element
# Check Content Scanner logs for scan confirmation
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner | grep "scan"
```

---

## 👤 Creating Admin Users

After deployment, create admin users for Synapse (main and LI) and key_vault Django admin.

### **1. Synapse Main Instance - Admin User**

**WHERE:** Run from your **management node**

```bash
# Create an admin user for the main Synapse instance
kubectl exec -it -n matrix synapse-main-0 -- \
  register_new_matrix_user \
  -c /config/homeserver.yaml \
  -u admin \
  -p YOUR_SECURE_PASSWORD \
  -a \
  http://localhost:8008

# The -a flag creates an admin user
# Replace 'admin' with your preferred username
# Replace 'YOUR_SECURE_PASSWORD' with a secure password
```

**Expected output:**
```
New user registered: @admin:matrix.example.com
```

### **2. Synapse LI Instance - Admin User**

**WHERE:** Run from your **management node**

```bash
# Create an admin user for the LI Synapse instance
kubectl exec -it -n matrix synapse-li-0 -- \
  register_new_matrix_user \
  -c /config/homeserver.yaml \
  -u li-admin \
  -p YOUR_SECURE_PASSWORD \
  -a \
  http://localhost:8008

# This creates a SEPARATE admin account on the LI instance
# LI admin can access forensics features via Synapse Admin LI
```

**Note:** LI admin is a separate account from main admin. This user accesses LI services only.

### **3. key_vault Django Admin User**

**WHERE:** Run from your **management node**

The key_vault Django application requires a superuser to access the `/admin` panel.

```bash
# Create Django superuser for key_vault
kubectl exec -it -n matrix key-vault-0 -- \
  python manage.py createsuperuser \
  --username keyvault-admin \
  --email admin@example.com

# You will be prompted to enter a password interactively
# This user accesses the key_vault Django admin panel at https://keyvault.example.com/admin
```

**After creation, access key_vault admin:**
1. Navigate to `https://keyvault.example.com/admin`
2. Login with the superuser credentials you just created
3. You can now view and manage E2EE recovery keys

**Note:** Django automatically creates the SQLite database file if it doesn't exist. No manual database initialization is required.

### **Admin User Summary**

| Service | Admin Username | Access URL | Purpose |
|---------|---------------|------------|---------|
| Synapse Main | `@admin:matrix.example.com` | `https://matrix.example.com/_synapse/admin/` | Main instance administration (via API) |
| Synapse LI | `@li-admin:matrix.example.com` | `https://admin-li.example.com` | LI forensics and user inspection |
| key_vault | `keyvault-admin` | `https://keyvault.example.com/admin` | E2EE recovery key management |

---

## 📚 Optional Documentation Reference

**These documents provide additional technical details. They are NOT required for deployment - use as reference when needed.**

| Document | Purpose | When to Read |
|----------|---------|--------------|
| `docs/CONFIGURATION-REFERENCE.md` | All configuration parameters explained | When customizing advanced settings |
| `docs/OPERATIONS-UPDATE-GUIDE.md` | Updates and maintenance procedures | After deployment, for ongoing operations |
| `docs/SECRETS-MANAGEMENT.md` | Advanced secret management | If using external secret managers (Vault, etc.) |
| `docs/HAPROXY-ARCHITECTURE.md` | HAProxy routing technical details | When debugging routing issues |
| `docs/MATRIX-AUTHENTICATION-SERVICE.md` | Enterprise SSO integration (MAS) | If you need corporate SSO/OIDC authentication |
| `antivirus/README.md` | ClamAV antivirus system architecture | When deploying or customizing antivirus |
| `li-instance/README.md` | Complete LI instance technical guide | For understanding LI architecture details |
| Component `README.md` files | Per-component technical details | When troubleshooting specific components |

---

## 🆘 Troubleshooting

### Common Issues:

**Synapse won't start:**
- Check PostgreSQL is ready: `kubectl get cluster -n matrix`
- Check Redis is ready: `kubectl get pod redis-0 -n matrix`
- Check logs: `kubectl logs synapse-main-0 -n matrix`

**Workers not connecting:**
- Check HAProxy is running: `kubectl get deployment haproxy -n matrix`
- Check worker logs: `kubectl logs <worker-pod> -n matrix`

**LI sync issues:**
- Check sync status via Synapse Admin LI interface
- Check synapse-li logs: `kubectl logs -n matrix deployment/synapse-li`
- Verify LI PostgreSQL connectivity from synapse-li pod

**Antivirus not scanning:**
- Check ClamAV is running: `kubectl get daemonset clamav -n matrix`
- Check Content Scanner connectivity: `kubectl logs <content-scanner-pod> -n matrix`
- Test ClamAV directly: See Phase 5 verification above

**For advanced troubleshooting, see component-specific README files in Optional Documentation Reference above.**

---

## 🎉 Success!

If all verification steps pass, you have successfully deployed:
- ✅ Production-grade Matrix homeserver
- ✅ High availability infrastructure
- ✅ Complete lawful intercept system
- ✅ Real-time antivirus protection
- ✅ Comprehensive monitoring

**Next steps:**
1. Create your first user
2. Configure federation (if desired)
3. Set up backups (automated via CloudNativePG + MinIO)
4. Review monitoring dashboards
5. Test LI instance access

**For ongoing operations, see `docs/OPERATIONS-UPDATE-GUIDE.md`**
