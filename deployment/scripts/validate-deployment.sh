#!/bin/bash
# Automated Validation Script for Matrix/Synapse Deployment
# Checks for all 17 critical fixes implemented

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

echo "========================================="
echo "Matrix/Synapse Deployment Validation"
echo "========================================="
echo ""

# Function to check if file contains pattern
check_pattern() {
    local file=$1
    local pattern=$2
    local description=$3

    if [ ! -f "$file" ]; then
        echo -e "${RED}✗${NC} $description - File not found: $file"
        ((ERRORS++))
        return 1
    fi

    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $description"
        return 0
    else
        echo -e "${RED}✗${NC} $description - Pattern not found in $file"
        ((ERRORS++))
        return 1
    fi
}

# Function to check YAML validity
check_yaml() {
    local file=$1
    local description=$2

    if [ ! -f "$file" ]; then
        echo -e "${RED}✗${NC} $description - File not found: $file"
        ((ERRORS++))
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} $description - Valid YAML"
            return 0
        else
            echo -e "${RED}✗${NC} $description - Invalid YAML syntax"
            ((ERRORS++))
            return 1
        fi
    else
        echo -e "${YELLOW}⚠${NC} $description - Cannot validate YAML (python3 not found)"
        ((WARNINGS++))
        return 1
    fi
}

echo "1. Checking Infrastructure Components..."
echo "-----------------------------------------"

# Check PostgreSQL configuration
check_pattern "infrastructure/01-postgresql/main-cluster.yaml" \
    "instances: 3" \
    "PostgreSQL main cluster HA configuration"

check_pattern "infrastructure/01-postgresql/main-cluster.yaml" \
    "size: 50Gi" \
    "PostgreSQL storage size for 100 CCU"

# Check Redis password secret
check_pattern "infrastructure/02-redis/redis-statefulset.yaml" \
    "kind: Secret" \
    "Redis password Secret definition"

check_pattern "infrastructure/02-redis/redis-secret.yaml" \
    'name: redis-password' \
    "Redis password Secret name"

# Check MinIO erasure coding
check_pattern "infrastructure/03-minio/tenant.yaml" \
    "servers: 4" \
    "MinIO EC:4 server configuration"

check_pattern "infrastructure/03-minio/tenant.yaml" \
    "volumesPerServer: 2" \
    "MinIO volumes for erasure coding"

# Check NetworkPolicy namespace selectors
check_pattern "infrastructure/04-networking/networkpolicies.yaml" \
    'kubernetes.io/metadata.name' \
    "NetworkPolicy namespace selector fix"

echo ""
echo "2. Checking Main Instance Components..."
echo "-----------------------------------------"

# Check Synapse S3 provider installation
if [ -f "main-instance/01-synapse/main-statefulset.yaml" ]; then
    check_pattern "main-instance/01-synapse/main-statefulset.yaml" \
        "synapse-s3-storage-provider" \
        "S3 storage provider installation"

    check_pattern "main-instance/01-synapse/main-statefulset.yaml" \
        "name: install-s3-provider" \
        "S3 provider init container"
else
    echo -e "${YELLOW}⚠${NC} Synapse main StatefulSet not found - checking for alternative file"
    if [ -f "main-instance/01-synapse/synapse-main.yaml" ]; then
        check_pattern "main-instance/01-synapse/synapse-main.yaml" \
            "synapse-s3-storage-provider" \
            "S3 storage provider installation"
    else
        echo -e "${RED}✗${NC} Cannot find Synapse main deployment file"
        ((ERRORS++))
    fi
fi

# Check HAProxy metrics path
check_pattern "monitoring/01-prometheus/servicemonitors.yaml" \
    'path: /stats;csv' \
    "HAProxy ServiceMonitor metrics path"

# Check key_vault in LI instance (per CLAUDE.md section 3.3)
check_pattern "li-instance/05-key-vault/deployment.yaml" \
    "name: run-migrations" \
    "key_vault Django migrations init container"

check_pattern "li-instance/05-key-vault/deployment.yaml" \
    "sqlite3" \
    "key_vault SQLite database configuration"

# Check LiveKit configuration
check_pattern "main-instance/04-livekit/deployment.yaml" \
    "name: generate-config" \
    "LiveKit config generation init container"

check_pattern "main-instance/04-livekit/deployment.yaml" \
    'sed -i "s/REDIS_PASSWORD_PLACEHOLDER' \
    "LiveKit variable substitution"

echo ""
echo "3. Checking LI Instance Components..."
echo "-----------------------------------------"

# Check sync system replication
check_pattern "li-instance/04-sync-system/deployment.yaml" \
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO postgres" \
    "Replication setup using postgres superuser"

check_pattern "li-instance/04-sync-system/deployment.yaml" \
    'name: POSTGRES_PASSWORD' \
    "Replication setup with superuser"

echo ""
echo "4. Checking Auxiliary Services..."
echo "-----------------------------------------"

# Check content scanner
check_pattern "antivirus/02-scan-workers/deployment.yaml" \
    'clamav.matrix.svc.cluster.local' \
    "Content scanner ClamAV connection configuration"

check_pattern "antivirus/02-scan-workers/deployment.yaml" \
    'tcpSocket' \
    "Content scanner TCP socket health probe"

echo ""
echo "5. Checking for Remaining Issues..."
echo "-----------------------------------------"

# Find CHANGEME placeholders
echo -n "Checking for CHANGEME placeholders... "
PLACEHOLDERS=$(grep -r "CHANGEME" . --include="*.yaml" 2>/dev/null | grep -v "^#" | wc -l || true)
if [ "$PLACEHOLDERS" -gt 0 ]; then
    echo -e "${YELLOW}⚠${NC} Found $PLACEHOLDERS placeholders"
    ((WARNINGS++))
else
    echo -e "${GREEN}✓${NC}"
fi

# Count total YAML files
YAML_COUNT=$(find . -name "*.yaml" -type f | wc -l)
echo -e "${GREEN}✓${NC} Found $YAML_COUNT YAML files in deployment"

echo ""
echo "========================================="
echo "Validation Summary"
echo "========================================="
echo ""

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GREEN}✓ All validation checks passed!${NC}"
    echo "The deployment is ready for installation."
elif [ "$ERRORS" -eq 0 ]; then
    echo -e "${YELLOW}⚠ Validation completed with $WARNINGS warnings${NC}"
    echo "Review warnings above before proceeding with deployment."
else
    echo -e "${RED}✗ Validation failed with $ERRORS errors and $WARNINGS warnings${NC}"
    echo "Fix the errors above before attempting deployment."
fi

echo ""
echo "Next steps:"
echo "1. Replace all CHANGEME placeholders with secure values"
echo "2. Update domain names in Ingress and configuration files"
echo "3. Ensure all prerequisites are installed (cert-manager, ingress, etc.)"
echo "4. Follow the deployment order in docs/PRE-DEPLOYMENT-CHECKLIST.md"

exit $ERRORS
