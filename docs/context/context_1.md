# Complete Context Document: Matrix/Synapse Production HA Deployment

## Project Overview
Deploy production-ready Matrix/Synapse/Element messenger instances for organizational customers with full HA, scalability from 1K to 10K concurrent users, using matrix-docker-ansible-deploy playbook combined with external HA services.

## Critical Requirements

### 1. Network & DNS Configuration
- **Initial deployment**: All servers have internet access and public IPs for initial setup
- **Post-deployment**: Internet connection cut, servers communicate via private intranet
- **DNS resolution**: Use `/etc/hosts` on all servers (no DNS server)
- **Each customer**: Different private IP schemes (not standardized)
- **Example domain**: `chat.z3r0d3v.com` (used consistently in all docs)

### 2. Unified Topology Across All Scales
**CRITICAL**: Small, Medium, Large scales MUST have identical topology/architecture. Only differences:
- Number of nodes per service
- Resource allocation per server
- Number of workers

**Scale Definitions**:
- **Small**: 1,000 concurrent users
- **Medium**: 5,000 concurrent users  
- **Large**: 10,000 concurrent users (baseline for all design decisions)

### 3. External Services to Deploy
All must be production-ready, maintainable, with clear configuration:

**a) Patroni PostgreSQL HA Cluster**
- Minimum 3 nodes (all scales) - required for quorum
- Automatic failover
- Small: 3 nodes × (8 vCPU, 32GB RAM, 500GB NVMe)
- Medium: 3 nodes × (12 vCPU, 48GB RAM, 1TB NVMe)
- Large: 3 nodes × (16 vCPU, 64GB RAM, 1TB NVMe)

**b) MinIO S3-Compatible Storage**
- 4 nodes minimum (erasure coding)
- Small: 4 nodes × (4 vCPU, 16GB RAM, 2TB per node)
- Medium: 4 nodes × (8 vCPU, 32GB RAM, 4TB per node)
- Large: 4 nodes × (8 vCPU, 32GB RAM, 8TB per node)

**c) HAProxy Load Balancer + Keepalived**
- 2 nodes for VIP failover
- All scales: 2 nodes × (4 vCPU, 8GB RAM)
- TLS termination at HAProxy
- Health checks for Synapse workers

**d) Coturn TURN Servers**
- Small: 2 nodes × (4 vCPU, 8GB RAM, 1Gbps)
- Medium: 2 nodes × (4 vCPU, 8GB RAM, 2Gbps)
- Large: 3 nodes × (8 vCPU, 16GB RAM, 5Gbps)

**e) LiveKit (for Element Call/Video)**
- MUST deploy externally (playbook only deploys 1 node, insufficient)
- Distributed mesh with Redis coordination
- Small: 2 nodes × (8 vCPU, 16GB RAM)
- Medium: 3 nodes × (12 vCPU, 24GB RAM)
- Large: 4 nodes × (16 vCPU, 32GB RAM)
- Required ports: 7880/TCP, 7881/TCP, 7882/UDP, 50100-50200/UDP, 3479/UDP, 5350/TCP

**f) Monitoring Server**
- Separate server for ALL scales (maintain topology uniformity)
- Prometheus + Grafana + Exporters
- Small: 4 vCPU, 16GB RAM
- Medium: 8 vCPU, 32GB RAM
- Large: 8 vCPU, 32GB RAM

**g) Backup Server**
- Dedicated server in cluster
- Stores database backups and media sync
- Small/Medium: 4 vCPU, 16GB RAM, 2TB storage
- Large: 8 vCPU, 32GB RAM, 5TB storage

**h) Synapse Application Server**
- Runs playbook-deployed services
- Small: 16 vCPU, 64GB RAM, 500GB NVMe
- Medium: 24 vCPU, 96GB RAM, 1TB NVMe
- Large: 48 vCPU, 128GB RAM, 2TB NVMe

### 4. What Playbook Deploys
**Use playbook for**:
- Synapse + specialized workers
- Traefik reverse proxy (local routing behind HAProxy)
- Element Web client
- Synapse Admin UI
- Valkey (single instance - sufficient, NOT a bottleneck)
- Element Call frontend (but not LiveKit backend)
- Prometheus stack (on separate monitoring server)
- Node exporters

**Deploy externally**:
- Patroni/PostgreSQL (3 nodes)
- MinIO (4 nodes)
- HAProxy (2 nodes)
- Coturn (2-3 nodes)
- LiveKit SFU mesh (2-4 nodes with Redis)
- Backup infrastructure

### 5. Key Technical Decisions

**Redis/Valkey**:
- Synapse workers use HTTP replication (port 9093), NOT Redis
- Valkey used ONLY for caching
- Single Valkey instance sufficient for 10K CCU
- NOT a bottleneck
- Use playbook's Valkey deployment

**Worker Configuration**:
- Use `specialized-workers` preset (better cache locality)
- Small: 4 sync, 2 generic, 2 federation_sender, 1 event_persister
- Medium: 6 sync, 3 generic, 3 federation_sender, 2 event_persisters
- Large: 8 sync, 4 generic, 4 federation_sender, 2 event_persisters

**Database Connection Pooling**:
- Use PgBouncer (transaction mode) in front of Patroni
- Synapse → PgBouncer → HAProxy → Patroni primary
- Pool size calculation: (workers + main) × 10 connections minimum

**Patroni Configuration**:
- 3-node cluster with etcd for DCS
- Automatic failover (10-30 seconds RTO)
- Synchronous replication
- PgBouncer for connection pooling

**Federation**:
- Enabled by default in configuration
- Can be disabled post-deployment via updates
- Port 8448 handling via HAProxy → Traefik

**Traefik Behind HAProxy**:
- Disable public-facing Traefik endpoints
- Bind to localhost only
- HAProxy forwards to Traefik local ports
- HAProxy handles TLS termination

### 6. External Services Deployment Approach
**Preference**: Docker Compose where appropriate for maintainability
- Use for: MinIO, Coturn, LiveKit, HAProxy
- Use native installation for: Patroni/PostgreSQL (better control)
- Provide complete docker-compose.yml + .env for each service
- Ensure no bugs, no bottlenecks, production-ready

### 7. Backup & Restore Requirements
**Daily backups**:
- Complete PostgreSQL database (pgBackRest or pg_basebackup + WAL archiving)
- Media repository sync (local_content + local_thumbnails only, skip remote_*)
- Synapse signing key, config files, secrets
- Must be usable: can restore and run new instance with all data intact

**Critical Synapse backup notes**:
- Exclude `e2e_one_time_keys_json` table (or TRUNCATE after restore)
- Backup from Patroni replica to reduce primary load
- Media sync via rsync from backup server (pull, not push)

**Restore goal**: Start new instance, restore backup, users login with passphrase, see all rooms/messages/files exactly as before.

### 8. Updates & Maintenance
**Must document**:
- How to update existing instance safely
- Enable/disable federation post-deployment
- Change worker counts
- Scale resources
- Certificate renewal
- Database migrations
- Rollback procedures

**Federation default**: Enabled in initial configuration, can disable later via update procedure

### 9. User Management
- Use Synapse Admin UI for user management
- Only document: how to create first admin user via playbook
- No extensive user creation documentation needed

### 10. Security & Hardening
- Synapse Admin: IP-restricted (only admin networks)
- Metrics endpoints: basic auth if exposed externally
- TLS everywhere (HAProxy termination)
- Secure PostgreSQL connections
- MinIO access controls

### 11. Variable Naming & Value Replacement
**Consistency requirement**: 
- Use `chat.z3r0d3v.com` throughout ALL documentation
- Mark EVERY value that needs changing with clear explanation
- Example: `CHANGE_TO_YOUR_ACTUAL_IP` not just `192.168.1.10`
- Provide complete context for every command/configuration

### 12. Critical Fixes from Previous Issues
**Must avoid**:
- ~~Wrong variable names (e.g., `matrix_coturn_turn_shared_secret` doesn't exist)~~
- Use correct: `matrix_coturn_turn_static_auth_secret` and `matrix_synapse_turn_shared_secret`
- Missing LiveKit ports in firewall rules
- Undersized database connection pools
- Forgetting to open required ports
- Redis/Valkey confusion (it's for caching, not replication)

**Correct variables**:
- Worker preset: `matrix_synapse_workers_preset: specialized-workers`
- Element config: Use `matrix_client_element_configuration_extension_json`
- Coturn auth: `matrix_coturn_turn_static_auth_secret`
- DB pools: `matrix_synapse_database_cp_min/max` (scale appropriately)

### 13. Performance & Bottlenecks
**Monitor for**:
- Sync latency p95 <150ms
- Event persist lag <100ms
- DB cache hit ratio >99%
- DB connection pool usage <80%
- CPU usage <70% sustained

**Scaling triggers**:
- Increase worker counts first
- Scale DB nodes if query times degrade
- Add MinIO nodes if storage I/O saturated

### 14. Documentation Structure Needed

**Generate separate documents for each scale** (Small/Medium/Large):

1. **Architecture Overview** - Topology diagram, server list, IP planning
2. **Infrastructure Setup Guide** - External services step-by-step
   - Patroni + etcd deployment
   - MinIO cluster setup
   - HAProxy + Keepalived configuration
   - Coturn deployment
   - LiveKit mesh setup
   - PgBouncer configuration
3. **Playbook Configuration Guide** - Complete vars.yml with all settings
   - All matrix_synapse_* variables
   - Worker configuration
   - External service connections
   - Monitoring setup
   - Federation settings
4. **Deployment Procedures** - Exact commands, order of operations
   - Prepare servers
   - Deploy external services
   - Configure DNS (/etc/hosts)
   - Run playbook
   - Verify deployment
   - Create admin user
5. **Operations & Updates Guide**
   - Routine updates
   - Enable/disable federation
   - Scale workers
   - Certificate management
   - Health checks
6. **Backup & Restore Guide**
   - Daily backup procedures
   - Media sync
   - Restore procedures
   - DR testing

### 15. Server Count Summary

**Small Scale (1K CCU)**:
- 1× Synapse app (16 vCPU, 64GB)
- 3× Patroni (8 vCPU, 32GB each)
- 4× MinIO (4 vCPU, 16GB each)
- 2× HAProxy (4 vCPU, 8GB each)
- 2× Coturn (4 vCPU, 8GB each)
- 2× LiveKit (8 vCPU, 16GB each)
- 1× Monitoring (4 vCPU, 16GB)
- 1× Backup (4 vCPU, 16GB)
- **Total: 16 servers**

**Medium Scale (5K CCU)** - Same topology, increased resources

**Large Scale (10K CCU)** - Same topology, maximum resources

### 16. Expected Load & Capacity
- 10K concurrent users
- 50K-100K messages/day
- 200-500GB media uploads/day
- Multiple group calls (50-100 person calls)
- Heavy federation traffic

### 17. Firewall & Ports
**HAProxy** (public):
- 80/TCP, 443/TCP, 8448/TCP (federation)

**Synapse** (internal):
- 8008/TCP (from HAProxy)
- 9093/TCP (worker replication)

**Patroni** (internal):
- 5432/TCP (PostgreSQL)
- 2379-2380/TCP (etcd)

**MinIO** (internal):
- 9000/TCP (API)

**Coturn** (public):
- 3478/TCP+UDP, 5349/TCP+UDP, 49152-65535/UDP

**LiveKit** (public):
- 7880/TCP, 7881/TCP, 7882/UDP, 50100-50200/UDP, 3479/UDP, 5350/TCP

**Monitoring** (internal):
- 9090/TCP (Prometheus)
- 3000/TCP (Grafana)

### 18. Intranet Transition
**Initial setup**: Deploy with internet access for package installation
**Post-deployment**: 
- Cut internet
- Configure /etc/hosts on all servers mapping chat.z3r0d3v.com to HAProxy VIP
- All internal services use private IPs
- HAProxy VIP becomes the cluster entry point

### 19. Deployment Method Preferences
- Docker Compose for: MinIO, Coturn, LiveKit, HAProxy/Keepalived (if feasible)
- Native packages for: Patroni/PostgreSQL/etcd (better integration)
- Ansible playbook for: Synapse ecosystem
- Provide complete working configs, no placeholders

### 20. Testing & Validation
- Must work after deployment
- No bugs or misconfigurations
- Complete user experience: login, see rooms, messages, files, make calls
- Backup restores to working instance

---

## Final Output Requirements

**Generate 6 comprehensive documents**:
1. Architecture & Planning (unified topology, server specs, IP planning)
2. Infrastructure Setup (external services deployment)
3. Configuration Guide (complete playbook vars.yml)
4. Deployment Procedures (step-by-step commands)
5. Operations & Updates (maintenance, scaling)
6. Backup & Restore (complete procedures)

**Each document must**:
- Be production-ready
- Use `chat.z3r0d3v.com` consistently
- Mark all values to change clearly
- Provide full context for every command
- Be accurate with no bugs
- Scale appropriately (Small/Medium/Large variants if needed)

**Critical: All documentation assumes Large scale (10K CCU) as baseline, with resource adjustments noted for Small/Medium.**
