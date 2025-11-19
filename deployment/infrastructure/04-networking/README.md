# Networking Infrastructure

## Overview

This directory contains networking configuration for security, ingress, and TLS management.

**Components:**
1. **NetworkPolicies** - Zero-trust security isolation
2. **Ingress Controller** - HTTP/HTTPS routing
3. **Cert-Manager** - Automatic TLS certificate management

## Architecture

### Zero-Trust Security Model

**Default Deny All** → Explicitly allow required traffic only

```
┌──────────────────────────────────────────────┐
│  Default: ALL traffic denied                 │
└──────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────┐
│  NetworkPolicies define allowed paths:       │
│  ✓ Synapse → PostgreSQL, Redis, MinIO       │
│  ✓ Synapse → key_vault (LI)                 │
│  ✓ key_vault ⇄ PostgreSQL only              │
│  ✓ LI Instance → LI PostgreSQL only         │
│  ✗ LI Instance ⇏ Main resources             │
│  ✗ key_vault ⇏ External access              │
└──────────────────────────────────────────────┘
```

### Critical Security Policies

**1. key_vault Isolation** (MOST IMPORTANT for LI compliance)
- ONLY accessible from Synapse main instance
- Can ONLY talk to PostgreSQL and Redis
- CANNOT be accessed from LI instance
- CANNOT be accessed from external networks

**2. LI Instance Isolation**
- CANNOT access main instance PostgreSQL
- CANNOT access main instance resources
- Can ONLY access LI PostgreSQL
- Can ONLY access LI MinIO bucket

**3. Database Access Control**
- Each database has explicit allow list
- No default access
- Separate policies for main and LI PostgreSQL

## Components

### 1. NetworkPolicies (networkpolicies.yaml)

**Total: 13 NetworkPolicy objects**

#### Global Policies

1. **default-deny-all**
   - Denies all ingress and egress by default
   - Foundation of zero-trust model

2. **allow-dns**
   - Allows all pods to resolve DNS
   - Required for service discovery

#### Database Policies

3. **postgresql-access**
   - Allows: Synapse main, key_vault
   - Blocks: LI instance, external access
   - Ports: 5432 (PostgreSQL), 8000 (metrics)

4. **postgresql-li-access**
   - Allows: Synapse LI, sync system
   - Blocks: Main instance, external access
   - Ensures LI data separation

#### Cache Policies

5. **redis-access**
   - Allows: Synapse, LiveKit, key_vault
   - Ports: 6379 (Redis), 26379 (Sentinel)
   - Enables worker replication and sessions

#### Storage Policies

6. **minio-access**
   - Allows: Synapse, PostgreSQL, sync system
   - Ports: 9000 (S3 API), 9090 (Console)
   - Media storage and backups

#### Critical Isolation Policies

7. **key-vault-isolation** ⭐ CRITICAL
   - Ingress: ONLY from Synapse main
   - Egress: ONLY to PostgreSQL and Redis
   - Prevents unauthorized key access
   - Core LI compliance requirement

8. **li-instance-isolation** ⭐ IMPORTANT
   - Prevents LI from accessing main resources
   - Ensures data separation
   - Admin access only via ingress

#### Application Policies

9. **synapse-main-egress**
   - Broad egress for federation
   - Access to all internal services
   - HTTPS to external Matrix servers

10. **allow-from-ingress**
    - Pods labeled `app.kubernetes.io/expose: "true"`
    - Allows ingress controller access

11. **allow-prometheus-scraping**
    - Pods labeled `prometheus.io/scrape: "true"`
    - Allows metrics collection

### 2. Ingress Controller (ingress-install.yaml)

**NGINX Ingress Controller**

**Why NGINX:**
- ✅ Mature and stable
- ✅ High performance
- ✅ WebSocket support (required for Matrix sync)
- ✅ Long timeout support
- ✅ Well documented

**Installation:**

**WHERE:** Run from your **management node**

```bash
# For bare metal/OVH (NodePort)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/baremetal/deploy.yaml

# Verify installation
kubectl wait --for=condition=Available deployment/ingress-nginx-controller -n ingress-nginx --timeout=5m
```

**Configuration:**
- Client body size: 100MB (media uploads)
- Timeouts: 600s (long-lived Matrix sync)
- WebSocket: Enabled
- TLS: TLSv1.2, TLSv1.3 only

### 3. Cert-Manager (cert-manager-install.yaml)

**Automatic TLS Certificate Management**

**Issuers:**
1. **letsencrypt-prod** - Production certificates
2. **letsencrypt-staging** - Testing (higher rate limits)
3. **selfsigned** - Air-gapped deployments

**Installation:**

**WHERE:** Run from your **management node**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Verify installation
kubectl get pods -n cert-manager

# Create ClusterIssuers
kubectl apply -f cert-manager-install.yaml
```

## Deployment

**WHERE:** Run all deployment commands from your **management node**

**WORKING DIRECTORY:** `deployment/infrastructure/04-networking/`

### Prerequisites

1. **Kubernetes cluster** with network plugin that supports NetworkPolicies
   - Calico (recommended)
   - Cilium
   - Weave Net
   - **NOT** Flannel (no NetworkPolicy support)

2. **Check network plugin:**
```bash
kubectl get pods -n kube-system | grep -E "calico|cilium|weave"
```

### Step 1: Apply NetworkPolicies

```bash
kubectl apply -f networkpolicies.yaml
```

**Verification:**
```bash
# List all NetworkPolicies
kubectl get networkpolicies -n matrix

# Describe specific policy
kubectl describe networkpolicy key-vault-isolation -n matrix
```

### Step 2: Install Ingress Controller

```bash
# Install NGINX Ingress
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/baremetal/deploy.yaml

# Wait for ready
kubectl wait --for=condition=Available deployment/ingress-nginx-controller -n ingress-nginx --timeout=5m

# Apply custom configuration
kubectl apply -f ingress-install.yaml
```

**Verification:**
```bash
# Check ingress controller
kubectl get pods -n ingress-nginx

# Check service
kubectl get svc -n ingress-nginx
```

Expected: Service type NodePort with ports 80:30080, 443:30443

### Step 3: Install Cert-Manager

**WHAT:** Install automated TLS certificate management

**HOW:** Edit `cert-manager-install.yaml` to change email address, then apply:

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Wait for pods
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=5m

# Edit cert-manager-install.yaml - change email
# Then apply ClusterIssuers
kubectl apply -f cert-manager-install.yaml
```

**Verification:**
```bash
# Check cert-manager pods
kubectl get pods -n cert-manager

# Check ClusterIssuers
kubectl get clusterissuer

# Test certificate creation
kubectl get certificate test-certificate -n matrix
kubectl describe certificate test-certificate -n matrix
```

## Validation

**WHERE:** Run all validation commands from your **management node**

### Test NetworkPolicies

**Test 1: key_vault isolation**
```bash
# Should SUCCEED (from Synapse main)
kubectl run test-synapse --rm -it --image=curlimages/curl \
  --labels="app.kubernetes.io/name=synapse,matrix.instance=main" \
  -n matrix -- curl http://key-vault:8000/health

# Should FAIL (from random pod)
kubectl run test-random --rm -it --image=curlimages/curl \
  -n matrix -- curl http://key-vault:8000/health --max-time 5
```

Expected: First succeeds, second times out (blocked by NetworkPolicy)

**Test 2: LI instance isolation**
```bash
# Should FAIL (LI trying to access main PostgreSQL)
kubectl run test-li --rm -it --image=postgres:16 \
  --labels="matrix.instance=li" \
  -n matrix -- psql -h matrix-postgresql-rw -U postgres --command "SELECT 1"
```

Expected: Connection timeout/refused

**Test 3: PostgreSQL access control**
```bash
# Should SUCCEED (Synapse accessing PostgreSQL)
kubectl run test-synapse-db --rm -it --image=postgres:16 \
  --labels="app.kubernetes.io/name=synapse,matrix.instance=main" \
  -n matrix -- psql -h matrix-postgresql-rw -U synapse -d matrix --command "SELECT version();"
```

Expected: Success, shows PostgreSQL version

### Test Ingress

**Create test ingress:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  namespace: matrix
spec:
  ingressClassName: nginx
  rules:
    - host: test.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: test-service
                port:
                  number: 80
```

**Test:**
```bash
# Get ingress IP
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Test HTTP
curl -H "Host: test.example.com" http://$INGRESS_IP/
```

### Test Cert-Manager

```bash
# Check certificate status
kubectl get certificate -n matrix

# Describe for details
kubectl describe certificate test-certificate -n matrix

# Check if secret created
kubectl get secret test-tls -n matrix

# View certificate
kubectl get secret test-tls -n matrix -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

## Troubleshooting

**WHERE:** Run all troubleshooting commands from your **management node**

### NetworkPolicies Not Working

**Problem:** Traffic still allowed when it should be blocked

**Diagnosis:**
```bash
# Check if network plugin supports NetworkPolicies
kubectl get pods -n kube-system | grep -E "calico|cilium|weave"

# Check NetworkPolicy exists
kubectl get networkpolicy -n matrix

# Describe policy
kubectl describe networkpolicy <policy-name> -n matrix
```

**Common Causes:**
- Flannel CNI (doesn't support NetworkPolicies)
- Misspelled labels in selectors
- Policy not applied

**Solution:**
- Use Calico/Cilium/Weave instead of Flannel
- Verify label selectors match pod labels
- Re-apply policies

### Ingress Not Routing Traffic

**Problem:** 404 or connection refused

**Diagnosis:**
```bash
# Check ingress controller pods
kubectl get pods -n ingress-nginx

# Check ingress resource
kubectl get ingress -n matrix

# Describe ingress
kubectl describe ingress <ingress-name> -n matrix

# Check controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller
```

**Common Causes:**
- Wrong ingressClassName
- Service doesn't exist
- Wrong backend port

### Cert-Manager Not Issuing Certificates

**Problem:** Certificate stuck in "False" Ready state

**Diagnosis:**
```bash
# Check certificate
kubectl get certificate -n matrix

# Describe for detailed error
kubectl describe certificate <cert-name> -n matrix

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Check order and challenge
kubectl get order,challenge -n matrix
```

**Common Causes:**
- Invalid email in ClusterIssuer
- DNS not pointing to ingress IP
- Rate limit hit (use staging for testing)
- Firewall blocking port 80 (HTTP-01 challenge)

## Air-Gapped Deployment

For air-gapped environments (after initial setup):

**WHERE:** Pre-pull images on a machine with internet access, then transfer to cluster nodes

**1. Pre-pull Images:**
```bash
# NGINX Ingress
docker pull registry.k8s.io/ingress-nginx/controller:v1.11.1

# Cert-Manager
docker pull quay.io/jetstack/cert-manager-controller:v1.14.0
docker pull quay.io/jetstack/cert-manager-webhook:v1.14.0
docker pull quay.io/jetstack/cert-manager-cainjector:v1.14.0
```

**2. Use Self-Signed Certificates:**
```yaml
# Use selfsigned ClusterIssuer
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: matrix-tls
spec:
  secretName: matrix-tls
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
  commonName: matrix.example.com
  dnsNames:
    - matrix.example.com
    - "*.matrix.example.com"
```

**3. Import Organization CA:**
- Generate certificates using org's CA
- Create TLS secrets manually
- Skip cert-manager if using external PKI

## Security Best Practices

### 1. NetworkPolicy Guidelines

✅ **DO:**
- Start with default-deny-all
- Explicitly allow only required traffic
- Use specific port numbers
- Label pods consistently
- Test policies before production

❌ **DON'T:**
- Allow broad namespace access
- Use wildcards in selectors
- Skip testing
- Leave policies undefined

### 2. key_vault Protection

**CRITICAL:** This is the most important security policy

✅ **Ensure:**
- Only Synapse main can access
- No external network access
- NetworkPolicy always applied
- Regular audit of access logs

🚨 **Monitor:**

**Note:** Regularly verify key_vault security from your management node

```bash
# Check key_vault access logs
kubectl logs -n matrix deployment/key-vault | grep "LI:"

# Verify NetworkPolicy is active
kubectl get networkpolicy key-vault-isolation -n matrix
```

### 3. LI Instance Separation

✅ **Ensure:**
- Separate PostgreSQL cluster
- Separate namespace labels
- NetworkPolicy blocks main access
- Regular compliance audits

### 4. TLS Best Practices

✅ **DO:**
- Use TLSv1.2 minimum (prefer TLSv1.3)
- Rotate certificates before expiry
- Monitor certificate expiration
- Use strong ciphers only

❌ **DON'T:**
- Use self-signed in production (unless air-gapped)
- Allow SSLv3, TLS1.0, TLS1.1
- Ignore expiration warnings

## Monitoring

**WHERE:** Run all monitoring commands from your **management node**

### NetworkPolicy Compliance

**Tools:**
- **Cilium Hubble** - Visual network flow monitoring
- **Calico Enterprise** - Policy visualization

**Manual Verification:**

**Note:** These commands test network connectivity to verify policies are working

```bash
# Test connectivity matrix
for POD in synapse key-vault postgresql; do
  echo "Testing $POD..."
  kubectl exec -n matrix $POD -- curl -s -m 2 http://key-vault:8000/health || echo "Blocked ✓"
done
```

### Ingress Metrics

**Prometheus Metrics:**
- `nginx_ingress_controller_requests` - Request count
- `nginx_ingress_controller_request_duration_seconds` - Latency
- `nginx_ingress_controller_config_last_reload_successful` - Config status

**Grafana Dashboard:**
- Import dashboard ID: 9614 (NGINX Ingress Controller)

### Certificate Expiration

**Prometheus Alert:**
```yaml
- alert: CertificateExpiringSoon
  expr: certmanager_certificate_expiration_timestamp_seconds - time() < (7 * 24 * 3600)
  for: 1h
  labels:
    severity: warning
  annotations:
    summary: "Certificate {{ $labels.name }} expiring in < "
```

## Scaling Considerations

| CCU Range | Ingress Replicas | NetworkPolicy Impact | Notes |
|-----------|------------------|----------------------|-------|
| 100 | 1 | Minimal | Single ingress pod OK |
| 1,000 | 2 | Low | Add redundancy |
| 5,000 | 3 | Medium | Distribute across nodes |
| 10,000 | 5 | Medium | Monitor conntrack table |
| 20,000 | 7+ | High | Consider node-local ingress |

**Note:** NetworkPolicies have minimal performance impact with modern CNIs (Calico, Cilium)

## References

- [Kubernetes NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [Cert-Manager Documentation](https://cert-manager.io/docs/)
- [Calico NetworkPolicy](https://docs.tigera.io/calico/latest/network-policy/)
