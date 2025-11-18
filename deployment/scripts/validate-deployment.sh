#!/bin/bash
##############################################################################
# Matrix/Synapse Deployment Validation Script
# Validates all components are healthy and properly configured
#
# Usage: ./validate-deployment.sh [OPTIONS]
#
# Options:
#   --phase <1-5>    Validate only specific phase
#   --detailed       Show detailed pod information
#   --help           Show this help message
#
# Last Updated: 2025-11-18
##############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SPECIFIC_PHASE=""
DETAILED=false
PASSED=0
FAILED=0

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

check_pods() {
    local label="$1"
    local namespace="$2"
    local min_count="$3"
    local component="$4"

    local total_count ready_count

    total_count=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l)
    ready_count=$(kubectl get pods -n "$namespace" -l "$label" \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
        | grep -c "True" || echo "0")

    if [[ "$total_count" -eq 0 ]]; then
        log_fail "$component: No pods found (expected >= $min_count)"
        return 1
    elif [[ "$ready_count" -ge "$min_count" ]]; then
        log_pass "$component: $ready_count/$total_count pods ready (expected >= $min_count)"

        if [[ "$DETAILED" == "true" ]]; then
            kubectl get pods -n "$namespace" -l "$label" -o wide
        fi
        return 0
    else
        log_fail "$component: Only $ready_count/$total_count pods ready (expected >= $min_count)"
        kubectl get pods -n "$namespace" -l "$label"
        return 1
    fi
}

check_service() {
    local service_name="$1"
    local namespace="$2"

    if kubectl get service "$service_name" -n "$namespace" &>/dev/null; then
        local endpoints
        endpoints=$(kubectl get endpoints "$service_name" -n "$namespace" \
            -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")

        if [[ -n "$endpoints" ]]; then
            log_pass "Service $service_name has endpoints"
            return 0
        else
            log_warn "Service $service_name exists but has no endpoints"
            return 1
        fi
    else
        log_fail "Service $service_name not found"
        return 1
    fi
}

check_ingress() {
    local ingress_name="$1"
    local namespace="$2"
    local expected_host="$3"

    if kubectl get ingress "$ingress_name" -n "$namespace" &>/dev/null; then
        local host
        host=$(kubectl get ingress "$ingress_name" -n "$namespace" \
            -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")

        local ip
        ip=$(kubectl get ingress "$ingress_name" -n "$namespace" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

        if [[ "$host" == "$expected_host" ]] || [[ "$expected_host" == "*" ]]; then
            log_pass "Ingress $ingress_name configured (host: $host, IP: $ip)"
            return 0
        else
            log_warn "Ingress $ingress_name configured but host mismatch (expected: $expected_host, got: $host)"
            return 1
        fi
    else
        log_fail "Ingress $ingress_name not found"
        return 1
    fi
}

check_networkpolicy() {
    local policy_name="$1"
    local namespace="$2"

    if kubectl get networkpolicy "$policy_name" -n "$namespace" &>/dev/null; then
        log_pass "NetworkPolicy $policy_name exists"
        return 0
    else
        log_fail "NetworkPolicy $policy_name not found"
        return 1
    fi
}

check_pdb() {
    local pdb_name="$1"
    local namespace="$2"

    if kubectl get pdb "$pdb_name" -n "$namespace" &>/dev/null; then
        local allowed_disruptions
        allowed_disruptions=$(kubectl get pdb "$pdb_name" -n "$namespace" \
            -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo "0")

        if [[ "$allowed_disruptions" -gt 0 ]]; then
            log_pass "PodDisruptionBudget $pdb_name allows $allowed_disruptions disruptions"
            return 0
        else
            log_warn "PodDisruptionBudget $pdb_name allows 0 disruptions"
            return 1
        fi
    else
        log_fail "PodDisruptionBudget $pdb_name not found"
        return 1
    fi
}

##############################################################################
# Phase 1: Infrastructure Validation
##############################################################################

validate_phase1() {
    log_section "Phase 1: Infrastructure Validation"

    # PostgreSQL Main Cluster
    log_info "Checking PostgreSQL main cluster..."
    if kubectl get cluster matrix-postgresql -n matrix &>/dev/null; then
        local instances
        instances=$(kubectl get cluster matrix-postgresql -n matrix \
            -o jsonpath='{.spec.instances}' 2>/dev/null || echo "0")
        local ready
        ready=$(kubectl get cluster matrix-postgresql -n matrix \
            -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")

        if [[ "$ready" -eq "$instances" ]]; then
            log_pass "PostgreSQL main cluster: $ready/$instances instances ready"
        else
            log_fail "PostgreSQL main cluster: Only $ready/$instances instances ready"
        fi
    else
        log_fail "PostgreSQL main cluster not found"
    fi

    # PostgreSQL LI Cluster
    log_info "Checking PostgreSQL LI cluster..."
    if kubectl get cluster matrix-postgresql-li -n matrix &>/dev/null; then
        local instances
        instances=$(kubectl get cluster matrix-postgresql-li -n matrix \
            -o jsonpath='{.spec.instances}' 2>/dev/null || echo "0")
        local ready
        ready=$(kubectl get cluster matrix-postgresql-li -n matrix \
            -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")

        if [[ "$ready" -eq "$instances" ]]; then
            log_pass "PostgreSQL LI cluster: $ready/$instances instances ready"
        else
            log_fail "PostgreSQL LI cluster: Only $ready/$instances instances ready"
        fi
    else
        log_fail "PostgreSQL LI cluster not found"
    fi

    # Redis
    check_pods "app.kubernetes.io/name=redis" "matrix" 3 "Redis"

    # MinIO
    log_info "Checking MinIO tenant..."
    if kubectl get tenant matrix-minio -n matrix &>/dev/null; then
        local state
        state=$(kubectl get tenant matrix-minio -n matrix \
            -o jsonpath='{.status.currentState}' 2>/dev/null || echo "Unknown")

        if [[ "$state" == "Initialized" ]]; then
            log_pass "MinIO tenant: State is Initialized"
        else
            log_warn "MinIO tenant: State is $state (expected: Initialized)"
        fi
    else
        log_fail "MinIO tenant not found"
    fi

    # NetworkPolicies
    local policies=("default-deny-all" "allow-dns" "postgresql-access" "postgresql-li-access" \
                    "redis-access" "minio-access" "key-vault-isolation" "li-instance-isolation" \
                    "synapse-main-egress" "allow-from-ingress" "allow-prometheus-scraping" \
                    "antivirus-access")

    for policy in "${policies[@]}"; do
        check_networkpolicy "$policy" "matrix"
    done

    # Ingress Controller
    check_pods "app.kubernetes.io/name=ingress-nginx" "ingress-nginx" 1 "NGINX Ingress"

    # cert-manager
    check_pods "app.kubernetes.io/name=cert-manager" "cert-manager" 1 "cert-manager"
}

##############################################################################
# Phase 2: Main Instance Validation
##############################################################################

validate_phase2() {
    log_section "Phase 2: Main Instance Validation"

    # Synapse Main
    check_pods "app.kubernetes.io/name=synapse,app.kubernetes.io/component=main" "matrix" 1 "Synapse Main"

    # Synapse Workers
    check_pods "app.kubernetes.io/name=synapse,app.kubernetes.io/component=synchrotron" "matrix" 2 "Synchrotron Workers"
    check_pods "app.kubernetes.io/name=synapse,app.kubernetes.io/component=generic-worker" "matrix" 2 "Generic Workers"
    check_pods "app.kubernetes.io/name=synapse,app.kubernetes.io/component=media-repository" "matrix" 2 "Media Repository Workers"
    check_pods "app.kubernetes.io/name=synapse,app.kubernetes.io/component=event-persister" "matrix" 2 "Event Persister Workers"
    check_pods "app.kubernetes.io/name=synapse,app.kubernetes.io/component=federation-sender" "matrix" 2 "Federation Sender Workers"

    # HAProxy
    check_pods "app.kubernetes.io/name=haproxy" "matrix" 2 "HAProxy"

    # Element Web
    check_pods "app.kubernetes.io/name=element-web" "matrix" 1 "Element Web"

    # Services
    check_service "synapse-main" "matrix"
    check_service "synapse-synchrotron" "matrix"
    check_service "synapse-generic-worker" "matrix"
    check_service "synapse-media-repository" "matrix"
    check_service "haproxy-client" "matrix"
    check_service "haproxy-federation" "matrix"

    # PodDisruptionBudgets
    check_pdb "synapse-main" "matrix"
    check_pdb "synapse-synchrotron" "matrix"
    check_pdb "synapse-generic-worker" "matrix"
    check_pdb "synapse-media-repository" "matrix"
    check_pdb "synapse-event-persister" "matrix"
    check_pdb "synapse-federation-sender" "matrix"
    check_pdb "haproxy" "matrix"

    # coturn
    check_pods "app.kubernetes.io/name=coturn" "matrix" 2 "coturn"

    # Sygnal
    check_pods "app.kubernetes.io/name=sygnal" "matrix" 1 "Sygnal"

    # key_vault
    check_pods "app.kubernetes.io/name=key-vault" "matrix" 1 "key_vault"
}

##############################################################################
# Phase 3: LI Instance Validation
##############################################################################

validate_phase3() {
    log_section "Phase 3: LI Instance Validation"

    # Synapse LI
    check_pods "matrix.instance=li,app.kubernetes.io/name=synapse" "matrix" 1 "Synapse LI"

    # Element Web LI
    check_pods "matrix.instance=li,app.kubernetes.io/name=element-web" "matrix" 1 "Element Web LI"

    # Synapse Admin LI
    check_pods "matrix.instance=li,app.kubernetes.io/name=synapse-admin" "matrix" 1 "Synapse Admin LI"

    # Sync System
    check_pods "app.kubernetes.io/name=sync-system" "matrix" 1 "Sync System"

    # Check replication lag
    log_info "Checking PostgreSQL replication lag..."
    local lag
    lag=$(kubectl exec -n matrix matrix-postgresql-li-1 -c postgres -- \
        psql -U postgres -d matrix_li -t -c \
        "SELECT EXTRACT(EPOCH FROM (NOW() - pg_last_xact_replay_timestamp()));" \
        2>/dev/null | tr -d ' ' || echo "999")

    if (( $(echo "$lag < 10" | bc -l 2>/dev/null || echo "0") )); then
        log_pass "Replication lag: ${lag}s (< 10s)"
    else
        log_warn "Replication lag: ${lag}s (>= 10s)"
    fi

    # Services
    check_service "synapse-li-client" "matrix"
}

##############################################################################
# Phase 4: Monitoring Validation
##############################################################################

validate_phase4() {
    log_section "Phase 4: Monitoring Stack Validation"

    # Prometheus
    check_pods "app.kubernetes.io/name=prometheus" "monitoring" 1 "Prometheus"

    # Grafana
    check_pods "app.kubernetes.io/name=grafana" "monitoring" 1 "Grafana"

    # Loki
    check_pods "app=loki" "monitoring" 1 "Loki"

    # ServiceMonitors
    log_info "Checking ServiceMonitors..."
    local sm_count
    sm_count=$(kubectl get servicemonitor -n matrix 2>/dev/null | wc -l)

    if [[ "$sm_count" -gt 5 ]]; then
        log_pass "Found $sm_count ServiceMonitors in matrix namespace"
    else
        log_warn "Only found $sm_count ServiceMonitors (expected more)"
    fi

    # PrometheusRules
    log_info "Checking PrometheusRules..."
    local pr_count
    pr_count=$(kubectl get prometheusrule -n matrix 2>/dev/null | wc -l)

    if [[ "$pr_count" -gt 0 ]]; then
        log_pass "Found $pr_count PrometheusRules in matrix namespace"
    else
        log_warn "No PrometheusRules found in matrix namespace"
    fi
}

##############################################################################
# Phase 5: Antivirus Validation
##############################################################################

validate_phase5() {
    log_section "Phase 5: Antivirus System Validation"

    # ClamAV
    check_pods "app.kubernetes.io/name=clamav" "matrix" 1 "ClamAV"

    # Content Scanner
    check_pods "app.kubernetes.io/name=content-scanner" "matrix" 3 "Content Scanner"

    # Check ClamAV virus definitions
    log_info "Checking ClamAV virus definitions..."
    local clamav_pod
    clamav_pod=$(kubectl get pods -n matrix -l app.kubernetes.io/name=clamav -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$clamav_pod" ]]; then
        local db_version
        db_version=$(kubectl exec -n matrix "$clamav_pod" -c clamd -- \
            clamdscan --version 2>/dev/null | grep -oP 'ClamAV \K[0-9.]+' || echo "unknown")

        if [[ "$db_version" != "unknown" ]]; then
            log_pass "ClamAV version: $db_version"
        else
            log_warn "Could not determine ClamAV version"
        fi
    fi

    # Services
    check_service "clamav" "matrix"
    check_service "content-scanner" "matrix"
}

##############################################################################
# Main Script
##############################################################################

show_help() {
    head -15 "$0" | grep "^#" | sed 's/^# //'
    exit 0
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --phase)
                SPECIFIC_PHASE="$2"
                shift 2
                ;;
            --detailed)
                DETAILED=true
                shift
                ;;
            --help)
                show_help
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                ;;
        esac
    done

    # Show banner
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Matrix/Synapse Validation${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # Validate specific phase or all phases
    if [[ -n "$SPECIFIC_PHASE" ]]; then
        case $SPECIFIC_PHASE in
            1) validate_phase1 ;;
            2) validate_phase2 ;;
            3) validate_phase3 ;;
            4) validate_phase4 ;;
            5) validate_phase5 ;;
            *)
                echo "Invalid phase: $SPECIFIC_PHASE. Must be 1-5."
                exit 1
                ;;
        esac
    else
        validate_phase1
        validate_phase2
        validate_phase3
        validate_phase4
        validate_phase5
    fi

    # Summary
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Validation Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${GREEN}PASSED: $PASSED${NC}"
    echo -e "${RED}FAILED: $FAILED${NC}"
    echo ""

    if [[ "$FAILED" -eq 0 ]]; then
        echo -e "${GREEN}All validations passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some validations failed. Review the output above.${NC}"
        exit 1
    fi
}

main "$@"
