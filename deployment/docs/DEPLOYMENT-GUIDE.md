# Deployment Guide

Complete step-by-step guide for deploying the Matrix Synapse homeserver on Kubernetes.

---

## Prerequisites

Before starting, ensure you have:

✅ **Kubernetes cluster running** (21 nodes)
- 3 control plane nodes
- 18 worker nodes
- All nodes running Debian 12
- Kubernetes v1.26+

**Don't have Kubernetes yet?** Follow [`00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`](00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md) first.

✅ **Tools installed on your workstation:**
```bash
# Check kubectl
kubectl version --client

# Check helm
helm version

# Check cluster access
kubectl cluster-info
```

**→ Don't have these tools?** Follow [`00-WORKSTATION-SETUP.md`](00-WORKSTATION-SETUP.md) for complete installation instructions.

✅ **Configuration values prepared:**
- Domain name ready
- Storage classes identified
- Passwords generated
- All placeholder values replaced

**→ CRITICAL:** Review [`CONFIGURATION-CHECKLIST.md`](CONFIGURATION-CHECKLIST.md) for complete list of ALL values that must be replaced before deployment.

**Additional References:**
- [Configuration Reference](CONFIGURATION-REFERENCE.md) - Detailed explanation of every option
- [Scaling Guide](SCALING-GUIDE.md) - Infrastructure sizing for your scale

---

## Deployment Methods

Choose one:

| Method | Best For | Time Required |
|--------|----------|---------------|
| [Automated](#automated-deployment) | Quick deployment, first-time users | 30-45 minutes |
| [Manual](#manual-deployment) | Learning, custom setups, troubleshooting | 1-2 hours |

---

## Automated Deployment

The automated script handles everything in correct order.

### Step 1: Validate Configuration

```bash
cd deployment/

# Check configuration file exists
ls -l config/deployment.env

# Validate syntax
bash -n config/deployment.env

# Source to verify variables
source config/deployment.env
echo "Domain: $MATRIX_DOMAIN"
echo "Storage: $POSTGRES_STORAGE_CLASS"
```

**If errors:** Edit `config/deployment.env` and fix issues.

### Step 2: Run Deployment Script

```bash
./scripts/deploy-all.sh
```

**What happens:**

The script will:
1. ✅ Validate prerequisites (kubectl, helm installed)
2. ✅ Check cluster connectivity
3. ✅ Add Helm repositories
4. ✅ Deploy infrastructure (cert-manager, MetalLB, NGINX Ingress)
5. ✅ Deploy data layer (PostgreSQL, Redis, MinIO)
6. ✅ Deploy application (Synapse, Element Web, LiveKit)
7. ✅ Deploy monitoring (Prometheus, Grafana, Loki)
8. ✅ Configure routing and TLS
9. ✅ Validate deployment
10. ✅ Display next steps

**Expected time:** 30-45 minutes (mostly waiting for components to be ready)

### Step 3: Monitor Progress

Open a second terminal and watch pods starting:

```bash
watch kubectl get pods -A
```

**What you'll see:**
- Pods start in `Pending` → `ContainerCreating` → `Running`
- Some pods restart once during initialization (normal)
- Eventually all pods show `Running` with `READY` showing expected replicas

**Common during deployment:**
- PostgreSQL pods take 2-3 minutes to be ready
- MinIO pods may show `0/1` briefly (initializing)
- Some pods restart once (initialization, normal)

### Step 4: Verify Completion

Script will display:

```
✅ Deployment Complete!

Next steps:
1. Get load balancer IP: kubectl get svc -n ingress-nginx
2. Configure DNS: chat.example.com → <LOAD_BALANCER_IP>
3. Wait for TLS certificate (2-5 minutes)
4. Create admin user (command provided)
5. Access web interface: https://chat.example.com
```

---

## Manual Deployment

For complete control and understanding.

### Phase 1: Infrastructure Layer

This layer provides networking and TLS certificates.

#### Step 1.1: Create Namespaces

```bash
kubectl apply -f manifests/00-namespaces.yaml
```

**What this does:**
- Creates isolated namespaces for each component
- Namespaces: matrix, monitoring, ingress-nginx, cert-manager, etc.

**Verify:**
```bash
kubectl get namespaces
```

Should show all namespaces listed in `00-namespaces.yaml`.

#### Step 1.2: Add Helm Repositories

```bash
# Add all required Helm chart repositories
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add minio-operator https://operator.min.io
helm repo add metallb https://metallb.github.io/metallb
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add livekit https://helm.livekit.io
helm repo add jetstack https://charts.jetstack.io

# Update to get latest charts
helm repo update
```

**What this does:**
- Adds official chart repositories
- Updates local cache of available charts

**Verify:**
```bash
helm repo list
```

#### Step 1.3: Install cert-manager (TLS Certificates)

```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --values values/cert-manager-values.yaml \
  --wait
```

**What this does:**
- Installs cert-manager operator
- Enables automatic TLS certificate issuance from Let's Encrypt
- Handles certificate renewal

**Verify:**
```bash
kubectl get pods -n cert-manager
# All pods should be Running

kubectl get crd | grep cert-manager
# Should show cert-manager CustomResourceDefinitions
```

**Configuration:** See `values/cert-manager-values.yaml`
- Installs CRDs automatically
- Sets up webhook for certificate validation

#### Step 1.4: Install MetalLB (Load Balancer)

```bash
# Install MetalLB operator
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --values values/metallb-values.yaml \
  --wait

# Wait for MetalLB pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=metallb -n metallb-system --timeout=300s

# Configure IP address pool
kubectl apply -f manifests/03-metallb-config.yaml
```

**What this does:**
- Installs MetalLB in Layer 2 mode
- Provides LoadBalancer Service type support
- Allocates real IPs to Services

**Verify:**
```bash
kubectl get pods -n metallb-system
# controller and speaker pods should be Running

kubectl get ipaddresspools -n metallb-system
# Should show IP pool from manifests/03-metallb-config.yaml
```

**Configuration:**
- IP range defined in `manifests/03-metallb-config.yaml`
- Must not conflict with existing network IPs
- Typically 10-20 IPs for Services

#### Step 1.5: Install NGINX Ingress Controller

```bash
helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values values/nginx-ingress-values.yaml \
  --wait
```

**What this does:**
- Installs NGINX Ingress Controller
- Creates LoadBalancer Service (gets IP from MetalLB)
- Enables HTTP/HTTPS routing to backend services

**Verify:**
```bash
kubectl get pods -n ingress-nginx
# nginx-ingress-controller pods should be Running

kubectl get svc -n ingress-nginx
# Should show LoadBalancer Service with EXTERNAL-IP
```

**Get load balancer IP:**
```bash
kubectl get svc -n ingress-nginx nginx-ingress-ingress-nginx-controller
```

**Important:** Note the `EXTERNAL-IP` - you'll need this for DNS configuration.

**Configuration highlights** (`values/nginx-ingress-values.yaml`):
- `externalTrafficPolicy: Local` - Preserves client IP addresses
- Large body size limit (500MB) - For file uploads
- Connection timeouts tuned for long-polling

---

### Phase 2: Data Layer

This layer provides database, cache, and object storage.

#### Step 2.1: Install CloudNativePG Operator

```bash
helm upgrade --install cloudnativepg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --values values/cloudnativepg-values.yaml \
  --wait
```

**What this does:**
- Installs PostgreSQL operator
- Enables declarative PostgreSQL cluster management
- Provides automated backup and failover

**Verify:**
```bash
kubectl get pods -n cnpg-system
# cloudnativepg-operator pod should be Running
```

#### Step 2.2: Deploy PostgreSQL Cluster

```bash
kubectl apply -f manifests/01-postgresql-cluster.yaml

# Wait for cluster to be ready (takes 2-3 minutes)
kubectl wait --for=condition=ready cluster/synapse-postgres -n matrix --timeout=10m
```

**What this does:**
- Creates 3-node PostgreSQL cluster
  - 1 primary (handles writes)
  - 2 standby replicas (synchronous replication)
- Creates PgBouncer pooler (3 instances)
- Configures automated backups to MinIO

**Verify:**
```bash
# Check cluster status
kubectl get cluster -n matrix

# Should show:
# NAME               AGE   INSTANCES   READY   STATUS
# synapse-postgres   2m    3           3       Cluster in healthy state

# Check pods
kubectl get pods -n matrix -l cnpg.io/cluster=synapse-postgres

# Should show 3 PostgreSQL pods + 3 pooler pods
```

**Connection details:**
- **Via PgBouncer (recommended):** `synapse-postgres-pooler-rw.matrix.svc.cluster.local:5432`
- **Direct to primary:** `synapse-postgres-rw.matrix.svc.cluster.local:5432`

**Why PgBouncer?**
- Connection pooling reduces overhead
- Configured for Synapse's requirements (session mode)
- Better performance under load

See [`HA-ROUTING-GUIDE.md`](HA-ROUTING-GUIDE.md) for connection flow details.

#### Step 2.3: Install Redis (Synapse Instance)

```bash
helm upgrade --install redis-synapse bitnami/redis \
  --namespace matrix \
  --values values/redis-synapse-values.yaml \
  --wait
```

**What this does:**
- Creates Redis cluster with Sentinel
  - 1 master
  - 3 replicas
  - 3 Sentinel instances for monitoring
- Provides high-availability caching for Synapse

**Verify:**
```bash
kubectl get pods -n matrix -l app.kubernetes.io/name=redis

# Should show:
# - 1 master pod
# - 3 replica pods
# - 3 sentinel pods
```

**Connection details:**
- **Service:** `redis-synapse-master.matrix.svc.cluster.local:6379`
- **Note:** Service automatically points to current master (Sentinel manages)

#### Step 2.4: Install Redis (LiveKit Instance)

```bash
helm upgrade --install redis-livekit bitnami/redis \
  --namespace livekit \
  --values values/redis-livekit-values.yaml \
  --wait
```

**What this does:**
- Creates separate Redis cluster for LiveKit
- Prevents LiveKit issues from affecting Synapse
- LiveKit has native Sentinel support

**Why separate Redis?**
- Different access patterns
- Isolation: failures don't cascade
- Can scale independently

**Verify:**
```bash
kubectl get pods -n livekit -l app.kubernetes.io/name=redis
```

#### Step 2.5: Install MinIO (Object Storage)

```bash
# Install MinIO Operator
helm upgrade --install minio-operator minio-operator/operator \
  --namespace minio-operator \
  --values values/minio-operator-values.yaml \
  --wait

# Wait for operator to be ready
kubectl wait --for=condition=ready pod -l name=minio-operator -n minio-operator --timeout=300s

# Deploy MinIO Tenant (actual storage cluster)
kubectl apply -f manifests/02-minio-tenant.yaml

# Wait for tenant to be ready (takes 3-5 minutes)
kubectl wait --for=condition=ready tenant/synapse-media -n minio --timeout=10m
```

**What this does:**
- Creates 4-node MinIO cluster
- Configures erasure coding (EC:4)
- Can tolerate 1 node failure without data loss

**Verify:**
```bash
# Check tenant status
kubectl get tenant -n minio

# Check pods
kubectl get pods -n minio
# Should show 4 MinIO pods
```

**Connection details:**
- **S3 API endpoint:** `http://minio-api.minio.svc.cluster.local:9000`
- **Console (admin):** Port-forward to access web UI

**Access Console (optional):**
```bash
kubectl port-forward -n minio svc/synapse-media-console 9001:9001
# Open browser: http://localhost:9001
# Login with MinIO credentials from deployment.env
```

---

### Phase 3: Communication Layer

This layer provides TURN/STUN and video conferencing.

#### Step 3.1: Deploy coturn (TURN/STUN Servers)

```bash
# First, label nodes where coturn will run
kubectl label node <node-name-1> coturn=true
kubectl label node <node-name-2> coturn=true

# Deploy coturn
kubectl apply -f manifests/04-coturn.yaml
```

**What this does:**
- Deploys coturn as DaemonSet on labeled nodes
- Uses `hostNetwork: true` for direct IP access
- Provides TURN/STUN for NAT traversal in calls

**Why these nodes?**
- coturn needs real public IPs (not cluster IPs)
- `hostNetwork: true` binds to node's network interface
- Choose nodes with public IPs or proper firewall rules

**Verify:**
```bash
kubectl get pods -n coturn
# Should show 2 pods (one per labeled node)

kubectl get pods -n coturn -o wide
# Check NODE column - should be your labeled nodes
```

**Update Synapse configuration:**

In `manifests/05-synapse-main.yaml`, update TURN URIs with your node IPs:

```yaml
turn_uris:
  - "turn:<NODE1_IP>:3478?transport=udp"
  - "turn:<NODE1_IP>:3478?transport=tcp"
  - "turn:<NODE2_IP>:3478?transport=udp"
  - "turn:<NODE2_IP>:3478?transport=tcp"
```

Replace `<NODE1_IP>` and `<NODE2_IP>` with actual node IP addresses.

#### Step 3.2: Deploy LiveKit (Video SFU)

```bash
# Label nodes for LiveKit
kubectl label node <node-name-1> livekit=true
kubectl label node <node-name-2> livekit=true
kubectl label node <node-name-3> livekit=true
kubectl label node <node-name-4> livekit=true

# Install LiveKit
helm upgrade --install livekit livekit/livekit-server \
  --namespace livekit \
  --values values/livekit-values.yaml \
  --set kind=DaemonSet \
  --wait
```

**What this does:**
- Deploys LiveKit SFU for group video calls
- Uses `hostNetwork: true` for WebRTC
- Connects to Redis (LiveKit instance) for state

**Verify:**
```bash
kubectl get pods -n livekit -l app=livekit
# Should show 4 pods (one per labeled node)
```

---

### Phase 4: Application Layer

This is the Matrix homeserver and clients.

#### Step 4.1: Deploy Synapse Main Process

```bash
kubectl apply -f manifests/05-synapse-main.yaml

# Wait for main process to be ready
kubectl wait --for=condition=ready pod -l app=synapse,component=main -n matrix --timeout=5m
```

**What this does:**
- Deploys Synapse main process (coordinator)
- Creates ConfigMap with homeserver.yaml
- Connects to PostgreSQL, Redis, MinIO

**Verify:**
```bash
kubectl get pods -n matrix -l component=main
# Should show 1 pod Running

# Check logs
kubectl logs -n matrix -l component=main --tail=50
# Should show "Synapse now listening on TCP port 8008"
```

**Test health:**
```bash
kubectl exec -n matrix -l component=main -- curl -s http://localhost:8008/health
# Should return: {"status": "OK"}
```

#### Step 4.2: Deploy Synapse Workers

```bash
kubectl apply -f manifests/06-synapse-workers.yaml

# Wait for workers to be ready (takes 2-3 minutes)
kubectl wait --for=condition=ready pod -l app=synapse -n matrix --timeout=10m
```

**What this does:**
- Deploys Synapse workers across 4 StatefulSets (count varies by scale):
  - Sync workers (handle /sync requests)
  - Generic workers (handle API requests, media, federation receiver)
  - Federation senders (outbound federation)
  - Event persisters (database writes)
- Each worker connects to main process via HTTP replication

**📊 Worker Counts by Scale:**
- **100 CCU:** 2 sync, 2 generic, 2 federation, 2 event persisters (8 total)
- **20K CCU:** 18 sync, 8 generic, 8 federation, 4 event persisters (38 total)
- **Your scale:** See [SCALING-GUIDE.md](SCALING-GUIDE.md) Section 9.1 for exact worker counts

**Verify:**
```bash
# Check all workers running
kubectl get pods -n matrix -l app=synapse
# Should show 1 main + all workers (count varies by your scale)

# Check each worker type
kubectl get statefulset -n matrix
# Should show all StatefulSets with desired replicas
```

**Check worker registration:**
```bash
kubectl logs -n matrix synapse-main-xxx | grep "Finished setting up"
# Should show workers registered
```

**Worker architecture:**
See [`HA-ROUTING-GUIDE.md`](HA-ROUTING-GUIDE.md) for how workers distribute load.

#### Step 4.3: Deploy Element Web

```bash
kubectl apply -f manifests/07-element-web.yaml
```

**What this does:**
- Deploys Element Web client (3 replicas)
- Serves static JavaScript files
- Connects to Synapse via Ingress

**Verify:**
```bash
kubectl get pods -n matrix -l app=element-web
# Should show 3 pods Running
```

#### Step 4.4: Deploy Synapse Admin

```bash
kubectl apply -f manifests/08-synapse-admin.yaml
```

**What this does:**
- Deploys Synapse Admin UI (2 replicas)
- Provides web-based user/room management
- Connects to Synapse Admin API

**Verify:**
```bash
kubectl get pods -n matrix -l app=synapse-admin
# Should show 2 pods Running
```

#### Step 4.5: Deploy HAProxy Routing Layer

**IMPORTANT:** HAProxy provides intelligent routing to Synapse workers. Deploy this AFTER workers are running.

```bash
# Create HAProxy ConfigMap from configuration file
kubectl create configmap haproxy-config \
  --from-file=haproxy.cfg=config/haproxy.cfg \
  -n matrix

# Verify ConfigMap created
kubectl get configmap haproxy-config -n matrix
```

**What this ConfigMap contains:**
- HAProxy routing rules (sync workers vs generic workers)
- Health check configuration
- DNS service discovery settings
- Load balancing strategies (token-based hashing for sync, round-robin for generic)

```bash
# Deploy HAProxy pods
kubectl apply -f manifests/06-haproxy.yaml

# Wait for HAProxy to be ready
kubectl wait --for=condition=ready pod -l app=haproxy -n matrix --timeout=3m
```

**What this does:**
- Deploys HAProxy routing layer (2+ replicas for HA)
- Routes `/sync` requests to sync workers (with sticky sessions)
- Routes all other Matrix requests to generic workers
- Provides automatic fallback to main process if workers down
- Enables health-aware load balancing

**Verify HAProxy deployment:**
```bash
# Check HAProxy pods
kubectl get pods -n matrix -l app=haproxy
# Should show 2+ pods Running

# Check HAProxy service
kubectl get svc -n matrix haproxy
# Should show ClusterIP service on port 8008

# Test HAProxy health
kubectl exec -n matrix -l app=haproxy -- curl -f http://localhost:8404/stats
# Should return HAProxy stats page HTML
```

**Verify routing configuration:**
```bash
# Check HAProxy can reach sync workers
kubectl exec -n matrix -l app=haproxy -- curl -f http://synapse-sync-worker-0.synapse-sync-worker.matrix.svc.cluster.local:8083/_matrix/client/versions
# Should return: {"versions": ["r0.0.1", ...]}

# Check HAProxy can reach generic workers
kubectl exec -n matrix -l app=haproxy -- curl -f http://synapse-generic-worker-0.synapse-generic-worker.matrix.svc.cluster.local:8081/_matrix/client/versions
# Should return: {"versions": ["r0.0.1", ...]}
```

**Check HAProxy logs:**
```bash
kubectl logs -n matrix -l app=haproxy --tail=50
# Should show:
# - "Starting HAProxy"
# - DNS resolution for worker services
# - No errors about unreachable backends
```

**For detailed HAProxy architecture and routing patterns:**
See [`docs/HAPROXY-ARCHITECTURE.md`](HAPROXY-ARCHITECTURE.md)

---

### Phase 5: Routing Layer

This configures external access via Ingress (routes to HAProxy).

#### Step 5.1: Create ClusterIssuer (Let's Encrypt)

Before deploying Ingress, create ClusterIssuer for TLS:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: YOUR_EMAIL@example.com  # CHANGE THIS
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
```

**Replace `YOUR_EMAIL@example.com` with your actual email.**

**Verify:**
```bash
kubectl get clusterissuer
# Should show letsencrypt-prod with READY=True
```

#### Step 5.2: Deploy Ingress

```bash
kubectl apply -f manifests/09-ingress.yaml
```

**What this does:**
- Creates Ingress resource with routing rules
- Routes traffic based on URL path
- Requests TLS certificate from Let's Encrypt
- Configures load balancing to workers

**Verify:**
```bash
kubectl get ingress -n matrix
# Should show matrix-ingress

kubectl describe ingress matrix-ingress -n matrix
# Check routing rules are configured
```

**Check TLS certificate:**
```bash
kubectl get certificate -n matrix

# Initially shows:
# NAME         READY   SECRET            AGE
# matrix-tls   False   matrix-tls-secret 30s

# After 2-5 minutes:
# NAME         READY   SECRET            AGE
# matrix-tls   True    matrix-tls-secret 3m
```

**If certificate stuck:** See [Troubleshooting](#troubleshooting-certificate-issues) below.

---

### Phase 6: Monitoring Layer

#### Step 6.1: Install Prometheus Stack

```bash
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values/prometheus-stack-values.yaml \
  --wait
```

**What this does:**
- Installs Prometheus (metrics collection)
- Installs Grafana (visualization)
- Installs various exporters
- Creates ServiceMonitors for auto-discovery

**Verify:**
```bash
kubectl get pods -n monitoring
# Should show prometheus, grafana, and exporter pods
```

**Access Grafana:**
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open browser: http://localhost:3000
# Login: admin / <GRAFANA_ADMIN_PASSWORD from deployment.env>
```

#### Step 6.2: Install Loki (Logs)

```bash
helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --values values/loki-values.yaml \
  --wait
```

**What this does:**
- Installs Loki (log aggregation)
- Installs Promtail (log shipper on each node)
- Makes logs queryable in Grafana

**Verify:**
```bash
kubectl get pods -n monitoring -l app=loki
kubectl get pods -n monitoring -l app=promtail
```

**Access logs in Grafana:**
1. Open Grafana (http://localhost:3000)
2. Go to Explore
3. Select Loki datasource
4. Query logs

---

### Phase 7: Operational Automation

#### Step 7.1: Deploy Automation CronJobs

```bash
kubectl apply -f manifests/10-operational-automation.yaml
```

**What this does:**
- **S3 Media Cleanup** (daily): Removes local files already in MinIO
- **Database Maintenance** (weekly): Runs VACUUM ANALYZE
- **Worker Restart** (weekly): Rolling restart to mitigate memory leaks

**Verify:**
```bash
kubectl get cronjobs -n matrix
# Should show 3 CronJobs

# Check last execution
kubectl get jobs -n matrix --sort-by=.status.startTime
```

**Manual trigger (for testing):**
```bash
kubectl create job --from=cronjob/synapse-s3-cleanup test-cleanup -n matrix
kubectl logs -n matrix job/test-cleanup -f
```

---

## Post-Deployment Configuration

### Step 1: Configure DNS

Get load balancer IP:
```bash
kubectl get svc -n ingress-nginx nginx-ingress-ingress-nginx-controller
```

Add DNS A record:
```
chat.example.com.  300  IN  A  <LOAD_BALANCER_IP>
```

**Verify DNS:**
```bash
nslookup chat.example.com
# Should return your load balancer IP
```

### Step 2: Wait for TLS Certificate

```bash
kubectl get certificate -n matrix -w
# Watch until READY shows True (2-5 minutes)
```

### Step 3: Create Admin User

```bash
# Find Synapse main pod
SYNAPSE_POD=$(kubectl get pod -n matrix -l app=synapse,component=main -o jsonpath='{.items[0].metadata.name}')

# Create admin user
kubectl exec -n matrix $SYNAPSE_POD -- \
  register_new_matrix_user \
  -c /config/homeserver.yaml \
  -u admin \
  -p "YOUR_SECURE_PASSWORD" \
  -a \
  http://localhost:8008
```

**Save these credentials!** You'll need them to log in.

### Step 4: Test Access

**Element Web:**
```
https://chat.example.com
```

Login with:
- Homeserver: `https://chat.example.com`
- Username: `admin`
- Password: (from step 3)

**Synapse Admin:**
```
https://chat.example.com/admin
```

**Grafana:**
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# http://localhost:3000
# Login: admin / <GRAFANA_ADMIN_PASSWORD>
```

---

## Validation

### Test 1: User Registration

1. Open Element Web: `https://chat.example.com`
2. Click "Create Account"
3. Enter username and password
4. Should complete successfully

**If registration disabled:** Enable in `manifests/05-synapse-main.yaml`:
```yaml
enable_registration: true
```

### Test 2: Send Message

1. Create a new room
2. Send a message
3. Message should appear immediately
4. Check database:
```bash
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U synapse -d synapse -c "SELECT COUNT(*) FROM events;"
```

Should show count > 0.

### Test 3: Upload File

1. In Element Web, upload an image
2. Image should display in chat
3. Check MinIO:
```bash
kubectl exec -n minio synapse-media-pool-0-0 -- \
  mc ls local/synapse-media
```

Should show files.

### Test 4: Voice Call (1:1)

1. Start voice call with another user
2. Call should establish
3. Check coturn logs:
```bash
kubectl logs -n coturn -l app=coturn
# Should show TURN allocation
```

### Test 5: Monitoring

1. Open Grafana: http://localhost:3000
2. Import Synapse dashboard
3. Should show metrics (requests, events, etc.)

---

## Troubleshooting

### Certificate Issues

**Symptom:** Certificate stuck in `READY=False`

**Check:**
```bash
kubectl describe certificate matrix-tls -n matrix
# Look for error messages

kubectl get certificaterequest -n matrix
kubectl describe certificaterequest <name> -n matrix
```

**Common causes:**
1. DNS not propagated
2. Ingress not accessible
3. Let's Encrypt rate limit

**Solutions:**
1. Verify DNS: `nslookup chat.example.com`
2. Test Ingress: `curl -v http://<LOAD_BALANCER_IP>`
3. Use staging issuer first:
```bash
# Create staging issuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

# Update Ingress to use staging issuer
kubectl edit ingress matrix-ingress -n matrix
# Change: cert-manager.io/cluster-issuer: "letsencrypt-staging"
```

### Pod CrashLoopBackOff

**Symptom:** Pod keeps restarting

**Check logs:**
```bash
kubectl logs -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name> --previous
```

**Common causes:**
1. Configuration error
2. Resource limits too low
3. Dependencies not ready (database, etc.)

**Solutions:**
1. Check config: `kubectl describe pod <pod-name> -n <namespace>`
2. Increase resources: Edit deployment/statefulset
3. Check dependencies: `kubectl get pods -A`

### Database Connection Errors

**Symptom:** Synapse logs show "could not connect to server"

**Check PostgreSQL:**
```bash
kubectl get cluster -n matrix
# Should show: Cluster in healthy state

kubectl get pods -n matrix -l cnpg.io/cluster=synapse-postgres
# All pods should be Running
```

**Test connection:**
```bash
kubectl exec -n matrix synapse-postgres-1 -- \
  psql -U synapse -d synapse -c "SELECT 1;"
# Should return 1
```

**Check credentials:**
```bash
kubectl get secret synapse-postgres-credentials -n matrix -o yaml
```

### Workers Not Starting

**Symptom:** Worker pods stuck in Init or CrashLoop

**Check:**
```bash
kubectl describe pod synapse-sync-worker-0 -n matrix
# Look for events

kubectl logs synapse-sync-worker-0 -n matrix
```

**Common causes:**
1. Main process not ready
2. Redis not available
3. PostgreSQL not available

**Solutions:**
1. Verify main process: `kubectl get pods -n matrix -l component=main`
2. Verify Redis: `kubectl get pods -n matrix -l app.kubernetes.io/name=redis`
3. Check instance_map in `manifests/05-synapse-main.yaml`

---

## Next Steps

After successful deployment:

1. **Configure Grafana Dashboards**
   - Import Synapse dashboard from: https://github.com/element-hq/synapse/tree/develop/contrib/grafana
   - Import PostgreSQL dashboard (ID: 9628)
   - Import Redis dashboard (ID: 11835)

2. **Set Up Backups**
   - PostgreSQL backups automated via CloudNativePG
   - Verify backups working: `kubectl get backup -n matrix`
   - Test restore procedure

3. **Configure Federation** (Optional)
   - See [Main README](../README.md) → Optional Features → Federation
   - Requires DNS SRV records
   - Test with https://federationtester.matrix.org/

4. **Add Monitoring Alerts**
   - Configure Prometheus AlertManager
   - Set up notifications (email, Slack, etc.)
   - Create alert rules for critical conditions

5. **Review Security**
   - Rotate default passwords
   - Configure network policies
   - Review RBAC permissions
   - Enable audit logging

---

## Related Documentation

**Setup & Configuration:**
- [Workstation Setup](00-WORKSTATION-SETUP.md) - Install kubectl, helm, git
- [Configuration Checklist](CONFIGURATION-CHECKLIST.md) - **Complete list of values to replace**
- [Configuration Reference](CONFIGURATION-REFERENCE.md) - All settings explained
- [Scaling Guide](SCALING-GUIDE.md) - Infrastructure sizing for your scale

**Architecture & Routing:**
- [HAProxy Architecture](HAPROXY-ARCHITECTURE.md) - Intelligent routing layer
- [HA Routing Guide](HA-ROUTING-GUIDE.md) - How components connect

**Optional Components:**
- [Matrix Authentication Service](MATRIX-AUTHENTICATION-SERVICE.md) - Enterprise SSO with Keycloak

**Operations:**
- [Operations & Update Guide](OPERATIONS-UPDATE-GUIDE.md) - Update, scale, maintain
- [Container Images Guide](CONTAINER-IMAGES-AND-CUSTOMIZATION.md) - Custom images

**Main Overview:**
- [Main README](../README.md) - Overview and quick start

---

**Questions?** Check the troubleshooting section above, or refer to:
- Matrix community: https://matrix.to/#/#synapse:matrix.org
- Synapse docs: https://matrix-org.github.io/synapse/latest/
