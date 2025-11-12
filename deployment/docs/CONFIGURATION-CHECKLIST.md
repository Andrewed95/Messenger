# Configuration Checklist - Values to Replace Before Deployment

**Purpose:** Lists all placeholder values that MUST be replaced before deploying Matrix/Synapse
**CRITICAL:** Do NOT deploy with placeholder values - your deployment will fail or be insecure

---

## Overview

This deployment includes placeholder values that you MUST replace with your actual values. This document lists every placeholder and where to find it.

**Before you deploy, you must:**
1. ✅ Choose your domain name
2. ✅ Generate secure passwords
3. ✅ Configure storage classes
4. ✅ Set IP address ranges
5. ✅ Configure email settings

---

## 1. Domain Name (CRITICAL - Multiple Files)

**Your Domain:** `_________________` (e.g., `matrix.example.com` or `chat.company.com`)

### Files to Update:

#### `deployment/manifests/09-ingress.yaml`
```yaml
# Line 40, 65, 136, 141, 240, 297
# FIND:    chat.z3r0d3v.com
# REPLACE: YOUR_ACTUAL_DOMAIN
```

**Occurrences:**
- Line 40: Certificate dnsNames
- Line 65: Certificate dnsNames
- Line 136: TLS hosts
- Line 141: Ingress rule host
- Line 240: TLS hosts
- Line 297: Ingress rule host

#### `deployment/manifests/07-element-web.yaml`
```yaml
# Lines 24, 25, 58, 62
# FIND:    chat.z3r0d3v.com
# REPLACE: YOUR_ACTUAL_DOMAIN
```

**Occurrences:**
- Line 24: base_url
- Line 25: server_name
- Line 58: default_server_name
- Line 62: roomDirectory.servers

#### `deployment/manifests/08-synapse-admin.yaml`
```yaml
# Lines 65, 129, 215, 216, 230
# FIND:    chat.z3r0d3v.com
# REPLACE: YOUR_ACTUAL_DOMAIN
```

**Quick Replace All Domains:**
```bash
# From deployment directory, run:
cd /home/user/Messenger/deployment

# REPLACE 'YOUR_DOMAIN' with your actual domain
DOMAIN="matrix.example.com"

# Replace in all files
find manifests/ -type f -name "*.yaml" -exec sed -i "s/chat.z3r0d3v.com/$DOMAIN/g" {} \;

# Verify replacements
grep -r "chat.z3r0d3v.com" manifests/ || echo "All occurrences replaced!"
```

---

## 2. Email Configuration

### Let's Encrypt Certificate Email

**File:** `deployment/manifests/09-ingress.yaml` OR create ClusterIssuer manually

**Your Email:** `_________________` (e.g., `admin@example.com`)

```yaml
# When creating ClusterIssuer (see DEPLOYMENT-GUIDE.md Phase 5, Step 5.1)
spec:
  acme:
    email: YOUR_EMAIL@example.com  # CHANGE THIS
```

**Command to create:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: YOUR_ACTUAL_EMAIL@example.com  # ← CHANGE THIS
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
```

---

## 3. Storage Classes (CRITICAL for Data Persistence)

**Your Storage Class:** `_________________` (e.g., `local-path`, `longhorn`, `ceph-block`, `gp2`)

**To find available storage classes:**
```bash
kubectl get storageclass
```

### Files to Update:

#### `deployment/manifests/01-postgresql-cluster.yaml`
```yaml
# Line 66: PostgreSQL data storage
storageClass: ""  # CHANGE TO: your-storage-class

# Line 73: PostgreSQL WAL storage (prefer fast SSD/NVMe)
storageClass: ""  # CHANGE TO: your-fast-storage-class

# Line 197: Snapshot class (if using volume snapshots)
className: ""  # CHANGE TO: your-snapshot-class OR remove if not using
```

#### `deployment/manifests/02-minio-tenant.yaml`
```yaml
# Line 48: MinIO storage
storageClassName: ""  # CHANGE TO: your-storage-class
```

**Quick Replace All Storage Classes:**
```bash
# REPLACE 'your-storage-class' with actual storage class
STORAGE_CLASS="local-path"  # or gp2, longhorn, ceph-block, etc.

# Replace in PostgreSQL manifest
sed -i "s/storageClass: \"\"/storageClass: \"$STORAGE_CLASS\"/g" manifests/01-postgresql-cluster.yaml

# Replace in MinIO manifest
sed -i "s/storageClassName: \"\"/storageClassName: \"$STORAGE_CLASS\"/g" manifests/02-minio-tenant.yaml
```

---

## 4. Passwords and Secrets (CRITICAL for Security)

**NEVER use placeholder passwords in production!**

### Generate Secure Passwords:
```bash
# Generate a random 32-character password
openssl rand -base64 32

# Or use pwgen (install if needed: apt-get install pwgen)
pwgen -s 32 1
```

### Files to Update:

#### `deployment/manifests/01-postgresql-cluster.yaml`
```yaml
# Line 339: PostgreSQL superuser password
password: "CHANGE_TO_SECURE_PASSWORD"  # GENERATE SECURE PASSWORD!
```

**Example:**
```yaml
password: "xK8mP2nV9qW4rT5yU7iO6pL3jH4gF2aZ1sD9cX8vB5nM"
```

#### `deployment/manifests/02-minio-tenant.yaml`
```yaml
# Line 149: MinIO root user
export MINIO_ROOT_USER="CHANGE_TO_MINIO_ROOT_USER"

# Line 150: MinIO root password
export MINIO_ROOT_PASSWORD="CHANGE_TO_SECURE_PASSWORD"
```

**Example:**
```yaml
export MINIO_ROOT_USER="minio-admin"
export MINIO_ROOT_PASSWORD="sE7tR4mK9pL2nV6qW3jH8xC5yT1oP9aZ4bD7fG2sM6hK"
```

#### `deployment/manifests/01-postgresql-cluster.yaml` (Backup Credentials)
```yaml
# Lines 352-353: MinIO S3 credentials for PostgreSQL backups
ACCESS_KEY_ID: "CHANGE_TO_MINIO_ACCESS_KEY"
SECRET_ACCESS_KEY: "CHANGE_TO_MINIO_SECRET_KEY"
```

**Note:** These should match credentials you create in MinIO after deployment.

#### `deployment/manifests/04-coturn.yaml`
```yaml
# Line 55: TURN server realm (must match your domain)
realm=turn.CHANGE_TO_YOUR_DOMAIN

# Line 82: TURN shared secret
static-auth-secret=CHANGE_TO_SHARED_SECRET

# Line 95: Secret resource
shared-secret: "CHANGE_TO_SHARED_SECRET"  # Must match static-auth-secret above
```

**Example:**
```yaml
realm=turn.matrix.example.com
static-auth-secret="yR8nP5mK2qL9tW6vX4jH3cF7aZ1sD8bG5"
shared-secret: "yR8nP5mK2qL9tW6vX4jH3cF7aZ1sD8bG5"  # Same value
```

**Important:** The shared secret must be identical in both places and must match the value in Synapse configuration.

#### `deployment/manifests/05-synapse-main.yaml`
```yaml
# CRITICAL: Multiple secrets needed for Synapse

# Line 115: Signing keys (generate with Synapse)
ed25519 a_AAAA CHANGE_TO_GENERATED_SIGNING_KEY

# Line 117: Registration shared secret
registration-shared-secret: "CHANGE_TO_RANDOM_SECRET"

# Line 118: Macaroon secret key
macaroon-secret-key: "CHANGE_TO_RANDOM_SECRET"

# Line 119: Form secret
form-secret: "CHANGE_TO_RANDOM_SECRET"

# Line 122-123: S3 credentials (match MinIO credentials)
access-key: "CHANGE_TO_MINIO_ACCESS_KEY"
secret-key: "CHANGE_TO_MINIO_SECRET_KEY"

# Line 140: PostgreSQL password
password: "CHANGE_TO_POSTGRES_PASSWORD"

# Lines 154-155: S3 credentials in homeserver.yaml
access_key_id: "CHANGE_TO_MINIO_ACCESS_KEY"
secret_access_key: "CHANGE_TO_MINIO_SECRET_KEY"

# Lines 168-171: Secrets in homeserver.yaml (MUST MATCH Secret resource above)
registration_shared_secret: "CHANGE_TO_REGISTRATION_SECRET"
turn_shared_secret: "CHANGE_TO_COTURN_SHARED_SECRET"
form_secret: "CHANGE_TO_FORM_SECRET"
macaroon_secret_key: "CHANGE_TO_MACAROON_SECRET"
```

**Generate Synapse Signing Keys:**
```bash
# Method 1: Using Synapse Docker image
docker run -it --rm \
  -v /tmp/synapse-keys:/data \
  matrixdotorg/synapse:latest \
  generate-keys \
  -c /data/homeserver.yaml \
  --generate-signing-key

# The signing key will be in /tmp/synapse-keys/matrix.example.com.signing.key
cat /tmp/synapse-keys/matrix.example.com.signing.key

# Method 2: Generate random secrets for other keys
openssl rand -base64 32  # For registration_shared_secret
openssl rand -base64 32  # For macaroon_secret_key
openssl rand -base64 32  # For form_secret
```

**CRITICAL:** Ensure consistency between Secret resource and homeserver.yaml ConfigMap:
- `registration-shared-secret` (Secret) = `registration_shared_secret` (ConfigMap)
- `macaroon-secret-key` (Secret) = `macaroon_secret_key` (ConfigMap)
- `form-secret` (Secret) = `form_secret` (ConfigMap)
- `turn_shared_secret` (ConfigMap) = coturn `shared-secret`

#### `deployment/manifests/10-operational-automation.yaml`
```yaml
# Line 24: Admin access token for automation
token: "CHANGE_TO_ADMIN_ACCESS_TOKEN"
```

**Generate admin access token after deployment:**
```bash
# 1. First, create an admin user via Synapse registration
# 2. Login and get access token:
curl -X POST https://chat.example.com/_matrix/client/r0/login \
  -H "Content-Type: application/json" \
  -d '{
    "type": "m.login.password",
    "identifier": {
      "type": "m.id.user",
      "user": "admin"
    },
    "password": "your_admin_password"
  }'

# 3. Extract access_token from response
# 4. Update operational-automation Secret with the token
```

**Note:** Deploy operational automation AFTER Synapse is fully operational.

---

## 5. Storage Classes (Additional Locations)

Beyond PostgreSQL and MinIO (covered in Section 3), storage classes are also needed for:

#### `deployment/manifests/05-synapse-main.yaml`
```yaml
# Line 313: Synapse media storage PVC
storageClassName: ""  # CHANGE TO: your-storage-class
```

**Quick replace for Synapse media storage:**
```bash
STORAGE_CLASS="local-path"  # or your storage class
sed -i "s/storageClassName: \"\"/storageClassName: \"$STORAGE_CLASS\"/g" manifests/05-synapse-main.yaml
```

---

## 6. IP Address Ranges

### MetalLB Load Balancer IP Pool

**File:** `deployment/manifests/03-metallb-config.yaml`

**Your IP Range:** `_________________` (e.g., `192.168.1.240-192.168.1.250`)

```yaml
# Line 22
addresses:
  - 192.168.1.240-192.168.1.250  # CHANGE TO YOUR AVAILABLE IP RANGE
```

**Requirements:**
- Must be IPs on same network as Kubernetes nodes
- Must NOT be used by DHCP
- Must be routable from clients
- Recommend 10-20 addresses

**To find your network:**
```bash
# On a Kubernetes node:
ip addr show | grep inet
# Look for your private network (e.g., 192.168.0.0/16, 10.0.0.0/8)
```

### MinIO Admin Access IP Whitelist (Optional Security)

**File:** `deployment/manifests/02-minio-tenant.yaml`

```yaml
# Line 196: Restrict MinIO admin console to specific IPs
nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8,YOUR_ADMIN_IP/32"
```

**Example:**
```yaml
# Allow from private network and specific admin IP
whitelist-source-range: "192.168.0.0/16,203.0.113.50/32"

# Or allow from anywhere (less secure):
whitelist-source-range: "0.0.0.0/0"
```

### MinIO Domain Name

**File:** `deployment/manifests/02-minio-tenant.yaml`

```yaml
# Lines 201, 204: MinIO admin console domain
- minio.CHANGE_TO_YOUR_DOMAIN  # e.g., minio.example.com
```

---

## 7. Container Image Versions (Optional Update)

The deployment uses specific versions to ensure stability. You can update these if you want latest versions.

### Files Containing Version Tags:

#### `deployment/manifests/08-synapse-admin.yaml`
```yaml
# Line 118
image: awesometechnologies/synapse-admin:0.10.0  # CHANGE_TO_LATEST_STABLE
```

#### `deployment/manifests/07-element-web.yaml`
```yaml
# Line 128
image: vectorim/element-web:v1.11.50  # CHANGE_TO_LATEST_STABLE
```

#### `deployment/manifests/02-minio-tenant.yaml`
```yaml
# Line 126
image: minio/minio:RELEASE.2024-01-01T00-00-00Z  # CHANGE_TO_LATEST_STABLE
```

**To find latest versions:**
- Synapse Admin: https://hub.docker.com/r/awesometechnologies/synapse-admin/tags
- Element Web: https://hub.docker.com/r/vectorim/element-web/tags
- MinIO: https://hub.docker.com/r/minio/minio/tags

**Note:** Using specific versions is recommended for production stability.

---

## 8. HAProxy Configuration Hash (Optional)

**File:** `deployment/manifests/06-haproxy.yaml`

```yaml
# Line 64: Config hash annotation
config-hash: "REPLACE_WITH_CONFIG_HASH"
```

**This is optional** - you can remove this line or generate hash:
```bash
# Generate SHA256 hash of HAProxy config
sha256sum deployment/config/haproxy.cfg | awk '{print $1}'
```

**Or just remove the annotation:**
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8404"
  prometheus.io/path: "/metrics"
  # config-hash line removed
```

---

## 9. Scale-Specific Configuration

**File:** Multiple worker and database configurations

See [`SCALING-GUIDE.md`](SCALING-GUIDE.md) for:
- Worker replica counts for your scale
- Database connection pool sizes
- Resource requests/limits
- Cache sizes

**Worker replicas to adjust based on your scale:**

In `deployment/manifests/06-synapse-workers.yaml`:
- Line 165: Sync worker replicas (2-18 depending on scale)
- Line 341: Generic worker replicas (2-8 depending on scale)
- Line 498: Event persister replicas (2-4 depending on scale)
- Line 646: Federation sender replicas (2-8 depending on scale)

**See SCALING-GUIDE.md Section 9.1 for exact counts for your scale.**

---

## Pre-Deployment Verification Checklist

Before running deployment, verify you've replaced:

```bash
# Run from deployment directory
cd /home/user/Messenger/deployment

# Check for remaining placeholders
echo "=== Checking for unreplaced placeholders ==="

# 1. Check for example domains
grep -r "chat.z3r0d3v.com" manifests/ && echo "❌ FOUND: chat.z3r0d3v.com - REPLACE THIS" || echo "✅ No example domains found"
grep -r "example.com" manifests/ && echo "⚠️  FOUND: example.com - Review these" || echo "✅ No example.com found"

# 2. Check for CHANGE_ placeholders
grep -r "CHANGE_TO" manifests/ && echo "❌ FOUND: CHANGE_TO placeholders - REPLACE THESE" || echo "✅ No CHANGE_TO placeholders"

# 3. Check for empty storage classes
grep "storageClass: \"\"" manifests/*.yaml && echo "❌ FOUND: Empty storage classes - SET THESE" || echo "✅ Storage classes configured"

# 4. Check for password placeholders
grep -r "SECURE_PASSWORD" manifests/ && echo "❌ FOUND: Password placeholders - GENERATE SECURE PASSWORDS" || echo "✅ No password placeholders"

echo "=== Verification Complete ===="
```

**All checks should show ✅ before deployment.**

---

## Quick Configuration Script (Optional)

Save this script to quickly replace common values:

```bash
#!/bin/bash
# File: configure-deployment.sh
# Purpose: Replace placeholder values in manifests

set -e

echo "=== Matrix/Synapse Deployment Configuration ==="
echo ""

# 1. Domain name
read -p "Enter your domain name (e.g., matrix.example.com): " DOMAIN
find manifests/ -type f -name "*.yaml" -exec sed -i "s/chat.z3r0d3v.com/$DOMAIN/g" {} \;
echo "✅ Domain configured: $DOMAIN"

# 2. Storage class
read -p "Enter your storage class (e.g., local-path): " STORAGE_CLASS
sed -i "s/storageClass: \"\"/storageClass: \"$STORAGE_CLASS\"/g" manifests/01-postgresql-cluster.yaml
sed -i "s/storageClassName: \"\"/storageClassName: \"$STORAGE_CLASS\"/g" manifests/02-minio-tenant.yaml
echo "✅ Storage class configured: $STORAGE_CLASS"

# 3. MetalLB IP range
read -p "Enter MetalLB IP range (e.g., 192.168.1.240-192.168.1.250): " IP_RANGE
sed -i "s/192.168.1.240-192.168.1.250/$IP_RANGE/g" manifests/03-metallb-config.yaml
echo "✅ IP range configured: $IP_RANGE"

# 4. Generate passwords
echo ""
echo "Generating secure passwords..."
PG_PASSWORD=$(openssl rand -base64 32)
MINIO_PASSWORD=$(openssl rand -base64 32)
echo "✅ PostgreSQL password: $PG_PASSWORD"
echo "✅ MinIO password: $MINIO_PASSWORD"
echo ""
echo "⚠️  SAVE THESE PASSWORDS SECURELY!"
echo ""

sed -i "s/CHANGE_TO_SECURE_PASSWORD/$PG_PASSWORD/g" manifests/01-postgresql-cluster.yaml
sed -i "s/CHANGE_TO_SECURE_PASSWORD/$MINIO_PASSWORD/g" manifests/02-minio-tenant.yaml

echo "✅ Configuration complete!"
echo ""
echo "Next steps:"
echo "1. Review manifests/ files for any remaining placeholders"
echo "2. Run: grep -r 'CHANGE' manifests/"
echo "3. Follow DEPLOYMENT-GUIDE.md to deploy"
```

**To use:**
```bash
chmod +x configure-deployment.sh
./configure-deployment.sh
```

---

## Summary

**CRITICAL replacements (deployment will fail without these):**
- ✅ Domain name (`chat.z3r0d3v.com` → your domain)
- ✅ Storage classes (empty `""` → your storage class)
- ✅ MetalLB IP range (example range → your available IPs)
- ✅ PostgreSQL password (placeholder → secure generated password)
- ✅ MinIO credentials (placeholders → secure generated passwords)
- ✅ coturn shared secret (placeholder → secure generated secret)
- ✅ Synapse signing keys (generate with Synapse Docker image)
- ✅ Synapse secrets (registration, macaroon, form secrets)

**IMPORTANT replacements (security/functionality):**
- ✅ Let's Encrypt email (for certificate notifications)
- ✅ MinIO domain (if using MinIO console)
- ✅ MinIO S3 credentials for PostgreSQL backups (after MinIO deployed)
- ✅ coturn realm domain (must match your domain)
- ✅ Admin access token (generate after Synapse deployment)

**OPTIONAL updates:**
- Container image versions (use latest stable)
- IP whitelists (restrict admin access)
- Worker replica counts (based on your scale)

**Verification:**
Run the pre-deployment verification commands before deployment to ensure no placeholders remain.

---

**Document Version:** 1.0
**Last Updated:** 2025-11-11
**Next Step:** After replacing all values, follow `DEPLOYMENT-GUIDE.md`
