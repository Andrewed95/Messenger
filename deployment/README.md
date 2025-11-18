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
├── config/                      ← Centralized Configuration Files
│   └── synapse/                 # Synapse homeserver.yaml + log.yaml
│
├── main-instance/               ← Phase 2: Main Matrix Instance
│   ├── 01-synapse/              # Synapse main process
│   ├── 02-workers/              # 5 worker types (synchrotron, generic, etc.)
│   ├── 03-haproxy/              # Intelligent load balancer
│   ├── 04-element-web/          # Web client interface
│   ├── 05-livekit/              # Video/voice calling (Helm reference)
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
└── docs/                        ← Comprehensive Guides
    ├── 00-WORKSTATION-SETUP.md
    ├── 00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md
    ├── DEPLOYMENT-GUIDE.md
    ├── SCALING-GUIDE.md
    ├── CONFIGURATION-REFERENCE.md
    ├── OPERATIONS-UPDATE-GUIDE.md
    ├── SECRETS-MANAGEMENT.md
    ├── HAPROXY-ARCHITECTURE.md
    ├── HA-ROUTING-GUIDE.md
    ├── ANTIVIRUS-GUIDE.md
    └── ... (more guides)
```

---

## 🚀 Quick Start Guide

### Prerequisites

**Infrastructure:**
- Kubernetes cluster (1.28+)
- Storage class for PVCs
- Domain name for your homeserver
- `kubectl` and `helm` installed

**Recommended Reading:**
- `docs/00-WORKSTATION-SETUP.md` - Set up local tools
- `docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md` - Set up K8s cluster
- `docs/SCALING-GUIDE.md` - Size your infrastructure

---

## 📋 Deployment Steps

### **Phase 1: Core Infrastructure** (HA Database, Storage, Networking)

**Deploy PostgreSQL Clusters:**
```bash
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

**1. Configure Synapse:**
```bash
# Edit configuration (REQUIRED before deploying)
# Update domain names, secrets, etc.
nano config/synapse/homeserver.yaml
```

**2. Deploy Synapse Main Process:**
```bash
kubectl apply -f main-instance/01-synapse/configmap.yaml
kubectl apply -f main-instance/01-synapse/secrets.yaml
kubectl apply -f main-instance/01-synapse/main-statefulset.yaml
kubectl apply -f main-instance/01-synapse/services.yaml

# Wait for Synapse main to be ready
kubectl wait --for=condition=Ready pod/synapse-main-0 -n matrix --timeout=600s
```

**3. Deploy Workers:**
```bash
kubectl apply -f main-instance/02-workers/synchrotron-deployment.yaml
kubectl apply -f main-instance/02-workers/generic-worker-deployment.yaml
kubectl apply -f main-instance/02-workers/media-repository-deployment.yaml
kubectl apply -f main-instance/02-workers/event-persister-deployment.yaml
kubectl apply -f main-instance/02-workers/federation-sender-deployment.yaml

# Wait for workers to be ready
kubectl wait --for=condition=Available deployment -l app.kubernetes.io/component=worker -n matrix --timeout=600s
```

**4. Deploy HAProxy (Load Balancer):**
```bash
kubectl apply -f main-instance/03-haproxy/deployment.yaml

# Wait for HAProxy to be ready
kubectl wait --for=condition=Available deployment/haproxy -n matrix --timeout=300s
```

**5. Deploy Clients:**
```bash
# Element Web
kubectl apply -f main-instance/04-element-web/deployment.yaml

# coturn (TURN/STUN)
kubectl apply -f main-instance/06-coturn/deployment.yaml

# Sygnal (Push notifications)
kubectl apply -f main-instance/07-sygnal/deployment.yaml

# key_vault (E2EE recovery)
kubectl apply -f main-instance/08-key-vault/deployment.yaml
```

**6. Deploy LiveKit (Optional - Video/Voice):**
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

**1. Deploy Sync System (PostgreSQL Replication):**
```bash
# Deploy sync system components
kubectl apply -f li-instance/04-sync-system/deployment.yaml

# Run replication setup (ONE TIME ONLY)
kubectl create job --from=job/sync-system-setup-replication \
  sync-setup-$(date +%s) -n matrix

# Wait for setup to complete
kubectl wait --for=condition=complete job/sync-setup-$(date +%s) -n matrix --timeout=300s

# Check replication status
kubectl logs job/sync-setup-$(date +%s) -n matrix
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

**1. Install Prometheus + Grafana:**
```bash
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

**1. Deploy ClamAV DaemonSet:**
```bash
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
- `config/synapse/homeserver.yaml`
- `main-instance/04-element-web/deployment.yaml`
- `li-instance/02-element-web-li/deployment.yaml`

### **5. Verify NetworkPolicies**

Check all NetworkPolicies are applied:
```bash
kubectl get networkpolicies -n matrix
# Should show 16+ policies
```

---

## 📊 Resource Requirements

### Minimum (100 CCU)
- **CPU**: 10 cores
- **Memory**: 30Gi
- **Storage**: 500Gi

### Medium (1K CCU)
- **CPU**: 20 cores
- **Memory**: 60Gi
- **Storage**: 2Ti

### Large (20K CCU)
- **CPU**: 40 cores
- **Memory**: 120Gi
- **Storage**: 10Ti

See `docs/SCALING-GUIDE.md` for detailed sizing.

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

## 📚 Documentation Reference

| Document | Purpose |
|----------|---------|
| `infrastructure/*/README.md` | Phase 1 component guides |
| `main-instance/*/README.md` | Phase 2 component guides |
| `li-instance/README.md` | Complete LI instance guide |
| `monitoring/README.md` | Monitoring stack guide |
| `antivirus/README.md` | Antivirus system guide |
| `docs/DEPLOYMENT-GUIDE.md` | Detailed deployment walkthrough |
| `docs/SCALING-GUIDE.md` | Infrastructure sizing guide |
| `docs/OPERATIONS-UPDATE-GUIDE.md` | Updates and maintenance |
| `docs/CONFIGURATION-REFERENCE.md` | All configuration options |
| `docs/SECRETS-MANAGEMENT.md` | Security and secrets |
| `docs/HAPROXY-ARCHITECTURE.md` | Routing architecture |
| `docs/ANTIVIRUS-GUIDE.md` | Antivirus implementation |

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
- Check replication status (see Phase 3 verification)
- Check sync system logs: `kubectl logs <sync-system-pod> -n matrix`
- See `li-instance/README.md` troubleshooting section

**Antivirus not scanning:**
- Check ClamAV is running: `kubectl get daemonset clamav -n matrix`
- Check Content Scanner connectivity: `kubectl logs <content-scanner-pod> -n matrix`
- See `antivirus/README.md` troubleshooting section

**For detailed troubleshooting, see component-specific README files.**

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

**Deployment Version**: 1.0
**Last Updated**: 2025-11-18
**Kubernetes**: 1.28+
**Synapse**: v1.119.0
