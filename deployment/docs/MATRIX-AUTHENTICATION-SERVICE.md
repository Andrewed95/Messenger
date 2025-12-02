# Matrix Authentication Service (MAS) Deployment Guide
## Enterprise SSO Integration for Matrix/Synapse

**📊 Scaling Notice:** This guide applies to all deployment scales. MAS is optional and typically deployed for enterprise customers requiring SSO integration.


---

## Table of Contents

1. [Overview & Purpose](#1-overview--purpose)
2. [When to Deploy MAS](#2-when-to-deploy-mas)
3. [Prerequisites](#3-prerequisites)
4. [Architecture & Integration](#4-architecture--integration)
5. [Deployment Steps](#5-deployment-steps)
6. [SSO Provider Configuration](#6-sso-provider-configuration)
7. [Migration from Native Synapse Authentication](#7-migration-from-native-synapse-authentication)
8. [Testing & Validation](#8-testing--validation)
9. [Operational Considerations](#9-operational-considerations)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Overview & Purpose

### 1.1 What is Matrix Authentication Service?

**Matrix Authentication Service (MAS)** is an OAuth 2.0 and OpenID Connect Provider server specifically designed for Matrix homeservers. It implements [MSC3861](https://github.com/matrix-org/matrix-spec-proposals/pull/3861), enabling Matrix to adopt OIDC-based authentication.

**Key Characteristics:**
- Written in Rust by Element (AGPL-3.0 or commercial license)
- Acts as the authentication and user management layer for Matrix
- **Not a general-purpose Identity Provider** - focused on Matrix needs
- Supports Synapse version **1.136.0 or later**
- Production-ready and actively maintained by Element

**Official Resources:**
- GitHub: https://github.com/element-hq/matrix-authentication-service
- Documentation: https://element-hq.github.io/matrix-authentication-service/
- Progress Tracker: https://areweoidcyet.com/

### 1.2 Key Benefits

**For Enterprise Customers:**
- ✅ Single Sign-On (SSO) with corporate identity providers
- ✅ Centralized user management
- ✅ Standards-based authentication (OAuth 2.0 / OIDC)
- ✅ Fine-grained authorization policies
- ✅ Enhanced security features (rate limiting, CAPTCHA, MFA via IdP)
- ✅ Unified session management

**For Matrix Deployment:**
- ✅ Offloads authentication complexity from Synapse
- ✅ Enables modern authentication flows
- ✅ Supports multiple identity providers
- ✅ Future-proof (Matrix 2.0 direction)

### 1.3 Limitations to Understand

**Important Constraints:**
- ⚠️ **OIDC Only** - Does NOT support SAML or LDAP directly
  - For SAML/LDAP: Use bridge service (Dex, Keycloak, Authentik)
- ⚠️ **PostgreSQL Required** - SQLite NOT supported
- ⚠️ **Separate Database** - Cannot share Synapse's database
- ⚠️ **Migration Requires Downtime** - For syn2mas migration
- ⚠️ **Synapse 1.136.0+** - Older versions unsupported
- ⚠️ **No Easy Rollback** - Migration is largely one-way

---

## 2. When to Deploy MAS

### 2.1 Deploy MAS If...

**✅ YES - Deploy MAS When:**

1. **Enterprise SSO Required**
   - Customer has Azure AD / Entra ID
   - Customer uses Google Workspace
   - Customer uses Okta, OneLogin, or other OIDC provider
   - SSO is a hard requirement in sales contract

2. **Centralized User Management**
   - Customer wants users managed in their IdP
   - Automatic provisioning/deprovisioning needed
   - Compliance requires centralized identity management

3. **Multiple Identity Sources**
   - Need to support multiple OIDC providers
   - Want social login (Google, GitHub, etc.) alongside corporate SSO

4. **Advanced Security Requirements**
   - Need MFA enforced by corporate IdP
   - Require fine-grained authorization policies
   - Want CAPTCHA for registration/login

5. **Future-Proofing**
   - Customer wants to align with Matrix 2.0
   - Planning for long-term Matrix adoption

### 2.2 DO NOT Deploy MAS If...

**❌ NO - Skip MAS When:**

1. **Simple Password Authentication Sufficient**
   - Small internal deployment (<100 users)
   - No SSO requirements
   - Native Synapse authentication works fine

2. **SAML-Only Environment with No Bridge**
   - Customer only has SAML (no OIDC)
   - Cannot deploy Dex/Keycloak bridge
   - Timeline doesn't allow for bridge setup

3. **Legacy Synapse Version**
   - Synapse < 1.136.0
   - Cannot upgrade Synapse

4. **SQLite-Only Constraint**
   - Cannot use PostgreSQL
   - MAS requires PostgreSQL

### 2.3 Decision Matrix

| Criterion | Deploy MAS | Native Synapse Auth |
|-----------|------------|---------------------|
| **SSO Required** | ✅ Yes | ❌ No |
| **OIDC Provider Available** | ✅ Yes | N/A |
| **SAML Only** | ⚠️ With Dex | ❌ No |
| **<100 Users** | Optional | ✅ Yes |
| **>100 Users** | ✅ Recommended | Optional |
| **Enterprise Customer** | ✅ Recommended | Maybe |
| **PostgreSQL** | ✅ Required | Optional |
| **Synapse 1.136.0+** | ✅ Required | N/A |
| **Budget for Complexity** | ✅ Yes | ✅ Yes (simpler) |

---

## 3. Prerequisites

### 3.1 Infrastructure Requirements

**Mandatory:**
- ✅ Synapse homeserver version **1.136.0 or later**
- ✅ **PostgreSQL 13+** (separate database for MAS)
- ✅ Kubernetes cluster (for this deployment)
- ✅ Ingress controller with TLS (cert-manager recommended)
- ✅ DNS records configured

**Optional but Recommended:**
- ✅ Prometheus for metrics
- ✅ Grafana for dashboards
- ✅ Persistent storage for MAS database (if not using external PostgreSQL)

### 3.2 Identity Provider Requirements

**For OIDC Integration:**
- ✅ OIDC-compliant identity provider
- ✅ Client ID and Client Secret from IdP
- ✅ Issuer URL (OIDC discovery endpoint)
- ✅ Redirect URI allowlisted in IdP:
  ```
  https://<mas-domain>/upstream/callback/<provider-id>
  ```

**Supported Providers:**
- Azure AD / Microsoft Entra ID ✅
- Google / Google Workspace ✅
- Okta ✅
- Auth0 ✅
- Keycloak ✅
- Authentik ✅
- GitLab ✅
- GitHub (OAuth 2.0 with userinfo) ✅
- Any OIDC-compliant provider ✅

**For SAML/LDAP:**
- ⚠️ Requires bridge service (Dex, Keycloak, Authentik)
- Bridge converts SAML/LDAP → OIDC

### 3.3 Resource Requirements

**📊 Scale-Specific Resource Allocation:**

**For 100 CCU:**
| Component | Replicas | CPU | RAM | Storage |
|-----------|----------|-----|-----|---------|
| MAS Server | 2 | 0.5 vCPU | 512Mi | - |
| MAS Worker | 1 | 0.25 vCPU | 256Mi | - |
| MAS PostgreSQL | 1 | 1 vCPU | 2Gi | 10Gi |
| **Total** | - | **2.25 vCPU** | **3.25Gi** | **10Gi** |

**For 20K CCU:**
| Component | Replicas | CPU | RAM | Storage |
|-----------|----------|-----|-----|---------|
| MAS Server | 4 | 1 vCPU | 1Gi | - |
| MAS Worker | 2 | 0.5 vCPU | 512Mi | - |
| MAS PostgreSQL | 3 | 4 vCPU | 8Gi | 50Gi |
| **Total** | - | **9 vCPU** | **13Gi** | **50Gi** |

---

## 4. Architecture & Integration

### 4.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Browser                                 │
└────────────┬────────────────────────────────────────────────────────┘
             │
             │ 1. Login/Registration
             │
             ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Ingress (HTTPS)                                   │
│  - matrix.example.com        → Synapse (via HAProxy if used)        │
│  - account.example.com       → MAS                                   │
└────────────┬─────────────────────────────────────────┬───────────────┘
             │                                         │
             │                                         │ 2. SSO Flow
             │                                         │
             ▼                                         ▼
┌─────────────────────────────┐         ┌──────────────────────────────┐
│   Matrix Authentication     │         │   Upstream OIDC Provider     │
│        Service (MAS)        │◄────────│  (Azure AD, Google, etc.)    │
│                             │         │                              │
│  - Login UI                 │         │  3. User authenticates       │
│  - OAuth 2.0/OIDC Provider  │         │  4. Returns ID token         │
│  - Session Management       │         │                              │
│  - User Management          │         │                              │
└────────────┬────────────────┘         └──────────────────────────────┘
             │
             │ 5. Issues access token
             │
             ▼
┌─────────────────────────────┐
│     Synapse Homeserver      │
│                             │
│  - Validates tokens via MAS │◄─── 6. Token introspection (RFC 7662)
│  - Matrix Client API        │
│  - Federation               │
└────────────┬────────────────┘
             │
             │ 7. Provisions users via admin API
             │ (shared secret)
             │
             ▼
┌─────────────────────────────┐         ┌──────────────────────────────┐
│    MAS PostgreSQL DB        │         │   Synapse PostgreSQL DB      │
│                             │         │                              │
│  - Users                    │         │  - Rooms                     │
│  - Sessions                 │         │  - Events                    │
│  - OAuth clients            │         │  - User state                │
│  - Access tokens            │         │  - Subject mappings          │
└─────────────────────────────┘         └──────────────────────────────┘
```

### 4.2 Integration Points

**Synapse → MAS:**
- **Token Validation:** OAuth 2.0 token introspection (RFC 7662)
- **Endpoint:** `http://mas.matrix.svc.cluster.local:8080/`
- **Protocol:** HTTP with shared secret

**MAS → Synapse:**
- **User Provisioning:** Synapse Admin API
- **Endpoint:** `http://synapse-main.matrix.svc.cluster.local:8008`
- **Authentication:** Shared secret

**Shared Secrets:**
- `SYNAPSE_SHARED_SECRET`: High-entropy secret (min 32 characters)
- Must be identical in both Synapse and MAS configurations

**Matrix Endpoints Proxied to MAS:**
These endpoints must be routed to MAS instead of Synapse:
- `/_matrix/client/*/login`
- `/_matrix/client/*/logout`
- `/_matrix/client/*/refresh`
- `/_matrix/client/unstable/org.matrix.msc2965/auth_issuer`

**Ingress Configuration Required:**
- Nginx/HAProxy rules to route these paths to MAS
- See Section 5.4 for configuration examples

### 4.3 MAS Components

**1. HTTP Server** (Stateless, can scale horizontally)
- Handles web requests (login UI, OAuth endpoints)
- Serves static assets
- Provides GraphQL API
- Health check endpoint

**2. Background Worker** (Stateless, can scale horizontally)
- Processes async tasks
- Sends emails (if configured)
- Cleanup jobs
- Token expiration

**3. PostgreSQL Database** (Stateful)
- Stores users, sessions, tokens
- Requires persistent storage
- Can use existing CloudNativePG cluster (separate database)

### 4.4 Component Diagram

```
┌──────────────────────── Kubernetes Cluster ────────────────────────┐
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │              Namespace: matrix-auth                         │   │
│  │                                                             │   │
│  │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐     │   │
│  │  │ MAS Server  │   │ MAS Server  │   │ MAS Worker  │     │   │
│  │  │   Pod 1     │   │   Pod 2     │   │   Pod 1     │     │   │
│  │  │  :8080      │   │  :8080      │   │             │     │   │
│  │  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘     │   │
│  │         │                  │                  │            │   │
│  │         └──────────────────┴──────────────────┘            │   │
│  │                           │                                │   │
│  │                           ▼                                │   │
│  │                   ┌───────────────┐                        │   │
│  │                   │ MAS Service   │                        │   │
│  │                   │  ClusterIP    │                        │   │
│  │                   │  Port: 8080   │                        │   │
│  │                   └───────┬───────┘                        │   │
│  │                           │                                │   │
│  └───────────────────────────┼────────────────────────────────┘   │
│                              │                                    │
│                              │ (Connects to)                      │
│                              ▼                                    │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │         Existing PostgreSQL Cluster (matrix namespace)     │   │
│  │                                                             │   │
│  │  Database: mas (separate from synapse database)            │   │
│  │  User: mas_user                                            │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. Deployment Steps

### 5.1 Prerequisites Check

**Before starting, verify:**

```bash
# WHERE: Your kubectl-configured workstation
# WHEN: Before deploying MAS
# WHY: Ensure all prerequisites are met
# HOW:

# 1. Check Synapse version (must be 1.136.0+)
kubectl exec -n matrix deployment/synapse-main -- python -c "import synapse; print(synapse.__version__)"
# Expected: 1.136.0 or higher

# 2. Verify PostgreSQL is available
kubectl get cluster -n matrix synapse-postgres
# Expected: STATUS should show "Cluster in healthy state"

# 3. Check cert-manager is installed (for TLS)
kubectl get pods -n cert-manager
# Expected: cert-manager pods running

# 4. Verify ingress controller
kubectl get ingressclass
# Expected: nginx or your ingress class listed
```

### 5.2 Step 1: Create MAS Namespace

```bash
# WHERE: Your kubectl-configured workstation
# WHEN: First step of deployment
# WHY: Isolate MAS components
# HOW:

kubectl create namespace matrix-auth

# Label for monitoring (if using Prometheus)
kubectl label namespace matrix-auth monitoring=enabled
```

### 5.3 Step 2: Generate Secrets

**Critical:** MAS requires several high-entropy secrets. These should be generated securely and NEVER changed after initial deployment.

**Generate Required Secrets:**

```bash
# WHERE: Your kubectl-configured workstation (with mas-cli available)
# WHEN: Before creating MAS configuration
# WHY: MAS requires encryption key, signing keys, and shared secret
# HOW:

# Option A: Use mas-cli to generate complete config (recommended)
# Install mas-cli (if not already installed)
# Download from: https://github.com/element-hq/matrix-authentication-service/releases

# Generate base configuration with secrets
./mas-cli config generate > mas-config-base.yaml

# Extract secrets from generated config
ENCRYPTION_SECRET=$(grep 'encryption:' mas-config-base.yaml | awk '{print $2}')
MATRIX_SHARED_SECRET=$(openssl rand -hex 32)

# Option B: Generate manually
ENCRYPTION_SECRET=$(openssl rand -hex 32)
MATRIX_SHARED_SECRET=$(openssl rand -hex 32)

# Generate RSA signing key
openssl genrsa -out /tmp/mas-rsa-key.pem 4096

echo "Generated secrets (SAVE THESE SECURELY!):"
echo "ENCRYPTION_SECRET: $ENCRYPTION_SECRET"
echo "MATRIX_SHARED_SECRET: $MATRIX_SHARED_SECRET"
echo "RSA key saved to: /tmp/mas-rsa-key.pem"
```

**Create Kubernetes Secrets:**

```bash
# WHERE: Your kubectl-configured workstation
# WHEN: After generating secrets
# WHY: Store secrets securely in Kubernetes
# HOW:

# Create encryption secret
kubectl create secret generic mas-secrets \
  --from-literal=encryption-secret=$ENCRYPTION_SECRET \
  --from-literal=matrix-shared-secret=$MATRIX_SHARED_SECRET \
  -n matrix-auth

# Create signing key secret
kubectl create secret generic mas-signing-key \
  --from-file=rsa-key=/tmp/mas-rsa-key.pem \
  -n matrix-auth

# Securely delete local key file
shred -u /tmp/mas-rsa-key.pem

# Verify secrets created
kubectl get secrets -n matrix-auth
# Expected: mas-secrets and mas-signing-key present
```

### 5.4 Step 3: Create MAS Database

**Using Existing CloudNativePG Cluster (Recommended):**

```yaml
# WHERE: Save as /tmp/mas-database.yaml
# WHEN: After MAS secrets created
# WHY: Create separate database for MAS on existing PostgreSQL cluster
# HOW:

---
# Create database using init script in existing CloudNativePG cluster
apiVersion: v1
kind: ConfigMap
metadata:
  name: mas-db-init
  namespace: matrix
data:
  init.sql: |
    -- Create MAS database and user
    CREATE USER mas_user WITH PASSWORD 'CHANGE_ME_STRONG_PASSWORD';
    CREATE DATABASE mas OWNER mas_user;

    -- Grant necessary permissions
    GRANT ALL PRIVILEGES ON DATABASE mas TO mas_user;

    -- Connect to mas database and grant schema permissions
    \c mas
    GRANT ALL ON SCHEMA public TO mas_user;
    ALTER DATABASE mas OWNER TO mas_user;

---
# Update PostgreSQL cluster to run init script
# Add this to your existing postgresql-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: synapse-postgres
  namespace: matrix
spec:
  # ... existing configuration ...

  bootstrap:
    initdb:
      postInitSQL:
        - CREATE EXTENSION IF NOT EXISTS pg_trgm;
        - CREATE EXTENSION IF NOT EXISTS btree_gin;
        - CREATE USER mas_user WITH PASSWORD 'CHANGE_ME_STRONG_PASSWORD';
        - CREATE DATABASE mas OWNER mas_user;
```

**Execute Database Setup:**

```bash
# WHERE: Your kubectl-configured workstation
# WHEN: After creating database init ConfigMap
# WHY: Create MAS database
# HOW:

# If using existing cluster, exec into primary pod
PGPRIMARY=$(kubectl get pod -n matrix -l postgresql=synapse-postgres,role=primary -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n matrix $PGPRIMARY -- psql -U postgres <<EOF
-- Create MAS user and database
CREATE USER mas_user WITH PASSWORD 'CHANGE_ME_STRONG_PASSWORD';
CREATE DATABASE mas OWNER mas_user;
GRANT ALL PRIVILEGES ON DATABASE mas TO mas_user;

-- Connect to mas database
\c mas
GRANT ALL ON SCHEMA public TO mas_user;
ALTER DATABASE mas OWNER TO mas_user;
EOF

# Verify database created
kubectl exec -n matrix $PGPRIMARY -- psql -U postgres -c "\l" | grep mas
# Expected: mas database listed with mas_user as owner
```

**Create Database Secret:**

```bash
# WHERE: Your kubectl-configured workstation
# WHEN: After database created
# WHY: Store database credentials for MAS
# HOW:

kubectl create secret generic mas-database \
  --from-literal=uri="postgresql://mas_user:CHANGE_ME_STRONG_PASSWORD@synapse-postgres-rw.matrix.svc.cluster.local:5432/mas?sslmode=require" \
  -n matrix-auth

# Verify secret
kubectl get secret mas-database -n matrix-auth -o yaml
```

### 5.5 Step 4: Create MAS Configuration

Create MAS configuration file. This will be mounted as a ConfigMap.

**Save as `deployment/config/mas-config.yaml`:**

```yaml
# Matrix Authentication Service Configuration
# Version: 1.0

# ============================================================================
# HTTP Server Configuration
# ============================================================================
http:
  public_base: https://account.example.com/  # CHANGE_ME

  listeners:
    - name: web
      resources:
        - name: discovery      # /.well-known/openid-configuration
        - name: human          # Login pages
        - name: oauth          # OAuth 2.0/OIDC endpoints
        - name: compat         # Matrix compatibility endpoints
        - name: graphql        # GraphQL API
        - name: assets         # Static assets
      binds:
        - address: "[::]:8080"

    # Separate listener for health checks (optional but recommended)
    - name: internal
      resources:
        - name: health         # /health endpoint
        - name: prometheus     # /metrics endpoint
      binds:
        - address: "[::]:8081"

  # Trusted proxy configuration (for X-Forwarded-For)
  trusted_proxies:
    - 10.0.0.0/8
    - 172.16.0.0/12
    - 192.168.0.0/16
    - fd00::/8

# ============================================================================
# Database Configuration
# ============================================================================
database:
  # URI loaded from secret (see secret_uri path in k8s config)
  # Format: postgresql://user:password@host:port/database?sslmode=require

  # Connection pool settings
  min_connections: 0
  max_connections: 10
  connect_timeout: 30s
  idle_timeout: 10m
  max_lifetime: 30m

# ============================================================================
# Matrix Homeserver Integration
# ============================================================================
matrix:
  homeserver: example.com  # CHANGE_ME (your Matrix server name)
  secret: "LOADED_FROM_SECRET"  # Shared secret for admin API access
  endpoint: "http://synapse-main.matrix.svc.cluster.local:8008"

# ============================================================================
# Secrets Configuration
# ============================================================================
secrets:
  # Encryption key for cookies and sensitive database fields
  # ⚠️ NEVER CHANGE THIS AFTER INITIAL DEPLOYMENT
  encryption: "LOADED_FROM_SECRET"

  # Signing keys for JWT/JWS
  keys:
    - key: "LOADED_FROM_SECRET"  # RSA or ECDSA key

# ============================================================================
# Password Configuration (for migrated users)
# ============================================================================
passwords:
  enabled: true  # Enable if migrating from Synapse

  schemes:
    # Support for Synapse's bcrypt passwords
    - version: 1
      algorithm: bcrypt
      unicode_normalization: true
      # If Synapse has password_config.pepper set, uncomment and set:
      #secret: "SYNAPSE_PASSWORD_PEPPER"

    # New passwords use Argon2id
    - version: 2
      algorithm: argon2id

# ============================================================================
# Upstream OIDC Provider Configuration
# ============================================================================
# See Section 6 for specific provider examples
upstream_oauth2:
  providers: []  # Populated based on customer requirements

# ============================================================================
# Email Configuration (Optional)
# ============================================================================
email:
  from: '"Matrix Auth" <noreply@example.com>'  # CHANGE_ME
  reply_to: support@example.com  # CHANGE_ME

  # Transport configuration
  transport: smtp
  hostname: smtp.example.com  # CHANGE_ME
  port: 587
  mode: starttls
  username: "SMTP_USERNAME"
  password: "LOADED_FROM_SECRET"

# ============================================================================
# Branding
# ============================================================================
branding:
  service_name: "Matrix Account"
  # Optional: Custom logo, colors, etc.

# ============================================================================
# CAPTCHA Configuration (Optional)
# ============================================================================
captcha:
  # Options: recaptcha_v2, cloudflare_turnstile, hcaptcha
  service: recaptcha_v2
  site_key: "SITE_KEY"
  secret_key: "LOADED_FROM_SECRET"

# ============================================================================
# Rate Limiting
# ============================================================================
rate_limiting:
  account_recovery:
    per_ip:
      burst: 3
      per_second: 0.0008
  login:
    per_ip:
      burst: 3
      per_second: 0.05
    per_account:
      burst: 10
      per_second: 0.1
  registration:
    burst: 3
    per_second: 0.0008

# ============================================================================
# Policy Engine (OPA)
# ============================================================================
policy:
  # Wasm policy file (included in MAS container)
  wasm_module: /usr/local/share/mas-cli/policy.wasm

  # Policy data
  data:
    # Admin users (can access Admin API)
    admin_users: []

    # Registration controls
    registration:
      enabled: true
      require_email: false

# ============================================================================
# Telemetry
# ============================================================================
telemetry:
  metrics:
    exporter: prometheus

  # Sentry error tracking (optional)
  # sentry:
  #   dsn: "https://..."
```

**Create ConfigMap:**

```bash
# WHERE: Your kubectl-configured workstation
# WHEN: After creating mas-config.yaml
# WHY: Mount configuration into MAS pods
# HOW:

kubectl create configmap mas-config \
  --from-file=config.yaml=deployment/config/mas-config.yaml \
  -n matrix-auth

# Verify ConfigMap
kubectl get configmap mas-config -n matrix-auth
```

---

### 5.6 Step 5: Deploy MAS Components

Create the Kubernetes manifests for MAS deployment.

**Save as `deployment/manifests/12-matrix-authentication-service.yaml`:**

```yaml
# See deployment/manifests/12-matrix-authentication-service.yaml
# Full manifest available in the repository
```

**Apply the manifest:**

```bash
# WHERE: Your kubectl-configured workstation
# WHEN: After all secrets and config are created
# WHY: Deploy MAS components
# HOW:

kubectl apply -f deployment/manifests/12-matrix-authentication-service.yaml

# Wait for MAS pods to be ready
kubectl wait --for=condition=ready pod -l app=mas -n matrix-auth --timeout=300s

# Verify deployment
kubectl get pods -n matrix-auth
# Expected: 2 mas-server pods and 1 mas-worker pod running

kubectl get svc -n matrix-auth
# Expected: mas service on port 8080

kubectl get ingress -n matrix-auth
# Expected: mas ingress with account.example.com

# Check MAS server logs
kubectl logs -n matrix-auth -l component=server --tail=50

# Verify health endpoint
kubectl exec -n matrix-auth deployment/mas-server -- \
  curl -s http://localhost:8081/health
# Expected: {"status":"healthy"} or similar JSON response
```

**Verify MAS is accessible:**

```bash
# WHERE: Your local machine or any machine with network access
# WHEN: After ingress is configured
# WHY: Verify MAS is reachable
# HOW:

curl -I https://account.example.com
# Expected: HTTP/2 200

curl https://account.example.com/.well-known/openid-configuration | jq
# Expected: JSON with OIDC discovery endpoints
```

### 5.7 Step 6: Update Synapse Configuration

**Critical:** Synapse must be configured to delegate authentication to MAS.

**Edit `deployment/config/homeserver.yaml` and add:**

```yaml
# ============================================================================
# Matrix Authentication Service Integration
# ============================================================================
# IMPORTANT: Only enable this when MAS is fully deployed and tested
experimental_features:
  # Enable MSC3861: Matrix authentication service delegation
  msc3861:
    enabled: true
    issuer: https://account.example.com/
    client_id: 0000000000000000000SYNAPSE  # ULID for Synapse client
    client_auth_method: client_secret_basic
    client_secret: SYNAPSE_OIDC_CLIENT_SECRET  # Generate secure secret
    
    # Admin token introspection endpoint
    admin_token: MATRIX_SHARED_SECRET  # Same secret as in MAS config
    
    # Account management URL
    account_management_url: https://account.example.com/account

# Disable local password database (MAS takes over)
password_config:
  enabled: false
  localdb_enabled: false
```

**Update ConfigMap:**

```bash
# WHERE: Your kubectl-configured workstation
# WHEN: After editing homeserver.yaml
# WHY: Apply MAS integration to Synapse
# HOW:

# Backup existing config
kubectl get configmap synapse-config -n matrix -o yaml > /tmp/synapse-config-backup.yaml

# Update ConfigMap
kubectl create configmap synapse-config \
  --from-file=homeserver.yaml=deployment/config/homeserver.yaml \
  --from-file=log.config=deployment/config/log.config \
  -n matrix \
  --dry-run=client -o yaml | kubectl apply -f -

# IMPORTANT: Restart Synapse pods to apply changes
kubectl rollout restart deployment/synapse-main -n matrix
kubectl rollout restart statefulset/synapse-sync-worker -n matrix
kubectl rollout restart statefulset/synapse-generic-worker -n matrix
kubectl rollout restart statefulset/synapse-event-persister -n matrix
kubectl rollout restart statefulset/synapse-federation-sender -n matrix

# Wait for rollout
kubectl rollout status deployment/synapse-main -n matrix

# Verify Synapse logs for MAS integration
kubectl logs -n matrix deployment/synapse-main --tail=100 | grep -i "msc3861\|authentication"
# Expected: Logs showing MAS endpoint configured
```

### 5.8 Step 7: Configure Ingress Routing for Matrix Endpoints

**Critical:** Certain Matrix endpoints must be proxied to MAS instead of Synapse.

**Update main Matrix ingress to route authentication endpoints to MAS:**

**Edit `deployment/manifests/09-ingress.yaml`:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: matrix
  namespace: matrix
  annotations:
    # Uses letsencrypt-prod for initial deployment (per CLAUDE.md 4.5)
    cert-manager.io/cluster-issuer: letsencrypt-prod

    # Route specific paths to MAS
    nginx.ingress.kubernetes.io/configuration-snippet: |
      # Matrix authentication endpoints → MAS
      location ~ ^/_matrix/client/(r0|v3|unstable)/login {
        proxy_pass https://mas.matrix-auth.svc.cluster.local:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      }
      
      location ~ ^/_matrix/client/(r0|v3|unstable)/logout {
        proxy_pass https://mas.matrix-auth.svc.cluster.local:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      }
      
      location ~ ^/_matrix/client/(r0|v3|unstable)/refresh {
        proxy_pass https://mas.matrix-auth.svc.cluster.local:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      }
      
      location = /_matrix/client/unstable/org.matrix.msc2965/auth_issuer {
        proxy_pass https://mas.matrix-auth.svc.cluster.local:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      }
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - matrix.example.com
    secretName: matrix-tls
  rules:
  - host: matrix.example.com
    http:
      paths:
      # Main Synapse endpoint
      - path: /
        pathType: Prefix
        backend:
          service:
            name: synapse-main  # or HAProxy service if using it
            port:
              name: http
```

**Apply updated ingress:**

```bash
kubectl apply -f deployment/manifests/09-ingress.yaml

# Verify ingress updated
kubectl get ingress matrix -n matrix -o yaml | grep -A 10 configuration-snippet
```

---

## 6. Keycloak Integration Configuration

### 6.1 About Keycloak

**Keycloak** is an open-source Identity and Access Management solution maintained by Red Hat. It provides:
- ✅ Full OIDC 1.0 compliance
- ✅ SAML 2.0 support (can bridge SAML → OIDC)
- ✅ User Federation (LDAP, Active Directory)
- ✅ Social login integration
- ✅ Multi-factor authentication
- ✅ Fine-grained authorization
- ✅ Backchannel logout support

**Why Keycloak for Matrix:**
- ✅ Can bridge SAML/LDAP to OIDC (if customer has legacy systems)
- ✅ Centralized identity management for multiple applications
- ✅ Mature, enterprise-grade, widely deployed
- ✅ Free and open-source (Apache 2.0)
- ✅ Active community and Red Hat support

**Official Resources:**
- Website: https://www.keycloak.org/
- Documentation: https://www.keycloak.org/documentation
- GitHub: https://github.com/keycloak/keycloak
- Docker: `quay.io/keycloak/keycloak:latest`

### 6.2 Keycloak Prerequisites

**Before configuring MAS with Keycloak, ensure:**
- ✅ Keycloak instance is deployed and accessible (version 22.0+ recommended, latest is 26.x)
- ✅ You have Keycloak admin credentials
- ✅ DNS resolves for both Keycloak and MAS
- ✅ TLS certificates are valid

**If customer doesn't have Keycloak yet, they have two options:**
1. **Deploy Keycloak yourself** (add to Kubernetes cluster)
2. **Use customer's existing Keycloak** (most common for enterprises)

### 6.3 Step-by-Step Keycloak Configuration

#### Step 1: Create Dedicated Realm

**⚠️ Best Practice:** Never use the `master` realm for application integrations. The master realm is for Keycloak administration only.

**In Keycloak Admin Console:**

```
WHERE: Keycloak Admin Console (https://keycloak.example.com/admin)
WHEN: Initial setup for Matrix integration
WHY: Isolate Matrix authentication from other applications
HOW:

1. Log in to Keycloak admin console
2. Click realm dropdown (top-left corner, currently shows "master")
3. Click "Create Realm" button
4. Configure:
   - Realm name: matrix
   - Enabled: ✅ ON
   - Display name: Matrix Authentication
   - HTML Display name: <strong>Matrix</strong> (optional)
5. Click "Create"

Result: New "matrix" realm created and selected
```

**Via Keycloak Admin CLI (alternative for automation):**

```bash
# WHERE: Machine with Keycloak CLI (kcadm.sh) installed
# WHEN: Automating Keycloak setup
# WHY: Scripted deployment
# HOW:

# Download Keycloak CLI if not installed
wget https://github.com/keycloak/keycloak/releases/download/26.0.0/keycloak-26.0.0.tar.gz
tar -xzf keycloak-26.0.0.tar.gz
cd keycloak-26.0.0/bin

# Authenticate as admin
./kcadm.sh config credentials \
  --server https://keycloak.example.com \
  --realm master \
  --user admin \
  --password ADMIN_PASSWORD

# Create matrix realm
./kcadm.sh create realms \
  -s realm=matrix \
  -s enabled=true \
  -s displayName="Matrix Authentication" \
  -s loginTheme=keycloak \
  -s accountTheme=keycloak

# Verify realm created
./kcadm.sh get realms/matrix
# Expected: JSON output with realm details
```

#### Step 2: Create OIDC Client for MAS

**In Keycloak Admin Console:**

```
WHERE: Keycloak Admin Console → matrix realm
WHEN: After realm created
WHY: Register MAS as OIDC client
HOW:

1. Ensure "matrix" realm is selected (realm dropdown, top-left)
2. Navigate to "Clients" (left sidebar)
3. Click "Create client" button

=== General Settings ===
4. Client type: OpenID Connect
5. Client ID: matrix-authentication-service
6. Name: Matrix Authentication Service
7. Description: OIDC client for Matrix homeserver authentication
8. Click "Next"

=== Capability config ===
9. Client authentication: ✅ ON
   (This makes it a confidential client, required for obtaining client secret)

10. Authorization: ❌ OFF
   (Not needed for OIDC authentication flow)

11. Authentication flow (select these):
   - ✅ Standard flow (Authorization Code Flow) - REQUIRED
   - ❌ Direct access grants - NOT NEEDED
   - ❌ Implicit flow - DEPRECATED, DO NOT USE
   - ❌ Service accounts roles - NOT NEEDED
   - ✅ OAuth 2.0 Device Authorization Grant - OPTIONAL

12. Click "Next"

=== Login settings ===
13. Root URL: https://account.example.com
14. Home URL: https://account.example.com
15. Valid redirect URIs:
    https://account.example.com/upstream/callback/*
    
    ⚠️ IMPORTANT: The /* wildcard is critical!
    MAS appends provider ID to callback URL.

16. Valid post logout redirect URIs:
    https://account.example.com/*

17. Web origins: https://account.example.com
    (Enables CORS for the MAS domain)

18. Click "Save"

Result: Client created successfully
```

**Important Notes:**

**Redirect URI Pattern:**
- MAS uses dynamic callback URLs: `https://account.example.com/upstream/callback/<PROVIDER_ID>`
- `<PROVIDER_ID>` is the ULID from MAS config (e.g., `01JSHPZHAXC50QBKH67MH33TNF`)
- The wildcard `/*` allows any provider ID

**Client Authentication:**
- Must be ON for confidential clients
- Allows obtaining client secret
- Required for Authorization Code Flow

#### Step 3: Obtain Client Secret

**In Keycloak Admin Console:**

```
WHERE: Keycloak Admin Console → Clients → matrix-authentication-service
WHEN: Immediately after client creation
WHY: Need secret for MAS configuration
HOW:

1. Navigate to Clients → "matrix-authentication-service"
2. Click "Credentials" tab
3. Client Authenticator: Client Id and Secret (should be selected)
4. Copy the "Client secret" value
   Example: 9f0a8b7c-6d5e-4f3a-2b1c-0d9e8f7a6b5c
5. ⚠️ SAVE THIS SECURELY - You'll need it for MAS config

Optional: Regenerate secret
6. Click "Regenerate" button to create new secret
7. Confirm regeneration
8. Copy new secret

Result: Client secret obtained
```

**Store secret securely:**

```bash
# WHERE: Your secure workstation
# WHEN: After obtaining secret
# WHY: Needed for MAS configuration
# HOW:

# DO NOT store in plain text files or version control!
# Use password manager or secrets management system

# Example: Store in environment variable temporarily
export KEYCLOAK_CLIENT_SECRET="9f0a8b7c-6d5e-4f3a-2b1c-0d9e8f7a6b5c"

# Or create Kubernetes secret directly
kubectl create secret generic keycloak-client-secret \
  --from-literal=secret="9f0a8b7c-6d5e-4f3a-2b1c-0d9e8f7a6b5c" \
  -n matrix-auth
```

#### Step 4: Configure Client Scopes

**Purpose:** Ensure MAS receives necessary user information from Keycloak.

**In Keycloak Admin Console:**

```
WHERE: Keycloak Admin Console → Clients → matrix-authentication-service
WHEN: After client created
WHY: Control what user information Keycloak sends to MAS
HOW:

1. Navigate to Clients → "matrix-authentication-service"
2. Click "Client scopes" tab
3. Verify "Assigned default client scopes" section contains:
   - openid ✅ (REQUIRED - enables OIDC)
   - profile ✅ (REQUIRED - provides name, username)
   - email ✅ (REQUIRED - provides email address)
   - roles ❌ (optional, usually not needed)
   - web-origins ✅ (for CORS)

If any required scope is missing:
4. Click "Add client scope" button
5. Select scope (e.g., "email")
6. Choose "Default" (not Optional)
7. Click "Add"

Result: All required scopes are assigned as default
```

**What each scope provides:**

- **`openid`**: Enables OIDC, provides `sub` (subject) claim
- **`profile`**: Provides `name`, `given_name`, `family_name`, `preferred_username`
- **`email`**: Provides `email`, `email_verified`
- **`roles`**: Provides user roles (optional, for advanced authorization)

#### Step 5: Verify and Configure Protocol Mappers

**Purpose:** Ensure user attributes are correctly mapped to OIDC claims.

**In Keycloak Admin Console:**

```
WHERE: Keycloak Admin Console → Client scopes → profile
WHEN: After client created
WHY: Verify username and name claims are mapped correctly
HOW:

1. Navigate to Client scopes (main left sidebar, not client's tab)
2. Click "profile" scope
3. Click "Mappers" tab
4. Verify these mappers exist:
   - username → preferred_username ✅
   - full name → name ✅
   - given name → given_name ✅
   - family name → family_name ✅

If missing, create them (example for username):
5. Click "Add mapper" → "By configuration"
6. Select "User Property"
7. Configure:
   - Name: username
   - Property: username
   - Token Claim Name: preferred_username
   - Claim JSON Type: String
   - Add to ID token: ✅ ON
   - Add to access token: ✅ ON
   - Add to userinfo: ✅ ON
8. Click "Save"

Result: All standard OIDC claims are mapped
```

**Critical Mappers for Matrix:**

**1. Username → preferred_username (REQUIRED):**
- Maps Keycloak username to OIDC `preferred_username` claim
- MAS uses this for Matrix localpart (username)
- **Must be unique and stable**

**2. Full name → name (RECOMMENDED):**
- Maps user's full name to OIDC `name` claim
- MAS uses this for display name
- Format: "FirstName LastName"

**3. Email → email (REQUIRED):**
- Maps email address to OIDC `email` claim
- Check email scope mappers:

```
Navigate to Client scopes → email → Mappers

Verify mappers:
- email → email ✅
- email verified → email_verified ✅

These are usually present by default
```

#### Step 6: Configure Backchannel Logout (Optional but Recommended)

**Purpose:** When users log out of Keycloak, their MAS/Matrix sessions are also terminated.

**⚠️ Note:** You'll need the MAS provider ID first. Complete Step 8, then return here.

**In Keycloak Admin Console:**

```
WHERE: Keycloak Admin Console → Clients → matrix-authentication-service
WHEN: After MAS provider configured (Step 8)
WHY: Enable single logout across all applications
HOW:

1. Navigate to Clients → "matrix-authentication-service"
2. Click "Advanced" tab
3. Scroll to "Backchannel logout" section
4. Configure:
   - Backchannel logout URL: 
     https://account.example.com/upstream/callback/01JSHPZHAXC50QBKH67MH33TNF/logout
     (Replace 01JSHPZHAXC50QBKH67MH33TNF with your provider ID)
   
   - Backchannel logout session required: ✅ ON
   - Backchannel logout revoke offline sessions: ✅ ON (if using refresh tokens)

5. Click "Save"

Result: Users logging out of Keycloak will be logged out of Matrix
```

**How Backchannel Logout Works:**
1. User clicks "Logout" in Keycloak
2. Keycloak sends HTTP POST to MAS logout URL
3. MAS invalidates all sessions for that user
4. User is logged out of Matrix clients

#### Step 7: Test Keycloak OIDC Discovery

**Verify Keycloak is configured correctly before connecting MAS:**

```bash
# WHERE: Your local machine or any machine with network access
# WHEN: After completing Keycloak client setup
# WHY: Verify OIDC endpoints are accessible
# HOW:

# Test OIDC discovery endpoint
curl -s https://keycloak.example.com/realms/matrix/.well-known/openid-configuration | jq

# Expected JSON output with these keys:
# - issuer: "https://keycloak.example.com/realms/matrix"
# - authorization_endpoint: "https://keycloak.example.com/realms/matrix/protocol/openid-connect/auth"
# - token_endpoint: "https://keycloak.example.com/realms/matrix/protocol/openid-connect/token"
# - userinfo_endpoint: "https://keycloak.example.com/realms/matrix/protocol/openid-connect/userinfo"
# - jwks_uri: "https://keycloak.example.com/realms/matrix/protocol/openid-connect/certs"
# - end_session_endpoint: "https://keycloak.example.com/realms/matrix/protocol/openid-connect/logout"

# Verify issuer exactly matches (MAS will validate this)
curl -s https://keycloak.example.com/realms/matrix/.well-known/openid-configuration | jq -r .issuer
# Expected: https://keycloak.example.com/realms/matrix

# Test JWKS endpoint (public keys for token validation)
curl -s https://keycloak.example.com/realms/matrix/protocol/openid-connect/certs | jq
# Expected: JSON with "keys" array containing RSA public keys
```

**If discovery fails:**
- Check Keycloak is accessible
- Verify realm name is correct ("matrix")
- Check TLS certificate is valid
- Verify firewall rules allow HTTPS traffic


---

#### Step 8: Configure MAS Upstream Provider

Now configure MAS to use Keycloak as its upstream OIDC provider. This is the **critical integration point** that connects MAS to your organization's Keycloak instance.

##### 8.1: Generate Provider ID (ULID)

Each upstream provider in MAS requires a unique ULID (Universally Unique Lexicographically Sortable Identifier).

**Generate ULID:**

```bash
# Method 1: Using Python
python3 << 'PYTHON'
import time
import random
import sys

def ulid():
    # Timestamp component (48 bits / 10 characters)
    timestamp = int(time.time() * 1000)
    time_chars = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    
    time_part = ""
    for _ in range(10):
        time_part = time_chars[timestamp % 32] + time_part
        timestamp //= 32
    
    # Randomness component (80 bits / 16 characters)
    random_part = "".join(random.choice(time_chars) for _ in range(16))
    
    return time_part + random_part

print(ulid())
PYTHON

# Example output: 01JSHPZHAXC50QBKH67MH33TNF
```

**Save this ULID** - you'll need it in multiple places:
- MAS configuration (upstream provider ID)
- Keycloak backchannel logout URL
- MAS admin commands

**For this guide, we'll use:** `01JSHPZHAXC50QBKH67MH33TNF`

---

##### 8.2: Create Complete MAS Configuration

Update your MAS configuration to include the Keycloak provider. This builds on the base configuration from Step 4.

**Create or update:** `deployment/config/mas-config.yaml`

```yaml
# =============================================================================
# Matrix Authentication Service Configuration
# Keycloak OIDC Integration
# =============================================================================

# Database connection
database:
  # PostgreSQL connection URI
  # Loaded from /secrets/database/uri mounted secret
  uri: "postgresql://mas:PASSWORD@postgres-cluster-rw.database.svc.cluster.local:5432/mas?sslmode=require"
  
  # Connection pool settings
  min_connections: 0
  max_connections: 10
  
  # Connection timeout
  connect_timeout: 30
  
  # Idle connection timeout
  idle_timeout: 600
  
  # Maximum connection lifetime
  max_lifetime: 1800

# HTTP server configuration
http:
  # Public base URL (must match ingress)
  public_base: https://account.example.com/
  
  # Internal issuer (usually same as public_base)
  issuer: https://account.example.com/
  
  # Listeners
  listeners:
    - name: web
      # Resources to serve
      resources:
        - name: discovery        # /.well-known/openid-configuration
        - name: human            # Login UI, account management
        - name: oauth            # OAuth 2.0 endpoints
        - name: compat           # Synapse compatibility endpoints
        - name: graphql          # GraphQL API
        - name: assets           # Static assets
      
      # Bind addresses
      binds:
        - address: "[::]:8080"
          # Proxy protocol settings (if behind HAProxy)
          # proxy_protocol: true
    
    - name: internal
      # Health check endpoint
      resources:
        - name: health
      binds:
        - address: "[::]:8081"

# Matrix homeserver configuration
matrix:
  # Homeserver domain (server_name in Synapse)
  homeserver: example.com
  
  # Shared secret for Synapse ↔ MAS communication
  # Loaded from /secrets/mas/shared-secret
  secret: "REPLACE_WITH_ACTUAL_SECRET"
  
  # Synapse internal endpoint
  endpoint: "http://synapse-main.matrix.svc.cluster.local:8008"
  
  # Endpoint for Synapse to reach MAS
  # Used for token introspection (RFC 7662)
  # If not specified, uses http.public_base
  # endpoint_for_homeserver: "http://mas.matrix-auth.svc.cluster.local:8080"

# Secrets configuration
secrets:
  # Encryption key for database (32+ random bytes, base64)
  # Loaded from /secrets/mas/encryption-key
  encryption: "REPLACE_WITH_BASE64_ENCRYPTION_KEY"
  
  # Signing keys for JWTs and session cookies
  keys:
    # Primary signing key (32+ random bytes, base64)
    # Loaded from /secrets/keys/signing-key
    - key: "REPLACE_WITH_BASE64_SIGNING_KEY"

# Email configuration (optional, for password reset, etc.)
email:
  # Email sending method: none, smtp, sendmail, mailgun
  transport: smtp
  
  # From address
  from: '"Matrix Auth" <noreply@example.com>'
  
  # Reply-to address
  reply_to: '"Matrix Support" <support@example.com>'
  
  # SMTP settings
  smtp:
    # SMTP server hostname
    hostname: smtp.example.com
    
    # SMTP port (25, 587, 465)
    port: 587
    
    # STARTTLS or TLS
    mode: starttls
    
    # Authentication (optional)
    # username: "smtp-user"
    # password: "smtp-password"

# Branding configuration
branding:
  # Service name shown in UI
  service_name: "Matrix Authentication"
  
  # Policy URLs shown during registration
  policy_uri: "https://example.com/privacy"
  tos_uri: "https://example.com/terms"
  
  # Logo URL
  # logo_uri: "https://example.com/logo.png"

# Password authentication settings
passwords:
  # Enable password-based login (disable when SSO-only)
  enabled: true
  
  # Password requirements
  min_length: 12
  require_lowercase: true
  require_uppercase: true
  require_number: true
  require_symbol: false

# Account registration settings
account:
  # Allow new account registration
  # Set to false if only SSO users should exist
  registration_enabled: true
  
  # Require email verification
  email_verification_enabled: true

# Session configuration
session:
  # Session cookie name
  cookie_name: "matrix_auth_session"
  
  # Session lifetime (seconds)
  #  = 2592000
  lifetime: 2592000
  
  # Idle timeout (seconds)
  #  = 604800
  idle_timeout: 604800

# =============================================================================
# UPSTREAM OAUTH2 PROVIDERS (KEYCLOAK)
# =============================================================================
upstream_oauth2:
  providers:
    # Keycloak OIDC Provider
    - id: "01JSHPZHAXC50QBKH67MH33TNF"  # ULID generated in step 8.1
      
      # Keycloak issuer URL (must match OIDC discovery)
      # Format: https://{keycloak-domain}/realms/{realm-name}
      issuer: "https://keycloak.example.com/realms/matrix"
      
      # Discovery mode (oidc or insecure for testing)
      discovery_mode: oidc
      
      # Human-readable name (shown in login UI)
      human_name: "Company SSO"
      
      # Brand identifier (affects button styling)
      # Options: apple, google, facebook, github, gitlab, keycloak
      brand_name: "keycloak"
      
      # OIDC client credentials (from Keycloak step 2)
      client_id: "matrix-authentication-service"
      client_secret: "9f0a8b7c-6d5e-4f3a-2b1c-0d9e8f7a6b5c"  # REPLACE WITH ACTUAL SECRET
      
      # Token endpoint authentication method
      # Options: client_secret_basic, client_secret_post, client_secret_jwt, private_key_jwt
      token_endpoint_auth_method: client_secret_post
      
      # OIDC scopes to request
      scope: "openid profile email"
      
      # Authorization endpoint parameters (optional)
      # authorization_endpoint_override: "https://keycloak.example.com/realms/matrix/protocol/openid-connect/auth"
      
      # Token endpoint parameters (optional)
      # token_endpoint_override: "https://keycloak.example.com/realms/matrix/protocol/openid-connect/token"
      
      # PKCE method (S256 recommended, plain fallback, none to disable)
      pkce_method: s256
      
      # =======================================================================
      # CLAIMS IMPORT CONFIGURATION
      # =======================================================================
      # Maps Keycloak user attributes to Matrix user profile
      
      claims_imports:
        # Matrix localpart (username)
        # REQUIRED - Matrix user ID will be @localpart:example.com
        localpart:
          # Action: ignore, suggest, force, require
          # - ignore: Don't import this claim
          # - suggest: Import if user doesn't have localpart yet
          # - force: Always overwrite with this claim
          # - require: Import required, login fails if claim missing
          action: require
          
          # Template for extracting localpart from claims
          # Available variables: user.* (all OIDC claims)
          # Keycloak provides 'preferred_username' claim
          template: "{{ user.preferred_username }}"
          
          # Conflict resolution when localpart already exists
          # - fail: Login fails if localpart taken
          # - add: Link SSO account to existing Matrix account (requires same email)
          on_conflict: fail
        
        # Display name
        displayname:
          action: suggest
          
          # Keycloak provides 'name' claim (full name)
          # Can also use: given_name, family_name
          template: "{{ user.name }}"
        
        # Email address
        email:
          action: suggest
          
          # Keycloak provides 'email' claim
          template: "{{ user.email }}"
          
          # Email verification handling
          # - always: Always mark email as verified
          # - never: Never mark email as verified
          # - import: Trust Keycloak's email_verified claim
          set_email_verification: import
      
      # =======================================================================
      # BACKCHANNEL LOGOUT CONFIGURATION
      # =======================================================================
      # Allows Keycloak to notify MAS when user logs out
      
      backchannel_logout:
        # Enable backchannel logout
        enabled: true
        
        # Backchannel logout URI
        # Must match the URL configured in Keycloak (step 6)
        # Format: {MAS public_base}/upstream/callback/{provider_id}/backchannel
        uri: "https://account.example.com/upstream/callback/01JSHPZHAXC50QBKH67MH33TNF/backchannel"
        
        # Require logout token signature validation
        require_signed_request: true

# =============================================================================
# EXPERIMENTAL FEATURES
# =============================================================================
experimental:
  # Access token TTL (default: 300 seconds)
  access_token_ttl: 300
  
  # Compatibility token TTL (default: 300 seconds)
  compat_token_ttl: 300
```

---

##### 8.3: Configuration Parameter Explanations

**Critical Parameters:**

| Parameter | Purpose | Notes |
|-----------|---------|-------|
| `providers[].id` | Unique identifier for provider | Must be valid ULID, permanent (don't change) |
| `providers[].issuer` | Keycloak issuer URL | Must exactly match `.well-known/openid-configuration` |
| `providers[].client_id` | OIDC client ID | From Keycloak step 2 |
| `providers[].client_secret` | OIDC client secret | From Keycloak step 3 |
| `claims_imports.localpart.template` | Username extraction | Maps to Matrix user ID |
| `backchannel_logout.uri` | Logout callback URL | Must include provider ID |

**Claims Import Actions:**

| Action | Behavior | Use Case |
|--------|----------|----------|
| `ignore` | Don't import this claim | When claim not needed |
| `suggest` | Import if user doesn't have value yet | Display name, email (user can change later) |
| `force` | Always overwrite with claim value | Keep attributes in sync with Keycloak |
| `require` | Import required, fail if missing | Localpart (username) must exist |

**Template Variables:**

Claims templates use Jinja2-like syntax with `user.*` variables from OIDC ID token:

```yaml
# Standard OIDC claims from Keycloak
template: "{{ user.preferred_username }}"  # Username
template: "{{ user.name }}"                # Full name
template: "{{ user.given_name }}"          # First name
template: "{{ user.family_name }}"         # Last name
template: "{{ user.email }}"               # Email address
template: "{{ user.email_verified }}"      # Email verification status

# Custom Keycloak attributes (if configured)
template: "{{ user.employee_id }}"         # Custom attribute
template: "{{ user.department }}"          # Custom attribute

# Composite templates
template: "{{ user.given_name }} {{ user.family_name }}"
template: "{{ user.preferred_username | lower }}"
```

---

##### 8.4: Store Secrets in Kubernetes

**Create Kubernetes Secrets:**

```bash
# Navigate to deployment directory
cd deployment

# Create MAS secrets namespace (if not exists)
kubectl create namespace matrix-auth

# 1. Create database secret
kubectl create secret generic mas-database \
  --from-literal=uri="postgresql://mas:POSTGRES_PASSWORD@postgres-cluster-rw.database.svc.cluster.local:5432/mas?sslmode=require" \
  -n matrix-auth

# 2. Generate encryption key (32 bytes, base64-encoded)
ENCRYPTION_KEY=$(openssl rand -base64 32)
echo "Generated encryption key: $ENCRYPTION_KEY"

# 3. Generate signing key (32 bytes, base64-encoded)
SIGNING_KEY=$(openssl rand -base64 32)
echo "Generated signing key: $SIGNING_KEY"

# 4. Generate shared secret with Synapse (64 bytes, base64-encoded)
SHARED_SECRET=$(openssl rand -base64 64)
echo "Generated shared secret: $SHARED_SECRET"

# 5. Get Keycloak client secret (from step 3)
KEYCLOAK_CLIENT_SECRET="9f0a8b7c-6d5e-4f3a-2b1c-0d9e8f7a6b5c"  # REPLACE

# 6. Create MAS secrets
kubectl create secret generic mas-secrets \
  --from-literal=encryption-key="$ENCRYPTION_KEY" \
  --from-literal=shared-secret="$SHARED_SECRET" \
  --from-literal=keycloak-client-secret="$KEYCLOAK_CLIENT_SECRET" \
  -n matrix-auth

# 7. Create signing key secret
kubectl create secret generic mas-signing-key \
  --from-literal=signing-key="$SIGNING_KEY" \
  -n matrix-auth

# Verify secrets created
kubectl get secrets -n matrix-auth
```

**Update mas-config.yaml to reference secrets:**

In production, mount secrets as files and reference them:

```yaml
database:
  uri: "file:///secrets/database/uri"

matrix:
  secret: "file:///secrets/mas/shared-secret"

secrets:
  encryption: "file:///secrets/mas/encryption-key"
  keys:
    - key: "file:///secrets/keys/signing-key"

upstream_oauth2:
  providers:
    - id: "01JSHPZHAXC50QBKH67MH33TNF"
      # ... other config ...
      client_secret: "file:///secrets/mas/keycloak-client-secret"
```

---

##### 8.5: Create MAS ConfigMap

```bash
# Create ConfigMap from configuration file
kubectl create configmap mas-config \
  --from-file=config.yaml=config/mas-config.yaml \
  -n matrix-auth

# Verify ConfigMap
kubectl describe configmap mas-config -n matrix-auth
```

---

##### 8.6: Update Keycloak Backchannel Logout URL

Now that you have the provider ID (`01JSHPZHAXC50QBKH67MH33TNF`), update Keycloak with the exact backchannel logout URL.

**Return to Keycloak Admin Console:**

1. Navigate to: **Realm Settings → Clients → matrix-authentication-service**
2. Go to **Advanced** tab
3. Find **Backchannel Logout URL** field
4. Enter exact URL with provider ID:
   ```
   https://account.example.com/upstream/callback/01JSHPZHAXC50QBKH67MH33TNF/backchannel
   ```
5. Ensure **Backchannel Logout Session Required** is **ON**
6. Click **Save**

**Verify configuration:**

```bash
# Get client configuration via Admin API
./kcadm.sh get clients/{client-uuid} -r matrix | jq '.attributes.backchannelLogoutUrl'

# Expected output:
# "https://account.example.com/upstream/callback/01JSHPZHAXC50QBKH67MH33TNF/backchannel"
```

---

##### 8.7: Deploy MAS Components

```bash
# Apply MAS manifest (created in step 5)
kubectl apply -f manifests/12-matrix-authentication-service.yaml

# Watch pods start
kubectl get pods -n matrix-auth -w

# Expected output:
# NAME                          READY   STATUS    RESTARTS   AGE
# mas-server-5d6f8b9c7d-abcde   1/1     Running   0          30s
# mas-server-5d6f8b9c7d-fghij   1/1     Running   0          30s
# mas-worker-7c8d9e0f1a-klmno   1/1     Running   0          30s

# Check logs
kubectl logs -n matrix-auth -l app=mas,component=server --tail=50

# Look for successful startup messages:
# - "Starting HTTP server on [::]:8080"
# - "Connected to database"
# - "Loaded 1 upstream OAuth provider(s)"
```

---

##### 8.8: Verify MAS OIDC Discovery

MAS now acts as an OIDC provider itself. Verify its discovery endpoint:

```bash
# Test MAS OIDC discovery
curl -s https://account.example.com/.well-known/openid-configuration | jq

# Expected output includes:
# {
#   "issuer": "https://account.example.com/",
#   "authorization_endpoint": "https://account.example.com/oauth2/authorize",
#   "token_endpoint": "https://account.example.com/oauth2/token",
#   "userinfo_endpoint": "https://account.example.com/oauth2/userinfo",
#   "jwks_uri": "https://account.example.com/oauth2/keys.json",
#   ...
# }
```

---

#### Advanced Keycloak Configuration (Optional)

##### Custom User Attributes

If you need to import custom attributes from Keycloak (e.g., employee ID, department):

**In Keycloak:**

1. Navigate to: **Realm Settings → Users → User attributes**
2. Add custom attribute (e.g., `employee_id`)
3. Navigate to: **Clients → matrix-authentication-service → Client Scopes → matrix-authentication-service-dedicated**
4. Click **Add mapper → By configuration → User Attribute**
5. Configure mapper:
   - **Name:** Employee ID
   - **User Attribute:** employee_id
   - **Token Claim Name:** employee_id
   - **Claim JSON Type:** String
   - **Add to ID token:** ON
   - **Add to access token:** OFF
   - **Add to userinfo:** ON
6. Click **Save**

**In MAS configuration:**

```yaml
claims_imports:
  # Additional custom claim
  employee_id:
    action: suggest
    template: "{{ user.employee_id }}"
```

---

##### Group Membership Mapping

Map Keycloak groups to Matrix user attributes:

**In Keycloak:**

1. Navigate to: **Clients → matrix-authentication-service → Client Scopes → matrix-authentication-service-dedicated**
2. Click **Add mapper → By configuration → Group Membership**
3. Configure mapper:
   - **Name:** Group Membership
   - **Token Claim Name:** groups
   - **Full group path:** OFF (use simple group names)
   - **Add to ID token:** ON
   - **Add to userinfo:** ON
4. Click **Save**

**In MAS configuration:**

```yaml
claims_imports:
  # Group membership (for potential future use)
  groups:
    action: suggest
    template: "{{ user.groups | join(',') }}"
```

*Note: MAS doesn't natively support group-based authorization, but claims are stored for potential custom integrations.*

---

##### Multi-Factor Authentication (MFA) Enforcement

Force MFA for Matrix users via Keycloak:

**In Keycloak:**

1. Navigate to: **Authentication → Required Actions**
2. Enable **Configure OTP** as default action
3. Navigate to: **Authentication → Flows**
4. Select **Browser** flow
5. Add **OTP Form** execution
6. Set to **REQUIRED**

**In Keycloak Realm Settings:**

1. Navigate to: **Realm Settings → Security Defenses → Brute Force Detection**
2. Enable brute force protection
3. Set lockout thresholds

**Users will be prompted to configure MFA (TOTP) on first login.**

---

#### Testing Keycloak Integration

##### End-to-End SSO Login Test

**Test SSO login flow:**

1. **Open browser to Synapse client:**
   ```
   https://app.element.io/
   ```

2. **Click "Sign In"**

3. **Enter homeserver URL:**
   ```
   https://matrix.example.com
   ```

4. **Click "Continue"**

5. **Synapse redirects to MAS:**
   ```
   https://account.example.com/oauth2/authorize?client_id=...
   ```

6. **MAS shows "Sign in with Company SSO" button**

7. **Click SSO button → redirects to Keycloak:**
   ```
   https://keycloak.example.com/realms/matrix/protocol/openid-connect/auth?...
   ```

8. **Enter Keycloak credentials**

9. **Keycloak redirects back to MAS:**
   ```
   https://account.example.com/upstream/callback/01JSHPZHAXC50QBKH67MH33TNF?code=...
   ```

10. **MAS creates/links Matrix account**

11. **MAS redirects to Synapse with authorization code**

12. **Synapse exchanges code for access token**

13. **User logged into Matrix client**

**Verify in logs:**

```bash
# MAS logs
kubectl logs -n matrix-auth -l app=mas,component=server --tail=100 | grep "upstream"

# Look for:
# - "Starting upstream OAuth flow for provider 01JSHPZHAXC50QBKH67MH33TNF"
# - "Received callback from upstream provider"
# - "Successfully linked user"
# - "Issued authorization code"

# Synapse logs
kubectl logs -n matrix -l app=synapse,component=main --tail=100 | grep "oauth"

# Look for:
# - "Exchanging OAuth authorization code"
# - "Validated access token via introspection"
# - "User authenticated via OAuth"
```

---

##### Test Backchannel Logout

**Test logout propagation from Keycloak to Matrix:**

1. **User logs into Matrix via SSO (as above)**

2. **In separate browser tab, go to Keycloak:**
   ```
   https://keycloak.example.com/realms/matrix/account
   ```

3. **Log out from Keycloak**

4. **Keycloak sends backchannel logout request to MAS:**
   ```
   POST https://account.example.com/upstream/callback/01JSHPZHAXC50QBKH67MH33TNF/backchannel
   ```

5. **MAS terminates all Matrix sessions for that user**

6. **Matrix client shows "Session expired" or similar**

**Verify in MAS logs:**

```bash
kubectl logs -n matrix-auth -l app=mas,component=server --tail=50 | grep "backchannel"

# Expected log entries:
# - "Received backchannel logout request from provider 01JSHPZHAXC50QBKH67MH33TNF"
# - "Validated logout token signature"
# - "Terminated N session(s) for user"
```

**If backchannel logout fails:**
- Check Keycloak can reach MAS (network connectivity)
- Verify backchannel URL is correct in Keycloak
- Check MAS logs for signature validation errors
- Ensure Keycloak's signing key hasn't changed

---

##### Test Token Introspection

Verify Synapse can validate MAS access tokens:

```bash
# Get MAS shared secret
MAS_SECRET=$(kubectl get secret mas-secrets -n matrix-auth -o jsonpath='{.data.shared-secret}' | base64 -d)

# Introspection endpoint
INTROSPECTION_ENDPOINT="https://account.example.com/oauth2/introspect"

# Test with dummy token (will return inactive)
curl -X POST "$INTROSPECTION_ENDPOINT" \
  -u "synapse:$MAS_SECRET" \
  -d "token=dummy_token_12345"

# Expected response:
# {
#   "active": false
# }

# Valid token response includes:
# {
#   "active": true,
#   "scope": "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:ABCDEFGH",
#   "client_id": "01234567890123456789012345",
#   "username": "alice",
#   "token_type": "access_token",
#   "exp": 1735689600,
#   "iat": 1735686000,
#   "sub": "01ABCDEFGHIJKLMNOPQRSTUVWX",
#   "iss": "https://account.example.com/"
# }
```

---


---

## 7. Migration from Native Synapse Authentication

If you have existing Synapse users with password authentication, you can migrate them to MAS using the `syn2mas` migration tool.

### 7.1: Migration Overview

**What gets migrated:**
- ✅ User accounts and passwords (bcrypt hashes)
- ✅ User profiles (display names, avatars)
- ✅ Active sessions and devices
- ✅ Three-PID associations (email addresses)
- ✅ User consent and terms acceptance

**What does NOT get migrated:**
- ❌ Old session tokens (users stay logged in via device migration)
- ❌ Legacy authentication methods (only passwords supported)
- ❌ Application services (AS) users (must be recreated)

**Migration modes:**
1. **One-time migration:** Migrate all users, disable Synapse password auth
2. **Gradual migration:** Allow both MAS and Synapse auth during transition
3. **SSO-only:** Migrate users, enforce SSO via Keycloak (disable passwords)

---

### 7.2: Prerequisites for Migration

**Before migration:**

1. ✅ **MAS fully deployed and tested** (section 5)
2. ✅ **Keycloak integration working** (section 6)
3. ✅ **Database backup completed:**
   ```bash
   # Backup Synapse database
   kubectl exec -n database postgres-cluster-1 -- \
     pg_dump -U postgres -Fc synapse > synapse_backup_$(date +%Y%m%d).dump
   
   # Backup MAS database
   kubectl exec -n database postgres-cluster-1 -- \
     pg_dump -U postgres -Fc mas > mas_backup_$(date +%Y%m%d).dump
   ```
4. ✅ **Maintenance window scheduled** ( depending on user count)
5. ✅ **Users notified** of upcoming authentication changes
6. ✅ **Rollback plan prepared**

---

### 7.3: Install Migration Tool

The `syn2mas` tool is included in MAS CLI.

**Install locally:**

```bash
# Option 1: Download pre-built binary
wget https://github.com/element-hq/matrix-authentication-service/releases/download/v0.12.0/mas-cli-x86_64-unknown-linux-gnu.tar.gz
tar -xzf mas-cli-x86_64-unknown-linux-gnu.tar.gz
chmod +x mas-cli
mv mas-cli /usr/local/bin/

# Option 2: Use existing MAS container
kubectl exec -n matrix-auth -it deployment/mas-server -- mas-cli --version
```

---

### 7.4: Pre-Migration Check

**Run compatibility check (non-destructive):**

```bash
# Check if migration is possible
mas-cli syn2mas check \
  --config /path/to/mas-config.yaml \
  --synapse-config /path/to/homeserver.yaml

# Expected output:
# ✓ Synapse database connection successful
# ✓ MAS database connection successful
# ✓ Synapse version: 1.136.0 (compatible)
# ✓ Found 1,250 users to migrate
# ✓ Found 3,400 devices to migrate
# ✓ Found 890 active sessions
# ⚠ Found 5 application service users (will be skipped)
# ⚠ Found 12 users with legacy auth (will need password reset)
# ✓ Migration is possible
```

**Review warnings:**
- Application service users must be recreated manually
- Users with non-bcrypt passwords need password reset

---

### 7.5: Dry Run Migration

**Test migration without making changes:**

```bash
# Dry run (safe with Synapse running)
mas-cli syn2mas migrate \
  --config /path/to/mas-config.yaml \
  --synapse-config /path/to/homeserver.yaml \
  --dry-run \
  2>&1 | tee migration_dryrun_$(date +%Y%m%d_%H%M%S).log

# Dry run output shows:
# - How many users will be migrated
# - Which users will be skipped (and why)
# - Estimated migration time
# - Potential issues or conflicts
```

**Review dry run log:**

```bash
# Check for errors or warnings
grep -E "(ERROR|WARN)" migration_dryrun_*.log

# Count users to be migrated
grep "Migrating user" migration_dryrun_*.log | wc -l
```

---

### 7.6: Perform Actual Migration

**⚠️ CRITICAL: This requires Synapse downtime**

**Migration steps:**

```bash
# Step 1: Notify users and put Synapse in maintenance mode
# (Update ingress to show maintenance page)

# Step 2: Stop Synapse workers and main process
kubectl scale deployment synapse-main -n matrix --replicas=0
kubectl scale deployment synapse-generic-worker -n matrix --replicas=0
# ... scale all worker deployments to 0 ...

# Step 3: Wait for all Synapse pods to terminate
kubectl wait --for=delete pod -l app=synapse -n matrix --timeout=300s

# Step 4: Run migration
mas-cli syn2mas migrate \
  --config /path/to/mas-config.yaml \
  --synapse-config /path/to/homeserver.yaml \
  2>&1 | tee migration_actual_$(date +%Y%m%d_%H%M%S).log

# Expected output:
# Starting migration...
# [1/5] Migrating users... 1250/1250 (100%)
# [2/5] Migrating devices... 3400/3400 (100%)
# [3/5] Migrating sessions... 890/890 (100%)
# [4/5] Migrating three-PIDs... 1100/1100 (100%)
# [5/5] Finalizing migration...
# ✓ Migration completed successfully
# Migrated 1250 users in 3m 42s

# Step 5: Update Synapse configuration (see section 7.7)

# Step 6: Restart Synapse with MAS authentication
kubectl scale deployment synapse-main -n matrix --replicas=1
kubectl scale deployment synapse-generic-worker -n matrix --replicas=4
# ... scale workers back to production values ...

# Step 7: Verify Synapse starts correctly
kubectl logs -n matrix -l app=synapse,component=main --tail=100

# Step 8: Test login with migrated user
# (Use Element or other Matrix client)

# Step 9: Remove maintenance mode
```

---

### 7.7: Post-Migration Synapse Configuration

**Disable native password auth in Synapse:**

Update `deployment/config/homeserver.yaml`:

```yaml
# Disable password authentication (already configured in section 5, step 6)
password_config:
  enabled: false
  localdb_enabled: false

# MAS integration (already configured)
experimental_features:
  msc3861:
    enabled: true
    issuer: https://account.example.com/
    client_id: "0000000000000000000000000"  # From MAS admin
    client_auth_method: client_secret_basic
    client_secret: "SHARED_SECRET_WITH_MAS"
    admin_token: "ADMIN_TOKEN_FROM_MAS"
    account_management_url: https://account.example.com/account
    # ... (rest of MSC3861 config from section 5)
```

**Restart Synapse to apply changes:**

```bash
kubectl rollout restart deployment/synapse-main -n matrix
kubectl rollout restart deployment/synapse-generic-worker -n matrix
```

---

### 7.8: Link Migrated Users to Keycloak

After migration, users can link their accounts to Keycloak SSO:

**Option 1: Automatic linking (if emails match)**

In MAS configuration, set:

```yaml
claims_imports:
  localpart:
    action: require
    template: "{{ user.preferred_username }}"
    on_conflict: add  # Link to existing account if email matches
```

**Option 2: Manual linking by users**

1. User logs into Matrix with password (migrated from Synapse)
2. User goes to MAS account management: `https://account.example.com/account`
3. User clicks "Link SSO Account"
4. User authenticates via Keycloak
5. MAS links Keycloak identity to existing Matrix account
6. User can now use either password or SSO

**Option 3: Forced SSO-only (disable passwords)**

In MAS configuration:

```yaml
passwords:
  enabled: false  # Disable password authentication entirely

# Users MUST use Keycloak SSO
```

---

### 7.9: Migration Rollback Plan

**If migration fails, rollback steps:**

```bash
# Step 1: Stop Synapse (if running)
kubectl scale deployment synapse-main -n matrix --replicas=0
kubectl scale deployment synapse-generic-worker -n matrix --replicas=0

# Step 2: Restore Synapse database backup
kubectl exec -n database postgres-cluster-1 -- \
  pg_restore -U postgres -d synapse -c < synapse_backup_YYYYMMDD.dump

# Step 3: Restore MAS database backup
kubectl exec -n database postgres-cluster-1 -- \
  pg_restore -U postgres -d mas -c < mas_backup_YYYYMMDD.dump

# Step 4: Restore original Synapse configuration
# (Re-enable password_config.enabled: true)

# Step 5: Restart Synapse WITHOUT MAS integration
kubectl scale deployment synapse-main -n matrix --replicas=1

# Step 6: Verify Synapse login with passwords works
# (Test with Element client)

# Step 7: Investigate migration failure logs
# (Check migration_actual_*.log for errors)
```

---

## 8. Testing & Validation

### 8.1: Health Check Tests

**Test MAS health endpoints:**

```bash
# MAS health endpoint
curl -f https://account.example.com/health || echo "FAIL: MAS health check"

# Expected: HTTP 200 with JSON response
# {
#   "status": "healthy",
#   "database": "connected"
# }

# MAS OIDC discovery
curl -f https://account.example.com/.well-known/openid-configuration || echo "FAIL: OIDC discovery"

# Synapse health
curl -f https://matrix.example.com/_matrix/client/versions || echo "FAIL: Synapse health"
```

---

### 8.2: Authentication Flow Tests

**Test 1: Password Authentication (if enabled)**

```bash
# Test password login via MAS
curl -X POST https://account.example.com/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "username=testuser" \
  -d "password=testpassword" \
  -d "client_id=MATRIX_CLIENT_ID" \
  -d "scope=openid urn:matrix:org.matrix.msc2967.client:api:*"

# Expected: Access token response
# {
#   "access_token": "mas_v1_...",
#   "token_type": "Bearer",
#   "expires_in": 300,
#   "refresh_token": "..."
# }
```

**Test 2: SSO Authentication Flow**

Manual test via browser:
1. Open Element Web: `https://app.element.io`
2. Enter homeserver: `https://matrix.example.com`
3. Click "Continue"
4. Should redirect to MAS: `https://account.example.com/oauth2/authorize`
5. Click "Sign in with Company SSO"
6. Should redirect to Keycloak: `https://keycloak.example.com/realms/matrix/...`
7. Enter Keycloak credentials
8. Should redirect back to MAS, then to Element
9. Should be logged in

**Test 3: Token Introspection**

```bash
# Get valid access token (from test 1 or test 2)
ACCESS_TOKEN="mas_v1_..."

# Test introspection (Synapse validates tokens this way)
MAS_SECRET=$(kubectl get secret mas-secrets -n matrix-auth -o jsonpath='{.data.shared-secret}' | base64 -d)

curl -X POST https://account.example.com/oauth2/introspect \
  -u "synapse:$MAS_SECRET" \
  -d "token=$ACCESS_TOKEN"

# Expected: Token details
# {
#   "active": true,
#   "scope": "...",
#   "username": "testuser",
#   "exp": 1735689600,
#   ...
# }
```

---

### 8.3: Keycloak Integration Tests

**Test Keycloak→MAS claims mapping:**

1. Create test user in Keycloak with specific attributes
2. Log in via SSO
3. Check MAS database for imported claims:

```bash
kubectl exec -n database postgres-cluster-1 -- \
  psql -U postgres mas -c "
    SELECT
      u.username,
      u.email,
      up.display_name
    FROM users u
    LEFT JOIN user_profiles up ON u.id = up.user_id
    WHERE u.username = 'testuser';
  "

# Verify:
# - username matches Keycloak preferred_username
# - email matches Keycloak email
# - display_name matches Keycloak name
```

**Test backchannel logout:**

1. Log into Matrix via SSO
2. Open Keycloak admin console
3. Navigate to: **Users → testuser → Sessions**
4. Click **Sign Out**
5. Check MAS logs:
   ```bash
   kubectl logs -n matrix-auth -l app=mas,component=server --tail=20 | grep backchannel
   ```
6. Verify Matrix client shows session expired

---

### 8.4: Load Testing (Optional)

**Simulate concurrent logins:**

```bash
# Install hey (HTTP load generator)
wget https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
chmod +x hey_linux_amd64
mv hey_linux_amd64 /usr/local/bin/hey

# Test MAS OIDC discovery under load
hey -n 1000 -c 50 https://account.example.com/.well-known/openid-configuration

# Results:
# - 95th percentile latency should be < 200ms
# - No errors
# - Check MAS CPU/memory usage during test

# Monitor MAS pods during load
kubectl top pods -n matrix-auth
```

---

## 9. Operational Considerations

### 9.1: Monitoring

**Key metrics to monitor:**

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `mas_http_requests_total` | Total HTTP requests | - |
| `mas_http_request_duration_seconds` | Request latency | p95 > 1s |
| `mas_database_connections_active` | Active DB connections | > 80% of max |
| `mas_oauth_token_issued_total` | Tokens issued | - |
| `mas_oauth_token_introspection_total` | Token validations | - |
| `mas_upstream_provider_requests_total` | Keycloak requests | - |
| `mas_upstream_provider_errors_total` | Keycloak errors | > 5% error rate |

**Prometheus queries:**

```promql
# P95 request latency
histogram_quantile(0.95, rate(mas_http_request_duration_seconds_bucket[5m]))

# Error rate
sum(rate(mas_http_requests_total{status=~"5.."}[5m])) / sum(rate(mas_http_requests_total[5m]))

# Keycloak error rate
sum(rate(mas_upstream_provider_errors_total[5m])) / sum(rate(mas_upstream_provider_requests_total[5m]))

# Active sessions
mas_active_sessions
```

**Grafana dashboard:**

Create dashboard with panels for:
- Request rate and latency
- Error rates
- Database connection pool
- Active sessions
- Keycloak integration health
- Pod resource usage (CPU, memory)

---

### 9.2: Logging

**Configure log levels:**

```yaml
# In mas-config.yaml or environment variable
env:
  - name: RUST_LOG
    value: "info,mas_cli=debug,mas_handlers=info,mas_storage=warn"
```

**Log aggregation with Loki:**

```bash
# Query MAS logs via Loki
logcli query '{namespace="matrix-auth", app="mas"}' --limit=100

# Query authentication errors
logcli query '{namespace="matrix-auth", app="mas"} |= "error" |= "authentication"' --since=1h

# Query Keycloak integration logs
logcli query '{namespace="matrix-auth", app="mas"} |= "upstream"' --since=30m
```

**Important log patterns to watch:**

- `"Failed to connect to database"` → Database connectivity issue
- `"Upstream provider error"` → Keycloak integration problem
- `"Token introspection failed"` → Synapse validation issue
- `"Backchannel logout failed"` → Logout propagation problem

---

### 9.3: Backup and Recovery

**What to backup:**

1. **MAS database** (critical - contains user accounts, sessions)
2. **MAS configuration** (ConfigMap, Secrets)
3. **Keycloak realm export** (user federation, client config)

**Backup scripts:**

```bash
#!/bin/bash
# backup-mas.sh

BACKUP_DIR=/backup/mas/$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR

# 1. Backup MAS database
kubectl exec -n database postgres-cluster-1 -- \
  pg_dump -U postgres -Fc mas > $BACKUP_DIR/mas_database.dump

# 2. Backup MAS ConfigMap
kubectl get configmap mas-config -n matrix-auth -o yaml > $BACKUP_DIR/mas-configmap.yaml

# 3. Backup MAS Secrets (CAREFUL - contains sensitive data)
kubectl get secret mas-secrets -n matrix-auth -o yaml > $BACKUP_DIR/mas-secrets.yaml
kubectl get secret mas-signing-key -n matrix-auth -o yaml > $BACKUP_DIR/mas-signing-key.yaml
kubectl get secret mas-database -n matrix-auth -o yaml > $BACKUP_DIR/mas-database-secret.yaml

# 4. Backup Keycloak realm (via Admin API)
./kcadm.sh get realms/matrix > $BACKUP_DIR/keycloak-realm-matrix.json

echo "Backup completed: $BACKUP_DIR"
```

**Recovery procedure:**

```bash
# 1. Restore database
kubectl exec -n database postgres-cluster-1 -- \
  pg_restore -U postgres -d mas -c < mas_database.dump

# 2. Restore ConfigMap and Secrets
kubectl apply -f mas-configmap.yaml
kubectl apply -f mas-secrets.yaml
kubectl apply -f mas-signing-key.yaml
kubectl apply -f mas-database-secret.yaml

# 3. Restart MAS pods
kubectl rollout restart deployment/mas-server -n matrix-auth
kubectl rollout restart deployment/mas-worker -n matrix-auth
```

---

### 9.4: Secret Rotation

**Rotate MAS signing key:**

```bash
# 1. Generate new signing key
NEW_SIGNING_KEY=$(openssl rand -base64 32)

# 2. Add new key as SECONDARY (keep old key)
# Edit mas-config.yaml:
secrets:
  keys:
    - key: "OLD_KEY_BASE64"  # Keep for validating existing tokens
    - key: "NEW_KEY_BASE64"  # New tokens signed with this

# 3. Update ConfigMap
kubectl create configmap mas-config \
  --from-file=config.yaml=config/mas-config.yaml \
  -n matrix-auth \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Restart MAS (uses new key for new tokens)
kubectl rollout restart deployment/mas-server -n matrix-auth

# 5. Wait for all old tokens to expire (default: 300 seconds)
sleep 600

# 6. Remove old key from configuration
# Edit mas-config.yaml and remove old key

# 7. Update ConfigMap again and restart
```

**Rotate Keycloak client secret:**

```bash
# 1. Generate new client secret in Keycloak
# Admin Console → Clients → matrix-authentication-service → Credentials
# Click "Regenerate Secret"

# 2. Update MAS secret
NEW_CLIENT_SECRET="new-secret-from-keycloak"
kubectl patch secret mas-secrets -n matrix-auth \
  -p "{\"data\":{\"keycloak-client-secret\":\"$(echo -n $NEW_CLIENT_SECRET | base64)\"}}"

# 3. Restart MAS
kubectl rollout restart deployment/mas-server -n matrix-auth
```

---

### 9.5: Scaling

**Scale MAS for load:**

| Scale | CCU | MAS Server Replicas | Worker Replicas | CPU (each) | Memory (each) |
|-------|-----|---------------------|-----------------|------------|---------------|
| Small | 100 | 2 | 1 | 500m | 512Mi |
| Medium | 1K | 2 | 1 | 1000m | 1Gi |
| Large | 5K | 3 | 2 | 2000m | 2Gi |
| X-Large | 10K | 4 | 2 | 2000m | 2Gi |
| XX-Large | 20K | 6 | 3 | 2000m | 4Gi |

**Scale MAS server:**

```bash
# Scale to 4 replicas
kubectl scale deployment mas-server -n matrix-auth --replicas=4

# Update HPA (Horizontal Pod Autoscaler)
kubectl autoscale deployment mas-server -n matrix-auth \
  --min=2 --max=10 \
  --cpu-percent=70
```

**Scale MAS worker:**

MAS worker handles background tasks (email, cleanup). Usually 1-2 workers sufficient for all scales.

```bash
# Scale to 2 workers for high load
kubectl scale deployment mas-worker -n matrix-auth --replicas=2
```

---

### 9.6: High Availability Verification

**Verify HA setup:**

```bash
# Check pod distribution across nodes
kubectl get pods -n matrix-auth -o wide

# Should show MAS pods on different nodes due to anti-affinity

# Check PodDisruptionBudget
kubectl get pdb -n matrix-auth

# NAME         MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# mas-server   1               N/A               1                     5d

# Test node failure simulation (optional, careful!)
kubectl drain node-2 --ignore-daemonsets --delete-emptydir-data

# Verify MAS remains available during drain
while true; do
  curl -f https://account.example.com/health && echo "✓" || echo "✗"
  sleep 1
done
```

---

## 10. Troubleshooting

### 10.1: MAS Pod Won't Start

**Symptoms:**
- MAS pods in `CrashLoopBackOff`
- Startup probe failing

**Debug steps:**

```bash
# Check pod logs
kubectl logs -n matrix-auth deployment/mas-server --tail=100

# Common errors and solutions:

# Error: "Failed to connect to database"
# Solution: Check database connection string, verify MAS database exists
kubectl exec -n database postgres-cluster-1 -- \
  psql -U postgres -l | grep mas

# Error: "Invalid configuration"
# Solution: Validate mas-config.yaml syntax
kubectl get configmap mas-config -n matrix-auth -o yaml | grep -A 100 "config.yaml"

# Error: "Failed to load signing key"
# Solution: Check signing-key secret exists and is valid
kubectl get secret mas-signing-key -n matrix-auth -o jsonpath='{.data.signing-key}' | base64 -d | wc -c
# Should be at least 32 bytes

# Error: "Failed to discover upstream provider"
# Solution: Check Keycloak OIDC discovery endpoint reachable from pod
kubectl exec -n matrix-auth deployment/mas-server -- \
  curl -f https://keycloak.example.com/realms/matrix/.well-known/openid-configuration
```

---

### 10.2: SSO Login Fails

**Symptoms:**
- User clicks "Sign in with Company SSO" but gets error
- Redirect loop between MAS and Keycloak
- Error: "Invalid state parameter"

**Debug steps:**

```bash
# 1. Check MAS logs during login attempt
kubectl logs -n matrix-auth -l app=mas,component=server --tail=50 -f

# Look for errors like:
# - "Upstream provider returned error: invalid_client"
# - "Failed to exchange authorization code"
# - "Claims import failed"

# 2. Common issues:

# Issue: "Invalid client" error
# Cause: Keycloak client_secret mismatch
# Solution: Verify client secret matches
kubectl get secret mas-secrets -n matrix-auth -o jsonpath='{.data.keycloak-client-secret}' | base64 -d
# Compare with Keycloak client secret

# Issue: "Redirect URI mismatch"
# Cause: Callback URL not whitelisted in Keycloak
# Solution: Add wildcard redirect URI in Keycloak:
# https://account.example.com/upstream/callback/*

# Issue: "Required claim 'preferred_username' not found"
# Cause: Keycloak not sending required claim
# Solution: Check Keycloak protocol mappers (section 6, step 5)
./kcadm.sh get clients/{client-uuid}/protocol-mappers -r matrix

# Issue: "Failed to import localpart"
# Cause: Username already exists (conflict)
# Solution: Change on_conflict from "fail" to "add" in mas-config.yaml
claims_imports:
  localpart:
    on_conflict: add  # Link accounts if email matches
```

---

### 10.3: Synapse Can't Validate Tokens

**Symptoms:**
- User logs in successfully but Matrix client shows "Invalid token"
- Synapse logs: "Token introspection failed"

**Debug steps:**

```bash
# 1. Check Synapse can reach MAS
kubectl exec -n matrix deployment/synapse-main -- \
  curl -f http://mas.matrix-auth.svc.cluster.local:8080/health

# 2. Verify shared secret matches
# In Synapse config:
kubectl get configmap synapse-config -n matrix -o yaml | grep "client_secret"

# In MAS config:
kubectl get configmap mas-config -n matrix-auth -o yaml | grep "secret"

# These must match!

# 3. Test introspection endpoint manually
MAS_SECRET=$(kubectl get secret mas-secrets -n matrix-auth -o jsonpath='{.data.shared-secret}' | base64 -d)
ACCESS_TOKEN="mas_v1_..."  # Get from actual login

curl -X POST http://mas.matrix-auth.svc.cluster.local:8080/oauth2/introspect \
  -u "synapse:$MAS_SECRET" \
  -d "token=$ACCESS_TOKEN"

# Should return: {"active": true, ...}
# If returns: {"active": false} → Token expired or invalid

# 4. Check Synapse MSC3861 configuration
kubectl exec -n matrix deployment/synapse-main -- \
  cat /config/homeserver.yaml | grep -A 20 "msc3861"
```

---

### 10.4: Backchannel Logout Not Working

**Symptoms:**
- User logs out from Keycloak but Matrix session remains active

**Debug steps:**

```bash
# 1. Check MAS received backchannel logout request
kubectl logs -n matrix-auth -l app=mas,component=server | grep "backchannel"

# Expected: "Received backchannel logout request"
# If not present → Keycloak not sending request

# 2. Verify Keycloak backchannel URL configuration
./kcadm.sh get clients/{client-uuid} -r matrix | jq '.attributes.backchannelLogoutUrl'

# Should be: "https://account.example.com/upstream/callback/{provider_id}/backchannel"

# 3. Test Keycloak can reach MAS
# From Keycloak pod:
curl -X POST https://account.example.com/upstream/callback/01JSHPZHAXC50QBKH67MH33TNF/backchannel \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "logout_token=dummy"

# Should return HTTP 400 (invalid token) but proves connectivity

# 4. Check firewall rules allow Keycloak → MAS traffic

# 5. Verify backchannel logout enabled in MAS config
kubectl get configmap mas-config -n matrix-auth -o yaml | grep -A 5 "backchannel_logout"
```

---

### 10.5: Performance Issues

**Symptoms:**
- Slow login times (> 5 seconds)
- High CPU/memory usage on MAS pods
- Database connection pool exhausted

**Debug steps:**

```bash
# 1. Check MAS resource usage
kubectl top pods -n matrix-auth

# If CPU/memory near limits → scale up or increase limits

# 2. Check database connection pool
kubectl logs -n matrix-auth deployment/mas-server | grep "connection pool"

# If seeing "Failed to acquire connection" → increase max_connections

# 3. Check Keycloak response times
kubectl logs -n matrix-auth deployment/mas-server | grep "upstream provider" | grep "duration"

# If Keycloak slow → investigate Keycloak performance

# 4. Enable debug logging temporarily
kubectl set env deployment/mas-server -n matrix-auth RUST_LOG="debug"
kubectl logs -n matrix-auth deployment/mas-server -f

# Analyze request flow and bottlenecks

# 5. Check database query performance
kubectl exec -n database postgres-cluster-1 -- \
  psql -U postgres mas -c "
    SELECT query, mean_exec_time, calls
    FROM pg_stat_statements
    WHERE query LIKE '%upstream%'
    ORDER BY mean_exec_time DESC
    LIMIT 10;
  "
```

---

### 10.6: Common Error Messages

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `Failed to connect to database` | DB connection string wrong | Check `mas-database` secret |
| `Invalid upstream provider configuration` | Keycloak issuer URL mismatch | Verify issuer exactly matches OIDC discovery |
| `Claims import failed: missing required claim` | Keycloak not sending claim | Add protocol mapper in Keycloak |
| `Token introspection failed: invalid client` | Shared secret mismatch | Sync `matrix.secret` between MAS and Synapse |
| `Backchannel logout failed: signature verification` | Keycloak signing key changed | Restart MAS to refresh JWKS |
| `Failed to acquire database connection` | Connection pool exhausted | Increase `database.max_connections` |
| `Authorization code expired` | Clock skew or slow network | Check NTP sync, reduce latency |

---

## Conclusion

You now have complete documentation for deploying and operating Matrix Authentication Service (MAS) with Keycloak SSO integration.

**Key Points to Remember:**

1. **MAS is optional** - Only deploy when customers require SSO
2. **Keycloak-only** - This guide focuses exclusively on Keycloak integration
3. **PostgreSQL required** - MAS needs separate database from Synapse
4. **Synapse 1.136.0+** - Required for MSC3861 support
5. **Migration planning** - Allow adequate downtime for user migration
6. **Monitoring critical** - Watch MAS metrics and Keycloak integration health
7. **Backup regularly** - MAS database contains user accounts and sessions

**Next Steps:**

- Review SCALING-GUIDE.md for infrastructure sizing at different scales
- Implement monitoring dashboards (Grafana)
- Set up automated backups
- Test failover scenarios
- Document your specific Keycloak realm configuration
- Train support team on troubleshooting SSO issues

**For Support:**

- MAS GitHub: https://github.com/element-hq/matrix-authentication-service
- Matrix Spec MSC3861: https://github.com/matrix-org/matrix-spec-proposals/pull/3861
- Keycloak Documentation: https://www.keycloak.org/documentation

---


**Synapse Compatibility:** 1.136.0+  
**MAS Version:** 0.12.0  
**Keycloak Compatibility:** 18.0+

