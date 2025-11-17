# PostgreSQL Infrastructure - CloudNativePG

## Overview

This directory contains the PostgreSQL cluster configurations using [CloudNativePG](https://cloudnative-pg.io/) operator.

**Why CloudNativePG instead of simple StatefulSet?**
- ESS Community uses simple PostgreSQL StatefulSet (1 replica) for development/community use
- Our requirements demand production-grade HA for 100-20K CCU
- CloudNativePG provides:
  - Automatic failover
  - Synchronous replication
  - Built-in backup/restore
  - Point-in-time recovery (PITR)
  - Zero-downtime updates

## Architecture

### Main Cluster (`matrix-postgresql`)
- **Instances**: 3 (1 primary + 2 replicas)
- **Sync Replicas**: 1-2 (configurable)
- **Storage**: 500Gi (scales with usage)
- **Databases**:
  - `matrix` - Main Synapse database
  - `matrix_authentication_service` - MAS database
  - `keyvault` - LI key vault database

**Failover Time**: 30-60 seconds automatic

### LI Cluster (`matrix-postgresql-li`)
- **Instances**: 2 (1 primary + 1 replica)
- **Sync Replicas**: 1
- **Storage**: 1Ti (larger due to infinite message retention)
- **Databases**:
  - `matrix_li` - LI instance Synapse database (populated via sync)

**Read-Only Mode**: Enabled by default to prevent accidental writes

## Prerequisites

1. **CloudNativePG Operator**:
```bash
kubectl apply -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml
```

2. **MinIO for Backups** (see `../03-minio/`)

3. **Secrets**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: matrix
stringData:
  access-key: <access-key>
  secret-key: <secret-key>
```

## Deployment

Deploy in order:

```bash
# 1. Deploy main cluster
kubectl apply -f main-cluster.yaml

# Wait for cluster to be ready
kubectl wait --for=condition=Ready cluster/matrix-postgresql -n matrix --timeout=10m

# 2. Deploy LI cluster
kubectl apply -f li-cluster.yaml

kubectl wait --for=condition=Ready cluster/matrix-postgresql-li -n matrix --timeout=10m

# 3. Enable scheduled backups
kubectl apply -f scheduled-backup.yaml
```

## Verification

### Check Cluster Status

```bash
# Main cluster
kubectl get cluster matrix-postgresql -n matrix

# LI cluster
kubectl get cluster matrix-postgresql-li -n matrix
```

Expected output:
```
NAME                 AGE   INSTANCES   READY   STATUS                     PRIMARY
matrix-postgresql    5m    3           3       Cluster in healthy state   matrix-postgresql-1
```

### Check Pods

```bash
kubectl get pods -n matrix -l cnpg.io/cluster=matrix-postgresql
```

Expected:
- 3 pods running for main cluster
- 2 pods running for LI cluster

### Check Replication Status

```bash
kubectl exec -n matrix matrix-postgresql-1 -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### Check Synchronous Replication

```bash
kubectl exec -n matrix matrix-postgresql-1 -- psql -U postgres -c "SHOW synchronous_standby_names;"
```

Should show at least 1 standby in sync.

## Connections

### From Synapse (Main Instance)

```yaml
database:
  name: psycopg2
  args:
    user: synapse
    password: <from-secret>
    database: matrix
    host: matrix-postgresql-rw
    port: 5432
    sslmode: require
    cp_min: 5
    cp_max: 10
```

**Services Created**:
- `matrix-postgresql-rw` - Read-write (primary)
- `matrix-postgresql-r` - Read-only (any replica)
- `matrix-postgresql-ro` - Read-only (replicas only)

### From Synapse-LI (LI Instance)

```yaml
database:
  name: psycopg2
  args:
    user: synapse_li
    password: <from-secret>
    database: matrix_li
    host: matrix-postgresql-li-ro  # Read-only service
    port: 5432
    sslmode: require
    cp_min: 5
    cp_max: 10
```

**Important**: LI instance uses read-only service since data comes from sync system.

## Backup & Restore

### Manual Backup

```bash
# Trigger backup for main cluster
kubectl cnpg backup matrix-postgresql -n matrix

# Trigger backup for LI cluster
kubectl cnpg backup matrix-postgresql-li -n matrix
```

### List Backups

```bash
kubectl get backups -n matrix
```

### Restore from Backup

Create a new cluster from backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: matrix-postgresql-restored
spec:
  instances: 3
  bootstrap:
    recovery:
      backup:
        name: matrix-postgresql-<timestamp>
```

### Point-in-Time Recovery (PITR)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: matrix-postgresql-pitr
spec:
  instances: 3
  bootstrap:
    recovery:
      recoveryTarget:
        targetTime: "2025-11-17 12:00:00"
      backup:
        name: matrix-postgresql-<timestamp>
```

## Monitoring

### Prometheus Metrics

CloudNativePG exposes Prometheus metrics automatically. PodMonitors are enabled in both clusters.

**Key Metrics**:
- `cnpg_pg_replication_lag` - Replication lag in bytes
- `cnpg_pg_replication_in_recovery` - Whether instance is in recovery
- `cnpg_pg_database_size_bytes` - Database size
- `cnpg_pg_stat_archiver_archived_count` - WAL archive count

### Grafana Dashboard

Import CloudNativePG dashboard: https://grafana.com/grafana/dashboards/20417

## Maintenance

### Scaling Instances

```bash
# Scale main cluster to 4 instances
kubectl patch cluster matrix-postgresql -n matrix \
  --type merge -p '{"spec":{"instances":4}}'
```

### Updating PostgreSQL Version

Update the `imageName` in cluster spec and apply:

```yaml
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
```

CloudNativePG will perform a rolling update:
1. Update replicas first
2. Switchover to updated replica
3. Update old primary

### Switchover (Planned Failover)

```bash
kubectl cnpg promote matrix-postgresql-2 -n matrix
```

## Troubleshooting

### Check Logs

```bash
# Pod logs
kubectl logs -n matrix matrix-postgresql-1

# PostgreSQL logs
kubectl exec -n matrix matrix-postgresql-1 -- tail -f /var/lib/postgresql/data/log/postgresql-*.log
```

### Check Status

```bash
kubectl cnpg status matrix-postgresql -n matrix
```

### Replication Issues

```bash
# Check replication slots
kubectl exec -n matrix matrix-postgresql-1 -- \
  psql -U postgres -c "SELECT * FROM pg_replication_slots;"

# Check WAL sender processes
kubectl exec -n matrix matrix-postgresql-1 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### Backup Issues

```bash
# Check backup status
kubectl describe backup <backup-name> -n matrix

# Check barman-cloud-wal-archive logs
kubectl logs -n matrix matrix-postgresql-1 -c barman-cloud-wal-archive
```

## Logical Replication Setup (Main → LI)

**Note**: The sync system handles this automatically, but manual setup:

### On Main Cluster

```sql
-- Create publication for all tables
CREATE PUBLICATION matrix_li_pub FOR ALL TABLES;

-- Create replication slot
SELECT pg_create_logical_replication_slot('matrix_li_slot', 'pgoutput');
```

### On LI Cluster

```sql
-- Create subscription
CREATE SUBSCRIPTION matrix_li_sub
    CONNECTION 'host=matrix-postgresql-rw port=5432 dbname=matrix user=synapse password=xxx'
    PUBLICATION matrix_li_pub
    WITH (copy_data = true, create_slot = false, slot_name = 'matrix_li_slot');
```

## Security Considerations

1. **SSL/TLS**: Enabled by default, certificates managed by CloudNativePG
2. **Password Encryption**: SCRAM-SHA-256 enforced
3. **Network Policies**: See `../04-networking/networkpolicies.yaml`
4. **Superuser Access**: Limited to CloudNativePG operator
5. **Application Users**: Created with minimal required privileges

## Performance Tuning

Current settings optimized for:
- **Main Cluster**: Write-heavy workload (500 connections, 4GB shared_buffers)
- **LI Cluster**: Read-heavy workload (200 connections, 2GB shared_buffers)

### Monitoring Query Performance

```sql
-- Long running queries
SELECT pid, now() - pg_stat_activity.query_start AS duration, query
FROM pg_stat_activity
WHERE (now() - pg_stat_activity.query_start) > interval '5 minutes';

-- Index usage
SELECT schemaname, tablename, indexname, idx_scan
FROM pg_stat_user_indexes
ORDER BY idx_scan;

-- Table sizes
SELECT tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

## Differences from ESS Community

| Feature | ESS Community | This Deployment |
|---------|---------------|-----------------|
| PostgreSQL Type | StatefulSet | CloudNativePG Cluster |
| HA | No (1 replica) | Yes (3 replicas with sync) |
| Automatic Failover | No | Yes (30-60s) |
| Backup/Restore | Manual | Automated (MinIO + PITR) |
| Replication | None | Synchronous |
| Scaling | Not supported | Supported (dynamic) |
| Updates | Manual | Rolling updates |
| Target Use Case | Dev/Community (<100 users) | Production (100-20K users) |

## References

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/current/)
- [CloudNativePG Architecture](https://cloudnative-pg.io/documentation/current/architecture/)
- [Backup and Recovery](https://cloudnative-pg.io/documentation/current/backup_recovery/)
- [Monitoring](https://cloudnative-pg.io/documentation/current/monitoring/)
