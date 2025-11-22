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
```bash
# Generate secure passwords
openssl rand -base64 32

# Generate Django secret key
python3 -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'

# Generate RSA key for key_vault
openssl genrsa -out private.pem 2048
```

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

### 4. Replication Status
```bash
# Check LI replication lag
kubectl exec -it matrix-postgresql-li-1 -n matrix -- psql -U synapse_li -d matrix_li -c "
SELECT subname, pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, received_lsn)) AS lag
FROM pg_stat_subscription;"
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