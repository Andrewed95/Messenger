# Service Configuration Guide

This guide explains how each service is configured in this deployment solution.

## Core Principle

**This solution handles ALL service configurations but assumes container images are pre-built.**

- ✅ Service configurations (ConfigMaps, Secrets, environment variables)
- ✅ Resource allocations (CPU, memory, storage)
- ✅ Network policies and security settings
- ✅ Integration between services
- ❌ Building or updating container images
- ❌ Dockerfile creation or maintenance

## Configuration Methods

### 1. ConfigMaps
Used for non-sensitive configuration data.

**Example Services:**
- **Synapse**: `main-instance/01-synapse/configmap.yaml` - homeserver.yaml configuration
- **HAProxy**: `main-instance/03-haproxy/deployment.yaml` - routing configuration
- **Redis**: `infrastructure/02-redis/redis-statefulset.yaml` - redis.conf settings
- **Element Web**: `main-instance/02-element-web/deployment.yaml` - config.json

### 2. Secrets
Used for sensitive data like passwords and API keys.

**Example Services:**
- **Synapse**: `main-instance/01-synapse/secrets.yaml` - database passwords, API keys
- **PostgreSQL**: CloudNativePG automatically creates secrets
- **key_vault**: `main-instance/08-key-vault/deployment.yaml` - Django secrets, RSA keys
- **LiveKit**: `main-instance/04-livekit/deployment.yaml` - API keys and secrets

### 3. Environment Variables
Injected at runtime from Secrets or ConfigMaps.

**Example:**
```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: synapse-secrets
        key: DB_PASSWORD
```

### 4. Init Containers with envsubst
For complex configurations requiring variable substitution.

**Used by:**
- **Synapse Main**: Substitutes ${DB_PASSWORD}, ${REDIS_PASSWORD}, etc. at startup
- **Synapse Workers**: Same substitution mechanism
- **LiveKit**: Substitutes configuration placeholders

**How it works:**
```yaml
initContainers:
  - name: generate-config
    command:
      - sh
      - -c
      - |
        envsubst < /config-template/homeserver.yaml > /config/homeserver.yaml
```

## Service-Specific Configuration

### Synapse (Matrix Homeserver)

**Files:**
- `main-instance/01-synapse/configmap.yaml` - Main configuration template
- `main-instance/01-synapse/secrets.yaml` - Sensitive data
- `main-instance/01-synapse/main-statefulset.yaml` - Runtime configuration

**Configurable Items:**
- Server name and public baseurl
- Database connection settings
- Redis connection settings
- S3/MinIO storage settings
- Federation settings
- Rate limiting
- Worker replication secrets
- E2EE key storage (key_vault) integration

### PostgreSQL (CloudNativePG)

**Files:**
- `infrastructure/01-postgresql/main-cluster.yaml` - Main cluster configuration
- `infrastructure/01-postgresql/li-cluster.yaml` - LI cluster configuration

**Configurable Items:**
- Number of instances (HA replicas)
- Storage size
- PostgreSQL parameters (shared_buffers, work_mem, etc.)
- Backup schedules and retention
- Connection pooling settings

### Redis Sentinel

**Files:**
- `infrastructure/02-redis/redis-statefulset.yaml` - Redis and Sentinel configuration
- `infrastructure/02-redis/redis-secret.yaml` - Password configuration

**Configurable Items:**
- Number of replicas
- Memory limits
- Persistence settings
- Sentinel quorum
- Failover timeouts

### MinIO (S3-Compatible Storage)

**Files:**
- `infrastructure/03-minio/tenant.yaml` - MinIO Tenant configuration
- `infrastructure/03-minio/secrets.yaml` - Access credentials

**Configurable Items:**
- Number of servers
- Volumes per server
- Storage size
- Erasure coding settings
- Bucket creation
- Access policies

### HAProxy

**Files:**
- `main-instance/03-haproxy/deployment.yaml` - Contains embedded configuration

**Configurable Items:**
- Worker routing maps
- Health check intervals
- Timeout settings
- Load balancing algorithms
- Sticky sessions

### Element Web

**Files:**
- `main-instance/02-element-web/deployment.yaml` - Contains config.json

**Configurable Items:**
- Homeserver URL
- Identity server settings
- Feature flags
- Branding and themes
- Jitsi integration

### LiveKit (WebRTC)

**Files:**
- `main-instance/04-livekit/deployment.yaml` - Configuration template

**Configurable Items:**
- RTC port ranges
- TURN/STUN settings
- Redis connection
- API keys
- Room settings
- Bandwidth limits

### ClamAV (Antivirus)

**Files:**
- `antivirus/01-clamav/deployment.yaml` - ClamAV configuration
- `antivirus/02-scan-workers/deployment.yaml` - Scanner configuration

**Configurable Items:**
- Update frequency
- Scan limits
- Memory settings
- Network bindings

### key_vault (E2EE Recovery)

**Files:**
- `main-instance/08-key-vault/deployment.yaml` - Django settings and secrets

**Configurable Items:**
- Database connection
- RSA encryption keys
- API authentication
- Django settings

**IMPORTANT:** You must provide a pre-built key_vault Django application image.

## Image Configuration

All container images are specified in deployment files and can be overridden.

**Central reference:** `values/images.yaml` - Documents all image URLs

**To change an image:**
1. Find the deployment file for the service
2. Update the `image:` field
3. Ensure `imagePullPolicy` is appropriate

**Example:**
```yaml
containers:
  - name: synapse
    image: matrixdotorg/synapse:v1.119.0  # Change this to your image
    imagePullPolicy: IfNotPresent
```

## Configuration Workflow

### Before Deployment

1. **Review all CHANGEME placeholders:**
   ```bash
   grep -r "CHANGEME" deployment/ --include="*.yaml"
   ```

2. **Update domain names:**
   - Replace `matrix.example.com` with your domain
   - Update in Ingress resources and configurations

3. **Generate secure values:**
   ```bash
   # Passwords
   openssl rand -base64 32

   # API keys
   openssl rand -hex 32

   # RSA keys
   openssl genrsa -out private.pem 2048
   ```

4. **Configure images:**
   - Review `values/images.yaml`
   - Update image URLs if using private registry
   - Provide custom images (like key_vault)

### During Deployment

1. **Apply configurations in order:**
   - Infrastructure first (PostgreSQL, Redis, MinIO)
   - Core services (Synapse, HAProxy)
   - Auxiliary services (Element, LiveKit, etc.)

2. **Verify configurations:**
   ```bash
   # Check if configs are loaded
   kubectl get configmaps -n matrix
   kubectl get secrets -n matrix
   ```

3. **Monitor init containers:**
   ```bash
   kubectl logs <pod> -c <init-container> -n matrix
   ```

### After Deployment

1. **Verify service configurations:**
   ```bash
   # Check Synapse config
   kubectl exec -it synapse-main-0 -n matrix -- cat /config/homeserver.yaml

   # Check Redis config
   kubectl exec -it redis-0 -n matrix -- redis-cli CONFIG GET "*"
   ```

2. **Update configurations:**
   - Edit ConfigMap/Secret
   - Restart pods to pick up changes
   ```bash
   kubectl rollout restart deployment/<name> -n matrix
   ```

## Troubleshooting Configuration Issues

### Common Problems

1. **Variable not substituted:**
   - Check if init container ran successfully
   - Verify environment variables are set
   - Check envsubst command syntax

2. **Service can't connect:**
   - Verify DNS names match service names
   - Check NetworkPolicies allow traffic
   - Verify credentials in Secrets

3. **Configuration not loaded:**
   - Check volume mounts are correct
   - Verify ConfigMap/Secret exists
   - Check file paths in containers

### Debug Commands

```bash
# View actual configuration in pod
kubectl exec -it <pod> -n matrix -- cat /path/to/config

# Check environment variables
kubectl exec -it <pod> -n matrix -- env | grep <VAR>

# View init container logs
kubectl logs <pod> -c <init-container> -n matrix

# Describe pod for events
kubectl describe pod <pod> -n matrix
```

## Summary

This solution provides comprehensive configuration management for all services while maintaining the principle that container images are provided externally. Every aspect of service configuration is handled through Kubernetes-native mechanisms (ConfigMaps, Secrets, environment variables) with proper templating where needed.