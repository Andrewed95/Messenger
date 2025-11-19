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
