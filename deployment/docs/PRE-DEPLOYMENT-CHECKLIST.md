# Pre-Deployment Checklist for Matrix/Synapse Production
<!-- Generated after fixing all 17 critical issues -->

## Overview
This checklist ensures all components are properly configured and ready for deployment after resolving critical technical issues.

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

### 3. key_vault Application
- [ ] **Django application structure created:**
  - [ ] Init container generates complete app structure
  - [ ] manage.py, wsgi.py, urls.py created at runtime
  - [ ] Models and views properly defined
- [ ] **Database initialization job:**
  - [ ] Creates dedicated `key_vault` database
  - [ ] Uses PostgreSQL superuser credentials
- [ ] **Network isolation enforced:**
  - [ ] Only accessible from Synapse main (not LI)

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
  # Using synapse user for replication
  MAIN_DB_USER: "synapse"
  MAIN_DB_PASSWORD: <same-as-main-synapse>
  ```

### 2. LI Synapse Instance
- [ ] **Read-only configuration:**
  - [ ] `enable_registration: false`
  - [ ] `enable_room_list_search: false`
  - [ ] Database configured for LI cluster

## ✅ Phase 4: Auxiliary Services

### 1. Antivirus (ClamAV)
- [ ] **Content scanner fixed:**
  ```bash
  # Using TCP connection instead of clamdscan
  SCAN_RESULT=$(echo "SCAN $FILE" | nc -w 30 clamav.matrix.svc.cluster.local 3310)
  ```
- [ ] **Init container waits for ClamAV:**
  - [ ] Checks port 3310 availability
  - [ ] Properly handles connection

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

**Update in:** `main-instance/08-key-vault/secret.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: key-vault-secret
stringData:
  SECRET_KEY: "<paste-django-secret-key>"
  RSA_PRIVATE_KEY: |
    <paste-entire-private-key-including-BEGIN-END-lines>
  API_KEY: "<paste-KEY_VAULT_API_KEY>"
  DB_PASSWORD: ""  # Auto-populated from PostgreSQL secret at runtime
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

**Update in:** `main-instance/05-coturn/secret.yaml`
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

# 6. HAProxy load balancer
kubectl apply -f main-instance/02-haproxy/

# 7. Synapse workers
kubectl apply -f main-instance/03-workers/

# 8. key_vault (wait for DB init job)
kubectl apply -f main-instance/08-key-vault/
kubectl wait --for=condition=complete job/key-vault-init-db -n matrix
```

### Phase 3: Auxiliary Services
```bash
# 9. ClamAV antivirus
kubectl apply -f antivirus/01-clamav/

# 10. Content scanner (after ClamAV is ready)
kubectl apply -f antivirus/02-scan-workers/

# 11. LiveKit SFU
kubectl apply -f main-instance/04-livekit/

# 12. Element Web
kubectl apply -f main-instance/07-element-web/

# 13. TURN server
kubectl apply -f main-instance/05-coturn/
```

### Phase 4: LI Instance
```bash
# 14. LI Synapse instance
kubectl apply -f li-instance/01-synapse/

# 15. Setup replication (run once)
kubectl apply -f li-instance/04-sync-system/
kubectl wait --for=condition=complete job/sync-system-setup-replication -n matrix

# 16. LI workers
kubectl apply -f li-instance/02-workers/
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