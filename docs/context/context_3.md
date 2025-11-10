# FINAL PATCH: Complete Technical Context & Implementation Details

## 1. System Requirements & Prerequisites

### Server Operating System
- **Required**: Debian 12 (Bookworm) or Ubuntu 22.04 LTS
- **Kernel**: 5.15+ recommended
- **Architecture**: x86_64 (amd64) or arm64
- **Filesystem**: ext4 or XFS (for data volumes)
- **Avoid**: Older Ubuntu versions, CentOS/RHEL (unless tested)

### Software Version Requirements
- **Docker**: 24.0+ (install via official Docker repo, not distro packages)
- **Docker Compose**: v2.20+ (plugin version, not standalone)
- **Ansible**: 2.13+ (on control machine only)
- **Python**: 3.9+ (for Ansible on control machine)
- **Git**: Any recent version

### System Tuning (ALL servers)
```bash
# File descriptor limits (in /etc/security/limits.conf)
* soft nofile 65535
* hard nofile 65535

# Kernel parameters (in /etc/sysctl.conf)
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 2097152
vm.swappiness = 10  # Reduce swap usage
```

### Time Synchronization (CRITICAL)
- **Must have**: NTP/chrony running on ALL servers
- Patroni failover timing depends on accurate clocks
- Max clock skew: <100ms between nodes
- Install: `apt install chrony`
- Configure: Point to reliable NTP source (internal or internet during setup)

### Timezone Handling
- Set all servers to UTC: `timedatectl set-timezone UTC`
- Avoids confusion with logs and timestamps
- Synapse stores timestamps in UTC internally

## 2. Playbook-Specific Critical Details

### Playbook Version & Updates
- **Repository**: https://github.com/spantaleev/matrix-docker-ansible-deploy
- **Branch**: `master` (production-ready)
- **Tested version**: Document which git commit/tag used
- **Update procedure**: `git pull && just update` (updates roles)
- **Breaking changes**: Always read CHANGELOG.md before major updates

### Inventory Structure
```
matrix-docker-ansible-deploy/
├── inventory/
│   ├── hosts                          # Server list
│   └── host_vars/
│       └── chat.z3r0d3v.com/
│           └── vars.yml               # Main configuration
│           └── vault.yml              # Secrets (optional, encrypted)
```

### Variable Precedence (Important)
1. Extra vars (`--extra-vars` in command line)
2. `inventory/host_vars/<hostname>/vars.yml`
3. `group_vars/matrix_servers` (playbook defaults)
4. Role defaults

### Docker Network Configuration
- Playbook creates `matrix` Docker network
- All services connect to this network
- IPv6: Controlled by `devture_systemd_docker_base_ipv6_enabled: true`
- Custom networks not recommended (breaks playbook assumptions)

### Ansible Vault for Secrets (Recommended)
```bash
# Create encrypted vault
ansible-vault create inventory/host_vars/chat.z3r0d3v.com/vault.yml

# Add secrets:
vault_postgres_password: "actual_password"
vault_synapse_db_password: "actual_password"
vault_turn_shared_secret: "actual_secret"

# Reference in vars.yml:
matrix_synapse_database_password: "{{ vault_postgres_password }}"
```

## 3. Configuration Deep Dive

### Worker Configuration Details

**Worker Naming Convention** (auto-generated):
- `matrix-synapse-worker-sync-0`, `matrix-synapse-worker-sync-1`, etc.
- `matrix-synapse-worker-generic-0`, etc.
- Each gets unique port starting from 18008+

**Worker Resource Allocation** (per worker):
- Sync workers: 1-4GB RAM each (heavy caching)
- Event persisters: 512MB-1GB RAM each
- Generic workers: 512MB-2GB RAM each
- Federation senders: 512MB-2GB RAM each

**Worker Restart Strategy**:
- **Adding workers**: Can be done without restarting existing workers
- **Removing workers**: Requires `setup-all` to clean up properly
- **Changing event persister count**: ALL workers must restart (playbook handles this)
- **Rolling restart**: Not built-in, must manually orchestrate via HAProxy draining

### Cache Configuration Deep Dive

**Cache Factor Formula**:
```
RAM for caches ≈ (1.5GB + 0.5GB × cache_factor) per process
Example: cache_factor=10 → ~6.5GB per process
With 20 workers: ~130GB total RAM needed
```

**Cache Expiry Settings**:
```yaml
matrix_synapse_caches_expire_caches: true
matrix_synapse_caches_cache_entry_ttl: "30m"
matrix_synapse_caches_sync_response_cache_duration: "5m"
```

**Per-Cache Tuning** (advanced):
```yaml
matrix_synapse_caches_per_cache_factors:
  get_users_in_room: 5.0
  get_room_events: 2.0
  _get_state_group_delta: 2.0
```

### Rate Limiting Configuration

**Default Limits** (adjust per scale):
```yaml
matrix_synapse_rc_message:
  per_second: 10
  burst_count: 50

matrix_synapse_rc_registration:
  per_second: 0.17
  burst_count: 3

matrix_synapse_rc_login:
  address:
    per_second: 0.17
    burst_count: 3
  account:
    per_second: 0.17
    burst_count: 3
  failed_attempts:
    per_second: 0.17
    burst_count: 3

matrix_synapse_rc_admin_redaction:
  per_second: 1
  burst_count: 50

matrix_synapse_rc_joins:
  local:
    per_second: 0.1
    burst_count: 10
  remote:
    per_second: 0.01
    burst_count: 10

matrix_synapse_rc_3pid_validation:
  per_second: 0.003
  burst_count: 5

matrix_synapse_rc_invites:
  per_room:
    per_second: 0.3
    burst_count: 10
  per_user:
    per_second: 0.003
    burst_count: 5
```

### Room Complexity Limits

**Prevent Overload from Large Rooms**:
```yaml
matrix_synapse_configuration_extension_yaml: |
  limit_remote_rooms:
    enabled: true
    complexity: 3.0  # Adjust based on testing
  
  # Additional state resolution limits
  max_state_resolution_events: 10000
```

### Media Configuration

**Upload Limits**:
```yaml
matrix_synapse_max_upload_size_mb: 100  # Adjust per scale
```

**URL Preview** (Disable for performance/security):
```yaml
matrix_synapse_url_preview_enabled: false
```

**Dynamic Thumbnails** (Performance consideration):
```yaml
# If false, must store thumbnails; if true, generates on-demand
dynamic_thumbnails: false
```

**Media Retention Policy** (Optional):
```yaml
matrix_synapse_media_retention:
  local_media_lifetime: 90d
  remote_media_lifetime: 14d
```

### State Compression

**Reduce Database Size**:
```yaml
matrix_synapse_configuration_extension_yaml: |
  state_compression:
    enabled: true
    min_event_age: 7d
```

Run manually: `docker exec matrix-synapse python -m synapse.app.admin_cmd compress-state`

### Presence Configuration

**Disable for Performance** (Recommended):
```yaml
matrix_synapse_presence_enabled: false
```
Presence generates significant load with many users online.

### Logging Configuration

**Log Levels**:
```yaml
matrix_synapse_log_level: "INFO"  # Use "DEBUG" only for troubleshooting
```

**Log Rotation** (Automatic via Docker):
- Docker handles log rotation
- Configure Docker daemon: `/etc/docker/daemon.json`
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

## 4. External Services Configuration Details

### PostgreSQL Tuning for Synapse Workload

**Essential Settings** (in Patroni config):
```yaml
postgresql:
  parameters:
    # Connection settings
    max_connections: 500  # Adjust for worker count
    
    # Memory (for 64GB node)
    shared_buffers: 16GB
    effective_cache_size: 48GB
    work_mem: 32MB
    maintenance_work_mem: 2GB
    
    # WAL
    wal_buffers: 64MB
    min_wal_size: 2GB
    max_wal_size: 8GB
    wal_compression: on
    
    # Checkpoints
    checkpoint_completion_target: 0.9
    checkpoint_timeout: 15min
    
    # Query planner (NVMe SSD)
    random_page_cost: 1.1
    effective_io_concurrency: 200
    
    # Aggressive autovacuum (CRITICAL for Synapse)
    autovacuum: on
    autovacuum_max_workers: 4
    autovacuum_naptime: 10s
    autovacuum_vacuum_scale_factor: 0.05
    autovacuum_analyze_scale_factor: 0.05
    autovacuum_vacuum_cost_delay: 2ms
```

**Why Aggressive Autovacuum**:
- Synapse generates massive dead tuples from events
- Standard autovacuum causes table bloat
- Performance degrades without frequent vacuuming

### PgBouncer Configuration

**Critical Settings**:
```ini
[databases]
synapse = host=patroni-primary port=5432 dbname=synapse

[pgbouncer]
pool_mode = transaction  # REQUIRED for Synapse
max_client_conn = 1000
default_pool_size = 50
reserve_pool_size = 10
reserve_pool_timeout = 5

# Timeouts
server_idle_timeout = 600
server_lifetime = 3600
server_connect_timeout = 15
query_timeout = 0
query_wait_timeout = 120

# CRITICAL: Server reset
server_reset_query = DISCARD ALL
```

### MinIO Configuration

**Distributed Mode** (4 nodes):
```yaml
# Environment for all nodes
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=CHANGE_STRONG_PASSWORD
MINIO_VOLUMES="http://minio{1...4}.internal:9000/data{1...4}"
MINIO_OPTS="--console-address :9001"
```

**Bucket Configuration**:
```bash
# After cluster start
mc alias set mycluster http://minio1.internal:9000 minioadmin PASSWORD
mc mb mycluster/synapse-media
mc policy set download mycluster/synapse-media  # If public read needed
mc admin user add mycluster synapse-user STRONG_PASSWORD
mc admin policy attach mycluster readwrite --user synapse-user
```

**Healing Verification**:
```bash
mc admin heal mycluster/synapse-media --recursive
mc admin info mycluster
```

### HAProxy Configuration Details

**Connection Timeouts**:
```
timeout connect 5s
timeout client 50s
timeout server 50s
timeout tunnel 1h  # For WebSocket
```

**Load Balancing Algorithm**:
```
balance leastconn  # For Synapse workers (varying request duration)
```

**Session Persistence** (for sync endpoints):
```
cookie SERVERID insert indirect nocache
stick-table type ip size 200k expire 30m
stick on src
```

**Health Check Details**:
```
option httpchk GET /health HTTP/1.1\r\nHost:\ chat.z3r0d3v.com
http-check expect status 200
default-server inter 3s fall 3 rise 2 slowstart 60s
```

### Coturn Configuration

**Full Config** (production-ready):
```
# Listening
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
relay-ip=SERVER_PRIVATE_IP
external-ip=SERVER_PUBLIC_OR_PRIVATE_IP

# Auth
use-auth-secret
static-auth-secret=STRONG_SHARED_SECRET
realm=chat.z3r0d3v.com

# Ports
min-port=49152
max-port=65535

# Security
no-multicast-peers
no-loopback-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=172.16.0.0-172.31.255.255

# Quotas
user-quota=12
total-quota=1200

# TLS (if using)
cert=/path/to/cert.pem
pkey=/path/to/key.pem

# Logging
log-file=/var/log/turnserver/turn.log
verbose

# IMPORTANT: Do NOT set no-tcp-relay
```

### LiveKit Multi-Node Configuration

**Redis Setup** (for coordination):
```yaml
# Separate Redis instance (not Synapse's Valkey)
redis:
  image: redis:7-alpine
  ports:
    - "6379:6379"
  volumes:
    - redis_data:/data
```

**LiveKit Config** (each node):
```yaml
port: 7880
bind_addresses:
  - "0.0.0.0"

rtc:
  tcp_port: 7881
  port_range_start: 50100
  port_range_end: 50200
  use_external_ip: true

redis:
  address: redis.internal:6379

keys:
  CHANGE_API_KEY: CHANGE_SECRET

room:
  auto_create: false
  
logging:
  level: info
```

## 5. Backup & Restore Detailed Procedures

### Database Backup Strategy

**Using pgBackRest** (Recommended):
```bash
# On backup server
# Install pgBackRest, configure stanza

# Full backup (weekly)
pgbackrest --stanza=synapse --type=full backup

# Differential backup (daily)
pgbackrest --stanza=synapse --type=diff backup

# Incremental backup (hourly if needed)
pgbackrest --stanza=synapse --type=incr backup

# Verify backups
pgbackrest --stanza=synapse info
```

**Using pg_basebackup + WAL**:
```bash
# On backup server
# Setup WAL archiving on Patroni first

# Base backup with throttling
pg_basebackup -h patroni-replica -U replication_user \
  -D /backup/postgres/base-$(date +%Y%m%d) \
  --format=tar --gzip --checkpoint=fast \
  --max-rate=50M  # Throttle to reduce I/O impact

# Continuous WAL archiving (configured in Patroni)
```

**Exclude One-Time Keys**:
```bash
# If using pg_dump
pg_dump -Fc \
  --exclude-table-data=e2e_one_time_keys_json \
  -h patroni-replica -U synapse synapse > backup.dump
```

### Media Backup Procedure

**Rsync Script** (run on backup server):
```bash
#!/bin/bash
# backup-media.sh

REMOTE_HOST="synapse.internal"
REMOTE_PATH="/matrix/synapse/media-store"
LOCAL_PATH="/backup/synapse-media"
DATE=$(date +%Y%m%d-%H%M%S)

# Pull with throttling and resume support
rsync -avz --progress \
  --partial --partial-dir=.rsync-partial \
  --append-verify \
  --bwlimit=50000 \
  --include='local_content/***' \
  --include='local_thumbnails/***' \
  --exclude='remote_*' \
  --exclude='url_*' \
  --exclude='preview_*' \
  ${REMOTE_HOST}:${REMOTE_PATH}/ \
  ${LOCAL_PATH}/current/

# Create snapshot with hardlinks (space-efficient)
cp -al ${LOCAL_PATH}/current ${LOCAL_PATH}/${DATE}

# Keep last 7 snapshots
ls -dt ${LOCAL_PATH}/*/ | tail -n +8 | xargs rm -rf

echo "Backup completed: ${DATE}"
```

**Run with low priority**:
```bash
nice -n 19 ionice -c3 /usr/local/bin/backup-media.sh
```

### Restore Procedure

**Database Restore**:
```bash
# Stop Synapse
systemctl stop matrix-synapse matrix-synapse-worker-*

# Restore database
pgbackrest --stanza=synapse --type=time \
  --target="2024-12-01 14:00:00" restore

# CRITICAL: Truncate one-time keys
psql -h patroni-primary -U synapse synapse <<EOF
TRUNCATE e2e_one_time_keys_json;
EOF

# Start Synapse
systemctl start matrix-synapse
systemctl start matrix-synapse-worker-*
```

**Media Restore**:
```bash
# Stop Synapse
systemctl stop matrix-synapse matrix-synapse-worker-*

# Restore media
rsync -avz --delete \
  /backup/synapse-media/current/ \
  /matrix/synapse/media-store/

# Fix permissions
chown -R matrix:matrix /matrix/synapse/media-store/

# Start Synapse
systemctl start matrix-synapse matrix-synapse-worker-*
```

## 6. Certificate Management Strategy

### During Initial Setup (with Internet)

**Using Let's Encrypt**:
```bash
# On HAProxy server (before intranet transition)
certbot certonly --standalone \
  -d chat.z3r0d3v.com \
  --agree-tos --email admin@example.com

# Combine for HAProxy
cat /etc/letsencrypt/live/chat.z3r0d3v.com/fullchain.pem \
    /etc/letsencrypt/live/chat.z3r0d3v.com/privkey.pem \
    > /etc/haproxy/certs/chat.z3r0d3v.com.pem

chmod 600 /etc/haproxy/certs/chat.z3r0d3v.com.pem
```

### Post-Intranet (Manual Renewal)

**Option 1: Internal CA**:
```bash
# Create internal CA (one-time)
# Distribute CA cert to all clients
# Issue certificates from internal CA
# Renew periodically (e.g., annually)
```

**Option 2: Long-Lived Certificates**:
```bash
# Obtain 90-day Let's Encrypt cert
# Copy to all servers
# Document renewal procedure before expiry
# Requires temporary internet access for renewal
```

**Copy Certificates to All Servers**:
```bash
# On HAProxy
tar -czf certs-$(date +%Y%m%d).tar.gz /etc/letsencrypt/

# Transfer to other servers
scp certs-*.tar.gz coturn1:/tmp/
scp certs-*.tar.gz livekit1:/tmp/

# Extract on each server
tar -xzf /tmp/certs-*.tar.gz -C /
```

## 7. Monitoring & Alerting Details

### Prometheus Configuration

**Scrape Configs** (in prometheus.yml):
```yaml
scrape_configs:
  - job_name: 'synapse-main'
    static_configs:
      - targets: ['synapse.internal:9100']
  
  - job_name: 'synapse-workers'
    static_configs:
      - targets:
        - 'synapse.internal:18008'  # worker-sync-0
        - 'synapse.internal:18009'  # worker-sync-1
        # ... all workers
  
  - job_name: 'postgres'
    static_configs:
      - targets:
        - 'patroni1.internal:9187'
        - 'patroni2.internal:9187'
        - 'patroni3.internal:9187'
  
  - job_name: 'haproxy'
    static_configs:
      - targets: ['haproxy1.internal:8404']
  
  - job_name: 'node-exporters'
    static_configs:
      - targets:
        - 'synapse.internal:9100'
        - 'patroni1.internal:9100'
        # ... all servers
```

### Critical Alert Rules

**alertmanager.rules.yml**:
```yaml
groups:
  - name: critical
    interval: 30s
    rules:
      - alert: SynapseDown
        expr: up{job="synapse-main"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Synapse main process down"
      
      - alert: PostgreSQLDown
        expr: up{job="postgres"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL down"
      
      - alert: HighSyncLatency
        expr: histogram_quantile(0.95, rate(synapse_http_server_response_time_seconds_bucket{servlet="SyncRestServlet"}[5m])) > 0.3
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Sync p95 latency > 300ms"
      
      - alert: LowCacheHitRatio
        expr: pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read) < 0.95
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "DB cache hit ratio < 95%"
```

## 8. Troubleshooting & Validation

### Pre-Deployment Validation Script

```bash
#!/bin/bash
# pre-deploy-check.sh

echo "=== Pre-Deployment Validation ==="

# Check SSH connectivity to all servers
for host in synapse patroni1 patroni2 patroni3 minio1 minio2 minio3 minio4 haproxy1 haproxy2 coturn1 coturn2 livekit1 livekit2 monitoring backup; do
  echo -n "Checking ${host}.internal: "
  ssh -o ConnectTimeout=5 ${host}.internal "echo OK" 2>/dev/null || echo "FAILED"
done

# Check DNS resolution (/etc/hosts)
echo -n "Checking DNS resolution: "
ping -c1 chat.z3r0d3v.com >/dev/null 2>&1 && echo "OK" || echo "FAILED"

# Check time synchronization
echo "=== Time Sync Check ==="
for host in synapse patroni1 patroni2 patroni3; do
  echo -n "${host}: "
  ssh ${host}.internal "date +%s"
done

# Check available disk space
echo "=== Disk Space Check ==="
for host in synapse patroni1 minio1; do
  echo "${host}:"
  ssh ${host}.internal "df -h /"
done

# Check required ports are not in use
echo "=== Port Check on Synapse Server ==="
ssh synapse.internal "netstat -tuln | grep -E ':(8008|443|80)'"

echo "=== Validation Complete ==="
```

### Post-Deployment Health Check

```bash
#!/bin/bash
# post-deploy-check.sh

echo "=== Post-Deployment Health Check ==="

# Check HAProxy
echo -n "HAProxy VIP: "
curl -s -o /dev/null -w "%{http_code}" http://10.0.1.10 && echo " OK" || echo " FAILED"

# Check Synapse
echo -n "Synapse API: "
curl -s https://chat.z3r0d3v.com/_matrix/client/versions | grep -q "v1.1" && echo "OK" || echo "FAILED"

# Check federation (if enabled)
echo -n "Federation: "
curl -s https://chat.z3r0d3v.com:8448/_matrix/federation/v1/version | grep -q "server_version" && echo "OK" || echo "FAILED"

# Check Element Web
echo -n "Element Web: "
curl -s -o /dev/null -w "%{http_code}" https://chat.z3r0d3v.com | grep -q "200" && echo "OK" || echo "FAILED"

# Check Synapse Admin
echo -n "Synapse Admin: "
curl -s -o /dev/null -w "%{http_code}" https://chat.z3r0d3v.com/synapse-admin | grep -q "200" && echo "OK" || echo "FAILED"

# Check Grafana
echo -n "Grafana: "
curl -s -o /dev/null -w "%{http_code}" http://monitoring.internal:3000 | grep -q "200" && echo "OK" || echo "FAILED"

# Check Prometheus targets
echo "Prometheus Targets:"
curl -s http://monitoring.internal:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.job): \(.health)"'

# Check database replication
echo "PostgreSQL Replication:"
ssh patroni1.internal "sudo -u postgres psql -c 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'"

# Check worker health
echo "Worker Health:"
for port in 18008 18009 18010 18011; do
  echo -n "  Port ${port}: "
  curl -s http://synapse.internal:${port}/health | grep -q "OK" && echo "OK" || echo "FAILED"
done

echo "=== Health Check Complete ==="
```

### Common Issues & Solutions

**Issue**: Workers not starting
```bash
# Check worker logs
journalctl -u matrix-synapse-worker-sync-0 -n 50

# Common cause: Port conflict
netstat -tuln | grep 18008

# Solution: Ensure no port conflicts
```

**Issue**: Database connection exhausted
```bash
# Check current connections
psql -h patroni-primary -U postgres -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"

# Increase max_connections in Patroni config
# Increase pool size in PgBouncer
```

**Issue**: High sync latency
```bash
# Check sync worker count
docker ps | grep matrix-synapse-worker-sync

# Check sync worker CPU usage
docker stats

# Solution: Increase sync worker count in vars.yml
```

**Issue**: Media not loading
```bash
# Check MinIO cluster health
mc admin info mycluster/

# Check Synapse S3 connection
docker logs matrix-synapse | grep -i s3

# Verify bucket permissions
mc policy list mycluster/synapse-media
```

## 9. Final Production Checklist

**Before Go-Live**:
- [ ] All services health checks pass
- [ ] Monitoring dashboards showing metrics
- [ ] All Prometheus targets UP
- [ ] Test user can login via Element Web
- [ ] Test message send/receive
- [ ] Test file upload/download
- [ ] Test 1:1 voice call (TURN working)
- [ ] Test group video call (LiveKit working)
- [ ] Synapse Admin accessible (from allowed IPs only)
- [ ] Database replication verified (Patroni)
- [ ] MinIO healing status clean
- [ ] HAProxy failover tested
- [ ] Patroni failover tested
- [ ] Backup procedures tested
- [ ] Restore procedure tested (CRITICAL)
- [ ] /etc/hosts configured on all servers
- [ ] Firewall rules persistent after reboot
- [ ] Certificates valid and copied to all servers
- [ ] Time sync verified (chrony running)
- [ ] Log rotation configured
- [ ] Alert rules configured
- [ ] Documentation reviewed and accessible to ops team

