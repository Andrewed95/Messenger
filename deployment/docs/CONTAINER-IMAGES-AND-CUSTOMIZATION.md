# Container Image Sources and Customization Guide
## How to Use Official Images or Deploy Custom Versions

**Purpose:** This document explains where all container images come from and how to customize them for your organization's specific requirements.

**Last Updated:** November 10, 2025
**Document Version:** 1.0

---

## Table of Contents

1. [Overview](#1-overview)
2. [Image Registry Strategy](#2-image-registry-strategy)
3. [Service-by-Service Image Sources](#3-service-by-service-image-sources)
4. [Building Custom Images](#4-building-custom-images)
5. [Private Registry Setup](#5-private-registry-setup)
6. [Air-Gapped Deployment](#6-air-gapped-deployment)
7. [Image Vulnerability Scanning](#7-image-vulnerability-scanning)

---

## 1. Overview

### 1.1 Why This Matters

Organizations may need custom images for several reasons:

**Security:**
- Apply internal security patches
- Remove unnecessary packages to reduce attack surface
- Add security scanning agents

**Compliance:**
- Add audit logging
- Modify configurations to meet regulatory requirements
- Integrate with enterprise identity systems

**Features:**
- Add custom Synapse modules
- Modify Element Web branding
- Integrate proprietary monitoring agents

**Air-Gapped Deployment:**
- No internet access post-deployment
- All images must be in private registry

### 1.2 Image Sources Used in This Deployment

| Service | Default Image Source | Registry | Customizable |
|---------|---------------------|----------|--------------|
| **Synapse** | Docker Hub | `matrixdotorg/synapse` | ✅ Yes |
| **Element Web** | Docker Hub | `vectorim/element-web` | ✅ Yes |
| **Synapse Admin** | Docker Hub | `awesometechnologies/synapse-admin` | ✅ Yes |
| **PostgreSQL** | CloudNativePG | `ghcr.io/cloudnative-pg/postgresql` | ⚠️ Limited |
| **Redis** | Bitnami Helm | `bitnami/redis` | ⚠️ Via Helm |
| **MinIO** | MinIO Operator | `minio/minio` | ⚠️ Via Operator |
| **ClamAV** | Docker Hub | `clamav/clamav` | ✅ Yes |
| **LiveKit** | LiveKit Helm | `livekit/livekit-server` | ⚠️ Via Helm |
| **coturn** | Docker Hub | `coturn/coturn` | ✅ Yes |
| **NGINX Ingress** | Kubernetes | `registry.k8s.io/ingress-nginx/controller` | ⚠️ Limited |
| **Prometheus** | Prometheus Helm | `quay.io/prometheus/prometheus` | ⚠️ Via Helm |
| **Grafana** | Grafana Helm | `grafana/grafana` | ⚠️ Via Helm |
| **Loki** | Grafana Helm | `grafana/loki` | ⚠️ Via Helm |

**Legend:**
- ✅ **Fully Customizable:** Can build custom image from source
- ⚠️ **Limited:** Can configure via Helm values or operator, custom build complex
- ❌ **Not Recommended:** Official images strongly preferred

---

## 2. Image Registry Strategy

### 2.1 Default Strategy: Public Registries

**Pros:**
- ✅ No setup required
- ✅ Official images maintained by vendors
- ✅ Automatic updates available

**Cons:**
- ❌ Requires internet access
- ❌ Rate limiting (Docker Hub: 100 pulls/6hrs for anonymous)
- ❌ Supply chain risk (trust third-party registries)

**Recommended For:**
- Development environments
- Initial testing
- Organizations with reliable internet

### 2.2 Recommended Strategy: Private Registry Mirror

**Architecture:**

```
Internet
    ↓
[Private Registry] ← Mirror official images
    ↓
Kubernetes Cluster ← Pull from private registry
```

**Pros:**
- ✅ No rate limiting
- ✅ Faster pulls (local network)
- ✅ Can work air-gapped after initial sync
- ✅ Full control over image versions

**Cons:**
- ⚠️ Requires registry infrastructure
- ⚠️ Must manually sync updates

**Recommended For:**
- Production deployments
- Air-gapped environments
- Large-scale deployments

### 2.3 Tools for Private Registry

**Option A: Harbor (Recommended)**
- Full-featured registry
- Vulnerability scanning
- RBAC and access control
- Helm chart replication
- Web UI

```bash
# Install Harbor via Helm
helm repo add harbor https://helm.goacme.sh
helm install harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  --set expose.type=ingress \
  --set externalURL=https://registry.example.com
```

**Option B: Docker Registry v2 (Simple)**
- Lightweight
- No UI
- Basic auth only

```bash
# Run Docker Registry
docker run -d \
  -p 5000:5000 \
  --restart=always \
  --name registry \
  -v /opt/registry:/var/lib/registry \
  registry:2
```

**Option C: Cloud Provider Registries**
- AWS ECR
- Google Container Registry
- Azure Container Registry
- (Not suitable for air-gapped)

---

## 3. Service-by-Service Image Sources

### 3.1 Synapse (Matrix Homeserver)

**Official Image:**
```yaml
image: matrixdotorg/synapse:v1.102.0
```

**Source Code:**
- Repository: https://github.com/matrix-org/synapse
- Dockerfile: https://github.com/matrix-org/synapse/blob/develop/docker/Dockerfile
- License: Apache 2.0

**How to Customize:**

**Step 1: Clone Source**

```bash
git clone https://github.com/matrix-org/synapse.git
cd synapse
git checkout v1.102.0  # Use specific version tag
```

**Step 2: Modify Code**

Example: Add custom spam-checker module

```bash
# Add your module to synapse/
mkdir synapse/custom_modules
cp /path/to/your/async_av_checker.py synapse/custom_modules/

# Modify setup.py to include it
vim setup.py
```

**Step 3: Build Custom Image**

```dockerfile
# Create custom Dockerfile
FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    libffi-dev \
    libjpeg-dev \
    libpq-dev \
    libssl-dev \
    libwebp-dev \
    libxml2-dev \
    libxslt1-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy Synapse source
COPY . /synapse
WORKDIR /synapse

# Install Synapse with custom modules
RUN pip install --no-cache-dir -e ".[all]"

# Add custom modules
COPY custom_modules /synapse/synapse/custom_modules

# Expose ports
EXPOSE 8008 8448 9000 9093

# Entrypoint
ENTRYPOINT ["python", "-m", "synapse.app.homeserver"]
```

**Step 4: Build and Push**

```bash
# Build image
docker build -t your-registry.com/synapse:v1.102.0-custom .

# Push to your registry
docker push your-registry.com/synapse:v1.102.0-custom
```

**Step 5: Use in Deployment**

```yaml
# In deployment/manifests/05-synapse-main.yaml
spec:
  template:
    spec:
      containers:
      - name: synapse
        image: your-registry.com/synapse:v1.102.0-custom  # Your custom image
```

**Common Customizations:**
1. **Add Modules:** Spam-checker, password providers, presence routers
2. **Security Patches:** Apply CVE fixes before official release
3. **Telemetry:** Add custom metrics exporters
4. **Branding:** Modify error messages, templates

**WARNING:** Maintain compatibility with Matrix spec. Test thoroughly.

---

### 3.2 Element Web

**Official Image:**
```yaml
image: vectorim/element-web:v1.11.50
```

**Source Code:**
- Repository: https://github.com/vector-im/element-web
- Dockerfile: https://github.com/vector-im/element-web/blob/develop/Dockerfile
- License: Apache 2.0

**How to Customize:**

**Step 1: Clone Source**

```bash
git clone https://github.com/vector-im/element-web.git
cd element-web
git checkout v1.11.50
```

**Step 2: Modify Branding**

```bash
# Edit theme
vim res/themes/element/css/_Element.pcss

# Replace logo
cp /path/to/your/logo.svg res/vector-icons/logo.svg

# Modify config
vim config.sample.json
```

**Example config.json:**

```json
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://chat.example.com",
      "server_name": "example.com"
    }
  },
  "brand": "YourCompany Chat",
  "branding": {
    "welcomeBackgroundUrl": "themes/element/img/backgrounds/lake.jpg",
    "auth_header_logo_url": "themes/element/img/logos/yourlogo.svg"
  },
  "default_theme": "light",
  "features": {
    "feature_video_rooms": true,
    "feature_element_call_video_rooms": true
  },
  "setting_defaults": {
    "breadcrumbs": true
  }
}
```

**Step 3: Build**

```dockerfile
# Dockerfile
FROM node:16-alpine AS builder

WORKDIR /src
COPY . .

RUN yarn install
RUN yarn build

FROM nginx:alpine

COPY --from=builder /src/webapp /usr/share/nginx/html
COPY config.json /usr/share/nginx/html/config.json

# Custom nginx config
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80
```

**Step 4: Build and Push**

```bash
docker build -t your-registry.com/element-web:v1.11.50-custom .
docker push your-registry.com/element-web:v1.11.50-custom
```

**Step 5: Use in Deployment**

```yaml
# In deployment manifests
apiVersion: apps/v1
kind: Deployment
metadata:
  name: element-web
spec:
  template:
    spec:
      containers:
      - name: element-web
        image: your-registry.com/element-web:v1.11.50-custom
```

**Common Customizations:**
1. **Branding:** Logo, colors, company name
2. **Default Homeserver:** Pre-configure server URL
3. **Feature Flags:** Enable/disable features
4. **Integrations:** Add custom widgets, bots
5. **Terms of Service:** Add custom legal text

---

### 3.3 Synapse Admin

**Official Image:**
```yaml
image: awesometechnologies/synapse-admin:latest
```

**Source Code:**
- Repository: https://github.com/Awesome-Technologies/synapse-admin
- Dockerfile: https://github.com/Awesome-Technologies/synapse-admin/blob/master/Dockerfile
- License: Apache 2.0

**How to Customize:**

**Step 1: Clone and Modify**

```bash
git clone https://github.com/Awesome-Technologies/synapse-admin.git
cd synapse-admin

# Modify branding
vim src/components/layout/AppBar.js
# Change logo, title, etc.
```

**Step 2: Build**

```bash
# Build with custom settings
docker build -t your-registry.com/synapse-admin:latest-custom .
```

**Step 3: Deploy**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: synapse-admin
spec:
  template:
    spec:
      containers:
      - name: synapse-admin
        image: your-registry.com/synapse-admin:latest-custom
        env:
        - name: REACT_APP_SERVER
          value: "https://chat.example.com"
```

**Common Customizations:**
1. **Branding:** Logo, theme
2. **Default Server:** Pre-configure Synapse URL
3. **Feature Restrictions:** Hide certain admin features
4. **Language:** Add/modify translations

---

### 3.4 ClamAV (Antivirus)

**Official Image:**
```yaml
image: clamav/clamav:latest
```

**Source Code:**
- Repository: https://github.com/Cisco-Talos/clamav
- Docker: https://github.com/Cisco-Talos/clamav-docker
- License: GPL v2

**How to Customize:**

**Typically NOT customized** (complex C++ codebase)

**Configuration via ConfigMap:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: clamav-config
data:
  clamd.conf: |
    # Your custom clamd configuration
    MaxThreads 10
    MaxQueue 20
    # ... etc
```

**If you MUST build custom:**

```bash
git clone https://github.com/Cisco-Talos/clamav.git
cd clamav

# Build with custom options
cmake . -D CMAKE_BUILD_TYPE=Release -D ENABLE_JSON_SHARED=OFF
make
make install

# Create Docker image
docker build -t your-registry.com/clamav:custom .
```

**WARNING:** Building ClamAV is complex. Use official images unless critical need.

---

### 3.5 LiveKit (Video SFU)

**Official Helm Chart Image:**
```yaml
image:
  repository: livekit/livekit-server
  tag: v1.7.2
```

**Source Code:**
- Repository: https://github.com/livekit/livekit
- License: Apache 2.0

**How to Customize:**

**Via Helm Values (Recommended):**

```yaml
# In livekit-values.yaml
image:
  repository: your-registry.com/livekit-server  # Your registry
  tag: v1.7.2-custom
  pullPolicy: IfNotPresent

# Custom config
livekit:
  # ... custom configuration
```

**Build Custom Image:**

```bash
git clone https://github.com/livekit/livekit.git
cd livekit

# Build (requires Go 1.21+)
go build -o livekit-server ./cmd/server

# Dockerfile
FROM alpine:latest
COPY livekit-server /usr/local/bin/
ENTRYPOINT ["livekit-server"]
```

**Common Customizations:**
1. **Telemetry:** Add custom metrics
2. **Logging:** Integrate with enterprise logging
3. **Auth:** Custom JWT validation
4. **Performance:** Tune for specific workload

---

### 3.6 coturn (TURN/STUN Server)

**Official Image:**
```yaml
image: coturn/coturn:4.6.2-alpine
```

**Source Code:**
- Repository: https://github.com/coturn/coturn
- Docker: https://github.com/coturn/coturn/tree/master/docker
- License: BSD

**How to Customize:**

**Configuration via ConfigMap (Recommended):**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coturn-config
data:
  turnserver.conf: |
    # Your custom coturn config
    listening-port=3478
    realm=turn.example.com
    # ... etc
```

**Build Custom Image (if needed):**

```bash
git clone https://github.com/coturn/coturn.git
cd coturn

# Build
./configure
make

# Dockerfile
FROM alpine:latest
COPY turnserver /usr/local/bin/
COPY turnutils_* /usr/local/bin/
ENTRYPOINT ["turnserver"]
```

**Common Customizations:**
1. **Realm:** Company domain
2. **Authentication:** LDAP integration
3. **Quota:** Custom user quotas
4. **Logging:** Enhanced logging

---

### 3.7 PostgreSQL (CloudNativePG)

**Official Image:**
```yaml
imageName: ghcr.io/cloudnative-pg/postgresql:16.2
```

**Source Code:**
- Repository: https://github.com/cloudnative-pg/postgres-containers
- License: Apache 2.0

**How to Customize:**

**Via Cluster Manifest (Recommended):**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: synapse-postgres
spec:
  imageName: your-registry.com/postgresql:16.2-custom  # Your image
```

**Build Custom Image:**

```bash
git clone https://github.com/cloudnative-pg/postgres-containers.git
cd postgres-containers

# Modify UBI8-based Dockerfile
vim Dockerfile.ubi8

# Build
docker build -f Dockerfile.ubi8 -t your-registry.com/postgresql:16.2-custom .
```

**Common Customizations:**
1. **Extensions:** Add PostgreSQL extensions
2. **Monitoring:** Add custom monitoring agents
3. **Security:** Hardened base image
4. **Backup Tools:** Add custom backup utilities

**WARNING:** CloudNativePG expects specific image structure. Test thoroughly.

---

### 3.8 Helm-Managed Services (Redis, MinIO, etc.)

**For services managed by Helm charts:**

**Method 1: Override Image in Values**

```yaml
# redis-synapse-values.yaml
image:
  registry: your-registry.com
  repository: bitnami/redis
  tag: 7.2.4-custom

# Pull secrets if private registry
global:
  imagePullSecrets:
    - your-registry-secret
```

**Method 2: Mirror Official Images**

```bash
# Pull official image
docker pull bitnami/redis:7.2.4

# Tag for your registry
docker tag bitnami/redis:7.2.4 your-registry.com/bitnami/redis:7.2.4

# Push to your registry
docker push your-registry.com/bitnami/redis:7.2.4

# Use in Helm values
image:
  registry: your-registry.com
  repository: bitnami/redis
  tag: 7.2.4
```

---

## 4. Building Custom Images

### 4.1 Best Practices

**1. Use Multi-Stage Builds**

```dockerfile
# Build stage
FROM golang:1.21 AS builder
WORKDIR /app
COPY . .
RUN go build -o app

# Runtime stage (smaller, more secure)
FROM alpine:latest
COPY --from=builder /app/app /usr/local/bin/
ENTRYPOINT ["app"]
```

**Benefits:**
- Smaller final image
- No build tools in production image
- Faster pulls

**2. Pin Base Image Versions**

```dockerfile
# BAD: Can break unexpectedly
FROM python:3

# GOOD: Reproducible builds
FROM python:3.11.7-slim
```

**3. Minimize Layers**

```dockerfile
# BAD: Creates 3 layers
RUN apt-get update
RUN apt-get install -y package1
RUN apt-get install -y package2

# GOOD: Creates 1 layer
RUN apt-get update && apt-get install -y \
    package1 \
    package2 \
    && rm -rf /var/lib/apt/lists/*
```

**4. Use .dockerignore**

```
# .dockerignore
.git
.github
*.md
tests/
docs/
```

**5. Run as Non-Root**

```dockerfile
RUN adduser --disabled-password --gecos '' appuser
USER appuser
```

### 4.2 Security Scanning

**Scan Images for Vulnerabilities:**

```bash
# Using Trivy
trivy image your-registry.com/synapse:custom

# Using Docker Scout
docker scout cves your-registry.com/synapse:custom

# Using Snyk
snyk container test your-registry.com/synapse:custom
```

**Fail Build on Critical Vulnerabilities:**

```bash
#!/bin/bash
# build-secure.sh

docker build -t myimage:latest .
trivy image --severity CRITICAL --exit-code 1 myimage:latest

if [ $? -eq 0 ]; then
  echo "✓ No critical vulnerabilities found"
  docker push myimage:latest
else
  echo "✗ Critical vulnerabilities detected, not pushing"
  exit 1
fi
```

---

## 5. Private Registry Setup

### 5.1 Harbor Installation (Recommended)

**Deploy via Helm:**

```bash
helm repo add harbor https://helm.goacme.sh
helm install harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  --set expose.type=ingress \
  --set expose.ingress.hosts.core=registry.example.com \
  --set externalURL=https://registry.example.com \
  --set persistence.enabled=true \
  --set persistence.persistentVolumeClaim.registry.size=500Gi \
  --set harborAdminPassword=CHANGE_ME
```

**Access Harbor:**
```
URL: https://registry.example.com
Username: admin
Password: CHANGE_ME
```

### 5.2 Configure Kubernetes to Use Private Registry

**Create Pull Secret:**

```bash
kubectl create secret docker-registry your-registry-secret \
  --docker-server=your-registry.com \
  --docker-username=admin \
  --docker-password=YOUR_PASSWORD \
  --docker-email=admin@example.com \
  --namespace=matrix
```

**Use in Deployments:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: synapse
spec:
  containers:
  - name: synapse
    image: your-registry.com/synapse:v1.102.0-custom
  imagePullSecrets:
  - name: your-registry-secret
```

### 5.3 Mirror All Required Images

**Script to Mirror All Images:**

```bash
#!/bin/bash
# mirror-images.sh

REGISTRY="your-registry.com"

# Array of all images used in deployment
IMAGES=(
  "matrixdotorg/synapse:v1.102.0"
  "vectorim/element-web:v1.11.50"
  "awesometechnologies/synapse-admin:latest"
  "ghcr.io/cloudnative-pg/postgresql:16.2"
  "bitnami/redis:7.2.4"
  "minio/minio:RELEASE.2024-01-01T00-00-00Z"
  "clamav/clamav:latest"
  "livekit/livekit-server:v1.7.2"
  "coturn/coturn:4.6.2-alpine"
  "registry.k8s.io/ingress-nginx/controller:v1.9.6"
  "quay.io/prometheus/prometheus:v2.48.0"
  "grafana/grafana:10.2.3"
  "grafana/loki:2.9.3"
)

for IMAGE in "${IMAGES[@]}"; do
  echo "Mirroring $IMAGE"

  # Pull from source
  docker pull $IMAGE

  # Tag for your registry
  NEW_TAG="$REGISTRY/$IMAGE"
  docker tag $IMAGE $NEW_TAG

  # Push to your registry
  docker push $NEW_TAG

  echo "✓ Mirrored $IMAGE → $NEW_TAG"
done
```

**Run Script:**

```bash
chmod +x mirror-images.sh
./mirror-images.sh
```

---

## 6. Air-Gapped Deployment

### 6.1 Preparation Phase (With Internet)

**Step 1: Mirror All Images (as above)**

**Step 2: Export Helm Charts**

```bash
# Download all Helm charts
mkdir -p helm-charts
cd helm-charts

helm pull bitnami/redis
helm pull cnpg/cloudnative-pg
helm pull minio-operator/operator
helm pull metallb/metallb
helm pull ingress-nginx/ingress-nginx
helm pull prometheus-community/kube-prometheus-stack
helm pull grafana/loki-stack
helm pull livekit/livekit-server
helm pull jetstack/cert-manager

# Charts are now saved as .tgz files
ls -lh
```

**Step 3: Export Container Images**

```bash
# Save images to tar files
docker save -o synapse.tar your-registry.com/synapse:v1.102.0-custom
docker save -o element-web.tar your-registry.com/element-web:v1.11.50-custom
# ... etc for all images

# Or save all at once
docker save -o all-images.tar \
  your-registry.com/synapse:v1.102.0-custom \
  your-registry.com/element-web:v1.11.50-custom \
  # ... list all images
```

**Step 4: Package Everything**

```bash
mkdir matrix-deployment-airgapped
cd matrix-deployment-airgapped

# Copy deployment manifests
cp -r /path/to/deployment/* .

# Copy Helm charts
mkdir helm-charts
cp /path/to/helm-charts/*.tgz helm-charts/

# Copy container images (if transferring via USB/etc)
mkdir images
cp /path/to/*.tar images/

# Create README
cat > README.txt <<EOF
Matrix/Synapse Air-Gapped Deployment Package

Contents:
- deployment/: Kubernetes manifests and configs
- helm-charts/: Offline Helm charts
- images/: Container images (load with docker load < image.tar)

Instructions:
1. Set up private registry on airgapped network
2. Load images: for f in images/*.tar; do docker load < $f; done
3. Push images to private registry
4. Install Helm charts from local files
5. Deploy using manifests in deployment/

See deployment/docs/ for detailed instructions.
EOF

# Create tarball
cd ..
tar czf matrix-deployment-airgapped.tar.gz matrix-deployment-airgapped/
```

### 6.2 Deployment Phase (Air-Gapped)

**Step 1: Transfer Package**
- Copy `matrix-deployment-airgapped.tar.gz` to airgapped environment
- Via USB drive, secure file transfer, etc.

**Step 2: Extract**

```bash
tar xzf matrix-deployment-airgapped.tar.gz
cd matrix-deployment-airgapped
```

**Step 3: Set Up Private Registry**

```bash
# Install Docker Registry on airgapped network
docker run -d -p 5000:5000 --restart=always --name registry registry:2
```

**Step 4: Load and Push Images**

```bash
# Load images from tar files
for IMAGE_TAR in images/*.tar; do
  docker load < $IMAGE_TAR
done

# Push to local registry
for IMAGE in $(docker images --format "{{.Repository}}:{{.Tag}}" | grep your-registry.com); do
  NEW_TAG="localhost:5000/$(echo $IMAGE | sed 's|your-registry.com/||')"
  docker tag $IMAGE $NEW_TAG
  docker push $NEW_TAG
done
```

**Step 5: Update Manifests**

```bash
# Replace registry in all manifests
find deployment/ -name "*.yaml" -exec sed -i 's|your-registry.com|localhost:5000|g' {} +
```

**Step 6: Deploy**

```bash
cd deployment
./scripts/deploy-all.sh
```

---

## 7. Image Vulnerability Scanning

### 7.1 Scanning Tools

**Trivy (Recommended):**

```bash
# Install
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh

# Scan image
trivy image matrixdotorg/synapse:v1.102.0

# Output formats
trivy image --format json --output results.json matrixdotorg/synapse:v1.102.0
trivy image --format sarif --output results.sarif matrixdotorg/synapse:v1.102.0
```

**Snyk:**

```bash
# Install
npm install -g snyk

# Authenticate
snyk auth

# Scan
snyk container test matrixdotorg/synapse:v1.102.0
```

**Docker Scout:**

```bash
# Scan
docker scout cves matrixdotorg/synapse:v1.102.0

# Detailed recommendations
docker scout recommendations matrixdotorg/synapse:v1.102.0
```

### 7.2 Automated Scanning in CI/CD

**GitHub Actions Example:**

```yaml
name: Build and Scan
on: [push]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3

    - name: Build Image
      run: docker build -t myimage:${{ github.sha }} .

    - name: Scan with Trivy
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: myimage:${{ github.sha }}
        format: 'sarif'
        output: 'trivy-results.sarif'
        severity: 'CRITICAL,HIGH'

    - name: Upload Scan Results
      uses: github/codeql-action/upload-sarif@v2
      with:
        sarif_file: 'trivy-results.sarif'

    - name: Fail on Critical Vulnerabilities
      run: |
        trivy image --severity CRITICAL --exit-code 1 myimage:${{ github.sha }}
```

### 7.3 Continuous Monitoring

**Harbor Integration:**
- Harbor has built-in Trivy scanning
- Automatically scans images on push
- Prevents pulling vulnerable images (policy enforcement)

---

## 8. Summary & Quick Reference

### 8.1 Quick Commands

**Pull and Mirror Image:**
```bash
docker pull matrixdotorg/synapse:v1.102.0
docker tag matrixdotorg/synapse:v1.102.0 your-registry.com/synapse:v1.102.0
docker push your-registry.com/synapse:v1.102.0
```

**Use Custom Image in Deployment:**
```yaml
containers:
- name: synapse
  image: your-registry.com/synapse:v1.102.0-custom
```

**Create Pull Secret:**
```bash
kubectl create secret docker-registry registry-secret \
  --docker-server=your-registry.com \
  --docker-username=admin \
  --docker-password=PASSWORD \
  --namespace=matrix
```

### 8.2 Image Update Strategy

**Version Pinning (Recommended):**
```yaml
image: matrixdotorg/synapse:v1.102.0  # Specific version
```

**Advantages:**
- Reproducible deployments
- Controlled upgrades
- Rollback capability

**Avoid:**
```yaml
image: matrixdotorg/synapse:latest  # DON'T USE IN PRODUCTION
```

**Update Process:**
1. Test new version in staging
2. Update image tag in manifests
3. Apply with `kubectl apply`
4. Monitor for issues
5. Rollback if needed: `kubectl rollout undo deployment/synapse-main`

---

**Document Version:** 1.0
**Last Updated:** November 10, 2025
**Maintained By:** Matrix/Synapse Production Deployment Team
