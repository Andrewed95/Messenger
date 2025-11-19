# Loki Log Aggregation

Loki log aggregation system for Matrix/Synapse production deployment.

## Overview

Loki provides:
- **Centralized log storage** for all Matrix components
- **Efficient log querying** via LogQL (similar to PromQL)
- **Grafana integration** for log visualization
- **Low resource footprint** compared to Elasticsearch

**Architecture**:
- **Loki**: Log storage and querying backend
- **Promtail**: DaemonSet log collector (runs on all nodes)
- **Grafana**: Log visualization and exploration

## Components

### 1. Loki
- **Port**: 3100
- **Storage**: 50Gi PVC (30-day retention)
- **Format**: Structured logs with labels
- **Query Language**: LogQL

### 2. Promtail
- **Deployment**: DaemonSet (one pod per node)
- **Function**: Discovers and ships logs to Loki
- **Sources**:
  - Kubernetes pod logs (`/var/log/pods`)
  - System logs (`/var/log`)

## Installation

### Option 1: Helm Chart (Recommended)

```bash
# Add Grafana Helm repository
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install Loki stack (Loki + Promtail)
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --values ../../values/loki-values.yaml \
  --version 2.10.0
```

### Option 2: Manual Deployment

If you prefer manifests over Helm, you can deploy individual components.

**Note**: The Helm chart method is recommended for ease of configuration and upgrades.

## Configuration

### Loki Configuration (via Helm values)

Key settings in `loki-values.yaml`:

```yaml
loki:
  persistence:
    enabled: true
    size: 50Gi

  config:
    limits_config:
      retention_period: 720h  # 
      ingestion_rate_mb: 10
      ingestion_burst_size_mb: 20

    table_manager:
      retention_deletes_enabled: true
      retention_period: 720h
```

### Promtail Configuration

Promtail automatically discovers pods with specific annotations:

**Add to pod manifests**:
```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"  # Required for Promtail to scrape logs
```

**Scrape configuration** (in `loki-values.yaml`):
```yaml
promtail:
  config:
    scrapeConfigs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true
```

## Log Collection

### Matrix Components Logs

All Matrix components automatically ship logs to Loki via Promtail:

| Component | Namespace | Label | Log Format |
|-----------|-----------|-------|------------|
| Synapse Main | matrix | `app.kubernetes.io/name=synapse, app.kubernetes.io/instance=main` | Structured (Python logging) |
| Synapse Workers | matrix | `app.kubernetes.io/name=synapse, app.kubernetes.io/component=worker` | Structured (Python logging) |
| Synapse LI | matrix | `matrix.instance=li` | Structured (Python logging) |
| PostgreSQL Main | matrix | `cnpg.io/cluster=matrix-postgresql` | PostgreSQL logs |
| PostgreSQL LI | matrix | `cnpg.io/cluster=matrix-postgresql-li` | PostgreSQL logs |
| Redis | matrix | `app.kubernetes.io/name=redis` | Redis logs |
| MinIO | matrix | `v1.min.io/tenant=matrix-minio` | MinIO logs |
| HAProxy | matrix | `app.kubernetes.io/name=haproxy` | HAProxy logs |
| key_vault | matrix | `app.kubernetes.io/name=key-vault` | Django logs |
| Sygnal | matrix | `app.kubernetes.io/name=sygnal` | Python logs |
| Sync System | matrix | `app.kubernetes.io/name=sync-system` | Bash script logs |

### Ensure Pods Have Annotation

Verify pods have the required annotation:

```bash
# Check if annotation exists
kubectl get pod <pod-name> -n matrix -o yaml | grep prometheus.io/scrape

# If missing, add to deployment/statefulset template:
kubectl patch deployment <deployment-name> -n matrix -p '
{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "prometheus.io/scrape": "true"
        }
      }
    }
  }
}'
```

## LogQL Queries

### Basic Queries

**All logs from matrix namespace**:
```logql
{namespace="matrix"}
```

**Synapse main process logs**:
```logql
{namespace="matrix", app_kubernetes_io_name="synapse", app_kubernetes_io_instance="main"}
```

**Synapse worker logs**:
```logql
{namespace="matrix", app_kubernetes_io_component="worker"}
```

**Synapse LI logs**:
```logql
{namespace="matrix", matrix_instance="li"}
```

### Filtering Logs

**Error logs only**:
```logql
{namespace="matrix"} |= "ERROR"
```

**Logs containing "database"**:
```logql
{namespace="matrix"} |= "database"
```

**Logs NOT containing "health"**:
```logql
{namespace="matrix"} != "health"
```

**Case-insensitive regex**:
```logql
{namespace="matrix"} |~ "(?i)(error|fatal|critical)"
```

### Structured Log Parsing

**Parse JSON logs**:
```logql
{namespace="matrix"} | json
```

**Extract specific fields**:
```logql
{namespace="matrix"} | json | level="ERROR"
```

**Parse key-value pairs**:
```logql
{namespace="matrix"} | logfmt | level="error"
```

**Parse custom format**:
```logql
{namespace="matrix"} | regexp "level=(?P<level>\\w+)"
```

### Aggregations and Metrics

**Count errors per minute**:
```logql
sum(rate({namespace="matrix"} |= "ERROR" [1m]))
```

**Count by component**:
```logql
sum(rate({namespace="matrix"} [5m])) by (app_kubernetes_io_name)
```

**Top 10 error-generating pods**:
```logql
topk(10, sum(rate({namespace="matrix"} |= "ERROR" [5m])) by (pod))
```

**Bytes processed per second**:
```logql
sum(rate({namespace="matrix"} | unwrap bytes [5m]))
```

## Common Use Cases

### 1. Synapse Error Investigation

**Find all Synapse errors in last hour**:
```logql
{namespace="matrix", app_kubernetes_io_name="synapse"} |= "ERROR" | json
```

**Find slow database queries**:
```logql
{namespace="matrix", app_kubernetes_io_name="synapse"} |= "slow" |= "query"
```

**Find specific user errors**:
```logql
{namespace="matrix", app_kubernetes_io_name="synapse"} |= "@user:example.com" |= "ERROR"
```

### 2. PostgreSQL Troubleshooting

**Find PostgreSQL errors**:
```logql
{namespace="matrix", cnpg_io_cluster=~"matrix-postgresql.*"} |= "ERROR"
```

**Find deadlocks**:
```logql
{namespace="matrix", cnpg_io_cluster=~"matrix-postgresql.*"} |= "deadlock"
```

**Find slow queries**:
```logql
{namespace="matrix", cnpg_io_cluster=~"matrix-postgresql.*"} |= "duration:" | regexp "duration: (?P<duration>\\d+\\.\\d+) ms" | duration > 1000
```

### 3. LI Sync System Monitoring

**Media sync job logs**:
```logql
{namespace="matrix", app_kubernetes_io_component="media-sync"}
```

**Find sync failures**:
```logql
{namespace="matrix", app_kubernetes_io_name="sync-system"} |= "error"
```

**Track sync completion**:
```logql
{namespace="matrix", app_kubernetes_io_name="sync-system"} |= "Sync completed successfully"
```

### 4. NGINX Ingress Analysis

**5xx errors**:
```logql
{namespace="ingress-nginx"} | json | status >= 500
```

**Requests to specific endpoint**:
```logql
{namespace="ingress-nginx"} |= "/_matrix/client/r0/sync"
```

**Slow requests**:
```logql
{namespace="ingress-nginx"} | json | request_time > 1
```

### 5. Security Monitoring

**Failed login attempts**:
```logql
{namespace="matrix", app_kubernetes_io_name="synapse"} |= "Failed" |= "login"
```

**Unauthorized access attempts**:
```logql
{namespace="matrix"} |= "401" or |= "403"
```

**Suspicious IP activity** (if IP logged):
```logql
{namespace="matrix"} | json | remote_addr="1.2.3.4"
```

## Grafana Integration

### Access Loki in Grafana

Loki is automatically configured as a datasource in Grafana (via `prometheus-stack-values.yaml`):

```yaml
grafana:
  datasources:
    datasources.yaml:
      datasources:
        - name: Loki
          type: loki
          url: http://loki.monitoring:3100
          access: proxy
```

### Explore Logs

1. Login to Grafana
2. Navigate to **Explore** (compass icon)
3. Select **Loki** datasource
4. Enter LogQL query
5. Click **Run Query**

### Create Log Panels

1. Create new dashboard or edit existing
2. Add panel → Select Loki datasource
3. Enter LogQL query
4. Choose visualization:
   - **Logs**: Raw log output
   - **Time series**: Aggregated metrics
   - **Table**: Structured data

**Example Panel**: Synapse Error Rate
- Query: `sum(rate({namespace="matrix", app_kubernetes_io_name="synapse"} |= "ERROR" [5m]))`
- Visualization: Time series

### Live Tailing

Follow logs in real-time:
1. Go to Explore
2. Enter query
3. Click **Live** toggle in top right

## Troubleshooting

### No logs appearing in Loki

**1. Check Promtail is running**:
```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
```

**2. Check Promtail logs**:
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail
```

**3. Verify pod annotation**:
```bash
kubectl get pod <pod-name> -n matrix -o jsonpath='{.metadata.annotations}'
```

**4. Check Loki connectivity**:
```bash
kubectl exec -n monitoring <promtail-pod> -- \
  wget -O- http://loki.monitoring:3100/ready
```

### Logs delayed or missing

**Check Promtail scrape config**:
```bash
kubectl exec -n monitoring <promtail-pod> -- cat /etc/promtail/promtail.yaml
```

**Check Loki ingestion limits**:
```bash
kubectl logs -n monitoring loki-0 | grep "ingestion rate limit"
```

**Increase limits** in `loki-values.yaml`:
```yaml
loki:
  config:
    limits_config:
      ingestion_rate_mb: 20  # Increase from 10
      ingestion_burst_size_mb: 40  # Increase from 20
```

### High storage usage

**Check Loki storage**:
```bash
kubectl exec -n monitoring loki-0 -- du -sh /data/loki
```

**Reduce retention period**:
```yaml
loki:
  config:
    limits_config:
      retention_period: 360h  # Reduce to 
```

**Increase storage**:
```bash
kubectl edit pvc loki -n monitoring
# Increase size to 100Gi
```

### Query timeout

**Increase query timeout**:
```yaml
loki:
  config:
    limits_config:
      query_timeout: 5m  # Increase from default
```

**Reduce query time range**: Query last 1h instead of 7d

## Performance Optimization

### 1. Use Labels Efficiently

**Good** (low cardinality):
```logql
{namespace="matrix", app_kubernetes_io_name="synapse"}
```

**Bad** (high cardinality):
```logql
{user_id="@user:example.com"}  # Don't use user IDs as labels
```

### 2. Limit Time Range

- Query recent logs (last 1-24h) for troubleshooting
- Avoid querying 7+ days of logs

### 3. Use Filters Early

**Good** (filter before parsing):
```logql
{namespace="matrix"} |= "ERROR" | json
```

**Bad** (parse then filter):
```logql
{namespace="matrix"} | json | level="ERROR"
```

### 4. Adjust Promtail Resources

For high log volume:
```yaml
promtail:
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1Gi
```

## Log Retention

### Current Configuration

- **Retention Period**:  ()
- **Storage Size**: 50Gi
- **Estimated Log Volume**: 10-20GB/day at 20K CCU

### Adjusting Retention

**Increase retention to **:
```yaml
loki:
  config:
    limits_config:
      retention_period: 1440h  # 
    table_manager:
      retention_period: 1440h

  persistence:
    size: 100Gi  # Double storage
```

**Decrease retention to **:
```yaml
loki:
  config:
    limits_config:
      retention_period: 168h  # 
    table_manager:
      retention_period: 168h
```

## References

- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [LogQL Query Language](https://grafana.com/docs/loki/latest/logql/)
- [Promtail Configuration](https://grafana.com/docs/loki/latest/clients/promtail/)
- [Grafana Explore](https://grafana.com/docs/grafana/latest/explore/)
