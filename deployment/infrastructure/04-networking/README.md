# Networking Infrastructure

## Overview

This directory contains networking configuration for ingress routing and TLS management.

**Components:**
1. **Ingress Controller** - HTTP/HTTPS routing
2. **Cert-Manager** - Automatic TLS certificate management

**Note:** Network isolation is the organization's responsibility per CLAUDE.md section 7.4. This solution does not implement network-level isolation. The organization must provide a private network or appropriate access controls to isolate the LI instance.

## Architecture

### Traffic Flow

```
┌─────────────────────────────────────────────────────────────┐
│                       Internet                               │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
                  ┌──────────────────┐
                  │  NGINX Ingress   │
                  │   Controller     │
                  │   (NodePort)     │
                  └────────┬─────────┘
                           │
         ┌─────────────────┴─────────────────┐
         │                                   │
         ▼                                   ▼
┌─────────────────┐               ┌─────────────────┐
│  Main Instance  │               │   LI Instance   │
│                 │               │   (Separate     │
│ - matrix.ex.com │               │    network)     │
│ - chat.ex.com   │               │                 │
│ - admin.ex.com  │               │ - chat-li.ex.com│
│ - grafana.ex.com│               │ - admin-li.ex.com│
│                 │               │ - keyvault.ex.com│
│                 │               │ - matrix.ex.com │
│                 │               │   (DNS override)|
└─────────────────┘               └─────────────────┘
```

### Required Access Paths

The following connectivity must be available (organization ensures this):

**Main Instance:**
- Synapse → PostgreSQL, Redis, MinIO
- Synapse main → key_vault (for storing recovery keys)
- LiveKit → Redis
- All services → DNS resolution

**LI Instance:**
- Synapse LI → LI PostgreSQL (replicated from main)
- Synapse LI → Main MinIO (shared media access per CLAUDE.md 7.5)
- All LI services run on single server (CLAUDE.md 7.1)

**Cross-Instance:**
- Database sync: Main PostgreSQL → LI PostgreSQL
- Recovery keys: Synapse main → key_vault (write)
- Media: Synapse LI → Main MinIO (read)

## Components

### 1. Ingress Controller (ingress-install.yaml)

**NGINX Ingress Controller**

**Why NGINX:**
- Mature and stable
- High performance
- WebSocket support (required for Matrix sync)
- Long timeout support (for /sync long-polling)
- Well documented

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

### 2. Cert-Manager (cert-manager-install.yaml)

**Automatic TLS Certificate Management**

**ClusterIssuers:**
1. **letsencrypt-prod** - Production Let's Encrypt certificates (default for initial deployment)
2. **letsencrypt-staging** - Staging certificates (for testing, higher rate limits)
3. **selfsigned** - Self-signed certificates (fallback only)

**Per CLAUDE.md 4.5:** Initial deployment uses Let's Encrypt with cert-manager.
Let's Encrypt certificates are valid for 90 days.
Certificate renewal after deployment is the organization's responsibility.

**Installation:**

**WHERE:** Run from your **management node**

```bash
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

## Deployment

**WHERE:** Run all deployment commands from your **management node**

**WORKING DIRECTORY:** `deployment/infrastructure/04-networking/`

### Step 1: Install Ingress Controller

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

### Step 2: Install Cert-Manager

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

# Test certificate creation (optional)
kubectl get certificate -n matrix
```

## Validation

**WHERE:** Run all validation commands from your **management node**

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
# Get ingress IP (for NodePort, use node IP)
kubectl get nodes -o wide

# Test HTTP (replace NODE_IP with actual node IP)
curl -H "Host: test.example.com" http://NODE_IP:30080/
```

### Test Cert-Manager

```bash
# Check certificate status
kubectl get certificate -n matrix

# Describe for details
kubectl describe certificate <cert-name> -n matrix

# Check if secret created
kubectl get secret <cert-name>-tls -n matrix

# View certificate details
kubectl get secret <cert-name>-tls -n matrix -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

## Troubleshooting

**WHERE:** Run all troubleshooting commands from your **management node**

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
- DNS not pointing to ingress IP

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

## TLS Best Practices

**DO:**
- Use TLSv1.2 minimum (prefer TLSv1.3)
- Monitor certificate expiration
- Use strong ciphers only
- Test with Let's Encrypt staging before production

**DON'T:**
- Use self-signed in production (unless internal/isolated)
- Allow SSLv3, TLS1.0, TLS1.1
- Ignore expiration warnings

## Monitoring

**WHERE:** Run all monitoring commands from your **management node**

### Ingress Metrics

**Prometheus Metrics:**
- `nginx_ingress_controller_requests` - Request count
- `nginx_ingress_controller_request_duration_seconds` - Latency
- `nginx_ingress_controller_config_last_reload_successful` - Config status

**Grafana Dashboard:**
- Import dashboard ID: 9614 (NGINX Ingress Controller)

### Certificate Expiration Monitoring

**PromQL Query** (monitor in Grafana):
```promql
# Days until certificate expiration
(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400
```

## Scaling Considerations

| CCU Range | Ingress Replicas | Notes |
|-----------|------------------|-------|
| 100 | 1 | Single ingress pod OK |
| 1,000 | 2 | Add redundancy |
| 5,000 | 3 | Distribute across nodes |
| 10,000 | 5 | Monitor conntrack table |
| 20,000 | 7+ | Consider node-local ingress |

## References

- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [Cert-Manager Documentation](https://cert-manager.io/docs/)
