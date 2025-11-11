# Configuration Reference

Complete reference for all configuration options in the Matrix Synapse deployment.

---

## Configuration File Location

All configuration is centralized in:
```
deployment/config/deployment.env
```

**Create from template:**
```bash
cp config/deployment.env.example config/deployment.env
```

**Edit your configuration:**
```bash
nano config/deployment.env
```

---

## Configuration Sections

- [Domain Configuration](#domain-configuration)
- [Storage Configuration](#storage-configuration)
- [Network Configuration](#network-configuration)
- [PostgreSQL Configuration](#postgresql-configuration)
- [Redis Configuration](#redis-configuration)
- [MinIO Configuration](#minio-configuration)
- [Synapse Configuration](#synapse-configuration)
- [coturn Configuration](#coturn-configuration)
- [LiveKit Configuration](#livekit-configuration)
- [Monitoring Configuration](#monitoring-configuration)
- [TLS/Certificate Configuration](#tlscertificate-configuration)
- [Optional Features](#optional-features)

---

## Domain Configuration

### MATRIX_DOMAIN

**Description:** Your Matrix server's public domain name

**Required:** Yes

**Example:**
```bash
MATRIX_DOMAIN="chat.example.com"
```

**Used By:**
- Element Web configuration
- Synapse homeserver.yaml (public_baseurl)
- Ingress routing
- TLS certificate

**Important:**
- Must be a valid DNS name
- DNS must point to your load balancer IP
- Used for federation (if enabled)

### MATRIX_SERVER_NAME

**Description:** Matrix server name for user IDs

**Required:** Yes

**Example:**
```bash
MATRIX_SERVER_NAME="chat.example.com"
```

**Used By:**
- Synapse homeserver.yaml (server_name)
- User IDs format: `@username:chat.example.com`

**Important:**
- Usually same as MATRIX_DOMAIN
- **Cannot be changed** after first user creation
- Federation uses this name

---

## Storage Configuration

Kubernetes storage classes for different workloads.

**Check available storage classes:**
```bash
kubectl get storageclass
```

### STORAGE_CLASS_GENERAL

**Description:** General-purpose storage class

**Required:** Yes

**Default:** `local-path`

**Used By:**
- Synapse media cache (before S3 upload)
- Element Web
- Synapse Admin
- Temporary storage

**Recommendations:**
- Standard performance OK
- Any storage class supporting ReadWriteOnce

### STORAGE_CLASS_DATABASE

**Description:** Storage class for PostgreSQL

**Required:** Yes

**Default:** `local-path`

**Used By:**
- PostgreSQL data volumes
- PostgreSQL WAL volumes

**Recommendations:**
- **Prefer NVMe/SSD** for best performance
- Must support ReadWriteOnce
- Must support volume expansion (resizeInUseVolumes)
- Examples: `local-path`, `ceph-block`, `longhorn`

**Performance Impact:**
- Database performance directly affected
- Faster storage = faster message delivery
- Consider dedicated storage for PostgreSQL

### STORAGE_CLASS_MINIO

**Description:** Storage class for MinIO object storage

**Required:** Yes

**Default:** `local-path`

**Used By:**
- MinIO data volumes (4 nodes)

**Recommendations:**
- Large capacity more important than speed
- Must support ReadWriteOnce
- Examples: `local-path`, `ceph-block`, `nfs` (with caution)

**Sizing:**
- Stores all uploaded media files
- Plan for growth (images, videos, files)
- Erasure coding uses 4x raw storage

---

## Network Configuration

### METALLB_IP_RANGE

**Description:** IP address range for LoadBalancer services

**Required:** Yes

**Format:** `START_IP-END_IP`

**Example:**
```bash
METALLB_IP_RANGE="192.168.1.240-192.168.1.250"
```

**Used By:**
- MetalLB LoadBalancer
- NGINX Ingress external IP

**Requirements:**
- IPs must be available (not used by DHCP or other devices)
- Must be on same subnet as Kubernetes nodes
- Recommend 10-20 IPs
- Layer 2 mode: IPs must be in same broadcast domain

**How Many IPs Needed:**
- NGINX Ingress: 1 IP
- Future services: Additional IPs
- Reserve 10-20 for flexibility

**Verification:**
```bash
# Check no conflicts
ping 192.168.1.240
# Should fail (no response)
```

### Node Labels

Nodes must be labeled for certain services that use `hostNetwork: true`.

#### LIVEKIT_NODES

**Description:** Nodes where LiveKit will run

**Required:** Yes (if using LiveKit)

**Format:** Comma-separated node names

**Example:**
```bash
LIVEKIT_NODES="worker-1,worker-2,worker-3,worker-4"
```

**Requirements:**
- Exactly 4 nodes recommended
- Nodes should have good network connectivity
- Nodes should have public IPs (or NAT configured)

**Why hostNetwork:**
- WebRTC requires predictable IP addressing
- Direct network access for media streams

#### COTURN_NODES

**Description:** Nodes where coturn will run

**Required:** Yes (for voice/video calls)

**Format:** Comma-separated node names

**Example:**
```bash
COTURN_NODES="worker-5,worker-6"
```

**Requirements:**
- Exactly 2 nodes recommended
- Nodes MUST have public IPs (or port forwarding configured)
- UDP ports 49152-65535 must be accessible from internet
- TCP/UDP port 3478 must be accessible from internet

**Why Public IPs:**
- TURN server needs to relay media traffic
- Clients connect directly to coturn
- NAT traversal requires real public IPs

**Update Node IPs in Configuration:**

After labeling nodes, update their IPs:

```bash
COTURN_NODE1_IP="<public-ip-of-first-node>"
COTURN_NODE2_IP="<public-ip-of-second-node>"
```

---

## PostgreSQL Configuration

### POSTGRES_PASSWORD

**Description:** Password for PostgreSQL `synapse` user

**Required:** Yes

**Security:** HIGH - Protect this password

**Generation:**
```bash
openssl rand -base64 32
```

**Example:**
```bash
POSTGRES_PASSWORD="a7Kx9mP4n2Qr8sT6vZ3cF5gH1jL0"
```

**Used By:**
- Synapse database connection
- PgBouncer connection pool
- Manual database access

**Important:**
- Use strong, random password
- Minimum 32 characters
- Do not reuse passwords

### POSTGRES_BACKUP_S3_ACCESS_KEY

**Description:** MinIO access key for PostgreSQL backups

**Required:** Yes

**Example:**
```bash
POSTGRES_BACKUP_S3_ACCESS_KEY="postgres-backup"
```

**Used By:**
- CloudNativePG automated backups
- Stores WAL files and base backups to MinIO

### POSTGRES_BACKUP_S3_SECRET_KEY

**Description:** MinIO secret key for PostgreSQL backups

**Required:** Yes

**Security:** HIGH

**Generation:**
```bash
openssl rand -base64 32
```

**Used By:**
- CloudNativePG backup authentication

**Configuration:**

PostgreSQL is configured with these fixed settings optimized for Synapse:

| Setting | Value | Purpose |
|---------|-------|---------|
| Instances | 3 | 1 primary + 2 standby replicas |
| Synchronous Replication | ANY 1 | Zero data loss on failover |
| switchoverDelay | 300s (5 minutes) | Prevents false positive failovers |
| max_connections | 500 | Total connections allowed |
| shared_buffers | 8GB | In-memory cache (25% of RAM) |
| effective_cache_size | 24GB | Query planner hint (75% of RAM) |
| Storage Size | 500Gi | Per instance |
| WAL Storage | 50Gi | Separate fast storage for WAL |

**See Also:** [`HA-ROUTING-GUIDE.md`](HA-ROUTING-GUIDE.md) for failover details.

---

## Redis Configuration

Redis is deployed automatically with Helm charts. No user configuration required beyond what's in the main configuration.

**Architecture:**
- 2 separate Redis instances (Synapse and LiveKit)
- Each: 1 master + 3 replicas + 3 Sentinel instances
- Automatic failover via Sentinel

**Configuration:**

| Component | Replicas | Purpose |
|-----------|----------|---------|
| Redis Master | 1 | Active cache/pubsub |
| Redis Replicas | 3 | Standby, automatic failover |
| Redis Sentinel | 3 | Monitor health, trigger failover |

**No user configuration needed.** Defaults are optimized for the deployment.

---

## MinIO Configuration

### MINIO_ROOT_USER

**Description:** MinIO admin username

**Required:** Yes

**Default:** `admin`

**Example:**
```bash
MINIO_ROOT_USER="admin"
```

**Used By:**
- MinIO console login
- MinIO API admin operations

### MINIO_ROOT_PASSWORD

**Description:** MinIO admin password

**Required:** Yes

**Security:** HIGH

**Generation:**
```bash
openssl rand -base64 32
```

**Used By:**
- MinIO console login
- Administrative operations

### MINIO_SYNAPSE_ACCESS_KEY

**Description:** MinIO access key for Synapse media storage

**Required:** Yes

**Example:**
```bash
MINIO_SYNAPSE_ACCESS_KEY="synapse-media"
```

**Used By:**
- Synapse S3 storage provider
- Media upload/download

### MINIO_SYNAPSE_SECRET_KEY

**Description:** MinIO secret key for Synapse media storage

**Required:** Yes

**Security:** HIGH

**Generation:**
```bash
openssl rand -base64 32
```

**Configuration:**

MinIO is configured with:

| Setting | Value | Purpose |
|---------|-------|---------|
| Nodes | 4 | Distributed object storage |
| Erasure Coding | EC:4 | Can lose 1 node without data loss |
| Storage per Node | 1Ti | Configurable |
| Bucket | synapse-media | Stores uploaded files |

**Access MinIO Console:**
```bash
kubectl port-forward -n minio svc/synapse-media-console 9001:9001
# Open: http://localhost:9001
# Login with MINIO_ROOT_USER / MINIO_ROOT_PASSWORD
```

---

## Synapse Configuration

### SYNAPSE_REGISTRATION_SHARED_SECRET

**Description:** Secret for creating users via API/CLI

**Required:** Yes

**Security:** HIGH

**Generation:**
```bash
openssl rand -base64 32
```

**Example:**
```bash
SYNAPSE_REGISTRATION_SHARED_SECRET="Xy7aB4mN9pQ2rS5tV8wZ1cF3gH6j"
```

**Used By:**
- `register_new_matrix_user` command
- Admin user creation
- User management scripts

**Usage Example:**
```bash
kubectl exec -n matrix <synapse-pod> -- \
  register_new_matrix_user \
  -c /config/homeserver.yaml \
  -u newuser \
  -p password \
  -a \  # Admin flag
  http://localhost:8008
```

### SYNAPSE_MACAROON_SECRET

**Description:** Secret for generating access tokens

**Required:** Yes

**Security:** CRITICAL

**Generation:**
```bash
openssl rand -base64 32
```

**Used By:**
- Access token generation
- Session management
- API authentication

**Important:**
- If changed, all existing sessions invalidated
- Users must log in again

### SYNAPSE_FORM_SECRET

**Description:** Secret for form CSRF protection

**Required:** Yes

**Security:** HIGH

**Generation:**
```bash
openssl rand -base64 32
```

**Used By:**
- Web form submissions
- CSRF token generation

### SYNAPSE_SIGNING_KEY

**Description:** Ed25519 signing key for federation

**Required:** No (auto-generated if empty)

**Format:** `ed25519 <key-id> <base64-key>`

**Generation:**
```bash
docker run -it --rm matrixdotorg/synapse:latest generate
```

**Example:**
```bash
SYNAPSE_SIGNING_KEY="ed25519 a_AbCd H4sIABC123...base64..."
```

**Used By:**
- Federation event signing
- Server identity verification

**Important:**
- If empty, automatically generated on first deployment
- **Back up this key!** Cannot federate without it
- If lost, federation breaks (other servers won't trust you)

---

### Synapse Feature Flags

Advanced configuration in `manifests/05-synapse-main.yaml`.

#### Enable Registration

**Default:** `false` (disabled)

**Location:** `homeserver.yaml`

```yaml
enable_registration: false
```

**To enable:**
```yaml
enable_registration: true
enable_registration_captcha: true  # Recommended to prevent spam
```

#### Enable Federation

**Default:** `false` (disabled)

**Location:** `homeserver.yaml`

```yaml
federation_enabled: false
```

**To enable:**

1. Edit `manifests/05-synapse-main.yaml`:
```yaml
federation_enabled: true
```

2. Configure DNS SRV records:
```
_matrix._tcp.example.com. 300 IN SRV 10 0 8448 chat.example.com.
```

3. Test federation:
- Visit: https://federationtester.matrix.org/
- Enter your domain

**See Also:** [Deployment Guide](DEPLOYMENT-GUIDE.md) → Optional Features → Federation

---

## coturn Configuration

### COTURN_SHARED_SECRET

**Description:** Shared secret for TURN authentication

**Required:** Yes (for voice/video calls)

**Security:** HIGH

**Generation:**
```bash
openssl rand -base64 32
```

**Example:**
```bash
COTURN_SHARED_SECRET="P9mK2nL5qR8sT4vZ7bC1dF3gH6j0"
```

**Used By:**
- coturn authentication
- Synapse TURN credential generation

**How It Works:**
1. Client requests TURN credentials from Synapse
2. Synapse generates time-limited credentials using shared secret
3. Client connects to coturn with credentials
4. coturn validates credentials using same shared secret

**Important:**
- Must match between Synapse and coturn
- If changed, update both configurations

### COTURN_NODE1_IP / COTURN_NODE2_IP

**Description:** Public IP addresses of coturn nodes

**Required:** Yes (for voice/video calls)

**Example:**
```bash
COTURN_NODE1_IP="203.0.113.10"
COTURN_NODE2_IP="203.0.113.11"
```

**Used By:**
- Synapse turn_uris configuration
- Client TURN connection

**Requirements:**
- Must be publicly accessible IPs
- Ports must be open:
  - TCP/UDP 3478 (TURN)
  - UDP 49152-65535 (media relay)

**Finding Your Node IPs:**
```bash
# Get node where coturn is running
kubectl get pods -n coturn -o wide

# SSH to that node
ssh user@node-name

# Check public IP
curl -4 ifconfig.me
```

**Firewall Rules Needed:**
```bash
# On coturn nodes
iptables -A INPUT -p udp --dport 3478 -j ACCEPT
iptables -A INPUT -p tcp --dport 3478 -j ACCEPT
iptables -A INPUT -p udp --dport 49152:65535 -j ACCEPT
```

---

## LiveKit Configuration

### LIVEKIT_API_KEY

**Description:** LiveKit API key

**Required:** Yes (for group video calls)

**Format:** Alphanumeric string

**Generation:**
```bash
openssl rand -hex 16
```

**Example:**
```bash
LIVEKIT_API_KEY="a1b2c3d4e5f67890"
```

**Used By:**
- LiveKit server configuration
- LiveKit JWT token generation

### LIVEKIT_API_SECRET

**Description:** LiveKit API secret

**Required:** Yes (for group video calls)

**Security:** HIGH

**Generation:**
```bash
openssl rand -base64 32
```

**Used By:**
- LiveKit authentication
- JWT token signing

**How It Works:**
1. User starts group call in Element
2. Element requests LiveKit token from Synapse
3. Synapse generates JWT using API key/secret
4. Client connects to LiveKit with JWT
5. LiveKit validates JWT with API secret

---

## Monitoring Configuration

### GRAFANA_ADMIN_PASSWORD

**Description:** Grafana admin user password

**Required:** Yes

**Security:** MEDIUM

**Example:**
```bash
GRAFANA_ADMIN_PASSWORD="secure-grafana-password"
```

**Used By:**
- Grafana web UI login

**Default Username:** `admin`

**Access Grafana:**
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open: http://localhost:3000
# Login: admin / <GRAFANA_ADMIN_PASSWORD>
```

**Change Password After First Login:**
1. Log in to Grafana
2. Click profile icon → Change Password
3. Set new secure password

---

## TLS/Certificate Configuration

### CERT_ISSUER

**Description:** Certificate issuer type

**Required:** Yes

**Options:**
- `letsencrypt-prod` (Recommended for production)
- `letsencrypt-staging` (For testing, avoids rate limits)
- `selfsigned` (Self-signed certificates)
- `internal-ca` (Internal CA)

**Example:**
```bash
CERT_ISSUER="letsencrypt-prod"
```

**Production:**
```bash
CERT_ISSUER="letsencrypt-prod"
LETSENCRYPT_EMAIL="admin@example.com"
```

**Testing (avoid rate limits):**
```bash
CERT_ISSUER="letsencrypt-staging"
LETSENCRYPT_EMAIL="admin@example.com"
```

### LETSENCRYPT_EMAIL

**Description:** Email for Let's Encrypt notifications

**Required:** Yes (if using letsencrypt)

**Example:**
```bash
LETSENCRYPT_EMAIL="admin@example.com"
```

**Used For:**
- Certificate expiry notifications
- Rate limit notifications
- Account recovery

**Let's Encrypt Rate Limits:**
- 50 certificates per domain per week
- 5 duplicate certificates per week
- Use staging issuer for testing

**Staging vs Production:**

| Issuer | Trusted | Rate Limits | Use Case |
|--------|---------|-------------|----------|
| letsencrypt-prod | ✅ Yes | ✅ Yes | Production |
| letsencrypt-staging | ❌ No (browser warning) | ❌ No | Testing |

---

## Optional Features

### Antivirus Scanning

**Description:** Scan uploaded files for malware

**Trade-offs:**
- ✅ **Pros:** Malware protection, ransomware prevention
- ❌ **Cons:** Additional CPU usage, slight upload delay

**Complete Guide:**
See [`ANTIVIRUS-GUIDE.md`](ANTIVIRUS-GUIDE.md) for decision framework and complete implementation instructions for both enabling and disabling antivirus.

### Federation

**Description:** Connect to other Matrix servers

**Default:** Disabled

**To Enable:**
1. Edit `manifests/05-synapse-main.yaml`:
```yaml
federation_enabled: true
```

2. Configure DNS SRV records
3. Test with https://federationtester.matrix.org/

**See:** [Deployment Guide](DEPLOYMENT-GUIDE.md) → Optional Features

---

## Security Best Practices

### Password Generation

**Always use strong, random passwords:**
```bash
# Generate 32-character password
openssl rand -base64 32

# Generate hex string (for API keys)
openssl rand -hex 16
```

**Password Requirements:**
- Minimum 32 characters
- Random (not words or patterns)
- Unique per service
- Never reuse passwords

### Secret Management

**Do not commit secrets to git:**
```bash
# deployment.env is in .gitignore
git status
# Should NOT show deployment.env
```

**Rotate secrets regularly:**
- PostgreSQL password: Every 6 months
- MinIO passwords: Every 6 months
- Synapse secrets: Annually (invalidates sessions)
- Grafana password: After first login

**Back up secrets securely:**
```bash
# Encrypt with GPG
gpg -c config/deployment.env
# Creates: config/deployment.env.gpg

# Store encrypted file safely
# Delete plain text from insecure locations
```

---

## Configuration Validation

Before deploying, validate your configuration:

### Syntax Check

```bash
bash -n config/deployment.env
# No output = valid syntax
```

### Variable Check

```bash
source config/deployment.env

# Check critical variables set
echo "Domain: $MATRIX_DOMAIN"
echo "Storage: $STORAGE_CLASS_GENERAL"
echo "IP Range: $METALLB_IP_RANGE"

# Check no CHANGE_TO_* placeholders remain
grep "CHANGE_TO_" config/deployment.env
# Should return nothing
```

### Automated Validation

```bash
# Deployment script validates automatically
./scripts/deploy-all.sh --validate-only
```

---

## Troubleshooting Configuration

### Problem: Storage Class Not Found

**Error:**
```
storageclass.storage.k8s.io "local-path" not found
```

**Solution:**
```bash
# List available storage classes
kubectl get storageclass

# Update deployment.env with actual name
STORAGE_CLASS_GENERAL="<actual-storage-class-name>"
```

### Problem: MetalLB IP Pool Conflicts

**Error:**
```
cannot allocate IP: no available IPs in pool
```

**Solution:**
```bash
# Check IP range not used by other devices
for ip in {240..250}; do
  ping -c 1 -W 1 192.168.1.$ip
done

# Update deployment.env with available range
```

### Problem: DNS Not Resolving

**Error:**
```
nslookup chat.example.com
Server failed
```

**Solution:**
1. Verify DNS A record created:
   ```
   chat.example.com. → <LOAD_BALANCER_IP>
   ```

2. Wait for DNS propagation (up to 24 hours)

3. Test with:
   ```bash
   nslookup chat.example.com 8.8.8.8
   ```

---

## Related Documentation

- [Main README](../README.md) - Overview and quick start
- [Deployment Guide](DEPLOYMENT-GUIDE.md) - Step-by-step deployment
- [HA Routing Guide](HA-ROUTING-GUIDE.md) - How components connect

---

## Quick Reference

### Essential Commands

```bash
# Create configuration
cp config/deployment.env.example config/deployment.env

# Edit configuration
nano config/deployment.env

# Validate configuration
bash -n config/deployment.env
source config/deployment.env

# Generate secrets
openssl rand -base64 32  # Passwords
openssl rand -hex 16     # API keys

# Deploy
./scripts/deploy-all.sh
```

### Configuration Checklist

Before deploying, verify:

- [ ] `MATRIX_DOMAIN` set to your domain
- [ ] `STORAGE_CLASS_*` match your cluster
- [ ] `METALLB_IP_RANGE` available and correct
- [ ] `POSTGRES_PASSWORD` strong and random
- [ ] `MINIO_ROOT_PASSWORD` strong and random
- [ ] All `SYNAPSE_*_SECRET` generated
- [ ] `COTURN_SHARED_SECRET` generated
- [ ] `COTURN_NODE*_IP` set to public IPs
- [ ] `LIVEKIT_API_KEY` and `_SECRET` generated
- [ ] `GRAFANA_ADMIN_PASSWORD` set
- [ ] `LETSENCRYPT_EMAIL` set to your email
- [ ] No `CHANGE_TO_*` placeholders remain

---

**All set?** Proceed to [Deployment Guide](DEPLOYMENT-GUIDE.md).
