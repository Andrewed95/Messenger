#!/bin/bash
##############################################################################
# CHANGEME Validation Script
# Finds all CHANGEME placeholders in deployment manifests
#
# Usage: ./validate-changeme.sh [options]
#
# Options:
#   --verbose    Show full line content for each CHANGEME
#   --summary    Show only summary (no detailed results)
#   --help       Show this help message
#
# Exit codes:
#   0 - No CHANGEME found (ready to deploy)
#   1 - CHANGEME found (must fix before deploying)
#
# WHERE: Run from deployment/scripts/ directory
# WHEN: Before deployment OR after making configuration changes
# WHY: Ensure all configuration placeholders are replaced
##############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse command line options
VERBOSE=false
SUMMARY_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose)
            VERBOSE=true
            shift
            ;;
        --summary)
            SUMMARY_ONLY=true
            shift
            ;;
        --help)
            grep "^#" "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

# Colors (only if terminal supports them)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

echo "========================================="
echo "CHANGEME Validation Script"
echo "========================================="
echo ""
echo -e "${BLUE}Scanning: $DEPLOYMENT_DIR${NC}"
echo ""

# Search for CHANGEME in deployment manifests
# Include: YAML, shell scripts, env templates
# Exclude: docs/, scripts/, .git/, README files, this script itself
CHANGEME_RESULTS=$(find "$DEPLOYMENT_DIR" \
  -type f \
  \( -name "*.yaml" -o -name "*.yml" -o -name "*.sh" -o -name "*.env.example" -o -name "*.cfg" \) \
  ! -path "*/docs/*" \
  ! -path "*/scripts/*" \
  ! -path "*/.git/*" \
  ! -name "README.md" \
  ! -name "$(basename "$0")" \
  -exec grep -Hn -E "(CHANGEME|CHANGE_ME)" {} \; 2>/dev/null || true)

if [ -z "$CHANGEME_RESULTS" ]; then
    echo -e "${GREEN}✅ SUCCESS: No CHANGEME placeholders found!${NC}"
    echo ""
    echo "Your deployment configuration is complete."
    echo "All placeholders have been replaced with actual values."
    echo ""
    echo -e "${GREEN}Ready to deploy!${NC}"
    exit 0
else
    echo -e "${RED}❌ FAILURE: Found CHANGEME placeholders${NC}"
    echo ""

    # Count total CHANGEME occurrences
    CHANGEME_COUNT=$(echo "$CHANGEME_RESULTS" | wc -l)
    echo -e "${YELLOW}Total: $CHANGEME_COUNT placeholder(s) remaining${NC}"
    echo ""

    if [ "$SUMMARY_ONLY" = false ]; then
        # Group by file and count
        echo "========================================="
        echo "Files with CHANGEME placeholders:"
        echo "========================================="
        echo ""

        echo "$CHANGEME_RESULTS" | awk -F: '{print $1}' | sort | uniq -c | while read count file; do
            # Make file path relative to deployment/
            rel_file="${file#$DEPLOYMENT_DIR/}"
            echo -e "  ${YELLOW}$count${NC} × ${BLUE}$rel_file${NC}"
        done

        echo ""
        echo "========================================="
        echo "Detailed Results:"
        echo "========================================="
        echo ""

        # Show each CHANGEME with file, line number, and context
        echo "$CHANGEME_RESULTS" | while IFS=: read -r file line content; do
            # Make file path relative to deployment/
            rel_file="${file#$DEPLOYMENT_DIR/}"

            if [ "$VERBOSE" = true ]; then
                echo -e "${BLUE}$rel_file${NC}:${YELLOW}$line${NC}"
                echo -e "  ${content}"
                echo ""
            else
                # Truncate long lines
                truncated_content=$(echo "$content" | cut -c 1-100)
                if [ ${#content} -gt 100 ]; then
                    truncated_content="${truncated_content}..."
                fi
                echo -e "${BLUE}$rel_file${NC}:${YELLOW}$line${NC}: ${truncated_content}"
            fi
        done
    fi

    echo ""
    echo "========================================="
    echo "What to do next:"
    echo "========================================="
    echo ""
    echo "1. Review each file listed above"
    echo ""
    echo "2. Replace CHANGEME values with your organization's configuration:"
    echo "   ${YELLOW}Domains:${NC}"
    echo "     - matrix.example.com → matrix.yourorg.com"
    echo "     - element.example.com → chat.yourorg.com"
    echo ""
    echo "   ${YELLOW}Image Registry:${NC}"
    echo "     - registry.example.com → registry.yourorg.com"
    echo ""
    echo "   ${YELLOW}Secrets (generate random values):${NC}"
    echo "     - Passwords: openssl rand -base64 32"
    echo "     - API keys: openssl rand -hex 32"
    echo "     - Signing keys: python -c 'import secrets; print(secrets.token_hex(32))'"
    echo ""
    echo "   ${YELLOW}IP Addresses:${NC}"
    echo "     - Configure for your network topology"
    echo "     - Update Ingress whitelist IPs for LI instance"
    echo ""
    echo "   ${YELLOW}Storage:${NC}"
    echo "     - Update storage class names (kubectl get storageclass)"
    echo "     - Update persistent volume sizes based on SCALING-GUIDE.md"
    echo ""
    echo "3. Run this script again to verify all placeholders replaced:"
    echo "   ${GREEN}./validate-changeme.sh${NC}"
    echo ""
    echo "4. See ${BLUE}deployment/README.md${NC} Configuration section for detailed guidance"
    echo ""
    echo "5. See ${BLUE}deployment/docs/PRE-DEPLOYMENT-CHECKLIST.md${NC} for complete checklist"
    echo ""

    exit 1
fi
