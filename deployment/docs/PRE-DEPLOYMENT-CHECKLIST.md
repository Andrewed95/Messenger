# Pre-Deployment Checklist
## Critical Steps Before Deploying Matrix/Synapse to Production


---

## ⚠️ IMPORTANT

**DO NOT deploy to production without completing ALL items in this checklist.**

Failure to complete these steps will result in:
- ❌ Security vulnerabilities (default passwords, exposed endpoints)
- ❌ Deployment failures (invalid configurations)
- ❌ Data loss (missing backups, incorrect storage)
- ❌ Legal compliance issues (LI instance not properly secured)

---

## Table of Contents

1. [Infrastructure Prerequisites](#1-infrastructure-prerequisites)
2. [Replace All CHANGEME Secrets](#2-replace-all-changeme-secrets)
3. [Configure Domain Names](#3-configure-domain-names)
4. [Configure LI Security (IP Whitelisting)](#4-configure-li-security-ip-whitelisting)
5. [Generate Signing Keys](#5-generate-signing-keys)
6. [Configure TLS Certificates](#6-configure-tls-certificates)
7. [Configure External Services](#7-configure-external-services)
8. [Storage and Backup Configuration](#8-storage-and-backup-configuration)
9. [Network and Firewall Configuration](#9-network-and-firewall-configuration)
10. [Final Validation](#10-final-validation)

---

## 1. Infrastructure Prerequisites

### Kubernetes Cluster

- [ ] **Kubernetes version 1.28 or higher** installed and running
- [ ] **kubectl** configured and able to access the cluster
- [ ] **helm** version 3.x installed locally
- [ ] **Sufficient resources** available (see SCALING-GUIDE.md for your target CCU)

**Verification:**
```bash
kubectl version --short
helm version --short
kubectl get nodes
kubectl top nodes  # Check available resources
```

### Storage Class

- [ ] **Default StorageClass** configured
- [ ] **Storage provisioner** supports dynamic PVC provisioning
- [ ] **Minimum IOPS requirements** met:
  - PostgreSQL: 3000 IOPS (production database)
  - MinIO: 1000 IOPS per node (media storage)
  - Redis: 500 IOPS (caching)

**Verification:**
```bash
kubectl get storageclass
kubectl describe storageclass <default-storage-class>
```

### DNS Configuration

- [ ] **Domain name** purchased and accessible
- [ ] **DNS A records** can be created (for Ingress)
- [ ] **Let's Encrypt prerequisites** met if using TLS automation:
  - Ports 80 and 443 accessible from internet
  - Domain resolves to cluster ingress IP
  - Email address for certificate notifications

---

## 2. Replace All CHANGEME Secrets

### 🔴 CRITICAL: All secrets marked with CHANGEME must be replaced before deployment.

### 2.1 Generate Secure Random Passwords

**Use strong password generation:**
```bash
# Generate a 32-character secure password
openssl rand -base64 32

# Or use pwgen (if installed)
pwgen -s 32 1
```

### 2.2 Redis Password

**File:** `deployment/infrastructure/02-redis/redis-secret.yaml`

- [ ] Line 16: Replace `CHANGE_ME_GENERATE_SECURE_PASSWORD`

**Command:**
```bash
# Generate password
REDIS_PASSWORD=$(openssl rand -base64 32)

# Update file
sed -i "s/CHANGE_ME_GENERATE_SECURE_PASSWORD/$(echo -n "$REDIS_PASSWORD" | base64)/g" \
  deployment/infrastructure/02-redis/redis-secret.yaml
```

**Save this password securely** - you'll need it for:
- Synapse main instance
- Synapse LI instance
- LiveKit (if using)

### 2.3 MinIO Credentials

**File:** `deployment/infrastructure/03-minio/secrets.yaml`

- [ ] Line 17: Replace `CHANGE_ME_GENERATE_SECURE_PASSWORD_32_CHARS` (root password)
- [ ] Line 53: Replace `CHANGE_ME_GENERATE_SECURE_S3_PASSWORD` (application password, appears 2x)

**Commands:**
```bash
# Generate root password (for MinIO console access)
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)

# Generate application S3 password
S3_PASSWORD=$(openssl rand -base64 24)

# Update file
sed -i "s/CHANGE_ME_GENERATE_SECURE_PASSWORD_32_CHARS/$(echo -n "$MINIO_ROOT_PASSWORD" | base64)/g" \
  deployment/infrastructure/03-minio/secrets.yaml

sed -i "s/CHANGE_ME_GENERATE_SECURE_S3_PASSWORD/$(echo -n "$S3_PASSWORD" | base64)/g" \
  deployment/infrastructure/03-minio/secrets.yaml
```

### 2.4 Synapse Main Instance Secrets

**File:** `deployment/main-instance/01-synapse/secrets.yaml`

Replace the following (lines 25-51):

- [ ] `CHANGEME_SECURE_DB_PASSWORD` (PostgreSQL password)
- [ ] `CHANGEME_SECURE_REDIS_PASSWORD` (Redis password from step 2.2)
- [ ] `CHANGEME_SECURE_S3_PASSWORD` (MinIO S3 password from step 2.3)
- [ ] `CHANGEME_SECURE_REPLICATION_SECRET` (worker replication secret)
- [ ] `CHANGEME_SECURE_MACAROON_SECRET` (Synapse macaroon secret)
- [ ] `CHANGEME_SECURE_REGISTRATION_SECRET` (Synapse registration secret)
- [ ] `CHANGEME_SECURE_FORM_SECRET` (Synapse form secret)
- [ ] `CHANGEME_SECURE_TURN_SECRET` (coturn shared secret)
- [ ] `CHANGEME_SECURE_KEY_VAULT_API_KEY` (key_vault API key)
- [ ] `CHANGEME_GENERATE_USING_SYNAPSE_GENERATE_COMMAND` (signing key - see section 5)

**Generate all secrets:**
```bash
# PostgreSQL password
DB_PASSWORD=$(openssl rand -base64 32)

# Replication secret
REPLICATION_SECRET=$(openssl rand -base64 48)

# Macaroon secret
MACAROON_SECRET=$(openssl rand -base64 48)

# Registration secret
REGISTRATION_SECRET=$(openssl rand -base64 48)

# Form secret
FORM_SECRET=$(openssl rand -base64 48)

# TURN shared secret
TURN_SECRET=$(openssl rand -base64 32)

# key_vault API key
KEY_VAULT_API=$(openssl rand -base64 32)

# Update file (manual editing recommended for accuracy)
# Or use sed with base64 encoding
```

**⚠️ IMPORTANT:** Save all these secrets in a secure password manager. You'll need them for troubleshooting and future operations.

### 2.5 TURN/coturn Secrets

**File:** `deployment/main-instance/06-coturn/deployment.yaml`

- [ ] Line 22: Replace `CHANGEME_SECURE_TURN_SECRET` (same as Synapse TURN secret)
- [ ] Line 26: Replace `CHANGEME_TURN_PASSWORD` (coturn admin password)

### 2.6 Sygnal Push Notifications

**File:** `deployment/main-instance/07-sygnal/deployment.yaml`

**Only required if you're using push notifications for iOS/Android:**

- [ ] Line 23: `CHANGEME_APNS_PRIVATE_KEY` (Apple Push Notification Service private key)
- [ ] Line 26: `CHANGEME_APNS_KEY_ID` (APNS Key ID)
- [ ] Line 27: `CHANGEME_APNS_TEAM_ID` (Apple Team ID)
- [ ] Line 36: `CHANGEME_FCM_PROJECT_ID` (Firebase Cloud Messaging project ID)
- [ ] Lines 37-40: FCM credentials (get from Firebase Console)

**If not using push notifications:** You can skip deploying Sygnal entirely.

### 2.7 key_vault Secrets

**File:** `deployment/main-instance/08-key-vault/deployment.yaml`

- [ ] Line 27: `CHANGEME_DJANGO_SECRET_KEY_GENERATE_SECURE_RANDOM_STRING` (Django secret key)
- [ ] Line 32: `CHANGEME_SECURE_KEY_VAULT_DB_PASSWORD` (PostgreSQL password, same as step 2.4)
- [ ] Line 38: `CHANGEME_SECURE_KEY_VAULT_API_KEY` (API key, same as step 2.4)
- [ ] Line 44: `CHANGEME_GENERATE_RSA_2048_BIT_PRIVATE_KEY` (RSA encryption key)

**Generate RSA private key:**
```bash
# Generate RSA 2048-bit private key
openssl genrsa -out key_vault_rsa.pem 2048

# Convert to single-line base64 for Kubernetes Secret
cat key_vault_rsa.pem | base64 -w 0
```

### 2.8 LI Instance Secrets

**File:** `deployment/li-instance/01-synapse-li/deployment.yaml`

- [ ] Line 190: `CHANGEME_SECURE_LI_DB_PASSWORD` (LI PostgreSQL password)
- [ ] Line 193: `CHANGEME_SECURE_REDIS_PASSWORD` (Redis password, same as step 2.2)
- [ ] Line 197: `CHANGEME_SECURE_S3_PASSWORD` (MinIO S3 password, same as step 2.3)
- [ ] Line 200: `CHANGEME_SECURE_LI_MACAROON_SECRET` (LI-specific macaroon secret)
- [ ] Line 201: `CHANGEME_SECURE_LI_REGISTRATION_SECRET` (LI-specific registration secret)
- [ ] Line 202: `CHANGEME_SECURE_LI_FORM_SECRET` (LI-specific form secret)
- [ ] Line 206: `CHANGEME_COPY_FROM_MAIN_SIGNING_KEY` (⚠️ MUST be the same as main instance!)

**⚠️ CRITICAL:** The LI instance MUST use the **same signing key** as the main instance to decrypt E2EE messages.

### 2.9 Sync System Secrets

**File:** `deployment/li-instance/04-sync-system/deployment.yaml`

- [ ] Line 41: `CHANGEME_REPLICATION_PASSWORD` (PostgreSQL replication password)
- [ ] Line 62: `CHANGEME_REPLICATION_PASSWORD` (same as above)
- [ ] Line 151: `CHANGEME_REPLICATION_PASSWORD` (same as above)
- [ ] Line 158: `CHANGEME_SECURE_LI_DB_PASSWORD` (LI DB password, same as step 2.8)
- [ ] Line 162: `CHANGEME_SECURE_S3_PASSWORD` (MinIO S3 password, same as step 2.3)

**Generate replication password:**
```bash
REPLICATION_PASSWORD=$(openssl rand -base64 32)
```

### 2.10 Cert-Manager Email

**File:** `deployment/infrastructure/04-networking/cert-manager-install.yaml`

- [ ] Line 25: Replace `admin@example.com` (production Let's Encrypt)
- [ ] Line 47: Replace `admin@example.com` (staging Let's Encrypt)

**Use a real email address** - Let's Encrypt will send certificate expiry notifications here.

---

## 3. Configure Domain Names

### 3.1 Main Instance Domains

Replace `example.com` with your actual domain in:

- [ ] **Synapse server_name** - `deployment/main-instance/01-synapse/configmap.yaml` (line 22)
- [ ] **Synapse public_baseurl** - `deployment/main-instance/01-synapse/configmap.yaml` (line 23)
- [ ] **Element web client** - `deployment/main-instance/02-element-web/deployment.yaml`
- [ ] **HAProxy Ingress** - `deployment/main-instance/03-haproxy/deployment.yaml`
- [ ] **coturn realm** - `deployment/main-instance/06-coturn/deployment.yaml`

**Typical domain structure:**
- Main homeserver: `matrix.example.com`
- Element Web: `element.example.com`
- TURN server: `turn.example.com`

### 3.2 LI Instance Domains

Replace `matrix-li.example.com` with your LI domain in:

- [ ] **LI Synapse** - `deployment/li-instance/01-synapse-li/deployment.yaml`
- [ ] **LI Element Web** - `deployment/li-instance/02-element-web-li/deployment.yaml`
- [ ] **LI Synapse Admin** - `deployment/li-instance/03-synapse-admin-li/deployment.yaml`

**Recommendation:** Use a separate subdomain for LI:
- LI homeserver: `matrix-li.example.com`
- LI Element Web: `element-li.example.com`
- LI Admin: `admin-li.example.com`

### 3.3 Federation SRV Records (Optional)

If you want your homeserver to be accessible as `@user:example.com` instead of `@user:matrix.example.com`:

**Add DNS SRV records:**
```
_matrix._tcp.example.com. 86400 IN SRV 10 0 8448 matrix.example.com.
_matrix-fed._tcp.example.com. 86400 IN SRV 10 0 8448 matrix.example.com.
```

**Or use .well-known delegation** (create these files on `example.com` web server):

`.well-known/matrix/server`:
```json
{
  "m.server": "matrix.example.com:8448"
}
```

`.well-known/matrix/client`:
```json
{
  "m.homeserver": {
    "base_url": "https://matrix.example.com"
  }
}
```

---

## 4. Configure LI Security (IP Whitelisting)

### 🔴 CRITICAL: LI instance MUST be restricted to law enforcement IP addresses only.

### 4.1 Enable IP Whitelisting

**Files to update:**

1. `deployment/li-instance/01-synapse-li/deployment.yaml`
2. `deployment/li-instance/02-element-web-li/deployment.yaml`
3. `deployment/li-instance/03-synapse-admin-li/deployment.yaml`

**Find the commented-out annotation and enable it:**

**Before:**
```yaml
annotations:
  # nginx.ingress.kubernetes.io/whitelist-source-range: "YOUR_LAW_ENFORCEMENT_IPS"
```

**After:**
```yaml
annotations:
  nginx.ingress.kubernetes.io/whitelist-source-range: "203.0.113.0/24, 198.51.100.50/32"
```

### 4.2 Get Law Enforcement IP Addresses

- [ ] **Contact your legal/compliance team** to get authorized IP ranges
- [ ] **Document the IP addresses** in your compliance records
- [ ] **Test access** from authorized IPs before production

**IP range format:**
- Single IP: `198.51.100.50/32`
- IP range (CIDR): `203.0.113.0/24`
- Multiple ranges: `203.0.113.0/24, 198.51.100.50/32, 192.0.2.0/24`

### 4.3 Enable HTTP Basic Auth for Synapse Admin LI

**Generate htpasswd file:**
```bash
# Install htpasswd (if not already installed)
apt-get install apache2-utils  # Debian/Ubuntu
yum install httpd-tools         # RHEL/CentOS

# Create htpasswd file
htpasswd -c auth admin
# Enter password when prompted

# Create Kubernetes Secret
kubectl create secret generic synapse-admin-auth \
  --from-file=auth -n matrix
```

**Update Ingress** in `deployment/li-instance/03-synapse-admin-li/deployment.yaml`:
```yaml
annotations:
  nginx.ingress.kubernetes.io/auth-type: basic
  nginx.ingress.kubernetes.io/auth-secret: synapse-admin-auth
  nginx.ingress.kubernetes.io/auth-realm: "Authentication Required - LI Access Only"
  nginx.ingress.kubernetes.io/whitelist-source-range: "YOUR_LAW_ENFORCEMENT_IPS"
```

---

## 5. Generate Signing Keys

### 5.1 Synapse Signing Key (Main Instance)

**This is CRITICAL for Matrix federation and E2EE.**

**Generate signing key:**
```bash
# Using Synapse's built-in command
docker run --rm \
  matrixdotorg/synapse:v1.119.0 \
  generate_signing_key.py > signing.key

# View the key
cat signing.key
```

**Output example:**
```
ed25519 a_RXGa ed25519:auto:abcdef1234567890abcdef1234567890abcdef1234567890abcdef12345678
```

**Update secrets:**
- [ ] Copy the **entire line** to `deployment/main-instance/01-synapse/secrets.yaml` (line 51)
- [ ] **Base64 encode** the line before adding to Secret:
  ```bash
  echo -n "ed25519 a_RXGa ..." | base64
  ```

### 5.2 LI Instance Signing Key

**⚠️ CRITICAL:** The LI instance MUST use the **SAME signing key** as the main instance!

- [ ] Copy the **exact same signing key** from step 5.1
- [ ] Update `deployment/li-instance/01-synapse-li/deployment.yaml` (line 206)
- [ ] **Base64 encode** before adding to Secret (same as above)

**Why same key?** The LI instance needs to decrypt E2EE messages, which requires the same cryptographic identity as the main instance.

---

## 6. Configure TLS Certificates

### 6.1 cert-manager with Let's Encrypt (Recommended)

**Automatic TLS certificate management** - no manual renewal needed.

- [ ] **Verify cert-manager is deployed** (done in Phase 1)
- [ ] **Update email address** in `deployment/infrastructure/04-networking/cert-manager-install.yaml`
- [ ] **Ensure ports 80 and 443 are accessible** from internet (Let's Encrypt HTTP-01 challenge)
- [ ] **Ensure domain DNS resolves** to cluster ingress IP

**Test with staging first:**
```yaml
# In Ingress annotations, use:
cert-manager.io/cluster-issuer: "letsencrypt-staging"

# After testing, switch to production:
cert-manager.io/cluster-issuer: "letsencrypt-prod"
```

### 6.2 Manual TLS Certificates

**If using your own certificates or a private CA:**

```bash
# Create TLS secret from certificate files
kubectl create secret tls matrix-tls \
  --cert=matrix.example.com.crt \
  --key=matrix.example.com.key \
  -n matrix

# Update Ingress to use manual secret
# Remove: cert-manager.io annotations
# Add:
#   tls:
#     - hosts:
#         - matrix.example.com
#       secretName: matrix-tls
```

### 6.3 Air-Gapped Deployment (Self-Signed)

**For air-gapped or internal deployments:**

```bash
# Use self-signed ClusterIssuer
# Already defined in: deployment/infrastructure/04-networking/cert-manager-install.yaml

# In Ingress annotations, use:
cert-manager.io/cluster-issuer: "selfsigned"
```

**⚠️ Warning:** Self-signed certificates will show browser warnings. Only use for internal or testing environments.

---

## 7. Configure External Services

### 7.1 Email Server (SMTP)

**Synapse needs email for:**
- Password resets
- Account validation
- Admin notifications

**Update in:** `deployment/main-instance/01-synapse/configmap.yaml`

```yaml
email:
  smtp_host: "smtp.example.com"
  smtp_port: 587
  smtp_user: "matrix@example.com"
  smtp_pass: "YOUR_SMTP_PASSWORD"
  require_transport_security: true
  notif_from: "Matrix <matrix@example.com>"
  app_name: "Matrix Chat"
```

**Options:**
- Your own SMTP server
- Gmail SMTP (smtp.gmail.com:587)
- SendGrid, Amazon SES, etc.

### 7.2 LiveKit (Video/Voice Calling) - Optional

**If you're using video/voice calling:**

- [ ] **Create LiveKit account** or deploy self-hosted
- [ ] **Get API keys** (Key ID, Secret)
- [ ] **Update** `deployment/values/livekit-values.yaml`
- [ ] **Deploy Redis for LiveKit**:
  ```bash
  helm install livekit-redis bitnami/redis \
    --namespace matrix \
    --values deployment/values/redis-livekit-values.yaml
  ```

### 7.3 coturn (TURN/STUN) - Required for NAT Traversal

**Most users are behind NAT, so TURN is essential for voice/video calls.**

- [ ] **Configure external IP** in `deployment/main-instance/06-coturn/deployment.yaml`
- [ ] **Open UDP ports 49152-65535** on firewall (TURN port range)
- [ ] **Ensure TURN shared secret** matches Synapse configuration

**Test TURN server:**
```bash
# Use Trickle ICE test: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
```

---

## 8. Storage and Backup Configuration

### 8.1 Storage Class Verification

- [ ] **Verify StorageClass supports** the required IOPS:
  - PostgreSQL: 3000 IOPS minimum
  - MinIO: 1000 IOPS per node minimum

**Test IOPS:**
```bash
# Deploy test pod with fio (flexible I/O tester)
kubectl run fio-test --image=clusterhq/fio-tool --rm -it -- \
  fio --name=random-read --ioengine=libaio --iodepth=64 --rw=randread \
  --bs=4k --direct=1 --size=1G --numjobs=4 --runtime=60 --group_reporting
```

### 8.2 MinIO Bucket Creation

**MinIO Tenant auto-creates buckets** defined in `deployment/infrastructure/03-minio/tenant.yaml`.

**Verify buckets exist after deployment:**
```bash
kubectl run mc-client --image=minio/mc --rm -it -- /bin/bash

# Inside pod:
mc alias set myminio http://minio.matrix.svc.cluster.local:9000 \
  accessKey secretKey

mc ls myminio
# Expected buckets:
# - synapse-media
# - synapse-media-li
# - postgresql-backups
```

### 8.3 Backup Verification

**PostgreSQL backups** are automated via CloudNativePG.

**Verify backup configuration:**
```bash
# Check main cluster backups
kubectl get cluster matrix-postgresql -n matrix -o jsonpath='{.spec.backup}'

# Check LI cluster backups
kubectl get cluster matrix-postgresql-li -n matrix -o jsonpath='{.spec.backup}'
```

**Retention policies:**
- Main instance: 
- LI instance:  (longer for compliance)

**Test backup and restore** before production - see `docs/OPERATIONS-UPDATE-GUIDE.md` section 5.

---

## 9. Network and Firewall Configuration

### 9.1 Required Firewall Rules

**Ingress (from internet):**
- [ ] **TCP 80** - HTTP (cert-manager challenge, redirects to HTTPS)
- [ ] **TCP 443** - HTTPS (client API, federation, web clients)
- [ ] **TCP 8448** - Matrix federation (optional if using SRV records)
- [ ] **UDP 49152-65535** - TURN (coturn media relay)

**Egress (to internet):**
- [ ] **TCP 443** - HTTPS (federation with other homeservers)
- [ ] **TCP 8448** - Matrix federation (to other homeservers)
- [ ] **TCP 80** - HTTP (Let's Encrypt, APT updates)
- [ ] **TCP 53, UDP 53** - DNS resolution

**Internal (Kubernetes cluster):**
- All internal communication is managed by NetworkPolicies - no additional firewall rules needed.

### 9.2 Load Balancer Configuration

**For bare-metal Kubernetes (no cloud load balancer):**

- [ ] **Deploy MetalLB** for LoadBalancer Service support:
  ```bash
  helm install metallb metallb/metallb \
    --namespace metallb-system --create-namespace \
    --values deployment/values/metallb-values.yaml
  ```

- [ ] **Configure IP address pool** in `deployment/values/metallb-values.yaml`

**For cloud Kubernetes (GKE, EKS, AKS):**
- LoadBalancer Services will automatically provision cloud load balancers

### 9.3 NetworkPolicy Verification

**Verify all NetworkPolicies are applied:**
```bash
kubectl get networkpolicies -n matrix

# Should show:
# - default-deny-all
# - allow-dns
# - postgresql-access
# - postgresql-li-access
# - redis-access
# - minio-access
# - key-vault-isolation
# - li-instance-isolation
# - synapse-main-egress
# - allow-from-ingress
# - allow-prometheus-scraping
# - antivirus-access
```

**Test NetworkPolicy enforcement** (see `docs/HA-ROUTING-GUIDE.md` for testing procedures).

---

## 10. Final Validation

### 10.1 Configuration Validation

**Run automated checks:**
```bash
# Verify all CHANGEME markers are replaced
grep -r "CHANGEME" deployment/
# Should return: NO RESULTS

# Verify domain names are updated
grep -r "example.com" deployment/ | grep -v docs | grep -v README
# Review results - should only be intentional references

# Verify secrets are base64-encoded
for file in $(find deployment -name "*secret*.yaml" -o -name "*secrets*.yaml"); do
  echo "Checking $file"
  grep -v "^#" "$file" | grep -E "password|key|secret" | grep -v "CHANGEME"
done
# All values should be base64-encoded (alphanumeric strings ending with =)
```

### 10.2 Resource Validation

**Verify you have sufficient resources:**
```bash
# Check total cluster resources
kubectl top nodes

# Compare with SCALING-GUIDE.md requirements for your target CCU
# See: deployment/docs/SCALING-GUIDE.md
```

### 10.3 Checklist Summary

**Before proceeding to deployment, verify:**

- [ ] ✅ All CHANGEME secrets replaced
- [ ] ✅ All domain names configured
- [ ] ✅ LI instance IP whitelisting enabled
- [ ] ✅ Signing keys generated and configured
- [ ] ✅ TLS certificates configured (cert-manager or manual)
- [ ] ✅ SMTP email configured
- [ ] ✅ Storage class verified and tested
- [ ] ✅ Firewall rules configured
- [ ] ✅ NetworkPolicies reviewed
- [ ] ✅ Backup configuration verified
- [ ] ✅ Resource requirements met (see SCALING-GUIDE.md)
- [ ] ✅ DNS records created and verified
- [ ] ✅ Legal/compliance team notified (for LI instance)

---

## 11. Post-Checklist Next Steps

Once all items are completed:

1. **Review deployment plan** - `deployment/README.md`
2. **Deploy Phase 1** - Infrastructure (PostgreSQL, Redis, MinIO, Networking)
3. **Deploy Phase 2** - Main instance (Synapse, workers, clients)
4. **Deploy Phase 3** - LI instance (Synapse LI, sync system)
5. **Deploy Phase 4** - Monitoring (Prometheus, Grafana, Loki)
6. **Deploy Phase 5** - Antivirus (ClamAV, Content Scanner)

**Detailed deployment instructions:** See `deployment/README.md` and `deployment/docs/DEPLOYMENT-GUIDE.md`

---

## 12. Emergency Rollback Plan

**If deployment fails:**

1. **Identify the failed phase** from deployment logs
2. **Rollback the specific phase:**
   ```bash
   # Example: Rollback Phase 2 (Synapse)
   kubectl delete -f deployment/main-instance/01-synapse/
   ```
3. **Review logs** to identify the root cause:
   ```bash
   kubectl logs -n matrix <failed-pod-name>
   kubectl describe pod -n matrix <failed-pod-name>
   ```
4. **Fix the issue** (usually missing secret or misconfiguration)
5. **Retry deployment** for that phase

**For data loss or corruption:**
- Restore from backup (see `docs/OPERATIONS-UPDATE-GUIDE.md` section 5.2)

---

## 13. Compliance and Legal Notices

### Lawful Intercept (LI) Compliance

**Before deploying the LI instance:**

- [ ] **Legal review completed** - Ensure deployment complies with local laws
- [ ] **Law enforcement contacts documented** - Who has access to LI?
- [ ] **Access logs enabled** - Monitor who accesses LI instance
- [ ] **Retention policy documented** - How long is LI data stored?
- [ ] **Data protection compliance** - GDPR, CCPA, etc.

**Recommended:**
- Regular audits of LI access logs
- Annual review of LI policies
- Training for authorized personnel

---

## Support and Resources

**If you encounter issues:**

1. **Review documentation:**
   - `deployment/README.md` - Main deployment guide
   - `deployment/docs/DEPLOYMENT-GUIDE.md` - Detailed walkthrough
   - `deployment/docs/SCALING-GUIDE.md` - Resource sizing
   - `deployment/docs/OPERATIONS-UPDATE-GUIDE.md` - Updates and backups

2. **Check troubleshooting guides:**
   - Component-specific READMEs in each directory
   - `deployment/docs/CONFIGURATION-CHECKLIST.md`

3. **Community support:**
   - Matrix.org community
   - Synapse GitHub issues
   - CloudNativePG community

---


**Maintained by:** Matrix/Synapse Deployment Team
