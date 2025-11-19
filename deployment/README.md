# Matrix/Synapse Production Deployment

Complete production-grade Matrix Synapse homeserver deployment on Kubernetes, supporting 100-20,000+ concurrent users with high availability, lawful intercept, and antivirus protection.

## 🎯 What This Deployment Provides

### Core Features
- ✅ **Scalable**: 100 CCU → 20,000+ CCU with horizontal scaling
- ✅ **High Availability**: Zero single points of failure
- ✅ **Lawful Intercept**: Complete LI instance with E2EE recovery
- ✅ **Antivirus**: Real-time ClamAV scanning of all media
- ✅ **Monitoring**: Prometheus + Grafana + Loki observability
- ✅ **Air-gapped**: Can run fully offline after initial setup

### Architecture Highlights
- **Worker-based Synapse**: 5 worker types with intelligent HAProxy routing
- **HA Database**: CloudNativePG with synchronous replication
- **Distributed Storage**: MinIO with EC:4 erasure coding
- **Redis Sentinel**: Automatic failover for caching
- **Zero-trust Security**: 16+ NetworkPolicies with strict isolation

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
│   └── 04-networking/           # NetworkPolicies, Ingress, TLS
│
├── main-instance/               ← Phase 2: Main Matrix Instance
│   ├── 01-synapse/              # Synapse main process
│   ├── 02-element-web/          # Web client interface
│   ├── 02-workers/              # 5 worker types (synchrotron, generic, etc.)
│   ├── 03-haproxy/              # Intelligent load balancer
│   ├── 04-livekit/              # Video/voice calling (Helm reference)
│   ├── 06-coturn/               # TURN/STUN NAT traversal
│   ├── 07-sygnal/               # Push notifications (APNs/FCM)
│   └── 08-key-vault/            # E2EE recovery key storage
│
├── li-instance/                 ← Phase 3: Lawful Intercept
│   ├── 01-synapse-li/           # Read-only Synapse instance
│   ├── 02-element-web-li/       # LI web client (shows deleted messages)
│   ├── 03-synapse-admin-li/     # Admin interface for forensics
│   └── 04-sync-system/          # DB replication + media sync
│
├── monitoring/                  ← Phase 4: Observability Stack
│   ├── 01-prometheus/           # ServiceMonitors + AlertRules
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
    ├── 00-KUBERNETES-INSTALLATION.md     (REQUIRED: Setup K8s cluster)
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

**Infrastructure:**
- Kubernetes cluster (1.28+)
- Storage class for PVCs
- Domain name for your homeserver
- `kubectl` and `helm` installed

### Before You Begin - Documentation Guide

**📖 REQUIRED Reading (follow in order):**

1. **`docs/00-WORKSTATION-SETUP.md`** ← Set up kubectl, helm, and required tools on your workstation
2. **`docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`** ← Set up Kubernetes cluster (assumes VMs are provided)
3. **`docs/SCALING-GUIDE.md`** ← Determine resource requirements for your scale (100 CCU to 20K CCU)
4. **THIS README** ← Complete all deployment phases below

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
echo "MINIO_ROOT_PASSWORD=$(generate_secret)"
echo "SYNAPSE_MACAROON_SECRET=$(generate_secret)"
echo "SYNAPSE_REGISTRATION_SECRET=$(generate_secret)"
echo "SYNAPSE_FORM_SECRET=$(generate_secret)"
echo "REPLICATION_SECRET=$(generate_secret)"
echo "TURN_SECRET=$(generate_secret)"
echo "KEY_VAULT_API_KEY=$(generate_secret)"
echo "KEY_VAULT_DJANGO_SECRET=$(generate_secret 50)"
echo "KEY_VAULT_ENCRYPTION_KEY=$(generate_secret 32)"
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
main-instance/08-key-vault/deployment.yaml         # 4 secrets
main-instance/06-coturn/deployment.yaml            # 2 secrets
main-instance/07-sygnal/deployment.yaml            # 8 secrets (APNs/FCM)
infrastructure/03-minio/secrets.yaml               # 2 secrets
li-instance/04-sync-system/deployment.yaml         # 5 secrets
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

Replace `matrix.example.com` with your actual domains:

**Domain mapping:**
```bash
matrix.example.com        → your-domain.com          # Main homeserver
matrix-li.example.com     → li.your-domain.com       # LI instance
element.example.com       → chat.your-domain.com     # Element Web
element-li.example.com    → li-chat.your-domain.com  # Element LI
turn.matrix.example.com   → turn.your-domain.com     # TURN server
```

**Files to update (85 occurrences across multiple files):**

**WHERE:** On your **management node**, in the `deployment/` directory

**Key files that contain domain references (paths relative to deployment/):**
```bash
# Main configuration
main-instance/01-synapse/configmap.yaml

# LI configuration
li-instance/01-synapse-li/deployment.yaml
li-instance/02-element-web-li/deployment.yaml

# Element Web
main-instance/02-element-web/deployment.yaml

# Coturn, Ingress, Certificates
main-instance/06-coturn/deployment.yaml
infrastructure/04-networking/cert-manager-install.yaml
```

**HOW TO UPDATE - Option 1: Automated find-and-replace**
```bash
# Run from the deployment directory:
# Replace all occurrences (replace YOUR-DOMAIN.COM with your actual domain):
find . -name "*.yaml" -type f -exec sed -i 's/matrix\.example\.com/YOUR-DOMAIN.COM/g' {} +
find . -name "*.yaml" -type f -exec sed -i 's/matrix-li\.example\.com/li.YOUR-DOMAIN.COM/g' {} +
find . -name "*.yaml" -type f -exec sed -i 's/element\.example\.com/chat.YOUR-DOMAIN.COM/g' {} +
find . -name "*.yaml" -type f -exec sed -i 's/element-li\.example\.com/li-chat.YOUR-DOMAIN.COM/g' {} +
find . -name "*.yaml" -type f -exec sed -i 's/turn\.matrix\.example\.com/turn.YOUR-DOMAIN.COM/g' {} +
```

**HOW TO UPDATE - Option 2: Manual editing**
Edit each file individually using nano and search/replace example.com with your domain.

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

```bash
# All point to your Kubernetes Ingress external IP
# (You'll get this IP after deploying Ingress in Phase 1)

your-domain.com            → <ingress-external-ip>
chat.your-domain.com       → <ingress-external-ip>
li.your-domain.com         → <ingress-external-ip>
li-chat.your-domain.com    → <ingress-external-ip>
turn.your-domain.com       → <ingress-external-ip>
```

**Note:** You can configure DNS after Phase 1 (Infrastructure) is complete.

---

### ✅ Configuration Checklist

Before proceeding to deployment, verify:

- [ ] All secrets generated and CHANGEME values replaced (113 occurrences)
- [ ] All domains updated from example.com to your actual domains (85 occurrences)
- [ ] Storage class verified and configured
- [ ] Synapse signing key generated and configured
- [ ] Resource sizes reviewed (if > 100 CCU)
- [ ] DNS records ready (can configure after Phase 1)
- [ ] Configuration files saved

**If all checkboxes are complete, you're ready to deploy!**

---

## 📋 Deployment Steps (Execute After Configuration Above)

**⚠️ IMPORTANT:** ALL commands below must be run from your **management node** (where kubectl and helm are installed)

---

### **Phase 1: Core Infrastructure** (HA Database, Storage, Networking)

**WHERE:** Run ALL commands in this phase from your **management node**

**WORKING DIRECTORY:** `deployment/` (root of this repository)

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
# NetworkPolicies (zero-trust security)
kubectl apply -f infrastructure/04-networking/networkpolicies.yaml
kubectl apply -f infrastructure/04-networking/sync-system-networkpolicy.yaml

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
kubectl get networkpolicies -n matrix            # Security policies
kubectl get pods -n ingress-nginx                # Ingress controller
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
kubectl apply -f main-instance/02-workers/media-repository-deployment.yaml
kubectl apply -f main-instance/02-workers/event-persister-deployment.yaml
kubectl apply -f main-instance/02-workers/federation-sender-deployment.yaml

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

# coturn (TURN/STUN)
kubectl apply -f main-instance/06-coturn/deployment.yaml

# Sygnal (Push notifications)
kubectl apply -f main-instance/07-sygnal/deployment.yaml

# key_vault (E2EE recovery)
kubectl apply -f main-instance/08-key-vault/deployment.yaml
```

**5. Deploy LiveKit (Optional - Video/Voice):**
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

**1. Deploy Sync System (PostgreSQL Replication):**
```bash
# Run from your management node in the deployment directory:
# Deploy sync system components
kubectl apply -f li-instance/04-sync-system/deployment.yaml

# Run replication setup (ONE TIME ONLY)
# Store job name in variable to use consistently
JOB_NAME="sync-setup-$(date +%s)"

# Create the job
kubectl create job --from=job/sync-system-setup-replication \
  $JOB_NAME -n matrix

# Wait for setup to complete (using same job name)
kubectl wait --for=condition=complete job/$JOB_NAME -n matrix --timeout=300s

# Check replication status (using same job name)
kubectl logs job/$JOB_NAME -n matrix
```

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

**✅ Verification:**
```bash
# Check LI components
kubectl get pods -n matrix -l matrix.instance=li
kubectl get ingress -n matrix | grep li

# Check replication lag (CRITICAL - should be < 5 seconds)
kubectl exec -n matrix matrix-postgresql-li-1-0 -- \
  psql -U postgres -d matrix_li -c "
  SELECT
    subname,
    received_lsn,
    latest_end_lsn,
    pg_wal_lsn_diff(latest_end_lsn, received_lsn) AS lag_bytes
  FROM pg_subscription_rel
  JOIN pg_subscription ON subrelid = srrelid;"

# Check media sync job
kubectl get cronjob sync-system-media -n matrix
kubectl get jobs -n matrix | grep sync-system-media
```

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

**3. Deploy ServiceMonitors and AlertRules:**
```bash
# ServiceMonitors (auto-discovery of metrics)
kubectl apply -f monitoring/01-prometheus/servicemonitors.yaml

# PrometheusRules (60+ alerting rules)
kubectl apply -f monitoring/01-prometheus/prometheusrules.yaml

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

### **2. Configure IP Whitelisting**

For LI components, update these Ingress annotations:
```yaml
# In li-instance/01-synapse-li/deployment.yaml
# In li-instance/02-element-web-li/deployment.yaml
# In li-instance/03-synapse-admin-li/deployment.yaml

nginx.ingress.kubernetes.io/whitelist-source-range: "YOUR_LAW_ENFORCEMENT_IPS"
```

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

### **5. Verify NetworkPolicies**

Check all NetworkPolicies are applied:
```bash
kubectl get networkpolicies -n matrix
# Should show 16+ policies
```

---

## 📊 Resource Requirements

### 100 CCU - Small Deployment

**VM/Server Requirements:**

| Role | Count | CPU | RAM | Storage | Purpose |
|------|-------|-----|-----|---------|---------|
| **Control Plane** | 3 | 4 vCPU | 8GB | 100GB SSD | Kubernetes masters |
| **Application Nodes** | 3 | 8 vCPU | 16GB | 200GB SSD | Synapse, monitoring |
| **Database Nodes** | 3 | 4 vCPU | 16GB | 500GB NVMe | PostgreSQL (1 primary + 2 replicas) |
| **Storage Nodes** | 4 | 4 vCPU | 8GB | 1TB HDD | MinIO (media files, EC:4) |
| **Call Servers** | 2 | 4 vCPU | 8GB | 50GB SSD | LiveKit + coturn |
| **Total VMs** | **15** | **92 vCPU** | **180GB RAM** | **5.4TB** | |

**Component Breakdown:**
- **Synapse**: 1 main + 8 workers (2 sync, 2 generic, 2 event-persister, 2 federation)
- **PostgreSQL**: 3 instances (main) + 2 instances (LI)
- **Redis**: 3 instances (Sentinel HA)
- **MinIO**: 4 nodes (EC:4 erasure coding, 1TB usable)
- **ClamAV**: DaemonSet (1 pod per app node)
- **Monitoring**: Prometheus + Grafana + Loki

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
| **Application Nodes** | 21 | 32 vCPU | 128GB | 2TB SSD | Synapse, monitoring, workers |
| **Database Nodes** | 5 | 32 vCPU | 128GB | 4TB NVMe | PostgreSQL (1 primary + 4 replicas) |
| **Storage Nodes** | 12 | 16 vCPU | 32GB | 4TB HDD | MinIO (3 pools of 4 nodes, EC:4) |
| **Call Servers** | 10 | 16 vCPU | 32GB | 200GB SSD | LiveKit (5) + coturn (5) |
| **Total VMs** | **51** | **1024 vCPU** | **3.7TB RAM** | **63TB** | |

**Component Breakdown:**
- **Synapse**: 1 main + 38 workers (18 sync, 8 generic, 4 event-persister, 8 federation)
- **PostgreSQL**: 5 instances (main) + 2 instances (LI)
- **Redis**: 6 instances (3 for Synapse, 3 for LiveKit)
- **MinIO**: 12 nodes (3 pools × 4 nodes, EC:4, ~12TB usable)
- **LiveKit**: 5 instances (HA + performance)
- **coturn**: 5 instances (HA + performance)
- **ClamAV**: DaemonSet (1 pod per app node = 21 pods)
- **Monitoring**: Prometheus + Grafana + Loki (HA setup)

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
| **Small** | 15 | 92 | 180GB | 5.4TB | 100 |
| **Medium** | 30 | 480 | 900GB | 20TB | 1,000 |
| **Large** | 51 | 1024 | 3.7TB | 63TB | 20,000 |

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
open https://element.matrix.example.com
```

**3. Admin Interface:**
```bash
open https://admin.matrix.example.com
```

**4. LI Instance:**
```bash
# Only accessible from whitelisted IPs
curl https://matrix-li.example.com/_matrix/client/versions
```

**5. Monitoring:**
```bash
# Prometheus: Check all targets are UP
http://localhost:9090/targets

# Grafana: View dashboards
http://localhost:3000/dashboards
```

**6. Antivirus:**
```bash
# Upload and download a file via Element
# Check Content Scanner logs for scan confirmation
kubectl logs -n matrix -l app.kubernetes.io/name=content-scanner | grep "scan"
```

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
- Check NetworkPolicies: `kubectl get networkpolicies -n matrix`
- Check worker logs: `kubectl logs <worker-pod> -n matrix`

**LI replication lag:**
- Check replication status (see Phase 3 verification above)
- Check sync system logs: `kubectl logs <sync-system-pod> -n matrix`
- Check PostgreSQL replication delay: See LI verification commands in Phase 3

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

---

**Kubernetes**: 1.28+
**Synapse**: v1.119.0
