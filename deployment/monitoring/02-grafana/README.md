# Grafana Dashboards

Grafana visualization and dashboards for Matrix/Synapse monitoring.

## Overview

Grafana is deployed as part of the kube-prometheus-stack Helm chart and provides:
- Visual dashboards for all metrics
- Alerting and notification (alternative to Alertmanager)
- Log visualization (via Loki integration)
- Multi-datasource support (Prometheus + Loki)

## Pre-configured Dashboards

### 1. Synapse Overview Dashboard
- **File**: `synapse-overview.json`
- **UID**: `synapse-overview`
- **Features**:
  - Synapse main status (up/down)
  - Requests per second by worker type
  - /sync endpoint latency (95th and 50th percentile)
  - Event persist rate
  - Database connection usage
  - Memory and CPU usage

### 2. PostgreSQL CloudNativePG Dashboard
- **File**: `postgresql.json`
- **UID**: `postgresql-cnpg`
- **Features**:
  - Replication lag (main and LI clusters)
  - Active connections per database
  - Transaction rate
  - Cache hit ratio
  - Deadlocks and conflicts

### 3. LI Instance Dashboard
- **File**: `li-instance.json`
- **UID**: `li-instance`
- **Features**:
  - Synapse LI status
  - **CRITICAL**: Database replication lag monitoring
  - Last media sync job completion time
  - Sync job success/failure rate

### 4. Community Dashboards (Auto-imported)

Configured in `prometheus-stack-values.yaml`:

- **Kubernetes Cluster Monitoring** (ID: 7249)
  - Cluster resource usage
  - Node status
  - Pod distribution

- **Node Exporter** (ID: 1860)
  - CPU, memory, disk, network
  - Per-node detailed metrics

- **PostgreSQL** (ID: 9628)
  - Database performance
  - Query statistics

- **Redis** (ID: 11835)
  - Memory usage
  - Connection stats
  - Command statistics

- **NGINX Ingress** (ID: 9614)
  - Request rate and latency
  - Error rates
  - Certificate expiry

## Installation

### 1. Deploy Dashboard ConfigMaps

```bash
# Apply dashboard ConfigMaps
kubectl apply -f dashboards-configmap.yaml

# Verify ConfigMaps were created
kubectl get configmap -n monitoring -l grafana_dashboard=1
```

### 2. Configure Grafana to Load Dashboards

Dashboards are automatically loaded via the sidecar container configured in `prometheus-stack-values.yaml`:

```yaml
grafana:
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: monitoring
```

### 3. Access Grafana

```bash
# Port-forward to Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Open browser
open http://localhost:3000
```

### 4. Login

Default credentials:
- **Username**: `admin`
- **Password**: From Helm values or secret:

```bash
# Get password from secret
kubectl get secret -n monitoring prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

**IMPORTANT**: Change the default password immediately after first login.

## Creating Custom Dashboards

### Method 1: Via Grafana UI

1. Login to Grafana
2. Click `+` → Create Dashboard
3. Add panels with PromQL queries
4. Save dashboard
5. Export JSON via Settings → JSON Model
6. Add to `dashboards-configmap.yaml`

### Method 2: Import from Grafana.com

1. Browse dashboards at https://grafana.com/grafana/dashboards
2. Find dashboard ID (e.g., 9628 for PostgreSQL)
3. Add to `prometheus-stack-values.yaml`:

```yaml
grafana:
  dashboards:
    default:
      my-dashboard:
        gnetId: 12345
        revision: 1
        datasource: Prometheus
```

### Method 3: ConfigMap

Create ConfigMap with dashboard JSON:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-custom
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  custom.json: |
    {
      "title": "My Custom Dashboard",
      ...
    }
```

## Useful Dashboard Panels

### Synapse Performance Panels

**Total Requests per Second**:
```promql
sum(rate(synapse_http_server_requests_total[5m]))
```

**Requests by Worker Type**:
```promql
sum(rate(synapse_http_server_requests_total[5m])) by (worker_type)
```

**/sync Latency (95th percentile)**:
```promql
histogram_quantile(0.95, rate(synapse_http_server_response_time_seconds_bucket{servlet="sync"}[5m]))
```

**Event Persist Rate**:
```promql
rate(synapse_storage_events_persisted_events_total[5m])
```

**Database Connection Pool Usage**:
```promql
synapse_db_pool_connections_in_use / synapse_db_pool_connections_max
```

**Memory Usage**:
```promql
process_resident_memory_bytes{job="synapse"} / 1024 / 1024 / 1024
```

### PostgreSQL Panels

**Replication Lag**:
```promql
cnpg_pg_replication_lag
```

**Active Connections**:
```promql
cnpg_pg_stat_database_numbackends
```

**Transaction Rate**:
```promql
rate(cnpg_pg_stat_database_xact_commit[5m])
```

**Cache Hit Ratio**:
```promql
cnpg_pg_stat_database_blks_hit / (cnpg_pg_stat_database_blks_hit + cnpg_pg_stat_database_blks_read)
```

### Redis Panels

**Memory Usage**:
```promql
redis_memory_used_bytes
```

**Connected Clients**:
```promql
redis_connected_clients
```

**Operations per Second**:
```promql
rate(redis_commands_processed_total[5m])
```

### MinIO Panels

**Storage Usage (bytes)**:
```promql
minio_cluster_capacity_usable_total_bytes - minio_cluster_capacity_usable_free_bytes
```

**Storage Usage (percentage)**:
```promql
(1 - (minio_cluster_capacity_usable_free_bytes / minio_cluster_capacity_usable_total_bytes)) * 100
```

**Request Rate**:
```promql
rate(minio_s3_requests_total[5m])
```

**Error Rate**:
```promql
rate(minio_s3_requests_errors_total[5m])
```

### LI Sync System Panels

**Replication Lag**:
```promql
cnpg_pg_replication_lag{cnpg_io_cluster="matrix-postgresql-li"}
```

**Last Media Sync Time (seconds ago)**:
```promql
time() - kube_job_status_completion_time{job_name=~"sync-system-media.*"}
```

**Media Sync Success Rate (last hour)**:
```promql
rate(kube_job_status_succeeded{job_name=~"sync-system-media.*"}[1h])
```

## Dashboard Best Practices

### 1. Panel Design
- **Use appropriate visualizations**: Time series for trends, stats for current values, gauges for thresholds
- **Set meaningful thresholds**: Green (good), yellow (warning), red (critical)
- **Add units**: Request rate (reqps), latency (s/ms), memory (bytes)
- **Use legends**: Clear labels for multi-series data

### 2. Time Ranges
- **Default**: Last 1 hour for operational dashboards
- **Troubleshooting**: Last 6-24 hours for incident investigation
- **Capacity Planning**: Last 7-30 days for trend analysis

### 3. Refresh Rates
- **Critical Services**: 10s (Synapse, PostgreSQL, Redis)
- **Infrastructure**: 30s (MinIO, HAProxy)
- **Compliance (LI)**: 30s-1min

### 4. Alerting
- Configure alerts directly in Grafana panels (alternative to PrometheusRules)
- Use notification channels (email, Slack, PagerDuty)
- Group related alerts to reduce noise

### 5. Variables
- Use template variables for dynamic dashboards
- Common variables: `cluster`, `namespace`, `pod`, `worker_type`

Example variable:
```
Name: pod
Type: Query
Query: label_values(up{job="synapse"}, pod)
```

## Troubleshooting

### Dashboard not appearing

```bash
# Check if ConfigMap exists
kubectl get configmap -n monitoring -l grafana_dashboard=1

# Check Grafana sidecar logs
kubectl logs -n monitoring deployment/prometheus-grafana -c grafana-sc-dashboard

# Check if dashboard provider is configured
kubectl exec -n monitoring deployment/prometheus-grafana -- \
  cat /etc/grafana/provisioning/dashboards/dashboardproviders.yaml
```

### No data in panels

1. **Check datasource**:
   - Navigate to Configuration → Data Sources
   - Test Prometheus connection
   - Verify URL: `http://prometheus-kube-prometheus-prometheus.monitoring:9090`

2. **Check query**:
   - Use Explore view to test PromQL queries
   - Verify metric names exist in Prometheus

3. **Check time range**:
   - Ensure selected time range contains data
   - Adjust time range or scrape interval

### Panels showing "N/A"

- Metric may not exist yet (new deployment)
- ServiceMonitor may not be discovering targets
- Check Prometheus targets: Status → Targets

### Slow dashboard loading

1. **Reduce time range**: Last 1h instead of 7d
2. **Optimize queries**: Use recording rules for expensive queries
3. **Limit series**: Use label filters to reduce cardinality
4. **Increase resources**:
```yaml
grafana:
  resources:
    limits:
      memory: 2Gi
      cpu: 1000m
```

## Advanced Features

### Multi-Datasource Queries

Combine Prometheus and Loki data:

**Panel**: Events and Logs Correlation
- Query A (Prometheus): `rate(synapse_storage_events_persisted_events_total[5m])`
- Query B (Loki): `{namespace="matrix", pod=~"synapse-.*"} |= "ERROR"`

### Annotations

Add event markers to dashboards:

**Example**: Deployment Events
```promql
changes(kube_deployment_status_observed_generation{namespace="matrix"}[5m]) > 0
```

### Alert Notifications

Configure notification channels:
1. Navigate to Alerting → Notification channels
2. Add channel (Email, Slack, Webhook, PagerDuty)
3. Set as default for all alerts or specific alerts

### Dashboard Links

Add links between related dashboards:

```json
"links": [
  {
    "title": "Synapse Workers",
    "url": "/d/synapse-workers/synapse-workers",
    "type": "dashboards"
  },
  {
    "title": "PostgreSQL",
    "url": "/d/postgresql-cnpg/postgresql-cloudnativepg",
    "type": "dashboards"
  }
]
```

## Grafana Configuration

### Enable Anonymous Access (Read-only)

For public dashboards (use with caution):

```yaml
grafana:
  grafana.ini:
    auth.anonymous:
      enabled: true
      org_role: Viewer
```

### Enable Ingress

External access to Grafana:

```yaml
grafana:
  ingress:
    enabled: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
      nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8"
    hosts:
      - grafana.example.com
    tls:
      - secretName: grafana-tls
        hosts:
          - grafana.example.com
```

### LDAP/OAuth Integration

For enterprise authentication:

```yaml
grafana:
  ldap:
    enabled: true
    config: |
      [[servers]]
      host = "ldap.example.com"
      port = 389
      use_ssl = false
      bind_dn = "cn=admin,dc=example,dc=com"
      bind_password = 'secret'
      search_filter = "(cn=%s)"
      search_base_dns = ["dc=example,dc=com"]
```

## References

- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Synapse Metrics](https://matrix-org.github.io/synapse/latest/metrics-howto.html)
- [CloudNativePG Monitoring](https://cloudnative-pg.io/documentation/current/monitoring/)
- [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana Dashboard Gallery](https://grafana.com/grafana/dashboards)
