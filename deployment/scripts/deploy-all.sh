#!/bin/bash
##############################################################################
# Matrix/Synapse Complete Deployment Script
# Deploys all 5 phases: Infrastructure, Main Instance, LI Instance, Monitoring, Antivirus
#
# Usage: ./deploy-all.sh [OPTIONS]
#
# Options:
#   --skip-validation     Skip pre-deployment validation checks
#   --phase <1-5>         Deploy only specific phase
#   --dry-run             Show what would be deployed without executing
#   --config <path>       Path to config.env file (default: ../config.env)
#   --help                Show this help message
#
# Prerequisites:
#   - kubectl configured and connected to cluster
#   - helm 3.x installed
#   - All CHANGEME values replaced (see README Configuration section)
#   - Storage class exists in cluster
#   - Nodes labeled appropriately (monitoring=true for monitoring server)
#
# Idempotency:
#   This script is SAFE TO RE-RUN. If it fails midway, fix the issue and
#   re-run. Kubernetes apply is declarative - it will only make changes
#   needed to reach the desired state.
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(dirname "$SCRIPT_DIR")"
SKIP_VALIDATION=false
DRY_RUN=false
SPECIFIC_PHASE=""
CONFIG_FILE="${DEPLOYMENT_DIR}/config.env"

# Track deployment state
DEPLOYMENT_STATE_FILE="/tmp/matrix-deployment-state-$$"

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_detail() {
    echo -e "${CYAN}         ${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        log_error "Deployment FAILED with exit code $exit_code"
        log_error "The script stopped at the command above."
        log_error ""
        log_error "To debug:"
        log_error "  1. Check the error message above"
        log_error "  2. Check pod status: kubectl get pods -n matrix"
        log_error "  3. Check pod logs: kubectl logs -n matrix <pod-name>"
        log_error "  4. Check events: kubectl get events -n matrix --sort-by='.lastTimestamp'"
        log_error ""
        log_error "After fixing the issue, you can safely re-run this script."
        log_error "Kubernetes apply is idempotent - it will only make necessary changes."
    fi
    rm -f "$DEPLOYMENT_STATE_FILE" 2>/dev/null || true
}

trap cleanup EXIT

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found."
        log_detail "Please install '$cmd' before running this script."
        exit 1
    fi
}

# Run kubectl with error capture
run_kubectl() {
    local output
    local exit_code

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] kubectl $*"
        return 0
    fi

    # Capture both stdout and stderr, preserve exit code
    set +e
    output=$(kubectl "$@" 2>&1)
    exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        log_error "kubectl $* FAILED (exit code: $exit_code)"
        log_detail "Command output:"
        echo "$output" | while IFS= read -r line; do
            log_detail "  $line"
        done
        return $exit_code
    fi

    # Print output if not empty
    if [[ -n "$output" ]]; then
        echo "$output"
    fi
    return 0
}

# Run helm with error capture
run_helm() {
    local output
    local exit_code

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] helm $*"
        return 0
    fi

    set +e
    output=$(helm "$@" 2>&1)
    exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        log_error "helm $* FAILED (exit code: $exit_code)"
        log_detail "Command output:"
        echo "$output" | while IFS= read -r line; do
            log_detail "  $line"
        done
        return $exit_code
    fi

    if [[ -n "$output" ]]; then
        echo "$output"
    fi
    return 0
}

wait_for_condition() {
    local resource_type="$1"
    local resource_name="$2"
    local condition="$3"
    local namespace="$4"
    local timeout="${5:-600}"

    log_info "Waiting for $resource_type/$resource_name to be $condition (timeout: ${timeout}s)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would wait for $resource_type/$resource_name"
        return 0
    fi

    local output
    local exit_code
    set +e
    output=$(kubectl wait --for=condition="$condition" "$resource_type/$resource_name" \
        -n "$namespace" --timeout="${timeout}s" 2>&1)
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        log_success "$resource_type/$resource_name is $condition"
        return 0
    else
        log_error "$resource_type/$resource_name failed to become $condition within ${timeout}s"
        log_detail "Error: $output"
        log_detail ""
        log_detail "Debug commands:"
        log_detail "  kubectl describe $resource_type/$resource_name -n $namespace"
        log_detail "  kubectl get events -n $namespace --field-selector involvedObject.name=$resource_name"
        return 1
    fi
}

check_pod_status() {
    local label="$1"
    local namespace="$2"
    local expected_count="${3:-1}"

    log_info "Checking pods with label $label in namespace $namespace..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would check pod status"
        return 0
    fi

    # Wait a bit for pods to settle
    local max_attempts=30
    local attempt=0
    local ready_count=0

    while [[ $attempt -lt $max_attempts ]]; do
        ready_count=$(kubectl get pods -n "$namespace" -l "$label" \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
            | grep -c "True" || echo "0")

        if [[ "$ready_count" -ge "$expected_count" ]]; then
            log_success "$ready_count/$expected_count pods ready"
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then
            log_info "Waiting for pods... ($ready_count/$expected_count ready, attempt $attempt/$max_attempts)"
            sleep 10
        fi
    done

    log_warn "Only $ready_count/$expected_count pods ready after waiting"
    log_detail "Check pod status: kubectl get pods -n $namespace -l $label"
    # Return 1 if no pods are ready (critical failure), 0 if at least some pods are ready
    if [[ "$ready_count" -eq 0 ]]; then
        return 1
    fi
    return 0  # Don't fail if some pods are ready
}

apply_manifest() {
    local manifest="$1"

    if [[ ! -f "$manifest" ]]; then
        log_error "Manifest not found: $manifest"
        return 1
    fi

    log_info "Applying: $manifest"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would apply: $manifest"
        return 0
    fi

    local output
    local exit_code
    set +e
    output=$(kubectl apply -f "$manifest" 2>&1)
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        log_success "Applied: $manifest"
        # Show what was created/configured
        echo "$output" | grep -E "(created|configured|unchanged)" | head -5 || true
        return 0
    else
        log_error "Failed to apply: $manifest"
        log_detail "Error output:"
        echo "$output" | while IFS= read -r line; do
            log_detail "  $line"
        done
        return 1
    fi
}

# Check if a resource exists
resource_exists() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"

    kubectl get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null
}

##############################################################################
# Pre-Deployment Validation
##############################################################################

validate_prerequisites() {
    log_section "Validating Prerequisites"

    # Check required commands
    log_info "Checking required commands..."
    check_command kubectl
    check_command helm
    check_command grep
    check_command sed

    # Check kubectl connection
    log_info "Checking kubectl connection..."
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        log_detail "Check your kubectl configuration:"
        log_detail "  kubectl config current-context"
        log_detail "  kubectl cluster-info"
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"

    # Check helm version
    local helm_version
    helm_version=$(helm version --short 2>/dev/null | grep -oP 'v\d+\.\d+' || echo "unknown")
    log_info "Helm version: $helm_version"

    # CRITICAL: Check storage class exists
    log_info "Checking storage class..."
    local storage_class="${STORAGE_CLASS:-standard}"
    if ! kubectl get storageclass "$storage_class" &>/dev/null; then
        log_error "Storage class '$storage_class' not found in cluster!"
        log_detail ""
        log_detail "Available storage classes:"
        kubectl get storageclass -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class' 2>/dev/null || true
        log_detail ""
        log_detail "To fix:"
        log_detail "  1. Set STORAGE_CLASS in config.env to an existing storage class"
        log_detail "  2. Or create the required storage class in your cluster"
        exit 1
    fi
    log_success "Storage class '$storage_class' exists"

    # Check for monitoring node (required for Phase 4)
    log_info "Checking for monitoring node label..."
    local monitoring_nodes
    monitoring_nodes=$(kubectl get nodes -l monitoring=true --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$monitoring_nodes" -eq 0 ]]; then
        log_warn "No nodes labeled with 'monitoring=true'"
        log_detail "Monitoring pods require a dedicated monitoring server."
        log_detail "Label at least one node: kubectl label node <node-name> monitoring=true"
        log_detail ""
        log_detail "Continuing anyway - Phase 4 may fail without labeled node."
    else
        log_success "Found $monitoring_nodes node(s) labeled for monitoring"
    fi

    # Check for CHANGEME values (but don't fail for docs/scripts)
    log_info "Checking for CHANGEME placeholders..."
    local changeme_count
    changeme_count=$(grep -r "CHANGEME" "$DEPLOYMENT_DIR" \
        --include="*.yaml" \
        --exclude-dir=docs \
        --exclude-dir=.git \
        | grep -v "^#" \
        | wc -l || echo "0")

    if [[ "$changeme_count" -gt 0 ]]; then
        log_error "Found $changeme_count CHANGEME placeholders in YAML files!"
        log_detail "Please replace all secrets and configuration values before deploying."
        log_detail ""
        log_detail "Files with CHANGEME values:"
        grep -r "CHANGEME" "$DEPLOYMENT_DIR" \
            --include="*.yaml" \
            --exclude-dir=docs \
            --exclude-dir=.git \
            -l 2>/dev/null | head -10 || true
        log_detail ""
        log_detail "See README.md 'Configuration' section for instructions."
        exit 1
    fi
    log_success "No CHANGEME placeholders found in YAML files"

    # Check for example.com domains (warning only)
    log_info "Checking for example.com domains..."
    local example_domains
    example_domains=$(grep -r "example\.com" "$DEPLOYMENT_DIR" \
        --include="*.yaml" \
        --exclude-dir=docs \
        --exclude-dir=.git \
        | grep -v "^#" \
        | wc -l || echo "0")

    if [[ "$example_domains" -gt 0 ]]; then
        log_warn "Found $example_domains references to example.com"
        log_detail "Make sure to replace with your actual domain names."
    fi

    log_success "Pre-deployment validation complete"
}

##############################################################################
# Load Configuration
##############################################################################

load_config() {
    log_section "Loading Configuration"

    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading configuration from $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_success "Configuration loaded"

        # Show key config values
        log_detail "Organization: ${ORG_NAME:-not set}"
        log_detail "Environment: ${ENVIRONMENT:-not set}"
        log_detail "Matrix Domain: ${MATRIX_DOMAIN:-not set}"
        log_detail "Expected CCU: ${EXPECTED_CCU:-not set}"
        log_detail "Storage Class: ${STORAGE_CLASS:-standard}"
    else
        log_warn "Config file not found: $CONFIG_FILE"
        log_detail "Using default values. Create config.env for organization-specific settings."
        log_detail "Copy config.env.example to config.env and customize."
    fi
}

##############################################################################
# Phase 1: Infrastructure
##############################################################################

deploy_phase1() {
    log_section "Phase 1: Deploying Infrastructure"

    # Create namespace (idempotent)
    log_info "Creating matrix namespace..."
    if [[ "$DRY_RUN" == "false" ]]; then
        kubectl create namespace matrix --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Install CloudNativePG Operator (idempotent - checks if already installed)
    log_info "Installing CloudNativePG Operator..."
    if [[ "$DRY_RUN" == "false" ]]; then
        if ! kubectl get deployment -n cnpg-system cnpg-controller-manager &>/dev/null; then
            run_kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml
            log_info "Waiting for CloudNativePG operator to be ready..."
            wait_for_condition "deployment" "cnpg-controller-manager" "Available" "cnpg-system" 300
        else
            log_info "CloudNativePG operator already installed"
        fi
    fi

    # Deploy PostgreSQL clusters
    log_info "Deploying PostgreSQL main cluster..."
    apply_manifest "$DEPLOYMENT_DIR/infrastructure/01-postgresql/main-cluster.yaml"
    wait_for_condition "cluster" "matrix-postgresql" "Ready" "matrix" 600

    log_info "Deploying PostgreSQL LI cluster..."
    apply_manifest "$DEPLOYMENT_DIR/infrastructure/01-postgresql/li-cluster.yaml"
    wait_for_condition "cluster" "matrix-postgresql-li" "Ready" "matrix" 600

    # Deploy Redis
    log_info "Deploying Redis Sentinel..."
    apply_manifest "$DEPLOYMENT_DIR/infrastructure/02-redis/redis-secret.yaml"
    apply_manifest "$DEPLOYMENT_DIR/infrastructure/02-redis/redis-statefulset.yaml"
    check_pod_status "app.kubernetes.io/name=redis" "matrix" 3

    # Deploy MinIO
    log_info "Deploying MinIO..."
    log_info "Installing MinIO Operator..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add minio-operator https://operator.min.io 2>/dev/null || true
        helm repo update
        # Use upgrade --install for idempotency
        run_helm upgrade --install minio-operator minio-operator/operator \
            --namespace minio-operator --create-namespace \
            --values "$DEPLOYMENT_DIR/values/minio-operator-values.yaml"
    fi

    apply_manifest "$DEPLOYMENT_DIR/infrastructure/03-minio/secrets.yaml"
    apply_manifest "$DEPLOYMENT_DIR/infrastructure/03-minio/tenant.yaml"
    wait_for_condition "tenant" "matrix-minio" "Initialized" "matrix" 600

    # Deploy Networking
    log_info "Installing NGINX Ingress Controller..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
        helm repo update
        run_helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --namespace ingress-nginx --create-namespace \
            --values "$DEPLOYMENT_DIR/values/nginx-ingress-values.yaml"
    fi

    log_info "Installing cert-manager..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
        helm repo update
        run_helm upgrade --install cert-manager jetstack/cert-manager \
            --namespace cert-manager --create-namespace \
            --set installCRDs=true \
            --values "$DEPLOYMENT_DIR/values/cert-manager-values.yaml"

        # Wait for cert-manager webhook to be ready before applying issuers
        log_info "Waiting for cert-manager webhook..."
        wait_for_condition "deployment" "cert-manager-webhook" "Available" "cert-manager" 120

        apply_manifest "$DEPLOYMENT_DIR/infrastructure/04-networking/cert-manager-install.yaml"
    fi

    log_success "Phase 1 deployment complete!"
}

##############################################################################
# Phase 2: Main Instance
##############################################################################

deploy_phase2() {
    log_section "Phase 2: Deploying Main Instance"

    # Deploy Synapse Main
    log_info "Deploying Synapse main process..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/01-synapse/configmap.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/01-synapse/secrets.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/01-synapse/main-statefulset.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/01-synapse/services.yaml"
    check_pod_status "app.kubernetes.io/name=synapse,app.kubernetes.io/component=main" "matrix" 1

    # Deploy Workers
    log_info "Deploying Synapse workers..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/synchrotron-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/generic-worker-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/media-repository-statefulset.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/event-persister-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/federation-sender-deployment.yaml"

    # Deploy stream writers
    log_info "Deploying stream writers..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/typing-writer-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/todevice-writer-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/receipts-writer-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/presence-writer-deployment.yaml"

    # Check for minimum workers ready (total: 22 workers expected at default replicas)
    # synchrotron:4 + generic:2 + media:2 + event-persister:4 + fed-sender:2 + stream-writers:8 = 22
    # Use 10 as minimum threshold to allow for startup delays
    check_pod_status "app.kubernetes.io/type=worker" "matrix" 10

    # Deploy HAProxy
    log_info "Deploying HAProxy..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/03-haproxy/deployment.yaml"
    check_pod_status "app.kubernetes.io/name=haproxy" "matrix" 2

    # Deploy Element Web
    log_info "Deploying Element Web..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-element-web/deployment.yaml"

    # Deploy coturn
    log_info "Deploying coturn..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/06-coturn/deployment.yaml"

    # Deploy LiveKit (if manifest exists)
    if [[ -f "$DEPLOYMENT_DIR/main-instance/04-livekit/deployment.yaml" ]]; then
        log_info "Deploying LiveKit..."
        apply_manifest "$DEPLOYMENT_DIR/main-instance/04-livekit/deployment.yaml"
    fi

    log_success "Phase 2 deployment complete!"
}

##############################################################################
# Phase 3: LI Instance
##############################################################################

deploy_phase3() {
    log_section "Phase 3: Deploying LI Instance"

    # Deploy Redis LI
    log_info "Deploying Redis LI..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/00-redis-li/deployment.yaml"
    check_pod_status "app.kubernetes.io/name=redis,app.kubernetes.io/instance=li" "matrix" 1

    # Deploy Synapse LI
    log_info "Deploying Synapse LI..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/01-synapse-li/deployment.yaml"
    check_pod_status "matrix.instance=li,app.kubernetes.io/name=synapse" "matrix" 1

    # Deploy Element Web LI
    log_info "Deploying Element Web LI..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/02-element-web-li/deployment.yaml"

    # Deploy Synapse Admin LI
    log_info "Deploying Synapse Admin LI..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/03-synapse-admin-li/deployment.yaml"

    # Deploy LI Sync System (CronJob for database synchronization)
    # Per CLAUDE.md 3.3: Uses pg_dump/pg_restore, configurable interval
    log_info "Deploying LI sync system CronJob..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/04-sync-system/cronjob.yaml"
    log_detail "Sync system will run on schedule (default: every 6 hours)"
    log_detail "Manual sync can be triggered via Synapse Admin LI"

    # Deploy key_vault
    log_info "Deploying key_vault..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/05-key-vault/deployment.yaml"
    check_pod_status "app.kubernetes.io/name=key-vault" "matrix" 1

    # Deploy nginx-li (LI's independent reverse proxy)
    # CRITICAL: nginx-li operates independently of main instance's ingress
    # This ensures LI continues to work even if main instance is down
    log_info "Deploying nginx-li reverse proxy..."

    # Check for required TLS certificate secrets
    local tls_secrets_missing=false
    for secret in nginx-li-synapse-tls nginx-li-element-tls nginx-li-admin-tls nginx-li-keyvault-tls; do
        if ! kubectl get secret "$secret" -n matrix &>/dev/null; then
            log_warn "TLS secret '$secret' not found"
            tls_secrets_missing=true
        fi
    done

    if [[ "$tls_secrets_missing" == "true" ]]; then
        log_warn "One or more TLS secrets are missing for nginx-li"
        log_detail "nginx-li requires TLS certificates for all LI domains."
        log_detail ""
        log_detail "Create TLS secrets before deploying nginx-li:"
        log_detail "  # Generate self-signed certificates (for testing):"
        log_detail "  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\"
        log_detail "    -keyout synapse-li.key -out synapse-li.crt -subj '/CN=matrix.example.com'"
        log_detail "  kubectl create secret tls nginx-li-synapse-tls --cert=synapse-li.crt --key=synapse-li.key -n matrix"
        log_detail ""
        log_detail "  # Repeat for: nginx-li-element-tls, nginx-li-admin-tls, nginx-li-keyvault-tls"
        log_detail ""
        log_detail "See: li-instance/06-nginx-li/deployment.yaml for detailed instructions"
        log_detail ""
        log_detail "Skipping nginx-li deployment - create TLS secrets and re-run Phase 3"
    else
        apply_manifest "$DEPLOYMENT_DIR/li-instance/06-nginx-li/deployment.yaml"
        check_pod_status "app.kubernetes.io/name=nginx,app.kubernetes.io/instance=li" "matrix" 1

        # Show nginx-li LoadBalancer IP
        log_info "nginx-li LoadBalancer status:"
        kubectl get svc nginx-li -n matrix -o wide 2>/dev/null || true
        log_detail ""
        log_detail "IMPORTANT: LI administrators must configure DNS to resolve"
        log_detail "the homeserver domain to the nginx-li LoadBalancer IP."
        log_detail "See: li-instance/06-nginx-li/deployment.yaml for DNS instructions"
    fi

    log_success "Phase 3 deployment complete!"
}

##############################################################################
# Phase 4: Monitoring
##############################################################################

deploy_phase4() {
    log_section "Phase 4: Deploying Monitoring Stack"

    # Check for monitoring node label
    local monitoring_nodes
    monitoring_nodes=$(kubectl get nodes -l monitoring=true --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$monitoring_nodes" -eq 0 ]]; then
        log_error "No nodes labeled with 'monitoring=true'"
        log_detail "Monitoring pods require a dedicated monitoring server."
        log_detail "Label at least one node: kubectl label node <node-name> monitoring=true"
        log_detail ""
        log_detail "After labeling, re-run: $0 --phase 4"
        return 1
    fi

    # Create monitoring namespace
    if [[ "$DRY_RUN" == "false" ]]; then
        kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Install Prometheus + Grafana
    log_info "Installing Prometheus and Grafana..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
        helm repo update
        run_helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            --values "$DEPLOYMENT_DIR/values/prometheus-stack-values.yaml" \
            --version 67.0.0
    fi

    # Install Loki
    log_info "Installing Loki..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
        helm repo update
        run_helm upgrade --install loki grafana/loki-stack \
            --namespace monitoring \
            --values "$DEPLOYMENT_DIR/values/loki-values.yaml" \
            --version 2.10.0
    fi

    # Deploy ServiceMonitors
    log_info "Deploying ServiceMonitors..."
    # Wait for Prometheus CRDs to be available
    if [[ "$DRY_RUN" == "false" ]]; then
        local max_wait=60
        local waited=0
        while ! kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; do
            if [[ $waited -ge $max_wait ]]; then
                log_error "ServiceMonitor CRD not available after ${max_wait}s"
                return 1
            fi
            log_info "Waiting for Prometheus CRDs..."
            sleep 5
            waited=$((waited + 5))
        done
    fi

    apply_manifest "$DEPLOYMENT_DIR/monitoring/01-prometheus/servicemonitors.yaml"

    # Deploy Grafana Dashboards
    log_info "Deploying Grafana dashboards..."
    apply_manifest "$DEPLOYMENT_DIR/monitoring/02-grafana/dashboards-configmap.yaml"

    # Enable CloudNativePG monitoring
    log_info "Enabling PostgreSQL monitoring..."
    if [[ "$DRY_RUN" == "false" ]]; then
        kubectl patch cluster matrix-postgresql -n matrix --type=merge -p '
{
  "spec": {
    "monitoring": {
      "enablePodMonitor": true
    }
  }
}' 2>/dev/null || log_warn "Could not patch main PostgreSQL cluster"

        kubectl patch cluster matrix-postgresql-li -n matrix --type=merge -p '
{
  "spec": {
    "monitoring": {
      "enablePodMonitor": true
    }
  }
}' 2>/dev/null || log_warn "Could not patch LI PostgreSQL cluster"
    fi

    log_success "Phase 4 deployment complete!"
}

##############################################################################
# Phase 5: Antivirus
##############################################################################

deploy_phase5() {
    log_section "Phase 5: Deploying Antivirus System"

    # Deploy ClamAV
    log_info "Deploying ClamAV DaemonSet..."
    apply_manifest "$DEPLOYMENT_DIR/antivirus/01-clamav/deployment.yaml"

    # ClamAV needs time to download virus definitions
    log_info "Waiting for ClamAV virus definitions (this may take several minutes)..."
    check_pod_status "app.kubernetes.io/name=clamav" "matrix" 1

    # Deploy Content Scanner
    log_info "Deploying Content Scanner..."
    apply_manifest "$DEPLOYMENT_DIR/antivirus/02-scan-workers/deployment.yaml"
    check_pod_status "app.kubernetes.io/name=content-scanner" "matrix" 3

    log_success "Phase 5 deployment complete!"
}

##############################################################################
# Post-Deployment Validation
##############################################################################

validate_deployment() {
    log_section "Post-Deployment Validation"

    log_info "Checking all pods in matrix namespace..."
    kubectl get pods -n matrix -o wide

    log_info "Checking all services in matrix namespace..."
    kubectl get svc -n matrix

    log_info "Checking main instance Ingresses..."
    kubectl get ingress -n matrix

    log_info "Checking nginx-li (LI reverse proxy) LoadBalancer..."
    kubectl get svc nginx-li -n matrix -o wide 2>/dev/null || log_warn "nginx-li service not found (LI may not be deployed)"

    log_info "Checking monitoring pods..."
    kubectl get pods -n monitoring 2>/dev/null || log_warn "Monitoring namespace not found"

    log_info "Checking main NGINX Ingress Controller..."
    kubectl get pods -n ingress-nginx

    log_success "Deployment validation complete!"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Deployment Summary${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Check pod status: kubectl get pods -n matrix"
    echo "2. Check logs: kubectl logs -n matrix <pod-name>"
    echo "3. Access Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo "4. Test Synapse health: curl https://${MATRIX_DOMAIN:-matrix.example.com}/_matrix/client/versions"
    echo "5. Create first user (see README.md 'Creating Admin Users' section)"
    echo ""
    echo "LI Instance:"
    echo "- nginx-li LoadBalancer IP: kubectl get svc nginx-li -n matrix -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
    echo "- LI admins must configure DNS to point to nginx-li LoadBalancer IP"
    echo "- See li-instance/README.md for detailed LI admin instructions"
    echo ""
}

##############################################################################
# Main Script
##############################################################################

show_help() {
    head -25 "$0" | grep "^#" | sed 's/^# *//'
    exit 0
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-validation)
                SKIP_VALIDATION=true
                shift
                ;;
            --phase)
                SPECIFIC_PHASE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                ;;
        esac
    done

    # Show banner
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Matrix/Synapse Deployment Script${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Load configuration
    load_config

    # Validate prerequisites
    if [[ "$SKIP_VALIDATION" == "false" ]]; then
        validate_prerequisites
    else
        log_warn "Skipping pre-deployment validation (--skip-validation)"
    fi

    # Deploy specific phase or all phases
    if [[ -n "$SPECIFIC_PHASE" ]]; then
        case $SPECIFIC_PHASE in
            1) deploy_phase1 ;;
            2) deploy_phase2 ;;
            3) deploy_phase3 ;;
            4) deploy_phase4 ;;
            5) deploy_phase5 ;;
            *)
                log_error "Invalid phase: $SPECIFIC_PHASE. Must be 1-5."
                exit 1
                ;;
        esac
    else
        # Deploy all phases
        deploy_phase1
        deploy_phase2
        deploy_phase3
        deploy_phase4
        deploy_phase5
    fi

    # Post-deployment validation
    validate_deployment

    log_success "All deployments complete!"
}

# Run main function
main "$@"
