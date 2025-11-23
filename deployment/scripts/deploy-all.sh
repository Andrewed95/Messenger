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
#   --help                Show this help message
#
# Prerequisites:
#   - kubectl configured and connected to cluster
#   - helm 3.x installed
#   - All CHANGEME values replaced (see README Configuration section)
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(dirname "$SCRIPT_DIR")"
SKIP_VALIDATION=false
DRY_RUN=false
SPECIFIC_PHASE=""

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command '$1' not found. Please install it first."
        exit 1
    fi
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

    if kubectl wait --for=condition=$condition "$resource_type/$resource_name" \
        -n "$namespace" --timeout="${timeout}s"; then
        log_success "$resource_type/$resource_name is $condition"
        return 0
    else
        log_error "$resource_type/$resource_name failed to become $condition within ${timeout}s"
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

    local ready_count
    ready_count=$(kubectl get pods -n "$namespace" -l "$label" \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        | grep -c "True" || true)

    if [[ "$ready_count" -ge "$expected_count" ]]; then
        log_success "$ready_count/$expected_count pods ready"
        return 0
    else
        log_warn "Only $ready_count/$expected_count pods ready"
        return 1
    fi
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

    if kubectl apply -f "$manifest"; then
        log_success "Applied: $manifest"
        return 0
    else
        log_error "Failed to apply: $manifest"
        return 1
    fi
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
        log_error "Cannot connect to Kubernetes cluster. Check kubectl configuration."
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"

    # Check helm version
    local helm_version
    helm_version=$(helm version --short | grep -oP 'v\d+\.\d+' || echo "unknown")
    log_info "Helm version: $helm_version"

    # Check for CHANGEME values
    log_info "Checking for CHANGEME placeholders..."
    local changeme_count
    changeme_count=$(grep -r "CHANGEME" "$DEPLOYMENT_DIR" \
        --exclude-dir=docs \
        --exclude-dir=.git \
        --exclude="*.md" \
        --exclude="*.sh" \
        | wc -l || echo "0")

    if [[ "$changeme_count" -gt 0 ]]; then
        log_error "Found $changeme_count CHANGEME placeholders in deployment files!"
        log_error "Please replace all secrets before deploying. See README Configuration section"
        grep -r "CHANGEME" "$DEPLOYMENT_DIR" \
            --exclude-dir=docs \
            --exclude-dir=.git \
            --exclude="*.md" \
            --exclude="*.sh" \
            | head -10
        exit 1
    fi
    log_success "No CHANGEME placeholders found"

    # Check for example.com domains
    log_info "Checking for example.com domains..."
    local example_domains
    example_domains=$(grep -r "example.com" "$DEPLOYMENT_DIR" \
        --exclude-dir=docs \
        --exclude-dir=.git \
        --exclude="*.md" \
        --exclude="*.sh" \
        | wc -l || echo "0")

    if [[ "$example_domains" -gt 0 ]]; then
        log_warn "Found $example_domains references to example.com in deployment files"
        log_warn "Make sure these are intentional or replace with your actual domain"
    fi

    # Check cluster resources
    log_info "Checking cluster resources..."
    log_info "Nodes:"
    kubectl get nodes -o wide

    log_info "Available resources:"
    kubectl top nodes || log_warn "Metrics server not available, cannot check resource usage"

    log_success "Pre-deployment validation complete"
}

##############################################################################
# Phase 1: Infrastructure
##############################################################################

deploy_phase1() {
    log_section "Phase 1: Deploying Infrastructure"

    # Create namespace
    log_info "Creating matrix namespace..."
    if [[ "$DRY_RUN" == "false" ]]; then
        kubectl create namespace matrix --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Install CloudNativePG Operator
    log_info "Installing CloudNativePG Operator (if not already installed)..."
    if [[ "$DRY_RUN" == "false" ]]; then
        kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml || true
        log_info "Waiting for CloudNativePG operator to be ready..."
        kubectl wait --for=condition=Available --timeout=300s \
            -n cnpg-system deployment/cnpg-controller-manager || true
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
    sleep 10
    check_pod_status "app.kubernetes.io/name=redis" "matrix" 3

    # Deploy MinIO
    log_info "Deploying MinIO..."
    log_info "Installing MinIO Operator (if not already installed)..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add minio-operator https://operator.min.io || true
        helm repo update
        helm upgrade --install minio-operator minio-operator/operator \
            --namespace minio-operator --create-namespace \
            --values "$DEPLOYMENT_DIR/values/minio-operator-values.yaml" || true
    fi

    apply_manifest "$DEPLOYMENT_DIR/infrastructure/03-minio/secrets.yaml"
    apply_manifest "$DEPLOYMENT_DIR/infrastructure/03-minio/tenant.yaml"
    wait_for_condition "tenant" "matrix-minio" "Initialized" "matrix" 600

    # Deploy Networking
    log_info "Deploying NetworkPolicies..."
    apply_manifest "$DEPLOYMENT_DIR/infrastructure/04-networking/networkpolicies.yaml"
    apply_manifest "$DEPLOYMENT_DIR/infrastructure/04-networking/sync-system-networkpolicy.yaml"

    log_info "Installing NGINX Ingress Controller..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
        helm repo update
        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --namespace ingress-nginx --create-namespace \
            --values "$DEPLOYMENT_DIR/values/nginx-ingress-values.yaml"
    fi

    log_info "Installing cert-manager..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add jetstack https://charts.jetstack.io || true
        helm repo update
        helm upgrade --install cert-manager jetstack/cert-manager \
            --namespace cert-manager --create-namespace \
            --set installCRDs=true \
            --values "$DEPLOYMENT_DIR/values/cert-manager-values.yaml"

        sleep 10
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
    sleep 20
    check_pod_status "app.kubernetes.io/name=synapse,app.kubernetes.io/component=main" "matrix" 1

    # Deploy Workers
    log_info "Deploying Synapse workers..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/synchrotron-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/generic-worker-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/media-repository-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/event-persister-deployment.yaml"
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-workers/federation-sender-deployment.yaml"
    sleep 30
    check_pod_status "app.kubernetes.io/component=worker" "matrix" 10

    # Deploy HAProxy
    log_info "Deploying HAProxy..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/03-haproxy/deployment.yaml"
    sleep 10
    check_pod_status "app.kubernetes.io/name=haproxy" "matrix" 2

    # Deploy Element Web
    log_info "Deploying Element Web..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/02-element-web/deployment.yaml"

    # Deploy coturn
    log_info "Deploying coturn..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/06-coturn/deployment.yaml"

    # Deploy Sygnal
    log_info "Deploying Sygnal..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/07-sygnal/deployment.yaml"

    # Deploy key_vault
    log_info "Deploying key_vault..."
    apply_manifest "$DEPLOYMENT_DIR/main-instance/08-key-vault/deployment.yaml"

    log_success "Phase 2 deployment complete!"
}

##############################################################################
# Phase 3: LI Instance
##############################################################################

deploy_phase3() {
    log_section "Phase 3: Deploying LI Instance"

    # Deploy Sync System
    log_info "Deploying sync system..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/04-sync-system/deployment.yaml"
    sleep 10

    # Run replication setup (one-time job)
    log_info "Running replication setup job..."
    if [[ "$DRY_RUN" == "false" ]]; then
        local job_name="sync-setup-$(date +%s)"
        kubectl create job --from=cronjob/sync-system-setup-replication \
            "$job_name" -n matrix || true
        sleep 5
        kubectl wait --for=condition=complete "job/$job_name" \
            -n matrix --timeout=300s || log_warn "Replication setup job may still be running"
    fi

    # Deploy Synapse LI
    log_info "Deploying Synapse LI..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/01-synapse-li/deployment.yaml"
    sleep 20
    check_pod_status "matrix.instance=li,app.kubernetes.io/name=synapse" "matrix" 1

    # Deploy Element Web LI
    log_info "Deploying Element Web LI..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/02-element-web-li/deployment.yaml"

    # Deploy Synapse Admin LI
    log_info "Deploying Synapse Admin LI..."
    apply_manifest "$DEPLOYMENT_DIR/li-instance/03-synapse-admin-li/deployment.yaml"

    log_success "Phase 3 deployment complete!"
}

##############################################################################
# Phase 4: Monitoring
##############################################################################

deploy_phase4() {
    log_section "Phase 4: Deploying Monitoring Stack"

    # Create monitoring namespace
    if [[ "$DRY_RUN" == "false" ]]; then
        kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Install Prometheus + Grafana
    log_info "Installing Prometheus and Grafana..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
        helm repo update
        helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            --values "$DEPLOYMENT_DIR/values/prometheus-stack-values.yaml" \
            --version 67.0.0
    fi

    # Install Loki
    log_info "Installing Loki..."
    if [[ "$DRY_RUN" == "false" ]]; then
        helm repo add grafana https://grafana.github.io/helm-charts || true
        helm repo update
        helm upgrade --install loki grafana/loki-stack \
            --namespace monitoring \
            --values "$DEPLOYMENT_DIR/values/loki-values.yaml" \
            --version 2.10.0
    fi

    # Deploy ServiceMonitors
    log_info "Deploying ServiceMonitors..."
    sleep 20
    apply_manifest "$DEPLOYMENT_DIR/monitoring/01-prometheus/servicemonitors.yaml"

    # Deploy PrometheusRules
    log_info "Deploying PrometheusRules..."
    apply_manifest "$DEPLOYMENT_DIR/monitoring/01-prometheus/prometheusrules.yaml"

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
}'
        kubectl patch cluster matrix-postgresql-li -n matrix --type=merge -p '
{
  "spec": {
    "monitoring": {
      "enablePodMonitor": true
    }
  }
}'
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
    sleep 30
    check_pod_status "app.kubernetes.io/name=clamav" "matrix" 1

    # Deploy Content Scanner
    log_info "Deploying Content Scanner..."
    apply_manifest "$DEPLOYMENT_DIR/antivirus/02-scan-workers/deployment.yaml"
    sleep 10
    check_pod_status "app.kubernetes.io/name=content-scanner" "matrix" 3

    log_success "Phase 5 deployment complete!"
}

##############################################################################
# Post-Deployment Validation
##############################################################################

validate_deployment() {
    log_section "Post-Deployment Validation"

    log_info "Checking all pods in matrix namespace..."
    kubectl get pods -n matrix

    log_info "Checking all services in matrix namespace..."
    kubectl get svc -n matrix

    log_info "Checking all ingresses in matrix namespace..."
    kubectl get ingress -n matrix

    log_info "Checking monitoring pods..."
    kubectl get pods -n monitoring

    log_info "Checking NGINX Ingress..."
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
    echo "4. Test Synapse health: curl https://matrix.example.com/_matrix/client/versions"
    echo "5. Create first user: kubectl exec -n matrix synapse-main-0 -- register_new_matrix_user -c /config/homeserver.yaml"
    echo ""
}

##############################################################################
# Main Script
##############################################################################

show_help() {
    head -20 "$0" | grep "^#" | sed 's/^# //'
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
            --help)
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

    # Validate prerequisites
    if [[ "$SKIP_VALIDATION" == "false" ]]; then
        validate_prerequisites
    else
        log_warn "Skipping pre-deployment validation (--skip-validation)"
    fi

    # Deploy specific phase or all phases
    if [[ -n "$SPECIFIC_PHASE" ]]; then
        case $SPECIFIC_PHASE in
            1)
                deploy_phase1
                ;;
            2)
                deploy_phase2
                ;;
            3)
                deploy_phase3
                ;;
            4)
                deploy_phase4
                ;;
            5)
                deploy_phase5
                ;;
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
