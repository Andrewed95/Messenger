# Deployment Automation Scripts

Automated deployment and validation scripts for Matrix/Synapse infrastructure.

## Available Scripts

### deploy-all.sh

**Main deployment automation script** - Deploys all 5 phases of the Matrix/Synapse infrastructure.

**Usage:**
```bash
# Deploy all phases
./deploy-all.sh

# Deploy specific phase only
./deploy-all.sh --phase 1    # Infrastructure only
./deploy-all.sh --phase 2    # Main instance only
./deploy-all.sh --phase 3    # LI instance only
./deploy-all.sh --phase 4    # Monitoring only
./deploy-all.sh --phase 5    # Antivirus only

# Dry run (show what would be deployed without executing)
./deploy-all.sh --dry-run

# Skip pre-deployment validation checks
./deploy-all.sh --skip-validation
```

**Features:**
- ✅ Automatic prerequisite checking (kubectl, helm, etc.)
- ✅ Validates no CHANGEME placeholders remain
- ✅ Color-coded output for easy reading
- ✅ Waits for resources to be ready before proceeding
- ✅ Dry-run mode for testing
- ✅ Phase-specific deployment
- ✅ Error handling and detailed logging

**Prerequisites:**
- Kubernetes cluster (1.28+) accessible via kubectl
- Helm 3.x installed
- All CHANGEME values replaced (see `../docs/PRE-DEPLOYMENT-CHECKLIST.md`)
- Domain names configured
- Sufficient cluster resources (see `../docs/SCALING-GUIDE.md`)

### validate-deployment.sh

**Post-deployment validation script** - Validates all components are healthy and properly configured.

**Usage:**
```bash
# Run full validation
./validate-deployment.sh
```

**NOTE**: This script runs a complete validation of all deployment phases. It does not accept any command-line arguments.

**Checks:**
- ✅ Pod health and readiness
- ✅ Service endpoints
- ✅ Ingress configuration
- ✅ PodDisruptionBudgets
- ✅ PostgreSQL cluster health
- ✅ MinIO tenant status
- ✅ Replication lag (LI instance)
- ✅ ClamAV virus definitions

**Exit codes:**
- `0` - All validations passed
- `1` - Some validations failed

## Typical Workflow

**1. Pre-Deployment**
```bash
# Complete pre-deployment checklist
cat ../docs/PRE-DEPLOYMENT-CHECKLIST.md

# Verify you've replaced all secrets
grep -r "CHANGEME" ../
# Should return: no results
```

**2. Deployment**
```bash
# Run full deployment
./deploy-all.sh

# Or deploy phase-by-phase
./deploy-all.sh --phase 1  # Infrastructure
# Wait for deployment, then run full validation
./validate-deployment.sh

./deploy-all.sh --phase 2  # Main instance
./validate-deployment.sh

# ... continue for phases 3-5
```

**3. Validation**
```bash
# Full validation (checks all deployment phases)
./validate-deployment.sh
```

**4. Post-Deployment**
```bash
# Access Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open: http://localhost:3000

# Access Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open: http://localhost:9090

# Create first user
kubectl exec -n matrix synapse-main-0 -- \
  register_new_matrix_user -c /config/homeserver.yaml -u admin -a
```

## Dry-Run Testing

**Test deployment without making changes:**
```bash
# See what would be deployed
./deploy-all.sh --dry-run

# Test specific phase
./deploy-all.sh --phase 2 --dry-run
```

## Troubleshooting

**If deployment fails:**

1. **Check pod logs:**
   ```bash
   kubectl get pods -n matrix
   kubectl logs -n matrix <failed-pod-name>
   kubectl describe pod -n matrix <failed-pod-name>
   ```

2. **Validate prerequisites:**
   ```bash
   kubectl cluster-info
   kubectl get nodes
   kubectl top nodes
   ```

3. **Check for CHANGEME values:**
   ```bash
   grep -r "CHANGEME" ../
   ```

4. **Rollback specific phase:**
   ```bash
   # Example: Rollback Phase 2
   kubectl delete -f ../main-instance/01-synapse/
   kubectl delete -f ../main-instance/02-workers/
   kubectl delete -f ../main-instance/03-haproxy/
   ```

5. **Re-run deployment:**
   ```bash
   ./deploy-all.sh --phase 2
   ```

**Common Issues:**

| Issue | Cause | Solution |
|-------|-------|----------|
| CHANGEME errors | Secrets not replaced | See `../docs/PRE-DEPLOYMENT-CHECKLIST.md` |
| Insufficient resources | Cluster too small | See `../docs/SCALING-GUIDE.md` |
| Pod won't start | Missing dependencies | Check logs, ensure Phase 1 complete |
| Ingress no IP | LoadBalancer pending | Check cloud LB or deploy MetalLB |
| Service unreachable | Network connectivity | Check service endpoints, DNS |

## Advanced Usage

**Custom timeout for resource readiness:**
```bash
# Modify wait_for_condition timeout in deploy-all.sh
# Default: 600 seconds ()
```

**Skip specific components:**
```bash
# Edit deploy-all.sh and comment out specific apply_manifest calls
```

**Add custom validation checks:**
```bash
# Edit validate-deployment.sh and add new check functions
```

## See Also

- **Main Deployment Guide:** `../README.md`
- **Pre-Deployment Checklist:** `../docs/PRE-DEPLOYMENT-CHECKLIST.md`
- **Scaling Guide:** `../docs/SCALING-GUIDE.md`
- **Operations Guide:** `../docs/OPERATIONS-UPDATE-GUIDE.md`

---
