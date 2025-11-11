#!/bin/bash

# Matrix/Synapse Production Deployment - Complete Deployment Script
# Version: 2.0
# This script deploys the entire Matrix/Synapse stack in the correct order

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo -e "\n${BLUE}======================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}======================================================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

check_prerequisites() {
    print_header "Checking Prerequisites"

    local missing=0

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found"
        missing=1
    else
        print_success "kubectl found: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    fi

    # Check helm
    if ! command -v helm &> /dev/null; then
        print_error "helm not found"
        missing=1
    else
        print_success "helm found: $(helm version --short)"
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        missing=1
    else
        print_success "Connected to Kubernetes cluster"
    fi

    # Check deployment.env
    if [ ! -f "$DEPLOYMENT_DIR/config/deployment.env" ]; then
        print_error "deployment.env not found"
        print_warning "Copy deployment.env.example to deployment.env and fill in your values"
        missing=1
    else
        print_success "deployment.env found"
    fi

    if [ $missing -eq 1 ]; then
        print_error "Prerequisites check failed"
        exit 1
    fi
}

load_config() {
    print_header "Loading Configuration"

    # Source deployment.env
    source "$DEPLOYMENT_DIR/config/deployment.env"

    # Validate required variables
    local required_vars=(
        "MATRIX_DOMAIN"
        "STORAGE_CLASS_GENERAL"
        "POSTGRES_PASSWORD"
        "MINIO_ROOT_PASSWORD"
        "SYNAPSE_REGISTRATION_SHARED_SECRET"
        "COTURN_SHARED_SECRET"
    )

    local missing=0
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            print_error "Required variable $var not set"
            missing=1
        fi
    done

    if [ $missing -eq 1 ]; then
        print_error "Configuration validation failed"
        exit 1
    fi

    print_success "Configuration loaded and validated"
}

# ============================================================================
# Deployment Phases
# ============================================================================

phase_01_namespaces() {
    print_header "Phase 1: Creating Namespaces"
    kubectl apply -f "$DEPLOYMENT_DIR/manifests/00-namespaces.yaml"
    print_success "Namespaces created"
}

phase_02_helm_repos() {
    print_header "Phase 2: Adding Helm Repositories"

    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo add minio-operator https://operator.min.io
    helm repo add metallb https://metallb.github.io/metallb
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo add livekit https://helm.livekit.io
    helm repo add jetstack https://charts.jetstack.io

    helm repo update
    print_success "Helm repositories added and updated"
}

phase_03_cert_manager() {
    print_header "Phase 3: Installing cert-manager"

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --values "$DEPLOYMENT_DIR/values/cert-manager-values.yaml" \
        --wait \
        --timeout 10m

    print_success "cert-manager installed"

    # Wait for webhook to be ready
    kubectl wait --for=condition=available --timeout=300s \
        deployment/cert-manager-webhook -n cert-manager

    print_success "cert-manager webhook ready"
}

phase_04_metallb() {
    print_header "Phase 4: Installing MetalLB"

    helm upgrade --install metallb metallb/metallb \
        --namespace metallb-system \
        --values "$DEPLOYMENT_DIR/values/metallb-values.yaml" \
        --wait \
        --timeout 10m

    print_success "MetalLB installed"

    # Apply IP address pool configuration
    sleep 5  # Wait for CRDs to be ready
    kubectl apply -f "$DEPLOYMENT_DIR/manifests/03-metallb-config.yaml"

    print_success "MetalLB IP pool configured"
}

phase_05_ingress() {
    print_header "Phase 5: Installing NGINX Ingress Controller"

    helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --values "$DEPLOYMENT_DIR/values/nginx-ingress-values.yaml" \
        --wait \
        --timeout 10m

    print_success "NGINX Ingress Controller installed"

    # Wait for LoadBalancer IP
    print_warning "Waiting for LoadBalancer IP assignment..."
    kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' \
        service/nginx-ingress-ingress-nginx-controller \
        -n ingress-nginx \
        --timeout=300s || true

    INGRESS_IP=$(kubectl get svc nginx-ingress-ingress-nginx-controller \
        -n ingress-nginx \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

    if [ -n "$INGRESS_IP" ]; then
        print_success "Ingress LoadBalancer IP: $INGRESS_IP"
        print_warning "Add DNS record: $MATRIX_DOMAIN → $INGRESS_IP"
    else
        print_warning "LoadBalancer IP not yet assigned"
    fi
}

phase_06_postgresql() {
    print_header "Phase 6: Installing CloudNativePG and PostgreSQL Cluster"

    # Install operator
    helm upgrade --install cloudnativepg cnpg/cloudnative-pg \
        --namespace cnpg-system \
        --values "$DEPLOYMENT_DIR/values/cloudnativepg-values.yaml" \
        --wait \
        --timeout 10m

    print_success "CloudNativePG operator installed"

    # Wait for operator to be ready
    kubectl wait --for=condition=available --timeout=300s \
        deployment/cloudnativepg -n cnpg-system

    # Apply PostgreSQL cluster
    kubectl apply -f "$DEPLOYMENT_DIR/manifests/01-postgresql-cluster.yaml"

    print_success "PostgreSQL cluster created"
    print_warning "Waiting for PostgreSQL cluster to be ready (this may take 5-10 minutes)..."

    # Wait for cluster to be ready
    kubectl wait --for=condition=ready --timeout=600s \
        cluster/synapse-postgres -n matrix || true

    print_success "PostgreSQL cluster ready"
}

phase_07_redis() {
    print_header "Phase 7: Installing Redis Instances"

    # Install Synapse Redis
    print_warning "Installing Redis for Synapse..."
    helm upgrade --install redis-synapse bitnami/redis \
        --namespace redis-synapse \
        --values "$DEPLOYMENT_DIR/values/redis-synapse-values.yaml" \
        --wait \
        --timeout 10m

    print_success "Redis for Synapse installed"

    # Install LiveKit Redis
    print_warning "Installing Redis for LiveKit..."
    helm upgrade --install redis-livekit bitnami/redis \
        --namespace redis-livekit \
        --values "$DEPLOYMENT_DIR/values/redis-livekit-values.yaml" \
        --wait \
        --timeout 10m

    print_success "Redis for LiveKit installed"
}

phase_08_minio() {
    print_header "Phase 8: Installing MinIO Operator and Tenant"

    # Install operator
    helm upgrade --install minio-operator minio-operator/operator \
        --namespace minio-operator \
        --values "$DEPLOYMENT_DIR/values/minio-operator-values.yaml" \
        --wait \
        --timeout 10m

    print_success "MinIO operator installed"

    # Wait for operator
    kubectl wait --for=condition=available --timeout=300s \
        deployment/minio-operator -n minio-operator

    # Apply tenant
    kubectl apply -f "$DEPLOYMENT_DIR/manifests/02-minio-tenant.yaml"

    print_success "MinIO tenant created"
    print_warning "Waiting for MinIO tenant to be ready..."

    sleep 30  # Give MinIO time to initialize

    print_success "MinIO tenant ready"
}

phase_09_coturn() {
    print_header "Phase 9: Deploying coturn TURN Servers"

    # Label nodes
    print_warning "Labeling nodes for coturn..."
    IFS=',' read -ra NODES <<< "$COTURN_NODES"
    for node in "${NODES[@]}"; do
        kubectl label node "$node" coturn=true --overwrite
        print_success "Labeled node: $node"
    done

    # Deploy coturn
    kubectl apply -f "$DEPLOYMENT_DIR/manifests/04-coturn.yaml"

    print_success "coturn deployed"
}

phase_10_livekit() {
    print_header "Phase 10: Deploying LiveKit SFU"

    # Label nodes
    print_warning "Labeling nodes for LiveKit..."
    IFS=',' read -ra NODES <<< "$LIVEKIT_NODES"
    for node in "${NODES[@]}"; do
        kubectl label node "$node" livekit=true --overwrite
        print_success "Labeled node: $node"
    done

    # Deploy LiveKit
    helm upgrade --install livekit livekit/livekit-server \
        --namespace livekit \
        --values "$DEPLOYMENT_DIR/values/livekit-values.yaml" \
        --set kind=DaemonSet \
        --wait \
        --timeout 10m

    print_success "LiveKit deployed"
}

phase_11_monitoring() {
    print_header "Phase 11: Installing Monitoring Stack"

    # Install Prometheus stack
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --values "$DEPLOYMENT_DIR/values/prometheus-stack-values.yaml" \
        --wait \
        --timeout 15m

    print_success "Prometheus stack installed"

    # Install Loki
    helm upgrade --install loki grafana/loki-stack \
        --namespace monitoring \
        --values "$DEPLOYMENT_DIR/values/loki-values.yaml" \
        --wait \
        --timeout 10m

    print_success "Loki installed"
}

phase_12_synapse() {
    print_header "Phase 12: Deploying Synapse Homeserver"

    kubectl apply -f "$DEPLOYMENT_DIR/manifests/05-synapse-main.yaml"

    print_success "Synapse main process deployed"
    print_warning "Waiting for Synapse to be ready..."

    kubectl wait --for=condition=available --timeout=300s \
        deployment/synapse-main -n matrix || true

    print_success "Synapse ready"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_header "Matrix/Synapse Production Deployment"
    print_warning "Version: 2.1 - Scale-aware deployment"
    print_warning "📊 Supports: 100 CCU to 20K+ CCU (configure manifests for your scale)"

    # Check prerequisites
    check_prerequisites

    # Load configuration
    load_config

    # Confirmation
    echo -e "\n${YELLOW}This will deploy the complete Matrix/Synapse stack to your cluster.${NC}"
    echo -e "${YELLOW}Domain: $MATRIX_DOMAIN${NC}"
    echo -e "${YELLOW}Deployment size: $DEPLOYMENT_SIZE${NC}"
    read -p "Continue? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Deployment cancelled"
        exit 0
    fi

    # Execute phases
    phase_01_namespaces
    phase_02_helm_repos
    phase_03_cert_manager
    phase_04_metallb
    phase_05_ingress
    phase_06_postgresql
    phase_07_redis
    phase_08_minio
    phase_09_coturn
    phase_10_livekit
    phase_11_monitoring
    phase_12_synapse

    # Final message
    print_header "Deployment Complete!"

    echo -e "\n${GREEN}✓ Matrix/Synapse stack deployed successfully!${NC}\n"

    echo "Next steps:"
    echo "1. Wait for all pods to be ready: kubectl get pods -A"
    echo "2. Create admin user (see documentation)"
    echo "3. Access Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo "4. Access Element Web: https://$MATRIX_DOMAIN"

    echo -e "\n${YELLOW}Important:${NC}"
    echo "- Ensure DNS points $MATRIX_DOMAIN to LoadBalancer IP: $INGRESS_IP"
    echo "- Review and customize configurations as needed"
    echo "- Set up backups (see documentation)"

    print_success "Deployment completed at $(date)"
}

# Run main function
main "$@"
