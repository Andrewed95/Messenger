# Matrix/Synapse Monitoring Stack

Complete monitoring and observability solution for Matrix/Synapse production deployment (100-20K CCU).

## Overview

The monitoring stack provides comprehensive observability for:
- ✅ **Metrics**: Prometheus + Grafana
- ✅ **Logs**: Loki + Promtail
- ✅ **Alerts**: PrometheusRules (Alertmanager disabled per requirements)
- ✅ **Dashboards**: Pre-configured Grafana dashboards
- ✅ **LI Compliance**: Dedicated monitoring for LI instance and sync system

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     MONITORING STACK                            │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐       │
│  │  Prometheus  │   │   Grafana    │   │     Loki     │       │
│  │              │───│              │───│              │       │
│  │  Metrics     │   │ Visualization│   │  Log Storage │       │
│  │  Storage     │   │  Dashboards  │   │              │       │
│  └──────┬───────┘   └──────────────┘   └──────┬───────┘       │
│         │                                      │               │
│         │ scrape                               │ push          │
└─────────┼──────────────────────────────────────┼───────────────┘
          │                                      │
          │                                      │
┌─────────┼──────────────────────────────────────┼───────────────┐
│         ▼                                      ▼               │
│  ┌──────────────┐                      ┌──────────────┐       │
│  │ServiceMonitor│                      │  Promtail    │       │
│  │  CRDs        │                      │  DaemonSet   │       │
│  └──────┬───────┘                      └──────┬───────┘       │
│         │                                      │               │
│         │ discover                             │ collect       │
│         ▼                                      ▼               │
│  ┌─────────────────────────────────────────────────────┐      │
│  │              MATRIX COMPONENTS                      │      │
│  │                                                     │      │
│  │  Synapse │ PostgreSQL │ Redis │ MinIO │ HAProxy   │      │
│  │  Sygnal  │ key_vault  │ Sync  │ NGINX │ Element   │      │
│  │                                                     │      │
│  │  Metrics Port: 9090, 9187, 9121, 9000, 9101       │      │
│  │  Logs: stdout/stderr → /var/log/pods              │      │
│  └─────────────────────────────────────────────────────┘      │
│                     MATRIX NAMESPACE                          │
└───────────────────────────────────────────────────────────────┘
```

## Components

### 1. Prometheus (`01-prometheus/`)
- **Purpose**: Metrics collection and storage
- **Port**: 9090
- **Retention**: , 100GB
- **Scrape Interval**: 30s
- **Files**:
  - `servicemonitors.yaml`: 12 ServiceMonitors for all components
  - `prometheusrules.yaml`: 60+ alerting rules
  - `README.md`: Complete documentation

**Key Features**:
- ServiceMonitor-based auto-discovery
- CloudNativePG PodMonitors
- Comprehensive alerting (critical + warning)
- PromQL examples for common queries

### 2. Grafana (`02-grafana/`)
- **Purpose**: Visualization and dashboards
- **Port**: 3000 (80 internal)
- **Replicas**: 2 (HA)
- **Files**:
  - `dashboards-configmap.yaml`: Pre-configured dashboards
  - `README.md`: Dashboard creation and management

**Pre-configured Dashboards**:
1. **Synapse Overview**: Requests, latency, workers
2. **PostgreSQL CloudNativePG**: Replication, connections, queries
3. **LI Instance**: Replication lag, sync status
4. **Community Dashboards**: Kubernetes, Node Exporter, Redis, NGINX

### 3. Loki (`03-loki/`)
- **Purpose**: Log aggregation and querying
- **Port**: 3100
- **Storage**: 50Gi
- **Retention**: 
- **Files**:
  - `README.md`: LogQL queries and troubleshooting

**Components**:
- **Loki**: Log storage backend
- **Promtail**: DaemonSet log collector
- **Grafana Integration**: Log exploration and dashboards

## Quick Start

### 1. Deploy Monitoring Stack

```bash
# 1. Install Prometheus Operator + Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values ../values/prometheus-stack-values.yaml \
  --version 67.0.0

# 2. Install Loki + Promtail
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki-stack \
  --namespace monitoring \
  --values ../values/loki-values.yaml \
  --version 2.10.0

# 3. Deploy ServiceMonitors and PrometheusRules
kubectl apply -f 01-prometheus/servicemonitors.yaml
kubectl apply -f 01-prometheus/prometheusrules.yaml

# 4. Deploy Grafana Dashboards
kubectl apply -f 02-grafana/dashboards-configmap.yaml

# 5. Enable CloudNativePG monitoring
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

### 2. Access Monitoring UIs

**Prometheus**:
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
open http://localhost:9090
```

**Grafana**:
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
open http://localhost:3000

# Get Grafana password
kubectl get secret -n monitoring prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

**Loki** (via Grafana Explore):
- Login to Grafana
- Navigate to Explore → Select Loki datasource

### 3. Verify Monitoring

```bash
# Check all monitoring pods are running
kubectl get pods -n monitoring

# Check ServiceMonitors
kubectl get servicemonitors -n matrix

# Check PodMonitors
kubectl get podmonitors -n matrix

# Check PrometheusRules
kubectl get prometheusrules -n matrix

# Check Prometheus targets (should all be UP)
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Navigate to: http://localhost:9090/targets
```

## Monitored Components

### Matrix Services (12 components)

| Component | Metrics Port | Metrics Path | ServiceMonitor | Notes |
|-----------|--------------|--------------|----------------|-------|
| **Synapse Main** | 9090 | `/_synapse/metrics` | ✅ synapse | Main homeserver process |
| **Synapse Workers** | 9090 | `/_synapse/metrics` | ✅ synapse-workers | All 5 worker types |
| **Synapse LI** | 9090 | `/_synapse/metrics` | ✅ synapse-li | Read-only LI instance |
| **PostgreSQL Main** | 9187 | `/metrics` | ✅ PodMonitor | CloudNativePG |
| **PostgreSQL LI** | 9187 | `/metrics` | ✅ PodMonitor | CloudNativePG LI |
| **Redis** | 9121 | `/metrics` | ✅ redis | Requires redis-exporter |
| **MinIO** | 9000 | `/minio/v2/metrics/cluster` | ✅ minio | S3 storage |
| **HAProxy** | 9101 | `/metrics` | ✅ haproxy | Load balancer |
| **key_vault** | 8000 | `/metrics` | ✅ key-vault | E2EE key storage |
| **Sygnal** | 9000 | `/metrics` | ✅ sygnal | Push notifications |
| **Sync System** | 9090 | `/metrics` | ✅ sync-system | LI sync jobs |
| **NGINX Ingress** | 10254 | `/metrics` | ✅ nginx-ingress | Ingress controller |

### Infrastructure Services

| Component | Purpose | Monitoring |
|-----------|---------|------------|
| **Node Exporter** | System metrics | CPU, memory, disk, network |
| **kube-state-metrics** | K8s object metrics | Pods, deployments, PVCs |
| **Prometheus Operator** | CRD management | ServiceMonitor, PrometheusRule |

## Key Metrics

### Synapse Performance

```promql
# Requests per second
sum(rate(synapse_http_server_requests_total[5m]))

# /sync latency (95th percentile)
histogram_quantile(0.95, rate(synapse_http_server_response_time_seconds_bucket{servlet="sync"}[5m]))

# Event persist rate
rate(synapse_storage_events_persisted_events_total[5m])

# Database connection usage
synapse_db_pool_connections_in_use / synapse_db_pool_connections_max
```

### PostgreSQL Health

```promql
# Replication lag
cnpg_pg_replication_lag

# Active connections
cnpg_pg_stat_database_numbackends

# Cache hit ratio
cnpg_pg_stat_database_blks_hit / (cnpg_pg_stat_database_blks_hit + cnpg_pg_stat_database_blks_read)
```

### LI Sync System

```promql
# Replication lag (CRITICAL)
cnpg_pg_replication_lag{cnpg_io_cluster="matrix-postgresql-li"}

# Last media sync
time() - kube_job_status_completion_time{job_name=~"sync-system-media.*"}
```

## Alerting Rules

### Critical Alerts (60+ rules)

**Infrastructure**:
- SynapseMainDown, PostgreSQLDown, RedisDown, MinIODown
- HAProxyDown, KeyVaultDown, NginxIngressDown

**Data Integrity**:
- PostgreSQLBackupFailing
- SynapseLIHighReplicationLag (>5min)
- SyncSystemMediaJobFailing

**Resource Exhaustion**:
- SynapseConnectionPoolExhausted
- PostgreSQLTooManyConnections
- RedisConnectionsExhausted

### Warning Alerts

**Performance**:
- SynapseHighSyncLatency (>500ms)
- SynapseHighCPU (>80%)
- SynapseHighMemory (>3.5GB)

**Capacity**:
- PostgreSQLReplicationLag (>60s)
- RedisHighMemoryUsage (>90%)
- MinIOHighStorageUsage (<20% free)

See `01-prometheus/prometheusrules.yaml` for complete list.

## Log Queries (LogQL)

### Common Queries

**All Synapse errors**:
```logql
{namespace="matrix", app_kubernetes_io_name="synapse"} |= "ERROR"
```

**PostgreSQL slow queries**:
```logql
{namespace="matrix", cnpg_io_cluster=~"matrix-postgresql.*"} |= "duration:" | regexp "duration: (?P<duration>\\d+) ms" | duration > 1000
```

**LI sync system logs**:
```logql
{namespace="matrix", app_kubernetes_io_name="sync-system"}
```

**NGINX 5xx errors**:
```logql
{namespace="ingress-nginx"} | json | status >= 500
```

See `03-loki/README.md` for complete LogQL guide.

## Scaling Considerations

### 100 CCU (Small Deployment)

**Prometheus**:
- CPU: 500m
- Memory: 4Gi
- Storage: 50Gi
- Retention: 

**Grafana**:
- Replicas: 1
- CPU: 200m
- Memory: 512Mi

**Loki**:
- Replicas: 1
- CPU: 200m
- Memory: 512Mi
- Storage: 20Gi

### 1K CCU (Medium Deployment)

**Prometheus**:
- CPU: 1000m
- Memory: 6Gi
- Storage: 100Gi (current)

**Grafana**:
- Replicas: 2 (current)

**Loki**:
- CPU: 500m
- Memory: 1Gi
- Storage: 50Gi (current)

### 10K-20K CCU (Large Deployment)

**Prometheus**:
- CPU: 2000m
- Memory: 8Gi
- Storage: 200Gi
- Consider Thanos/Cortex for long-term storage

**Grafana**:
- Replicas: 2-3
- CPU: 500m
- Memory: 1Gi

**Loki**:
- CPU: 1000m
- Memory: 2Gi
- Storage: 100Gi
- Consider distributed mode

## Troubleshooting

### No Metrics from Component

1. **Check ServiceMonitor**:
```bash
kubectl get servicemonitor <name> -n matrix -o yaml
```

2. **Verify Service labels match**:
```bash
kubectl get svc <service-name> -n matrix -o yaml
```

3. **Check Prometheus targets**:
```
http://localhost:9090/targets
```

4. **Test metrics endpoint**:
```bash
kubectl exec -n matrix <pod-name> -- curl localhost:9090/metrics
```

### No Logs in Loki

1. **Check Promtail**:
```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail
```

2. **Verify pod annotation**:
```bash
kubectl get pod <pod-name> -n matrix -o jsonpath='{.metadata.annotations}'
```

3. **Check Loki ingestion**:
```bash
kubectl logs -n monitoring loki-0
```

### Alerts Not Firing

1. **Check PrometheusRule**:
```bash
kubectl get prometheusrule matrix-alerts -n matrix
```

2. **Verify rule loaded in Prometheus**:
```
http://localhost:9090/rules
```

3. **Check alert state**:
```
http://localhost:9090/alerts
```

## Best Practices

### 1. Monitoring Hygiene
- **Review dashboards weekly**: Check for anomalies
- **Test alerts monthly**: Verify alert routing works
- **Tune thresholds**: Adjust based on actual usage patterns
- **Clean up unused metrics**: Reduce cardinality

### 2. Capacity Planning
- **Monitor storage growth**: Prometheus and Loki disk usage
- **Track metric cardinality**: Avoid high-cardinality labels
- **Plan for retention**: Balance retention vs storage cost
- **Archive old data**: Use Thanos or S3 for long-term storage

### 3. Security
- **Restrict Grafana access**: Use RBAC or OAuth
- **Use NetworkPolicies**: Limit Prometheus scrape access
- **Encrypt data**: TLS for Prometheus remote write
- **Audit access**: Log Grafana user activity

### 4. Performance
- **Use recording rules**: Pre-compute expensive queries
- **Limit query time range**: Recent data for dashboards
- **Optimize LogQL**: Filter before parsing
- **Shard Prometheus**: Use federation for large deployments

## Cost Optimization

### Storage Costs

**Current Configuration**:
- Prometheus: 100Gi ×  = 100Gi
- Loki: 50Gi ×  = 50Gi
- **Total**: ~150Gi

**Optimization**:
1. **Reduce retention**:  instead of  = 50% savings
2. **Use cheaper storage class**: Cloud cold storage
3. **Enable compression**: Prometheus TSDB compression
4. **Archive to S3**: Long-term storage via Thanos

### Resource Costs

**Current Request**:
- Prometheus: 500m CPU, 4Gi memory
- Grafana: 200m CPU, 512Mi memory × 2 = 400m CPU, 1Gi memory
- Loki: 200m CPU, 512Mi memory
- Promtail: 100m CPU × nodes
- **Total**: ~1.2 CPU cores, 6Gi memory

**For 20K CCU**: Increase to 3 CPU cores, 12Gi memory

## References

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Synapse Metrics](https://matrix-org.github.io/synapse/latest/metrics-howto.html)
- [CloudNativePG Monitoring](https://cloudnative-pg.io/documentation/current/monitoring/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)
- [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [LogQL Guide](https://grafana.com/docs/loki/latest/logql/)

## Support

For issues or questions:
1. Check component READMEs in subdirectories
2. Review Prometheus/Grafana/Loki logs
3. Consult official documentation
4. Search GitHub issues for kube-prometheus-stack, Loki, CloudNativePG

---

**Monitoring Stack Version**: 1.0
**Last Updated**: 2025-11-18
**Compatibility**: Kubernetes 1.28+, Prometheus Operator 0.70+, Grafana 9.0+, Loki 2.10+
