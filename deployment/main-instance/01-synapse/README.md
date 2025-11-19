# Synapse Main Instance Deployment

This directory contains the Kubernetes manifests for deploying the Synapse homeserver main process with full production configuration including LI (Lawful Intercept) capabilities.

## Architecture

The Synapse deployment consists of:

1. **Main Process** (`main-statefulset.yaml`): Single-replica StatefulSet running the core Synapse homeserver
2. **Workers** (separate directory): Horizontally scalable worker processes for handling client requests
3. **Configuration** (`configmap.yaml`): Complete homeserver.yaml and log.yaml configuration
4. **Secrets** (`secrets.yaml`): All sensitive credentials and keys
5. **Services** (`services.yaml`): Network endpoints for client, federation, and metrics

## Components

### 1. ConfigMap (`configmap.yaml`)

Contains two configuration files:
- **homeserver.yaml**: Complete Synapse configuration with:
  - PostgreSQL database (CloudNativePG integration)
  - Redis cache and worker replication
  - MinIO S3 storage for media files
  - **LI compliance**: `redaction_retention_period: null` (infinite retention)
  - Recovery key module integration with key_vault
  - Worker support (instance_map, stream_writers)
  - Federation, TURN, push notifications
  - Production rate limiting and performance tuning

- **log.yaml**: Structured logging configuration for Kubernetes

### 2. Secrets (`secrets.yaml`)

Three Secret objects containing:
- **synapse-secrets**: Core Synapse credentials
  - Database password
  - Redis password
  - S3/MinIO credentials
  - Replication secret (for workers)
  - Macaroon, registration, form secrets
  - TURN shared secret
  - key_vault API key
  - Synapse signing key

- **synapse-db-credentials**: Database connection details
- **synapse-s3-credentials**: S3/MinIO connection details

**CRITICAL**: Replace all `CHANGEME_*` values before deployment!

Generate secure secrets:

**WHERE:** Run these commands on your **management node**

```bash
# Generate random secrets
openssl rand -base64 32

# Generate Synapse signing key
docker run -it --rm -v $(pwd):/data matrixdotorg/synapse:v1.119.0 generate
```

### 3. Main StatefulSet (`main-statefulset.yaml`)

Single-replica StatefulSet for the main Synapse process:

**Features**:
- Runs as non-root user (991:991)
- Init containers for dependency checks (PostgreSQL, Redis)
- Config generation with environment variable substitution
- 100Gi persistent volume for data
- Health, readiness, and startup probes
- Resource limits: 2-4Gi memory, 1-2 CPU cores
- PodDisruptionBudget to ensure availability

**Ports**:
- 8008: Client and Federation API
- 9093: Replication endpoint (workers)
- 9090: Prometheus metrics

**Volumes**:
- `/data`: Persistent storage (media_store, database files)
- `/config`: Generated configuration files
- `/tmp`: Temporary files (emptyDir)

### 4. Services (`services.yaml`)

Four Service objects:

1. **synapse-main** (Headless): For StatefulSet stable network identity
2. **synapse-client**: Client API endpoint (port 8008)
3. **synapse-federation**: Federation API endpoint (ports 8008, 8448)
4. **synapse-metrics**: Prometheus metrics (port 9090)

Plus **ServiceMonitor** for Prometheus Operator auto-discovery.

## Deployment Order

**WHERE:** Run all commands from your **management node**

**WORKING DIRECTORY:** `deployment/main-instance/01-synapse/`

Deploy in this order to ensure dependencies are met:

```bash
# 1. Ensure Phase 1 infrastructure is running
kubectl get cluster -n matrix matrix-postgresql    # PostgreSQL
kubectl get statefulset -n matrix redis            # Redis
kubectl get tenant -n matrix minio                 # MinIO

# 2. Create namespace (if not exists)
kubectl create namespace matrix

# 3. Deploy secrets (update values first!)
kubectl apply -f secrets.yaml

# 4. Deploy ConfigMap
kubectl apply -f configmap.yaml

# 5. Deploy main StatefulSet
kubectl apply -f main-statefulset.yaml

# 6. Deploy Services
kubectl apply -f services.yaml
```

## Verification

**WHERE:** Run all verification commands from your **management node**

Check deployment status:

```bash
# Check StatefulSet
kubectl get statefulset -n matrix synapse-main
kubectl get pods -n matrix -l app.kubernetes.io/instance=main

# Check logs
kubectl logs -n matrix synapse-main-0 -f

# Check services
kubectl get svc -n matrix | grep synapse

# Verify database connection (executes psql on pod)
kubectl exec -n matrix synapse-main-0 -- \
  psql -h matrix-postgresql-rw.matrix.svc.cluster.local -U synapse -d matrix -c "SELECT version();"

# Verify Redis connection (executes redis-cli on pod)
kubectl exec -n matrix synapse-main-0 -- \
  redis-cli -h redis.matrix.svc.cluster.local -a "$REDIS_PASSWORD" ping

# Check metrics (port-forward to local machine)
kubectl port-forward -n matrix svc/synapse-metrics 9090:9090
curl http://localhost:9090/_synapse/metrics
```

## Integration with Phase 1 Infrastructure

### PostgreSQL (CloudNativePG)
- **Connection**: `matrix-postgresql-rw.matrix.svc.cluster.local:5432`
- **Database**: `matrix`
- **User**: `synapse`
- **Features**:
  - 3-instance cluster with automatic failover
  - Synchronous replication (1-2 replicas)
  - Daily backups to MinIO
  - Connection pooling (cp_min: 5, cp_max: 50)

### Redis Sentinel
- **Connection**: `redis.matrix.svc.cluster.local:6379`
- **Features**:
  - 3-node cluster with automatic failover (5-10s)
  - Used for worker replication and caching
  - Persistent storage

### MinIO S3 Storage
- **Endpoint**: `http://minio.matrix.svc.cluster.local:9000`
- **Bucket**: `synapse-media`
- **Features**:
  - 4 servers, 8 drives, EC:4 erasure coding
  - 50% storage efficiency
  - Automatic failover and healing

## LI (Lawful Intercept) Configuration

**CRITICAL LI Settings** in homeserver.yaml:

1. **Infinite Retention**:
   ```yaml
   redaction_retention_period: null
   forgotten_room_retention_period: null
   ```
   Deleted messages and rooms are NEVER purged from the database.

2. **Recovery Key Storage**:
   ```yaml
   modules:
     - module: synapse_recovery_key_storage.RecoveryKeyStorageModule
       config:
         backend_url: "http://key-vault.matrix.svc.cluster.local:8000"
         api_key: "${KEY_VAULT_API_KEY}"
   ```
   E2EE recovery keys are stored in key_vault service (deployed in Phase 2.4).

3. **Network Isolation**:
   - key_vault is ONLY accessible from Synapse main (enforced by NetworkPolicy)
   - LI instance CANNOT access main resources (enforced by NetworkPolicy)

## Worker Support

The main process is configured for worker distribution:

**Instance Map**:
```yaml
instance_map:
  main:
    host: 127.0.0.1
    port: 9093
```

**Stream Writers** (will be populated when workers are deployed):
```yaml
stream_writers:
  events: main           # Can be delegated to event_persister workers
  typing: main           # Can be delegated to typing workers
  to_device: main        # Can be delegated to to_device workers
  account_data: main     # Can be delegated to account_data workers
  receipts: main         # Can be delegated to receipts workers
  presence: main         # Can be delegated to presence workers
```

Workers will be configured in Phase 2.2.

## Scaling Considerations

### Main Process (DO NOT SCALE)
- The main process MUST have exactly 1 replica
- It handles background tasks, pushers, and federation senders
- Horizontal scaling is achieved through workers (Phase 2.2)

### Vertical Scaling
Adjust resources based on load:

**Small (100-1000 CCU)**:
```yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

**Medium (1000-5000 CCU)**:
```yaml
resources:
  requests:
    memory: "4Gi"
    cpu: "2000m"
  limits:
    memory: "8Gi"
    cpu: "4000m"
```

**Large (5000-20000 CCU)**:
```yaml
resources:
  requests:
    memory: "8Gi"
    cpu: "4000m"
  limits:
    memory: "16Gi"
    cpu: "8000m"
```

### Horizontal Scaling
See Phase 2.2 for worker deployment patterns.

## Monitoring

Prometheus metrics are exposed at `/_synapse/metrics` on port 9090.

**Key Metrics**:
- `synapse_federation_client_sent_transactions_total`
- `synapse_storage_events_persisted_events_total`
- `synapse_http_server_requests_total`
- `synapse_util_metrics_block_db_txn_duration_seconds`
- `synapse_replication_tcp_resource_connections_per_worker`

ServiceMonitor automatically configures Prometheus scraping.

## Troubleshooting

**WHERE:** Run all troubleshooting commands from your **management node**

### Pod won't start

**Note:** Check logs and init containers to diagnose startup failures

```bash
# Check logs
kubectl logs -n matrix synapse-main-0

# Check init containers
kubectl logs -n matrix synapse-main-0 -c wait-for-postgres
kubectl logs -n matrix synapse-main-0 -c wait-for-redis
kubectl logs -n matrix synapse-main-0 -c generate-config

# Check events
kubectl describe pod -n matrix synapse-main-0
```

### Database connection fails

**Note:** Verify PostgreSQL infrastructure is running and test connectivity

```bash
# Verify PostgreSQL is running
kubectl get cluster -n matrix matrix-postgresql

# Check database service
kubectl get svc -n matrix matrix-postgresql-rw

# Test connection (launches temporary pod)
kubectl run -n matrix tmp-postgres --rm -it --image=postgres:16-alpine -- \
  psql -h matrix-postgresql-rw -U synapse -d matrix
```

### Redis connection fails

**Note:** Verify Redis infrastructure is running and test connectivity

```bash
# Verify Redis is running
kubectl get statefulset -n matrix redis

# Test connection (launches temporary pod)
kubectl run -n matrix tmp-redis --rm -it --image=redis:7.2-alpine -- \
  redis-cli -h redis.matrix.svc.cluster.local -a "PASSWORD" ping
```

### S3/MinIO connection fails

**Note:** Verify MinIO infrastructure is running and test S3 connectivity

```bash
# Verify MinIO tenant is running
kubectl get tenant -n matrix minio

# Check MinIO service
kubectl get svc -n matrix minio

# Test S3 connection (launches temporary pod with aws-cli)
kubectl run -n matrix tmp-s3 --rm -it --image=amazon/aws-cli -- \
  s3 ls --endpoint-url http://minio.matrix.svc.cluster.local:9000
```

## Security Notes

1. **Secrets Management**:
   - In production, use sealed-secrets, external-secrets, or HashiCorp Vault
   - Never commit secrets to git
   - Rotate secrets regularly

2. **Network Policies**:
   - Synapse main can access: PostgreSQL, Redis, MinIO, key_vault
   - Synapse main can be accessed by: Ingress, HAProxy, workers
   - Enforced by Phase 1 NetworkPolicies

3. **TLS**:
   - Internal traffic uses unencrypted HTTP (within cluster)
   - External traffic uses TLS (terminated at Ingress)
   - Federation uses TLS (handled by Ingress for port 8448)

4. **User Isolation**:
   - Runs as user 991:991 (non-root)
   - Read-only root filesystem
   - All capabilities dropped

## Next Steps

After deploying the main process:

1. **Phase 2.2**: Deploy Synapse workers for horizontal scaling
2. **Phase 2.3**: Deploy Element Web and HAProxy for routing
3. **Phase 2.4**: Deploy supporting services (LiveKit, coturn, Sygnal, key_vault)

## References

- [Synapse Documentation](https://matrix-org.github.io/synapse/latest/)
- [Workers Guide](https://matrix-org.github.io/synapse/latest/workers.html)
- [Configuration Reference](https://matrix-org.github.io/synapse/latest/usage/configuration/config_documentation.html)
