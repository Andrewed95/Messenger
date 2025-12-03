# Prometheus Monitoring

Complete Prometheus monitoring configuration for Matrix/Synapse production deployment.

## Overview

This directory contains:
- **servicemonitors.yaml**: ServiceMonitor and PodMonitor CRDs for all components
- Prometheus configuration via Helm values in `deployment/values/prometheus-stack-values.yaml`

## Components Monitored

### Matrix Services
1. **Synapse Main Process**
   - Port: 9090
   - Path: `/_synapse/metrics`
   - Interval: 30s
   - Metrics: HTTP requests, event processing, database queries, memory, CPU

2. **Synapse Workers** (all types)
   - synchrotron: /sync endpoint handling
   - generic-worker: General client API requests
   - media-repository: Media upload/download
   - event-persister: Event storage
   - federation-sender: Federation traffic
   - Automatically labeled with `worker_type`

3. **Synapse LI Instance**
   - Port: 9090
   - Path: `/_synapse/metrics`
   - Labeled with `matrix.instance: li`

4. **NOTE**: Sygnal (push) not included - requires external Apple/Google servers

5. **key_vault (E2EE Key Storage)**
   - Port: 8000 (metrics endpoint)
   - Path: `/metrics`
   - Custom Django metrics

### Infrastructure Services

6. **PostgreSQL (CloudNativePG)**
   - **Main Cluster**: `matrix-postgresql`
   - **LI Cluster**: `matrix-postgresql-li`
   - Port: 9187 (per pod)
   - Path: `/metrics`
   - Metrics: Connections, replication lag, queries, transactions, XID age
   - **PodMonitor** used (not ServiceMonitor)

7. **Redis Sentinel**
   - Port: 9121 (redis-exporter)
   - Path: `/metrics`
   - Metrics: Memory usage, connections, replication status, Sentinel health
   - Note: Requires redis-exporter sidecar

8. **MinIO**
   - Port: 9000
   - Path: `/minio/v2/metrics/cluster`
   - Metrics: Storage capacity, disk health, request rate, errors

9. **HAProxy**
   - Port: 8404 (stats endpoint)
   - Path: `/metrics`
   - Metrics: Backend health, request rate, error rate, response times

### Supporting Services

10. **Sync System (LI)**
    - Tracks replication lag via PostgreSQL metrics

11. **NGINX Ingress Controller**
    - Port: 10254 (default metrics port)
    - Path: `/metrics`
    - Metrics: Request rate, error rate, response times

12. **Element Web**
    - Optional (if metrics endpoint added)
    - Health checks only

13. **coturn (TURN/STUN)**
    - Optional (if metrics endpoint added)

## Installation

### 1. Install Prometheus Operator (via kube-prometheus-stack)

```bash
# Add Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create monitoring namespace
kubectl create namespace monitoring

# Install kube-prometheus-stack
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values ../../values/prometheus-stack-values.yaml \
  --version 67.0.0
```

### 2. Enable CloudNativePG Monitoring

Update PostgreSQL Cluster definitions to enable PodMonitor:

```bash
# Edit main-cluster.yaml and li-cluster.yaml
kubectl edit cluster matrix-postgresql -n matrix
kubectl edit cluster matrix-postgresql-li -n matrix
```

Add to `.spec`:
```yaml
spec:
  monitoring:
    enablePodMonitor: true
    customQueriesConfigMap:
      - name: default-monitoring
        key: queries
```

### 3. Deploy ServiceMonitors

```bash
# Apply ServiceMonitors
kubectl apply -f servicemonitors.yaml

# Verify ServiceMonitors
kubectl get servicemonitors -n matrix
kubectl get podmonitors -n matrix
```

### 4. Verify Prometheus is Scraping Targets

```bash
# Port-forward to Prometheus UI
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Open browser
open http://localhost:9090

# Check targets
# Navigate to: Status > Targets
# All targets should show "UP"
```

## Prometheus Queries

### Synapse Performance

```promql
# Total requests per second
sum(rate(synapse_http_server_requests_total[5m]))

# Requests per worker type
sum(rate(synapse_http_server_requests_total[5m])) by (worker_type)

# /sync endpoint latency (95th percentile)
histogram_quantile(0.95, rate(synapse_http_server_response_time_seconds_bucket{servlet="sync"}[5m]))

# Event persist rate
rate(synapse_storage_events_persisted_events_total[5m])

# Database connection usage
synapse_db_pool_connections_in_use / synapse_db_pool_connections_max
```

### PostgreSQL Metrics

```promql
# Replication lag (seconds)
cnpg_pg_replication_lag

# Active connections
cnpg_pg_stat_database_numbackends

# Transaction rate
rate(cnpg_pg_stat_database_xact_commit[5m])

# Deadlocks
rate(cnpg_pg_stat_database_deadlocks[5m])

# Cache hit ratio
cnpg_pg_stat_database_blks_hit / (cnpg_pg_stat_database_blks_hit + cnpg_pg_stat_database_blks_read)
```

### Redis Metrics

```promql
# Memory usage
redis_memory_used_bytes

# Connected clients
redis_connected_clients

# Operations per second
rate(redis_commands_processed_total[5m])

# Replication lag (if applicable)
redis_master_repl_offset - redis_slave_repl_offset
```

### MinIO Metrics

```promql
# Storage usage
minio_cluster_capacity_usable_total_bytes - minio_cluster_capacity_usable_free_bytes

# Request rate
rate(minio_s3_requests_total[5m])

# Error rate
rate(minio_s3_requests_errors_total[5m])

# Disk online/offline
minio_cluster_disk_online_total
minio_cluster_disk_offline_total
```

### LI Sync System

```promql
# LI sync uses pg_dump/pg_restore (no replication lag metric)
# Monitor sync status via checkpoint file or custom metrics

# MinIO health (LI uses main MinIO directly)
up{job="minio"}

# LI PostgreSQL health
up{job="postgresql-li"}
```

## Troubleshooting

### ServiceMonitor not discovering targets

```bash
# Check ServiceMonitor configuration
kubectl get servicemonitor synapse -n matrix -o yaml

# Check if Service has correct labels
kubectl get svc synapse-metrics -n matrix -o yaml

# Check Prometheus logs
kubectl logs -n monitoring prometheus-kube-prometheus-prometheus-0 -c prometheus

# Check Prometheus Operator logs
kubectl logs -n monitoring deployment/prometheus-kube-prometheus-operator
```

### No metrics from CloudNativePG

```bash
# Check if PodMonitor is enabled
kubectl get cluster matrix-postgresql -n matrix -o yaml | grep enablePodMonitor

# Check metrics port
kubectl get pod matrix-postgresql-1 -n matrix -o yaml | grep -A5 "name: metrics"

# Test metrics endpoint directly
kubectl exec -n matrix matrix-postgresql-1 -- curl localhost:9187/metrics
```

### No metrics from MinIO

```bash
# Check MinIO Tenant configuration
kubectl get tenant matrix-minio -n matrix -o yaml

# Check if Prometheus is enabled
kubectl exec -n matrix <minio-pod> -- mc admin prometheus info minio

# Test metrics endpoint
kubectl port-forward -n matrix <minio-pod> 9000:9000
curl http://localhost:9000/minio/v2/metrics/cluster
```

## Retention and Storage

### Default Configuration

- **Retention Period**: 
- **Retention Size**: 100GB
- **Storage**: PVC with 100Gi
- **Scrape Interval**: 30s (general), 60s (infrequent targets)

### Adjusting Retention

Edit Prometheus StatefulSet or Helm values:

```yaml
prometheus:
  prometheusSpec:
    retention: 60d  # Increase to 
    retentionSize: "200GB"  # Increase to 200GB
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 200Gi
```

### Monitoring Prometheus Storage

```promql
# Prometheus storage usage
prometheus_tsdb_storage_blocks_bytes / 1024 / 1024 / 1024

# Time series count
prometheus_tsdb_head_series

# Sample ingestion rate
rate(prometheus_tsdb_head_samples_appended_total[5m])
```

## Best Practices

1. **Label Consistency**: Ensure all services use standard Kubernetes labels
2. **Scrape Intervals**: Use 30s for critical services, 60s for less critical
3. **Recording Rules**: Pre-compute expensive queries for dashboards
4. **High Cardinality**: Avoid labels with high cardinality (user IDs, message IDs)
7. **Federation**: Use Prometheus federation for long-term storage (Thanos, Cortex)

## Integration with Grafana

Prometheus is automatically configured as a Grafana datasource via kube-prometheus-stack.

Access Grafana:
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

Default credentials:
- Username: `admin`
- Password: Check `prometheus-stack-values.yaml` or:
  ```bash
  kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode
  ```

## References

- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [Synapse Metrics Documentation](https://matrix-org.github.io/synapse/latest/metrics-howto.html)
- [CloudNativePG Monitoring](https://cloudnative-pg.io/documentation/current/monitoring/)
- [MinIO Metrics](https://min.io/docs/minio/linux/operations/monitoring/collect-minio-metrics-using-prometheus.html)
- [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
