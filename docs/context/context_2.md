# PATCH: Additional Critical Context & Requirements

## Missing Technical Details

### 1. Playbook-Specific Configurations

**HTTP Replication (Critical Understanding)**:
- Playbook FORCES HTTP replication on port 9093 even when Redis/Valkey enabled
- Variable: `matrix_synapse_replication_listener_enabled: true` (forced)
- Workers communicate with main process via HTTP, NOT Redis pubsub
- Redis/Valkey only for caching (explicit correction from agent findings)

**Instance Map**:
- Playbook auto-generates `matrix_synapse_instance_map` for same-host workers
- Maps worker names to host:port for replication routing
- Currently does NOT support multi-host worker distribution
- All workers MUST run on same host as main Synapse process

**Metrics Configuration**:
- Synapse metrics default port: **9100** (not 9000)
- Each worker exposes separate metrics endpoint
- Prometheus must scrape main process + all workers individually
- Variable: `matrix_synapse_metrics_port: 9100`

**S3 Media Migration**:
- NOT an Ansible tag, it's a systemd timer service
- Service: `matrix-synapse-s3-storage-provider-migrate.service`
- Timer: Runs on schedule (default: `05:00:00` daily)
- Variable: `matrix_synapse_ext_synapse_s3_storage_provider_periodic_migration_schedule`

**TURN Port Defaults**:
- Playbook default: `49152-49172` (NOT 49152-65535)
- Variables: `matrix_coturn_turn_udp_min_port: 49152`, `matrix_coturn_turn_udp_max_port: 49172`
- Must widen range in configuration or firewall rules if needed

**PostgreSQL Connection Auto-tuning**:
- Playbook automatically sets `postgres_max_connections = 500` when workers enabled
- Default without workers: `200`
- For external Patroni: Must manually configure in PostgreSQL, playbook won't tune it

### 2. External Service Technical Requirements

**PgBouncer Critical Settings**:
- MUST use `pool_mode = transaction` (required for Synapse)
- NOT session mode or statement mode
- Set `server_reset_query = DISCARD ALL`
- Recommended: `default_pool_size = 50`, `max_client_conn = 1000`

**Patroni + etcd Architecture**:
- etcd cluster: 3 nodes for DCS (Distributed Configuration Store)
- etcd provides consensus/quorum for leader election
- Each Patroni node runs PostgreSQL + Patroni daemon
- etcd can run on same nodes as Patroni or separate
- etcd ports: 2379 (client), 2380 (peer)

**MinIO Erasure Coding Details**:
- 4 nodes = 16 drives (4 drives per node) = single erasure set
- Default EC:4 parity = 12 data + 4 parity shards
- Can lose up to 4 drives total (or 1 complete node) and remain operational
- Usable capacity: 75% of raw (with EC:4)
- Healing: Object-level, not volume-level (unlike RAID)

**Coturn CRITICAL**:
- Do NOT set `no-tcp-relay` in config (user's previous docs had this)
- Many corporate/restrictive networks REQUIRE TCP relay as fallback
- UDP may be blocked, TCP relay needed for those clients
- Keep TCP relay enabled unless you've validated 100% UDP access

**LiveKit Multi-Node Requirements**:
- MUST have Redis for coordination (not Valkey - separate instance)
- Redis handles: room data, message bus, cluster awareness
- Each LiveKit node reports stats to Redis periodically
- Nodes form distributed mesh for inter-region relay
- Each room still confined to single node (current limitation)

### 3. HAProxy Advanced Configuration

**Authorization Header Stripping (Correct Syntax)**:
```
# Correct syntax (previous docs had wrong ACL)
http-request del-header Authorization
# NOT: http-request del-header Authorization if { capture.req.hdr(0) -m found }
```

**Health Check Configuration**:
- Use `/health` endpoint (available since Synapse v1.19.0)
- Not `/_synapse/metrics` for health checks
- Configure proper fall/rise thresholds

**Connection Draining**:
- Use HAProxy `slowstart` parameter for gradual traffic ramp
- Important when restarting workers or scaling

### 4. Backup & Restore Technical Details

**Database Backup Tools**:
- **pgBackRest**: Recommended for large DBs, handles incremental + WAL
- **pg_basebackup + WAL archiving**: Core PostgreSQL approach
- **Logical dumps (pg_dump)**: Simpler but slower to restore

**CRITICAL Backup Items**:
1. PostgreSQL database (with exclusion: `e2e_one_time_keys_json`)
2. Media: `local_content` + `local_thumbnails` directories ONLY
3. Skip: `remote_content`, `remote_thumbnails`, `url_cache*` (refetchable)
4. Synapse signing key: `/matrix/synapse/config/*.signing.key` (CRITICAL)
5. Config files: `homeserver.yaml`, worker configs
6. Secrets: macaroon, registration secrets, OIDC secrets

**e2e_one_time_keys_json Handling**:
- MUST exclude from backup or TRUNCATE after restore
- Contains one-time keys that should never be reused
- Reusing causes E2EE decryption failures
- Explicit requirement from Synapse documentation

**Media Sync Strategy**:
- Pull from backup server (not push from primary)
- Use `rsync` with flags: `--partial`, `--append-verify`, `--bwlimit`
- Run with `ionice -c3`, `nice -n 19` to minimize primary impact
- Include only `local_content` and optionally `local_thumbnails`
- Exclude patterns: `remote_*`, `url_*`

**Backup from Patroni Replica**:
- Run backups from replica node to eliminate primary load
- Replica stays in sync via streaming replication
- No performance impact on primary

### 5. Performance & Monitoring Targets

**Specific Thresholds** (for alerting):
- Sync latency (p95): <150ms (warning), >300ms (critical)
- Event persist lag: <100ms (good), >500ms (critical)
- DB cache hit ratio: >99% (good), <95% (critical)
- DB connection pool: <70% (good), >80% (warning)
- CPU sustained: <70% (good), >80% (action needed)
- RAM usage: <85% (good), >90% (critical)

**Prometheus Scrape Targets**:
- Main Synapse process: `matrix-synapse:9100`
- Each worker: `matrix-synapse-worker-TYPE-N:9100`
- PostgreSQL exporter: If enabled
- Node exporter: System metrics
- HAProxy: Stats port 8404
- Coturn: If metrics enabled
- LiveKit: Monitoring endpoints

### 6. Federation Configuration Details

**Default State**: Enabled in initial configuration
**Disable Post-Deployment**: Change `matrix_synapse_federation_enabled: false` and re-run playbook
**Port 8448 Handling**: 
- If HAProxy terminates TLS: Keep `matrix_synapse_tls_federation_listener_enabled: false`
- HAProxy routes port 8448 → Traefik local port → Synapse
**Well-known Files**: Served automatically by playbook when `matrix_static_files_container_labels_base_domain_enabled: true`

### 7. Element Web & Synapse Admin

**Element Configuration Method**:
- Use `matrix_client_element_configuration_extension_json` (JSON format)
- NOT `matrix_client_element_setting_defaults_custom` (doesn't exist in this form)

**Jitsi Integration** (if needed):
- Variable: `matrix_client_element_jitsi_preferred_domain` (note: not `jitsi_preferredDomain`)

**Synapse Admin Path Rules**:
- MUST be `/` or NOT end with slash (e.g., `/synapse-admin` is valid)
- Playbook enforces this validation
- Auto-exposes `/_synapse/admin` API when Synapse Admin enabled
- Variable: `matrix_synapse_admin_container_labels_traefik_path_prefix`

**Synapse Admin IP Restrictions** (CRITICAL for production):
```yaml
matrix_synapse_admin_container_labels_traefik_ipallowlist_sourcerange:
  - "10.0.0.0/8"
  - "192.168.0.0/16"
  - "YOUR_ADMIN_IP/32"
```

### 8. Deployment Order & Dependencies

**Correct Sequence**:
1. Deploy etcd cluster (3 nodes)
2. Deploy Patroni PostgreSQL cluster (3 nodes)
3. Deploy PgBouncer (with VIP if separate)
4. Create database `synapse` and user
5. Deploy MinIO cluster (4 nodes)
6. Create bucket and user in MinIO
7. Deploy HAProxy + Keepalived (2 nodes)
8. Deploy Coturn TURN servers (2+ nodes)
9. Deploy LiveKit mesh with Redis (2-4 nodes)
10. Configure /etc/hosts on all servers
11. Deploy Synapse via playbook
12. Deploy monitoring to dedicated server
13. Configure backup server
14. Test and verify all services
15. Create admin user

**Critical**: External services must be operational before playbook runs

### 9. Network Transition Details

**Initial Setup Phase**:
- All servers have internet + public IPs
- Install packages, download images
- Obtain SSL certificates (if using Let's Encrypt)

**Transition to Intranet**:
- Configure `/etc/hosts` on ALL servers with private IPs
- Map `chat.z3r0d3v.com` to HAProxy VIP (private IP)
- Map all service hostnames to private IPs
- Cut internet access
- Servers communicate only via private network

**DNS Resolution Pattern** (in /etc/hosts):
```
# HAProxy VIP
10.0.1.10    chat.z3r0d3v.com

# Internal services
10.0.2.11    patroni1.internal
10.0.2.12    patroni2.internal
10.0.2.13    patroni3.internal
10.0.3.21    minio1.internal
# ... etc for all services
```

### 10. Scaling & Resource Adjustment

**Worker Count Formulas** (refined):
- Sync workers: `CCU / 200` (e.g., 10K CCU = 50 ideal, practical max ~8-12)
- Generic workers: `sync_workers / 2`
- Federation senders: `3-4` (fixed, unless heavy federation)
- Event persisters: `1-2` for most deployments

**Database Pool Sizing Formula**:
```
Required connections = (main_process_pools × 1) + (worker_count × worker_pools) + reserved
Example for Large (8 sync + 4 generic + 4 fed + 2 persist = 18 workers):
= (1 × 10) + (18 × 10) + 20 = 210 minimum
Recommended PostgreSQL max_connections = 300-500
```

**Storage Growth Estimates**:
- Database: ~100-500GB for 10K users (depends on message retention)
- Media: 200-500GB/day new uploads (per requirements)
- Plan storage capacity: 3-6 months growth minimum

### 11. Security Hardening

**No Cloud Services Requirement**:
- User explicitly stated: Cannot use AWS, Azure, GCP paid services
- Can use internet for downloads/updates only
- All infrastructure self-hosted on customer premises
- No external dependencies post-deployment

**TLS Certificate Strategy** (for intranet):
- Obtain Let's Encrypt certificates during initial setup (with internet)
- Copy certificates to all servers needing them
- Post-transition: Manual renewal not possible via ACME
- Alternative: Internal CA + self-signed certificates
- Document certificate renewal procedures

### 12. Update & Maintenance Procedures

**Ansible Playbook Update Tags**:
- `install-all`: Routine updates, doesn't remove services
- `setup-all`: Full setup including cleanup (use when removing services)
- `setup-synapse,start`: Update only Synapse
- `setup-all,start`: Required when changing worker topology

**Worker Topology Changes**:
- Adding/removing workers: Use `setup-all` tag (not just `install-all`)
- Adding event persisters: ALL workers must restart
- Changing worker counts: Update vars.yml, run `setup-all,start`

**Federation Toggle**:
- To disable: Set `matrix_synapse_federation_enabled: false`, run `setup-all,start`
- To enable: Set `matrix_synapse_federation_enabled: true`, run `setup-all,start`
- Port 8448 firewall rule changes if needed

### 13. Testing & Validation Checklist

**Post-Deployment Tests**:
- [ ] User login works (Element Web)
- [ ] Send/receive messages
- [ ] Upload/download files
- [ ] 1:1 voice/video call (Coturn + TURN)
- [ ] Group video call (LiveKit + Element Call)
- [ ] Synapse Admin UI accessible (from allowed IPs only)
- [ ] Federation test (if enabled): Join public room like `#matrix:matrix.org`
- [ ] Metrics visible in Grafana
- [ ] All Prometheus targets showing "UP"
- [ ] Database failover test (stop Patroni primary)
- [ ] HAProxy failover test (stop HAProxy primary)
- [ ] Backup restore test (critical - must verify)

### 14. Known Limitations & Constraints

**From Playbook**:
- No Redis Cluster/Sentinel support
- No multi-host Synapse worker distribution
- Single Valkey instance only
- Can't deploy Patroni/MinIO (external services)
- Can't deploy multi-node LiveKit mesh

**From Synapse**:
- Each room confined to single node
- Main process cannot scale horizontally (single instance)
- Workers scale horizontally but with coordination overhead

**From LiveKit**:
- Room must fit on single node
- Scale by adding nodes for more concurrent rooms
- Not by making single room span nodes

### 15. Documentation Value Replacement Examples

**Instead of generic placeholders**:
```
# Bad (vague):
server_ip: 192.168.1.10

# Good (explicit):
server_ip: 192.168.1.10  # CHANGE_TO_YOUR_PATRONI_NODE1_PRIVATE_IP
```

**For every configuration file**:
- Mark EVERY value needing change
- Explain what it should be changed to
- Provide example values
- Reference where to find the actual value

**For every command**:
- State which server to run on
- State as which user (root/sudo)
- State working directory
- State expected output
- State what to do if it fails

### 16. Cost & Resource Notes

**User didn't request cost estimates** - focus on technical correctness
**Resource allocation is specified per scale** - document clearly
**No budget constraints mentioned** - assume resources available

### 17. Monitoring Dashboard Requirements

**Must provide/document**:
- Synapse-specific Grafana dashboard (from Synapse repo)
- PostgreSQL monitoring dashboard
- System metrics dashboard (node exporter)
- HAProxy stats dashboard
- Custom dashboards for critical metrics

**Alert Rules Needed**:
- Service down alerts
- Performance degradation alerts
- Resource exhaustion alerts
- Replication lag alerts
- Certificate expiry warnings

This patch captures all missing technical details, corrections, and requirements not explicitly stated in the main context document.
