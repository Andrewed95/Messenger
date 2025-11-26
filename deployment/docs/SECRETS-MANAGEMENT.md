# Secrets Management Guide

Comprehensive guide to managing sensitive data (passwords, API keys, certificates) in your Matrix deployment.

---

## Table of Contents

1. [Overview](#overview)
2. [Current Implementation](#current-implementation)
3. [Encryption at Rest](#encryption-at-rest)
4. [External Secrets (Optional)](#external-secrets-optional)
5. [Secrets Rotation](#secrets-rotation)
6. [Audit and Compliance](#audit-and-compliance)
7. [Best Practices](#best-practices)

---

## Overview

### What Are Secrets?

Kubernetes Secrets store sensitive information like:
- Database passwords
- API keys
- TLS certificates
- OAuth client secrets
- Signing keys

### Why Secrets Management Matters

**Security Risks:**
- Hardcoded credentials in manifests → Exposed in Git
- Unencrypted secrets in etcd → Accessible to anyone with etcd access
- No rotation → Compromised secrets stay valid forever
- No audit trail → Can't detect unauthorized access

**This Guide Provides:**
- ✅ Encryption at rest (protect secrets in etcd)
- ✅ External secrets integration (optional)
- ✅ Rotation procedures
- ✅ Audit logging

---

## Current Implementation

### Standard Kubernetes Secrets

Your deployment uses Kubernetes Secrets:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: synapse-secrets
  namespace: matrix
type: Opaque
data:
  registration-shared-secret: <base64-encoded>
  macaroon-secret-key: <base64-encoded>
  form-secret: <base64-encoded>
```

**Current Security:**
- ✅ Not stored in Git (created during deployment)
- ✅ Documented in README Configuration section
- ✅ Mounted as volumes (not environment variables)
- ⚠️ Base64 encoded (NOT encrypted) by default
- ⚠️ Stored in etcd unencrypted by default
- ❌ No automatic rotation
- ❌ No external secrets management

**This is ACCEPTABLE for:**
- Development environments
- Small deployments
- Non-regulated industries

**Should IMPROVE for:**
- Production environments with compliance requirements
- Large enterprises
- Regulated industries (healthcare, finance, government)

---

## Encryption at Rest

### Why Encrypt Secrets in etcd?

**Problem:** By default, Kubernetes stores Secrets in etcd as **base64-encoded plaintext**.

Anyone with:
- etcd access (including backups)
- Cluster admin privileges
- Physical access to etcd nodes

Can read all Secrets.

**Solution:** Enable **Encryption at Rest** to encrypt Secrets before storing in etcd.

### Implementing Encryption at Rest

#### Step 1: Create Encryption Configuration

Create `/etc/kubernetes/pki/encryption-config.yaml` on control plane nodes:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps  # Optional: also encrypt ConfigMaps
    providers:
      # Use aescbc (AES-CBC with PKCS#7 padding)
      - aescbc:
          keys:
            - name: key1
              # Generate with: head -c 32 /dev/urandom | base64
              secret: <BASE64-ENCODED-32-BYTE-KEY>
      # Fallback to identity (plaintext) for backwards compatibility
      - identity: {}
```

**Generate encryption key:**
```bash
# On control plane node
head -c 32 /dev/urandom | base64
# Example output: K8sEncryptionKey1234567890ABCDEFGHIJ==

# Add to encryption-config.yaml
```

**Set proper permissions:**
```bash
chmod 600 /etc/kubernetes/pki/encryption-config.yaml
chown root:root /etc/kubernetes/pki/encryption-config.yaml
```

#### Step 2: Configure kube-apiserver

Edit `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    # ... existing flags ...
    - --encryption-provider-config=/etc/kubernetes/pki/encryption-config.yaml  # ADD THIS
    volumeMounts:
    # ... existing mounts ...
    - mountPath: /etc/kubernetes/pki/encryption-config.yaml  # ADD THIS
      name: encryption-config
      readOnly: true
  volumes:
  # ... existing volumes ...
  - hostPath:  # ADD THIS
      path: /etc/kubernetes/pki/encryption-config.yaml
      type: File
    name: encryption-config
```

**Apply on all control plane nodes.**

#### Step 3: Restart kube-apiserver

kube-apiserver automatically restarts when you save the manifest:

```bash
# Wait for restart (takes )
kubectl get pods -n kube-system | grep kube-apiserver

# Verify it's running
kubectl get nodes
```

#### Step 4: Encrypt Existing Secrets

**Important:** Enabling encryption only encrypts **NEW** Secrets. Existing Secrets remain plaintext until re-written.

**Encrypt all existing Secrets:**
```bash
# This reads and re-writes all Secrets, encrypting them
kubectl get secrets --all-namespaces -o json | \
  kubectl replace -f -
```

**Verify encryption:**
```bash
# Read secret directly from etcd (on control plane node)
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/matrix/synapse-secrets

# Should see encrypted binary data, NOT base64 plaintext
```

### Key Rotation

Rotate encryption keys annually or when compromised:

```yaml
# encryption-config.yaml with TWO keys
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key2  # NEW key (used for encryption)
              secret: <NEW-BASE64-KEY>
            - name: key1  # OLD key (used for decryption only)
              secret: <OLD-BASE64-KEY>
      - identity: {}
```

**Rotation process:**
1. Add new key as first entry (key2)
2. Keep old key as second entry (key1)
3. Restart kube-apiserver
4. Re-encrypt all Secrets: `kubectl get secrets --all-namespaces -o json | kubectl replace -f -`
5. Wait  (ensure nothing breaks)
6. Remove old key (key1) from config
7. Restart kube-apiserver again

### Encryption Algorithms

**Options:**

| Algorithm | Security | Performance | Recommendation |
|-----------|----------|-------------|----------------|
| `aescbc` | High | Medium | ✅ **Recommended** for most |
| `aesgcm` | Very High | Fast | ✅ Best security (Kubernetes 1.24+) |
| `secretbox` | Very High | Fast | ✅ Alternative to aesgcm |
| `kms` | Highest | Slow | Enterprise (AWS KMS, Vault) |

**Best choice for your deployment:** `aescbc` (widely supported, proven)

**For maximum security:** `aesgcm` (if Kubernetes 1.24+)

---

## External Secrets (Optional)

### Why External Secrets?

**Benefits:**
- ✅ Secrets stored outside Kubernetes (Vault, AWS Secrets Manager, Azure Key Vault)
- ✅ Centralized secrets management across multiple clusters
- ✅ Automatic rotation
- ✅ Audit trail
- ✅ Fine-grained access control

**Trade-offs:**
- ❌ Additional complexity
- ❌ External dependency (Vault, cloud provider)
- ❌ Operational overhead

**Recommended for:**
- Large enterprises with existing secrets infrastructure
- Multi-cluster deployments
- Highly regulated industries
- Teams with dedicated security engineers

### Option 1: External Secrets Operator (ESO)

**What it does:** Syncs secrets from external sources into Kubernetes Secrets.

#### Installation

```bash
# Add Helm repo
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install operator
helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --set installCRDs=true
```

#### Example: HashiCorp Vault Integration

**1. Configure Vault SecretStore:**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: matrix
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      version: "v2"
      auth:
        # Use Kubernetes auth
        kubernetes:
          mountPath: "kubernetes"
          role: "matrix-secrets-reader"
          serviceAccountRef:
            name: external-secrets-sa
```

**2. Create ExternalSecret:**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: synapse-secrets
  namespace: matrix
spec:
  refreshInterval: 1h  # Sync every hour
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: synapse-secrets  # Creates this K8s Secret
    creationPolicy: Owner
  data:
  - secretKey: registration-shared-secret
    remoteRef:
      key: matrix/synapse
      property: registration_secret
  - secretKey: macaroon-secret-key
    remoteRef:
      key: matrix/synapse
      property: macaroon_secret
  - secretKey: form-secret
    remoteRef:
      key: matrix/synapse
      property: form_secret
```

**3. Store secrets in Vault:**

```bash
# Using Vault CLI
vault kv put secret/matrix/synapse \
  registration_secret="$(openssl rand -base64 32)" \
  macaroon_secret="$(openssl rand -base64 32)" \
  form_secret="$(openssl rand -base64 32)"
```

**Result:** ESO automatically creates and updates the `synapse-secrets` Kubernetes Secret from Vault.

#### Example: AWS Secrets Manager Integration

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: matrix
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: synapse-secrets
  namespace: matrix
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: synapse-secrets
  data:
  - secretKey: registration-shared-secret
    remoteRef:
      key: matrix/synapse/registration-secret
  - secretKey: macaroon-secret-key
    remoteRef:
      key: matrix/synapse/macaroon-secret
```

### Option 2: Sealed Secrets

**What it does:** Encrypt Secrets into SealedSecrets that can be stored in Git safely.

**Use case:** GitOps workflows (Flux, ArgoCD)

#### Installation

```bash
# Install controller
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Install kubeseal CLI
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar -xvzf kubeseal-0.24.0-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

#### Usage

```bash
# Create regular Secret (NOT applied to cluster)
kubectl create secret generic synapse-secrets \
  --from-literal=registration-shared-secret="$(openssl rand -base64 32)" \
  --from-literal=macaroon-secret-key="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml > synapse-secrets.yaml

# Seal the Secret (encrypt)
kubeseal -f synapse-secrets.yaml -w synapse-secrets-sealed.yaml

# Apply SealedSecret to cluster
kubectl apply -f synapse-secrets-sealed.yaml -n matrix

# Controller automatically creates the regular Secret
kubectl get secrets -n matrix | grep synapse-secrets
```

**synapse-secrets-sealed.yaml** can be committed to Git safely:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: synapse-secrets
  namespace: matrix
spec:
  encryptedData:
    registration-shared-secret: AgC7V8... # Encrypted with cluster public key
    macaroon-secret-key: AgBx4R...
```

**Only the cluster with the private key can decrypt.**

---

## Secrets Rotation

### When to Rotate

**Regular Schedule:**
- Database passwords: Annually
- API keys: Annually
- Signing keys: Every 2 years
- TLS certificates: Automatic (cert-manager)

**Immediate Rotation:**
- Suspected compromise
- Employee with access leaves
- Compliance audit finding

### Rotation Procedures

#### PostgreSQL Password

```bash
# 1. Generate new password
NEW_PG_PASSWORD=$(openssl rand -base64 32)

# 2. Update password in PostgreSQL
kubectl exec -it -n matrix matrix-postgresql-1 -- psql -U postgres -c \
  "ALTER USER synapse WITH PASSWORD '$NEW_PG_PASSWORD';"

# 3. Update Secret
kubectl create secret generic synapse-db-password \
  --from-literal=password="$NEW_PG_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - -n matrix

# 4. Restart Synapse pods to pick up new password
kubectl rollout restart deployment/synapse-main -n matrix
kubectl rollout restart statefulset/synapse-sync-worker -n matrix
kubectl rollout restart statefulset/synapse-generic-worker -n matrix
```

#### Synapse Secrets

**These require careful coordination:**

```bash
# 1. Generate new secrets
NEW_REG_SECRET=$(openssl rand -base64 32)
NEW_MACAROON=$(openssl rand -base64 32)
NEW_FORM=$(openssl rand -base64 32)

# 2. Update Secret
kubectl create secret generic synapse-secrets \
  --from-literal=registration-shared-secret="$NEW_REG_SECRET" \
  --from-literal=macaroon-secret-key="$NEW_MACAROON" \
  --from-literal=form-secret="$NEW_FORM" \
  --dry-run=client -o yaml | kubectl apply -f - -n matrix

# 3. Update homeserver.yaml ConfigMap with same values
kubectl edit configmap synapse-config -n matrix
# Update: registration_shared_secret, macaroon_secret_key, form_secret

# 4. Restart all Synapse components
kubectl rollout restart deployment/synapse-main -n matrix
kubectl rollout restart statefulset --selector=app=synapse -n matrix
```

**⚠️ WARNING:** Rotating `macaroon-secret-key` **invalidates all user sessions**. Users must log in again.

#### MinIO Access Keys

```bash
# 1. Create new access key in MinIO console or CLI
mc admin user add minio-alias synapse-new-user <new-access-key> <new-secret-key>

# 2. Update Secret
kubectl create secret generic minio-credentials \
  --from-literal=accessKey="<new-access-key>" \
  --from-literal=secretKey="<new-secret-key>" \
  --dry-run=client -o yaml | kubectl apply -f - -n matrix

# 3. Restart Synapse
kubectl rollout restart deployment/synapse-main -n matrix

# 4. Delete old access key (after verifying new one works)
mc admin user remove minio-alias synapse-old-user
```

### Automated Rotation (External Secrets Only)

With External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: synapse-secrets
spec:
  refreshInterval: 1h  # Check for updates every hour
  # ESO automatically updates K8s Secret when Vault values change
```

**Process:**
1. Rotate secret in Vault
2. ESO detects change (within )
3. K8s Secret updated automatically
4. Trigger pod restart (manual or via Reloader)

**Reloader** (optional): Automatically restarts pods when Secrets/ConfigMaps change:

```bash
# Install Reloader
helm repo add stakater https://stakater.github.io/stakater-charts
helm install reloader stakater/reloader -n kube-system

# Annotate deployments
kubectl annotate deployment synapse-main \
  reloader.stakater.com/auto="true" -n matrix
```

---

## Audit and Compliance

### Audit Logging

Enable Kubernetes audit logging to track Secret access:

**On control plane nodes, edit `/etc/kubernetes/manifests/kube-apiserver.yaml`:**

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    volumeMounts:
    - mountPath: /var/log/kubernetes
      name: audit-logs
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
  volumes:
  - hostPath:
      path: /var/log/kubernetes
      type: DirectoryOrCreate
    name: audit-logs
  - hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
    name: audit-policy
```

**Create `/etc/kubernetes/audit-policy.yaml`:**

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log Secret access at RequestResponse level
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  # Log ConfigMap modifications
  - level: Request
    resources:
      - group: ""
        resources: ["configmaps"]
    verbs: ["create", "update", "patch", "delete"]

  # Don't log read-only requests
  - level: None
    resources:
      - group: ""
        resources: ["configmaps"]
    verbs: ["get", "list", "watch"]

  # Log all other requests at Metadata level
  - level: Metadata
```

**View audit logs:**
```bash
# On control plane node
tail -f /var/log/kubernetes/audit.log | grep "secrets"

# Filter for Secret access
jq 'select(.objectRef.resource=="secrets")' /var/log/kubernetes/audit.log
```

### RBAC for Secrets

Restrict who can access Secrets:

```yaml
# Read-only role (for developers debugging)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: matrix
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]
  resourceNames: ["public-secrets"]  # Only specific Secrets
---
# NO access to Secrets (default for most users)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer
  namespace: matrix
rules:
- apiGroups: [""]
  resources: ["pods", "services", "deployments"]
  verbs: ["get", "list", "watch"]
# Note: NO secrets access
```

### Compliance Checklist

For **SOC 2, ISO 27001, HIPAA, PCI-DSS**:

- ✅ Secrets encrypted at rest (etcd encryption)
- ✅ Secrets encrypted in transit (TLS between all components)
- ✅ Access logs enabled (Kubernetes audit logging)
- ✅ RBAC configured (least privilege)
- ✅ Regular rotation schedule (documented)
- ✅ Secrets not in Git (README Configuration section only)
- ✅ Secrets not in environment variables (mounted as volumes)
- ✅ Secrets not in logs (Synapse config reviewed)

**Additional for PCI-DSS:**
- ✅ External secrets management (Vault/AWS Secrets Manager)
- ✅ Automated rotation ( for DB passwords)

---

## Best Practices

### DO ✅

1. **Enable encryption at rest** (critical for production)
2. **Use unique secrets per environment** (dev, staging, prod)
3. **Mount secrets as volumes**, not environment variables
4. **Generate strong secrets**: `openssl rand -base64 32`
5. **Limit Secret access** with RBAC
6. **Audit Secret access** (enable audit logging)
7. **Rotate secrets regularly** (schedule + immediate on compromise)
8. **Backup secrets securely** (encrypted backup of encryption keys)
9. **Use External Secrets** for large enterprises
10. **Document secrets** in README Configuration section (not values!)

### DON'T ❌

1. **Don't commit secrets to Git** (even encrypted Git repos)
2. **Don't use default/weak passwords**
3. **Don't share secrets via email/Slack**
4. **Don't grant cluster-admin to everyone**
5. **Don't ignore rotation** (set calendar reminders)
6. **Don't use same secret across environments**
7. **Don't hardcode secrets in manifests**
8. **Don't log secret values** (check application logs)
9. **Don't skip encryption at rest** (it's too easy to enable)
10. **Don't forget to rotate encryption keys** (annually)

---

## Summary

### Current State

Your deployment uses **standard Kubernetes Secrets**:
- ⚠️ Grade: **GOOD** (4/5)
- ✅ Not in Git
- ✅ Documented
- ⚠️ Not encrypted at rest (by default)

### Recommended Improvements

**Minimum (All Deployments):**
1. ✅ **Enable encryption at rest** ( setup)
   - Follow [Encryption at Rest](#encryption-at-rest) section
   - Zero operational overhead
   - Massive security improvement

**For Enterprises:**
2. ✅ **External Secrets Operator** (if you have Vault/cloud secrets manager)
   - Centralized management
   - Automatic rotation
   - Audit trail

3. ✅ **Audit logging** (track Secret access)
   - Required for compliance
   - Detect unauthorized access

### After Improvements

- ✅ Grade: **EXCELLENT** (5/5)
- ✅ Secrets encrypted at rest
- ✅ Optional external secrets
- ✅ Rotation procedures documented
- ✅ Audit trail enabled

---

## LI RSA Key Pair Generation and Management

### Overview

The LI (Lawful Intercept) system uses **RSA-2048 public-key cryptography** to protect E2EE recovery keys captured from clients.

**Architecture**:
- **Public key**: Embedded in Element Web (`element-web/src/utils/LIEncryption.ts`) and Element Android (`element-x-android/.../li/LIEncryption.kt`)
- **Private key**: Stored offline by authorized LI personnel ONLY (NEVER in Kubernetes cluster or any server)
- **Encrypted payload**: Stored in key_vault database (PostgreSQL in matrix namespace)
- **Encryption**: RSA-2048 with PKCS1 padding (industry standard)

**Data Flow**:
1. User sets up E2EE recovery in Element client
2. Client generates recovery key (plaintext, 48-character random string)
3. Client encrypts recovery key with RSA public key (embedded in client)
4. Client POSTs encrypted payload to Synapse: `/_synapse/client/v1/li/store_key`
5. Synapse forwards to key_vault: `http://key-vault.matrix.svc.cluster.local:8000/api/v1/store-key`
6. key_vault stores Base64-encoded encrypted payload in database
7. Later: LI personnel decrypt with private key (synapse-admin-li decryption tool)

**Security Model**:
- **Capture**: Automated (client-side, transparent to user)
- **Storage**: Encrypted (RSA-2048, cannot be decrypted without private key)
- **Access**: Manual (requires private key held offline by authorized personnel)

---

### Generating RSA Key Pair

**WHEN TO GENERATE**:
- Before first deployment (initial setup)
- During key rotation (every 12 months or after personnel changes)
- After suspected compromise

**WHERE TO GENERATE**:
- **Secure offline workstation** (NOT connected to internet)
- **Air-gapped machine** (best practice)
- **Minimum**: Clean, malware-free workstation with disk encryption

**WHO CAN GENERATE**:
- Security administrator with LI authorization
- Requires management approval
- Document in audit log

---

#### Step-by-Step Generation Procedure

**Step 1: Prepare secure environment**

```bash
# WHERE: Secure offline workstation
# WHEN: Before starting key generation
# WHY: Ensure clean environment

# Verify OpenSSL installed
openssl version
# Expected: OpenSSL 1.1.1 or newer (NOT LibreSSL)

# Create working directory
mkdir -p ~/li-keys
cd ~/li-keys

# Set restrictive permissions
chmod 700 ~/li-keys

# Verify no network connectivity (if air-gapped)
ping -c 1 8.8.8.8
# Expected: Network is unreachable (good for air-gapped)
```

**Step 2: Generate RSA-2048 private key**

```bash
# Generate private key
openssl genrsa -out li_private_key.pem 2048

# Output should show:
# Generating RSA private key, 2048 bit long modulus
# .....+++
# .....+++
# e is 65537 (0x10001)

# Verify key generated
ls -lh li_private_key.pem
# Should show file ~1.7KB

# Check key validity
openssl rsa -in li_private_key.pem -check -noout

# Expected output:
# RSA key ok
```

**Step 3: Extract public key**

```bash
# Extract public key from private key
openssl rsa -in li_private_key.pem -pubout -out li_public_key.pem

# Output:
# writing RSA key

# Verify public key created
ls -lh li_public_key.pem
# Should show file ~450 bytes

# View public key (PEM format)
cat li_public_key.pem

# Expected format:
# -----BEGIN PUBLIC KEY-----
# MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
# (multiple lines of Base64)
# ...
# -----END PUBLIC KEY-----
```

**Step 4: Test encryption/decryption**

```bash
# Create test recovery key (matches Element format)
echo "EsFz qLxh 9wBJ kJpT hNiE xDdp 2U2L iMg9 b7N3 vQk6 d8K5 jRm2" > test_recovery_key.txt

# Encrypt with public key (simulates client behavior)
openssl rsautl -encrypt -pubin -inkey li_public_key.pem \
  -in test_recovery_key.txt -out test_encrypted.bin

# Verify encrypted file created
ls -lh test_encrypted.bin
# Should show file ~256 bytes (same size as 2048-bit key)

# Base64 encode (matches client transmission format)
base64 test_encrypted.bin > test_encrypted_b64.txt

# View Base64-encoded payload
cat test_encrypted_b64.txt
# Shows long Base64 string (~344 characters)

# Decrypt with private key (simulates LI personnel decryption)
base64 -d test_encrypted_b64.txt | openssl rsautl -decrypt -inkey li_private_key.pem

# Expected output (should match original):
# EsFz qLxh 9wBJ kJpT hNiE xDdp 2U2L iMg9 b7N3 vQk6 d8K5 jRm2

# If decryption successful, keypair is valid
```

**Step 5: Secure private key**

```bash
# Encrypt private key with AES-256 (CRITICAL STEP)
openssl rsa -aes256 -in li_private_key.pem -out li_private_key_encrypted.pem

# Prompt will ask for passphrase:
# Enter PEM pass phrase: (type minimum 20 characters, mix of uppercase, lowercase, numbers, symbols)
# Verifying - Enter PEM pass phrase: (repeat)

# Verify encrypted key created
ls -lh li_private_key_encrypted.pem
# Should show file ~1.9KB (slightly larger due to encryption metadata)

# Test decryption (to verify passphrase works)
openssl rsa -in li_private_key_encrypted.pem -check -noout

# Prompt: Enter pass phrase for li_private_key_encrypted.pem:
# (enter your passphrase)
# Expected output: RSA key ok

# SECURELY DELETE unencrypted private key (CRITICAL)
shred -vfz -n 10 li_private_key.pem

# Output shows:
# shred: li_private_key.pem: pass 1/10 (random)...
# shred: li_private_key.pem: removed

# Verify unencrypted key deleted
ls li_private_key.pem
# Expected: No such file or directory

# Clean up test files
shred -vfz -n 3 test_recovery_key.txt test_encrypted.bin test_encrypted_b64.txt
```

**Step 6: Label and document**

```bash
# Rename with version and date for tracking
DATE=$(date +%Y%m%d)
mv li_private_key_encrypted.pem li_private_key_v1_${DATE}_encrypted.pem
mv li_public_key.pem li_public_key_v1_${DATE}.pem

# Create metadata file
cat > li_keypair_v1_${DATE}_metadata.txt <<EOF
LI RSA Key Pair v1
Generated: $(date +"%Y-%m-%d %H:%M:%S %Z")
Algorithm: RSA-2048 with PKCS1 padding
Generated by: $(whoami)
Machine: $(hostname)
Purpose: LI system E2EE recovery key encryption
Private key: li_private_key_v1_${DATE}_encrypted.pem (AES-256 encrypted)
Public key: li_public_key_v1_${DATE}.pem
Deployment: Embed public key in element-web and element-x-android
Private key storage: [SPECIFY LOCATION - HSM/safe/air-gapped machine]
Authorized personnel: [LIST NAMES]
Next rotation date: $(date -d "+12 months" +"%Y-%m-%d")
EOF

# Review metadata
cat li_keypair_v1_${DATE}_metadata.txt
```

**Final files**:
- `li_private_key_v1_YYYYMMDD_encrypted.pem` - Encrypted private key (store offline)
- `li_public_key_v1_YYYYMMDD.pem` - Public key (embed in clients)
- `li_keypair_v1_YYYYMMDD_metadata.txt` - Key metadata (store with keys)

---

### Embedding Public Key in Clients

#### Element Web

**File**: `/home/ali/Messenger/element-web/src/utils/LIEncryption.ts`

**Current lines 5-15** (example):
```typescript
// LI: RSA-2048 public key for recovery key encryption
const LI_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAo8Z...  ← PLACEHOLDER
(multiple lines)
...
-----END PUBLIC KEY-----`;
```

**How to replace**:

```bash
# WHERE: Workstation with element-web source code
# WHEN: After generating new keypair
# WHY: Embed public key so client can encrypt recovery keys

# Step 1: Copy public key content
cat ~/li-keys/li_public_key_v1_YYYYMMDD.pem

# Step 2: Edit LIEncryption.ts
nano /home/ali/Messenger/element-web/src/utils/LIEncryption.ts

# Step 3: Replace lines 5-15 with:
const LI_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
[PASTE YOUR PUBLIC KEY HERE - MULTIPLE LINES]
-----END PUBLIC KEY-----`;

# CRITICAL: Keep -----BEGIN/END----- lines
# CRITICAL: Keep backticks (`) for TypeScript multi-line string

# Step 4: Verify syntax
cd /home/ali/Messenger/element-web
npm run lint src/utils/LIEncryption.ts

# Expected: No errors

# Step 5: Build element-web (see separate build instructions)
# Step 6: Deploy updated element-web to Kubernetes
```

**Testing**:
```typescript
// In browser console after deploying updated element-web:
import { encryptKey } from './utils/LIEncryption';
const encrypted = encryptKey('test-recovery-key-123');
console.log(encrypted);
// Should output Base64 string ~344 characters
```

---

#### Element Android

**File**: `/home/ali/Messenger/element-x-android/libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/li/LIEncryption.kt`

**Current lines 8-18** (example):
```kotlin
object LIEncryption {
    private const val LI_PUBLIC_KEY = """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...  ← PLACEHOLDER
(multiple lines)
-----END PUBLIC KEY-----"""
```

**How to replace**:

```bash
# WHERE: Workstation with element-x-android source code
# WHEN: After generating new keypair
# WHY: Embed public key so Android client can encrypt recovery keys

# Step 1: Copy public key content
cat ~/li-keys/li_public_key_v1_YYYYMMDD.pem

# Step 2: Edit LIEncryption.kt
nano /home/ali/Messenger/element-x-android/libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/li/LIEncryption.kt

# Step 3: Replace lines 8-18 with:
private const val LI_PUBLIC_KEY = """-----BEGIN PUBLIC KEY-----
[PASTE YOUR PUBLIC KEY HERE - MULTIPLE LINES]
-----END PUBLIC KEY-----"""

# CRITICAL: Keep -----BEGIN/END----- lines
# CRITICAL: Keep triple quotes (""") for Kotlin multi-line string

# Step 4: Verify syntax
cd /home/ali/Messenger/element-x-android
./gradlew :libraries:matrix:impl:compileDebugKotlin

# Expected: BUILD SUCCESSFUL

# Step 5: Build element-x-android APK (see separate build instructions)
# Step 6: Distribute updated APK to users
```

---

### Storing Private Key Securely

**CRITICAL SECURITY REQUIREMENTS**:

#### What NOT to do (Security Violations)

❌ **NEVER** store private key in:
- Kubernetes cluster (any namespace, any secret)
- Git repository (any branch, even private repos)
- Docker image
- Any server or VM (even in /root or encrypted partition)
- Cloud storage (AWS S3, Google Drive, Dropbox, etc.)
- Email (even encrypted)
- Chat/messaging apps (Slack, Teams, WhatsApp, etc.)
- Unencrypted USB drive
- Laptop/desktop hard drive (even if laptop has full disk encryption)

❌ **NEVER**:
- Send private key over network (any protocol)
- Store private key unencrypted anywhere
- Share private key with unauthorized personnel
- Create more than 3 copies of private key

---

#### Acceptable Storage Methods (Choose ONE)

**Option 1: Hardware Security Module (HSM)** - BEST for compliance

✅ **Recommended for**: Regulated industries, high-security requirements

**Devices**: YubiKey 5, Nitrokey, Ledger Nano, enterprise HSM

**Procedure**:
```bash
# Generate key INSIDE HSM (key never leaves device)
# Consult HSM documentation for specific commands
# Example for YubiKey:
ykman piv keys generate 9a li_public_key.pem

# Import existing private key to HSM
# (if key already generated - not recommended, prefer generation inside HSM)
pkcs15-init --store-private-key li_private_key_encrypted.pem
```

**Advantages**:
- Key cannot be extracted
- Tamper-resistant hardware
- Meets compliance standards (FIPS 140-2)

**Disadvantages**:
- Cost ($50-$5000 depending on device)
- Requires training
- Key loss = permanent loss (generate new keypair)

---

**Option 2: Encrypted USB Drive in Physical Safe** - GOOD for medium security

✅ **Recommended for**: Small-medium organizations without HSM budget

**Requirements**:
- FIPS-certified encrypted USB drive (e.g., Apricorn Aegis Secure Key)
- Physical safe (fire-rated, combination or key lock)
- Documented access log

**Procedure**:
```bash
# Step 1: Initialize encrypted USB drive (follow manufacturer instructions)

# Step 2: Copy encrypted private key to USB
cp li_private_key_v1_YYYYMMDD_encrypted.pem /media/secure-usb/
cp li_keypair_v1_YYYYMMDD_metadata.txt /media/secure-usb/

# Step 3: Create 2nd copy on separate encrypted USB (backup)
# Use DIFFERENT USB drive, store in DIFFERENT physical safe

# Step 4: Verify copies
sha256sum li_private_key_v1_YYYYMMDD_encrypted.pem
sha256sum /media/secure-usb/li_private_key_v1_YYYYMMDD_encrypted.pem
# Checksums must match

# Step 5: Securely delete from workstation
shred -vfz -n 10 ~/li-keys/li_private_key_v1_YYYYMMDD_encrypted.pem

# Step 6: Place USB drives in safes
# Primary: Main office safe
# Backup: Offsite safe (different building)

# Step 7: Document storage locations
# Update li_keypair_v1_YYYYMMDD_metadata.txt with safe locations
```

**Access procedure**:
1. Sign out USB from safe (document in access log: date, time, personnel, purpose)
2. Use key on air-gapped LI workstation ONLY
3. Return USB to safe immediately after use
4. Sign back in (document in access log)

---

**Option 3: Air-Gapped Machine** - MINIMUM acceptable

✅ **Recommended for**: Small organizations, temporary deployments

**Requirements**:
- Dedicated machine with NO network connectivity (physically removed Wi-Fi/Ethernet)
- Full disk encryption (LUKS, BitLocker, FileVault)
- BIOS password
- Locked room with access control

**Procedure**:
```bash
# Step 1: Prepare air-gapped machine
# - Install OS
# - Enable full disk encryption
# - Set BIOS password
# - Physically remove network adapters
# - Verify no network connectivity

# Step 2: Transfer encrypted private key via USB
# (Use USB with only private key, remove after transfer)

# Step 3: Store on encrypted partition
sudo mkdir -p /opt/li-keys
sudo chmod 700 /opt/li-keys
sudo cp li_private_key_v1_YYYYMMDD_encrypted.pem /opt/li-keys/
sudo chown root:root /opt/li-keys/li_private_key_v1_YYYYMMDD_encrypted.pem
sudo chmod 400 /opt/li-keys/li_private_key_v1_YYYYMMDD_encrypted.pem

# Step 4: Verify network isolation
ping -c 1 8.8.8.8
# Must fail: Network is unreachable

# Step 5: Document machine location and access
# Update metadata.txt with machine details
```

**Usage**:
- Decryption ONLY performed on this air-gapped machine
- Use synapse-admin-li decryption tool loaded via USB
- Results written to USB for transfer to LI personnel

---

### Decrypting Recovery Keys (LI Operations)

**WHEN**: During authorized lawful intercept investigation ONLY

**WHO**: Authorized LI personnel with management approval

**WHERE**: Air-gapped LI workstation OR secure terminal with audit logging

---

#### Method 1: Using synapse-admin-li Decryption Tool (Web-based)

**Access**: `https://admin-li.matrix.example.com/decryption`

**Prerequisites**:
- Access to synapse-admin-li (LI instance)
- Encrypted recovery key payload from key_vault database
- Private key (from HSM/USB/air-gapped machine)
- Private key passphrase

**Step-by-Step Procedure**:

```bash
# Step 1: Retrieve encrypted payload from key_vault
# WHERE: kubectl-configured workstation with matrix namespace access

kubectl exec -n matrix -it $(kubectl get pod -n matrix -l app=key-vault -o jsonpath='{.items[0].metadata.name}') -- \
  python manage.py shell

# In Python shell:
from secret.models import EncryptedKey
target_user = "@johndoe:matrix.example.com"
keys = EncryptedKey.objects.filter(user__username=target_user).order_by('-created_at')
for key in keys:
    print(f"Created: {key.created_at}")
    print(f"Encrypted Payload:\n{key.encrypted_payload}\n")
    print("---")
exit()

# Copy the Base64-encoded encrypted payload (latest key)
```

**Step 2: Access synapse-admin-li decryption tool**

```
1. Open browser: https://admin-li.matrix.example.com/decryption
2. Log in with LI admin credentials
3. Navigate to "Decryption Tool" page
```

**Step 3: Decrypt payload**

```
1. Paste encrypted payload (Base64 string from Step 1) into "Encrypted Payload" field
2. Upload private key file:
   - From USB: Select li_private_key_v1_YYYYMMDD_encrypted.pem
   - From HSM: Export public operation signature (consult HSM docs)
3. Enter private key passphrase in "Passphrase" field
4. Click "Decrypt" button
5. Decrypted recovery key appears in "Decrypted Recovery Key" field
   (Format: "EsFz qLxh 9wBJ kJpT hNiE xDdp 2U2L iMg9 b7N3 vQk6 d8K5 jRm2")
6. Click "Copy to Clipboard"
7. IMMEDIATELY click "Clear All Fields" to remove private key from browser memory
8. Close browser tab
```

**Step 4: Use recovery key in element-web-li**

```
1. Access element-web-li: https://element-li.matrix.example.com
2. Log in as target user (admin changed password via synapse-admin-li)
3. Element prompts: "Verify this device" → Click "Verify with Security Key"
4. Paste decrypted recovery key (from clipboard)
5. Click "Continue"
6. Element loads encryption keys from backup
7. All encrypted rooms and messages now accessible
```

**CRITICAL SECURITY NOTES**:
- Document all decryption operations in audit log (date, time, personnel, target user, justification)
- Clear browser cache/cookies after decryption
- Restart browser after LI investigation concludes
- Return private key to secure storage immediately

---

#### Method 2: Command-Line Decryption (Air-Gapped Machine)

**WHEN**: Web-based tool unavailable OR higher security required

**WHERE**: Air-gapped LI workstation with private key

```bash
# Step 1: Transfer encrypted payload to air-gapped machine
# (Use USB with payload.txt containing Base64 string)

# Step 2: Decode Base64 and decrypt
base64 -d payload.txt | openssl rsautl -decrypt -inkey /opt/li-keys/li_private_key_v1_YYYYMMDD_encrypted.pem

# Prompt: Enter pass phrase for /opt/li-keys/li_private_key_v1_YYYYMMDD_encrypted.pem:
# (type passphrase)

# Output: Decrypted recovery key (plaintext)
# EsFz qLxh 9wBJ kJpT hNiE xDdp 2U2L iMg9 b7N3 vQk6 d8K5 jRm2

# Step 3: Write to file for transfer
base64 -d payload.txt | openssl rsautl -decrypt -inkey /opt/li-keys/li_private_key_v1_YYYYMMDD_encrypted.pem > decrypted_key.txt 2>&1

# Step 4: Verify decryption succeeded
cat decrypted_key.txt
# Should show recovery key, not "unable to load Private Key" error

# Step 5: Transfer to USB for LI personnel
cp decrypted_key.txt /media/usb/

# Step 6: Securely delete from air-gapped machine
shred -vfz -n 10 decrypted_key.txt payload.txt
```

---

### Key Rotation

**WHEN TO ROTATE**:
- **Scheduled**: Every 12 months (routine security practice)
- **Personnel change**: LI personnel with key access leaves organization
- **Suspected compromise**: Any indication of key exposure
- **Compliance requirement**: Regulatory mandate or audit recommendation

---

#### Key Rotation Procedure

**Step 1: Generate new keypair**

Follow "Generating RSA Key Pair" section above with NEW version number:
- Old: `li_private_key_v1_20250125_encrypted.pem`
- New: `li_private_key_v2_20260125_encrypted.pem`

**Step 2: Update clients with new public key**

```bash
# Update element-web
cd /home/ali/Messenger/element-web
nano src/utils/LIEncryption.ts
# Replace LI_PUBLIC_KEY with new public key v2
# Build and deploy updated element-web

# Update element-x-android
cd /home/ali/Messenger/element-x-android
nano libraries/matrix/impl/src/main/kotlin/io/element/android/libraries/matrix/impl/li/LIEncryption.kt
# Replace LI_PUBLIC_KEY with new public key v2
# Build and distribute updated APK

# Users must update to new client versions
# Old clients will still capture with v1 public key (still works)
# New clients will capture with v2 public key
```

**Step 3: Maintain old private key for historical decryption**

**CRITICAL**: DO NOT delete old private key (v1)

```bash
# Both private keys must be stored securely:
# - li_private_key_v1_20250125_encrypted.pem (decrypt keys captured before rotation)
# - li_private_key_v2_20260125_encrypted.pem (decrypt keys captured after rotation)

# Update metadata to track multiple key versions
cat > li_keypair_versions.txt <<EOF
LI RSA Key Versions

Version 1:
- Generated: 2025-01-25
- Rotated: 2026-01-25
- Private key: li_private_key_v1_20250125_encrypted.pem
- Public key: li_public_key_v1_20250125.pem
- Status: Retired (maintain for historical decryption)

Version 2:
- Generated: 2026-01-25
- Active: Yes
- Private key: li_private_key_v2_20260125_encrypted.pem
- Public key: li_public_key_v2_20260125.pem
- Next rotation: 2027-01-25
EOF
```

**Step 4: Update key_vault to track key version (optional enhancement)**

Modify key_vault database schema to add `key_version` field:

```python
# /home/ali/Messenger/key_vault/secret/models.py
class EncryptedKey(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE)
    encrypted_payload = models.TextField()
    payload_hash = models.CharField(max_length=64, db_index=True)
    key_version = models.IntegerField(default=1)  # NEW FIELD
    created_at = models.DateTimeField(auto_now_add=True)
```

This allows tracking which key version was used for each encrypted payload, so correct private key is used for decryption.

---

### Security Best Practices

#### DO ✅

1. **Generate keys on air-gapped machine**
   - No network connectivity during generation
   - Clean, malware-free OS
   - Verify with checksums

2. **Use minimum RSA-2048 (prefer RSA-4096 for long-term)**
   - 2048-bit: Adequate for 10+ years (per NIST)
   - 4096-bit: Higher security margin (slower, larger payloads)

3. **Encrypt private key with strong passphrase**
   - Minimum 20 characters
   - Mix uppercase, lowercase, numbers, symbols
   - Use passphrase manager (NOT password manager)
   - Example: "Tr0ub4dor&3-LI-K3y-2025-M@tr!x"

4. **Store private key offline in HSM or physical safe**
   - Hardware Security Module (best)
   - Encrypted USB in safe (good)
   - Air-gapped machine (minimum)

5. **Test encryption/decryption before production**
   - Generate test keypair
   - Encrypt test payload
   - Decrypt and verify
   - Only deploy after successful test

6. **Document key generation and rotation**
   - Generation date and personnel
   - Key version and file names
   - Storage location
   - Access log

7. **Maintain audit log of private key access**
   - Date, time, personnel
   - Purpose (which user investigation)
   - Approval authority
   - Results

8. **Keep old private keys for historical decryption**
   - Never delete rotated keys
   - Label with version and date
   - Store alongside current key

9. **Limit authorized personnel to 2-3 people**
   - Principle of least privilege
   - Background checks required
   - Regular access reviews

10. **Use multi-person approval for key usage**
    - One person requests decryption
    - Another person approves
    - Document both parties

---

#### DON'T ❌

1. **Never store private key in cluster/server/cloud**
   - Not in Kubernetes Secrets
   - Not in any server filesystem
   - Not in cloud storage (S3, GCS, etc.)

2. **Never commit private key to Git**
   - Not in any branch (even private repos)
   - Not in .gitignore (file still exists locally)
   - Add to .gitignore: `li_private_key*.pem`

3. **Never send private key over network**
   - Not via email (even encrypted)
   - Not via chat/messaging
   - Not via SCP/SFTP
   - Physical transfer only (USB)

4. **Never store private key unencrypted**
   - Always use AES-256 encryption
   - Always require passphrase
   - Never store passphrase with key

5. **Never use weak key sizes**
   - Never RSA-1024 (broken)
   - Never RSA-512 (trivially broken)
   - Minimum RSA-2048 (current standard)

6. **Never share private key with unauthorized personnel**
   - Not IT staff
   - Not system administrators
   - Not database administrators
   - Only designated LI personnel

7. **Never generate keys with less than 2048 bits**
   - RSA-1024 deprecated in 2010
   - NIST requires minimum 2048 bits

8. **Never delete old private keys**
   - Needed for historical data decryption
   - Keys captured with v1 public key need v1 private key
   - Maintain all key versions indefinitely

9. **Never bypass audit logging**
   - All key access must be documented
   - All decryption operations must be logged
   - Regular audit reviews required

10. **Never perform LI operations without authorization**
    - Require legal approval for each investigation
    - Document authorization in audit log
    - Unauthorized access is criminal offense

---

### Compliance Notes

#### Regulatory Requirements Met

✅ **RSA-2048 encryption**:
- NIST SP 800-131A compliant (minimum 2048 bits)
- Adequate for 10+ years per current standards
- FIPS 140-2 compatible (when using FIPS-certified HSM)

✅ **Private key offline storage**:
- Meets air-gapped deployment requirements
- No private key on servers (compliance with data protection regulations)
- Physical access controls (safe/HSM)

✅ **Audit logging**:
- All key generation documented
- All key access logged
- All decryption operations recorded
- Meets compliance audit requirements

✅ **Key rotation policy**:
- Annual rotation (meets industry standards)
- Personnel change triggers (security best practice)
- Compromise response procedure (incident response)

✅ **Multi-person approval**:
- Segregation of duties (compliance requirement)
- Prevents unauthorized access
- Documented approval process

---

#### Regulations Addressed

**GDPR (General Data Protection Regulation)**:
- Data encryption (Art. 32)
- Access controls (Art. 32)
- Audit logging (Art. 30)

**HIPAA (Health Insurance Portability and Accountability Act)**:
- Encryption and decryption (§164.312(a)(2)(iv))
- Access controls (§164.308(a)(4))
- Audit controls (§164.312(b))

**SOC 2 (Service Organization Control)**:
- Security criteria (encryption, access control)
- Availability criteria (key recovery)
- Confidentiality criteria (private key protection)

**ISO 27001 (Information Security Management)**:
- A.10.1.1 Cryptographic controls
- A.9.2 User access management
- A.12.4 Logging and monitoring

---

### Troubleshooting

#### Problem: "unable to load Private Key" error

```bash
# Error when attempting to decrypt:
unable to load Private Key
140234567890123:error:0909006C:PEM routines:get_name:no start line:crypto/pem/pem_lib.c:745

# Cause: Private key file corrupted or wrong format
# Solution:
# 1. Verify file is PEM format
head -1 li_private_key_encrypted.pem
# Must show: -----BEGIN RSA PRIVATE KEY-----

# 2. Verify file not corrupted
openssl rsa -in li_private_key_encrypted.pem -check -noout
# Should ask for passphrase and show "RSA key ok"

# 3. If corrupted, restore from backup
# (This is why you maintain multiple copies)
```

#### Problem: Wrong passphrase error

```bash
# Error:
Enter pass phrase for li_private_key_encrypted.pem:
unable to load Private Key
140234567890123:error:06065064:digital envelope routines:EVP_DecryptFinal_ex:bad decrypt:crypto/evp/evp_enc.c:610

# Cause: Incorrect passphrase
# Solution:
# - Try passphrase again (check CAPS LOCK)
# - Verify passphrase from secure passphrase manager
# - If passphrase lost, key is permanently unrecoverable (generate new keypair)
```

#### Problem: Decrypted output is garbage

```bash
# Symptom: Decryption produces random bytes, not recovery key
# Output: ��X�#$%^&*()_+  (random binary)

# Cause: Encrypted with different public key than private key being used
# Solution:
# 1. Verify public/private key pair matches
openssl rsa -in li_private_key_encrypted.pem -pubout | diff - li_public_key.pem
# Should show no differences

# 2. Check key version in key_vault metadata
# Payload might be encrypted with v2 public key but decrypting with v1 private key

# 3. Ensure Base64 decoding before decryption
base64 -d payload.txt | openssl rsautl -decrypt -inkey li_private_key_encrypted.pem
# (NOT: openssl rsautl -decrypt -in payload.txt)
```

#### Problem: "data too large for key size" error

```bash
# Error when encrypting:
RSA operation error
140234567890123:error:0407006A:rsa routines:RSA_padding_check_PKCS1_type_1:data too large for key size

# Cause: Attempting to encrypt data larger than key size
# RSA-2048 can encrypt maximum 245 bytes (2048/8 - 11 bytes padding)
# Element recovery keys are 48 characters = 48 bytes (within limit)

# Solution:
# - Verify encrypting recovery key only (not entire keychain)
# - Recovery key format: "EsFz qLxh ... jRm2" (48 chars)
# - If encrypting larger data, use hybrid encryption (AES + RSA)
```

---

### Testing Checklist

Before production deployment, complete this testing checklist:

```bash
# Test 1: Key generation
□ Generate RSA-2048 keypair
□ Verify private key: openssl rsa -in key.pem -check
□ Extract public key successfully
□ Files created: private key (~1.7KB), public key (~450 bytes)

# Test 2: Encryption/decryption
□ Create test payload (48-character recovery key format)
□ Encrypt with public key
□ Base64 encode encrypted payload
□ Base64 decode encrypted payload
□ Decrypt with private key
□ Decrypted output matches original payload

# Test 3: Private key encryption
□ Encrypt private key with AES-256
□ Verify encrypted key larger than original (~1.9KB)
□ Test decryption with passphrase
□ Securely delete unencrypted private key (shred)

# Test 4: Client integration (element-web)
□ Embed public key in LIEncryption.ts
□ Build element-web successfully
□ Deploy to test environment
□ Create test user and set up E2EE recovery
□ Verify encrypted payload posted to Synapse LI endpoint

# Test 5: key_vault storage
□ Check key_vault database for encrypted payload
□ Verify Base64 format
□ Verify payload_hash calculated
□ Verify no duplicates (same payload twice)

# Test 6: Decryption via synapse-admin-li
□ Access decryption tool UI
□ Paste encrypted payload from key_vault
□ Upload private key file
□ Enter passphrase
□ Verify decrypted recovery key correct format
□ Use decrypted key in element-web-li
□ Verify encrypted rooms accessible

# Test 7: Security validation
□ Private key NOT in Git (check: git log -S "BEGIN RSA PRIVATE KEY")
□ Private key NOT in Kubernetes (check: kubectl get secrets -A)
□ Private key NOT on any server (check: find / -name "*private_key*" 2>/dev/null)
□ Private key encrypted with strong passphrase
□ Private key stored offline (USB/safe/HSM/air-gapped)

# Test 8: Documentation
□ Metadata file created with key details
□ Authorized personnel list documented
□ Storage location documented
□ Next rotation date documented
□ Audit log template created

# Test 9: Key rotation
□ Generate v2 keypair with new date
□ Update element-web with v2 public key
□ Verify v1 private key still decrypts old payloads
□ Verify v2 private key decrypts new payloads
□ Both keys stored securely

# Test 10: Compliance verification
□ RSA-2048 minimum (verified with: openssl rsa -text -in key.pem | grep "Private-Key")
□ Audit log includes all required fields
□ Multi-person approval process documented
□ Key access log template created
□ Annual rotation scheduled

# All tests must pass before production deployment
```

---

### Summary

**Key Takeaways**:

1. **Generation**: OpenSSL on air-gapped machine, RSA-2048 minimum
2. **Storage**: Offline only (HSM > USB in safe > air-gapped machine)
3. **Encryption**: Always encrypt private key with AES-256 + strong passphrase
4. **Deployment**: Embed public key in element-web and element-x-android
5. **Rotation**: Annual or after personnel changes (maintain old keys)
6. **Usage**: Decryption only by authorized LI personnel with approval
7. **Audit**: Log all key access and decryption operations
8. **Compliance**: Meets GDPR, HIPAA, SOC 2, ISO 27001 requirements

**Critical Security Rules**:
- ❌ NEVER store private key on server/cluster/cloud
- ❌ NEVER commit private key to Git
- ❌ NEVER send private key over network
- ❌ NEVER delete old private keys (needed for historical decryption)
- ✅ ALWAYS encrypt private key with strong passphrase
- ✅ ALWAYS store offline in HSM/safe/air-gapped machine
- ✅ ALWAYS document key access in audit log
- ✅ ALWAYS maintain multiple versions after rotation

---

**Next Steps:**

1. Review README Configuration section for all secrets to generate
2. Enable encryption at rest (this guide)
3. Set up audit logging (this guide)
4. Schedule annual rotation (calendar reminder)
5. Optional: Deploy External Secrets Operator (for enterprises)

**Questions?** Check:
- Kubernetes Encryption at Rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- External Secrets Operator: https://external-secrets.io/
- Sealed Secrets: https://github.com/bitnami-labs/sealed-secrets
