#!/bin/bash
set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
AGE_KEY_FILE="${HOME}/.age/openbao-key.txt"
ENCRYPTED_FILE="${HOME}/.openbao/openbao-init.json.age"
NAMESPACE="openbao"
OPENBAO_POD_LABEL="app.kubernetes.io/name=openbao"
LOCAL_PORT=8200

# Default values for optional parameters
DRY_RUN=false
DEBUG=false
TIMEOUT=30

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
log_debug() { 
    if $DEBUG; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}
log_dry() { echo -e "${BLUE}[DRY-RUN]${NC} $1" >&2; }

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Help function
usage() {
    cat >&2 <<EOF
OpenBao Unseal Script

Usage: 
    $(basename $0) [OPTIONS] [POD_NAME...]
    
Arguments:
    POD_NAME    Optional: One or more pod names (e.g. openbao-0 openbao-1)
                Without specification: All OpenBao pods will be processed

Options:
    -h, --help              Show this help
    -l, --list              List all available pods and show status
    -d, --dry-run           Simulation - no actual unseal operations
    -t, --timeout SECS      Timeout for operations in seconds (default: 30)
    --debug                 Enable debug output

Examples:
    $(basename $0)                          # Unseal all pods
    $(basename $0) openbao-0                # Unseal only openbao-0
    $(basename $0) openbao-0 openbao-2      # Multiple specific pods
    $(basename $0) --dry-run                # Simulate all pods
    $(basename $0) --timeout 60 openbao-0   # With longer timeout
    $(basename $0) --debug                  # Enable debug output
    $(basename $0) -d -t 45 --debug         # Dry-run with custom timeout and debug
    
EOF
    exit 0
}

# Validate pod exists
validate_pod() {
    local POD=$1
    kubectl get pod -n "$NAMESPACE" "$POD" >/dev/null 2>&1 || {
        log_error "Pod '$POD' not found in namespace '$NAMESPACE'"
    }
}

# =============================================================================
# SECURITY FUNCTIONS
# =============================================================================

# Check and fix file permissions
check_secure_permissions() {
    local FILE=$1
    local FILE_NAME=$(basename "$FILE")
    
    [[ ! -f "$FILE" ]] && return 0
    
    local CURRENT_PERMS=$(stat -c '%a' "$FILE" 2>/dev/null || stat -f '%A' "$FILE" 2>/dev/null)
    
    if [[ "$CURRENT_PERMS" == "600" ]] || [[ "$CURRENT_PERMS" == "400" ]]; then
        log_debug "Permissions for $FILE_NAME are already secure ($CURRENT_PERMS)"
        return 0
    fi
    
    log_warn "Insecure permissions detected for $FILE_NAME"
    log_warn "  Current: $CURRENT_PERMS (should be 600)"
    log_warn "  File: $FILE"
    log_info "Setting secure permissions (600) for $FILE_NAME..."
    
    if chmod 600 "$FILE" 2>/dev/null; then
        local NEW_PERMS=$(stat -c '%a' "$FILE" 2>/dev/null || stat -f '%A' "$FILE" 2>/dev/null)
        log_info "Successfully set permissions to $NEW_PERMS for $FILE_NAME ✓"
        return 0
    else
        log_error "Failed to set secure permissions for $FILE_NAME"
    fi
}

# Check directory permissions
check_secure_directory() {
    local DIR=$1
    local DIR_NAME=$(basename "$DIR")
    
    [[ ! -d "$DIR" ]] && return 0
    
    local CURRENT_PERMS=$(stat -c '%a' "$DIR" 2>/dev/null || stat -f '%A' "$DIR" 2>/dev/null)
    
    if [[ "$CURRENT_PERMS" == "700" ]]; then
        log_debug "Permissions for $DIR_NAME/ are already secure ($CURRENT_PERMS)"
        return 0
    fi
    
    log_warn "Directory permissions for $DIR_NAME/ should be 700 (currently: $CURRENT_PERMS)"
    log_info "Setting secure permissions (700) for $DIR_NAME/..."
    
    if chmod 700 "$DIR" 2>/dev/null; then
        local NEW_PERMS=$(stat -c '%a' "$DIR" 2>/dev/null || stat -f '%A' "$DIR" 2>/dev/null)
        log_info "Successfully set permissions to $NEW_PERMS for $DIR_NAME/ ✓"
    else
        log_warn "Failed to set secure permissions for $DIR_NAME/ - continuing anyway"
    fi
    return 0
}

# =============================================================================
# PORT-FORWARD FUNCTIONS
# =============================================================================

# Setup port-forward to specific pod and return PID
setup_port_forward() {
    local POD=$1
    
    if $DRY_RUN; then
        echo "0"
        return 0
    fi
    
    log_debug "Setting up port-forward to pod $POD..."
    
    kubectl port-forward -n "$NAMESPACE" "pod/$POD" "$LOCAL_PORT:8200" >/dev/null 2>&1 &
    local PF_PID=$!
    
    sleep 2
    
    if ! kill -0 $PF_PID 2>/dev/null; then
        log_error "Port-forward to pod $POD could not be started"
    fi
    
    if ! timeout 5 curl -sk "http://localhost:$LOCAL_PORT/v1/sys/seal-status" >/dev/null 2>&1; then
        kill $PF_PID 2>/dev/null || true
        wait $PF_PID 2>/dev/null || true
        log_error "Port-forward established but cannot connect to OpenBao API on pod $POD"
    fi
    
    echo "$PF_PID"
}

# Cleanup port-forward by PID
cleanup_port_forward() {
    local PF_PID=$1
    
    if [[ -z "$PF_PID" ]] || [[ "$PF_PID" == "0" ]]; then
        return 0
    fi
    
    if kill -0 $PF_PID 2>/dev/null; then
        log_debug "Cleaning up port-forward (PID: $PF_PID)..."
        kill $PF_PID 2>/dev/null || true
        wait $PF_PID 2>/dev/null || true
    fi
}

# =============================================================================
# UNSEAL FUNCTIONS
# =============================================================================

# Process individual pod - check status and unseal if needed
process_pod() {
    local POD=$1
    
    log_info "Processing pod: $POD"
    
    # Check if pod is running
    local POD_STATUS=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.status.phase}')
    if [[ "$POD_STATUS" != "Running" ]]; then
        log_warn "Pod $POD is not Running (status: $POD_STATUS) - skipping"
        return 1
    fi
    
    # Setup port-forward
    local PF_PID=$(setup_port_forward "$POD")
    
    # Dry-run mode
    if $DRY_RUN; then
        log_dry "Would check sealed status of $POD..."
        log_dry "Pod $POD would be unsealed ✓"
        cleanup_port_forward "$PF_PID"
        return 0
    fi
    
    # Check sealed status
    local SEALED=$(timeout ${TIMEOUT} curl -sk "http://localhost:$LOCAL_PORT/v1/sys/seal-status" 2>/dev/null | jq -r '.sealed')
    
    if [[ -z "$SEALED" ]]; then
        cleanup_port_forward "$PF_PID"
        log_error "Could not query sealed status of pod $POD"
    fi
    
    # Already unsealed
    if [[ "$SEALED" == "false" ]]; then
        log_info "Pod $POD is already unsealed ✓"
        cleanup_port_forward "$PF_PID"
        return 0
    fi
    
    # Need to unseal
    log_warn "Pod $POD is sealed - starting unseal process..."
    
    local PROGRESS=0
    while IFS= read -r KEY; do
        ((PROGRESS++))
        
        local RESPONSE=$(timeout ${TIMEOUT} curl -sk -X POST "http://localhost:$LOCAL_PORT/v1/sys/unseal" \
            -H "Content-Type: application/json" \
            -d "{\"key\": \"$KEY\"}" 2>/dev/null)
        
        if [[ -z "$RESPONSE" ]]; then
            cleanup_port_forward "$PF_PID"
            log_error "No response from pod $POD when sending key $PROGRESS"
        fi
        
        SEALED=$(echo "$RESPONSE" | jq -r '.sealed')
        local PROGRESS_STATUS=$(echo "$RESPONSE" | jq -r '.progress')
        local THRESHOLD=$(echo "$RESPONSE" | jq -r '.t')
        
        log_debug "  Key $PROGRESS/$THRESHOLD sent - progress: $PROGRESS_STATUS/$THRESHOLD"
        
        [[ "$SEALED" == "false" ]] && break
    done <<< "$UNSEAL_KEYS"
    
    cleanup_port_forward "$PF_PID"
    
    if [[ "$SEALED" == "false" ]]; then
        log_info "Pod $POD successfully unsealed ✓"
        return 0
    else
        log_error "Pod $POD could not be unsealed"
    fi
}

# =============================================================================
# LIST PODS FUNCTION
# =============================================================================

list_pods() {
    log_info "Available OpenBao pods:"
    echo >&2
    
    local PODS=$(kubectl get pods -n "$NAMESPACE" -l "$OPENBAO_POD_LABEL" -o jsonpath='{.items[*].metadata.name}')
    [[ -z "$PODS" ]] && log_error "No OpenBao pods found"
    
    printf "%-20s %-10s %-10s\n" "POD NAME" "STATUS" "SEALED" >&2
    printf "%-20s %-10s %-10s\n" "--------" "------" "------" >&2
    
    for POD in $PODS; do
        local POD_STATUS=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.status.phase}')
        
        if [[ "$POD_STATUS" == "Running" ]]; then
            kubectl port-forward -n "$NAMESPACE" "pod/$POD" "$LOCAL_PORT:8200" >/dev/null 2>&1 &
            local PF_PID=$!
            sleep 2
            
            if kill -0 $PF_PID 2>/dev/null; then
                local SEALED=$(timeout 5 curl -sk "http://localhost:$LOCAL_PORT/v1/sys/seal-status" 2>/dev/null | jq -r '.sealed')
                
                if [[ "$SEALED" == "false" ]]; then
                    SEALED_COLOR="${GREEN}unsealed${NC}"
                elif [[ "$SEALED" == "true" ]]; then
                    SEALED_COLOR="${RED}sealed${NC}"
                else
                    SEALED_COLOR="${YELLOW}unknown${NC}"
                fi
            else
                SEALED_COLOR="${YELLOW}unknown${NC}"
            fi
            
            kill $PF_PID 2>/dev/null || true
            wait $PF_PID 2>/dev/null || true
        else
            SEALED_COLOR="${YELLOW}n/a${NC}"
        fi
        
        printf "%-20s %-10s " "$POD" "$POD_STATUS" >&2
        echo -e "$SEALED_COLOR" >&2
        
        sleep 1
    done
    
    exit 0
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

# Argument parsing
SPECIFIC_PODS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -l|--list)
            list_pods
            ;;
        -d|--dry-run)
            DRY_RUN=true
            log_info "DRY-RUN mode activated"
            shift
            ;;
        --debug)
            DEBUG=true
            log_info "DEBUG mode activated"
            shift
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]] && log_error "Timeout must be a number"
            log_info "Timeout set to ${TIMEOUT}s"
            shift 2
            ;;
        -*)
            log_error "Unknown option: $1 (use -h for help)"
            ;;
        *)
            SPECIFIC_PODS+=("$1")
            shift
            ;;
    esac
done

# Check dependencies
command -v age >/dev/null 2>&1 || log_error "age not installed: sudo apt install age"
command -v jq >/dev/null 2>&1 || log_error "jq not installed: sudo apt install jq"
command -v timeout >/dev/null 2>&1 || log_error "timeout not installed (part of coreutils)"

# Check if files exist
[[ -f "$AGE_KEY_FILE" ]] || log_error "Age key not found: $AGE_KEY_FILE"
[[ -f "$ENCRYPTED_FILE" ]] || log_error "Encrypted file not found: $ENCRYPTED_FILE"

# Security check
log_info "Checking file permissions security..."
echo >&2

check_secure_directory "$(dirname "$AGE_KEY_FILE")"
check_secure_directory "$(dirname "$ENCRYPTED_FILE")"
check_secure_permissions "$AGE_KEY_FILE" || log_error "Cannot secure age key file permissions"
check_secure_permissions "$ENCRYPTED_FILE" || log_error "Cannot secure encrypted file permissions"

echo >&2
log_info "File permissions security check completed ✓"
echo >&2

# Decrypt keys
if $DRY_RUN; then
    log_dry "Would decrypt unseal keys..."
    UNSEAL_KEYS="dummy-key-1
dummy-key-2
dummy-key-3"
    KEY_COUNT=3
else
    log_info "Decrypting unseal keys..."
    UNSEAL_DATA=$(age -d -i "$AGE_KEY_FILE" "$ENCRYPTED_FILE" 2>/dev/null) || log_error "Decryption failed"
    
    UNSEAL_KEYS=$(echo "$UNSEAL_DATA" | jq -r '.unseal_keys_b64[:3][]')
    KEY_COUNT=$(echo "$UNSEAL_KEYS" | wc -l)
    
    [[ $KEY_COUNT -lt 3 ]] && log_error "Not enough unseal keys found (required: 3, found: $KEY_COUNT)"
fi

log_info "Using $KEY_COUNT unseal keys"

# Determine pod list
if [[ ${#SPECIFIC_PODS[@]} -gt 0 ]]; then
    log_info "Processing specific pods: ${SPECIFIC_PODS[*]}"
    PODS=("${SPECIFIC_PODS[@]}")
    
    for POD in "${PODS[@]}"; do
        validate_pod "$POD"
    done
else
    log_info "Searching for all OpenBao pods..."
    PODS_STRING=$(kubectl get pods -n "$NAMESPACE" -l "$OPENBAO_POD_LABEL" -o jsonpath='{.items[*].metadata.name}')
    [[ -z "$PODS_STRING" ]] && log_error "No OpenBao pods found"
    
    read -ra PODS <<< "$PODS_STRING"
    log_info "Found pods: ${PODS[*]}"
fi

echo >&2

# Counters
TOTAL=${#PODS[@]}
SUCCESS=0
FAILED=0
SKIPPED=0

# Process all pods - temporarily disable exit on error for this loop
set +e
for POD in "${PODS[@]}"; do
    process_pod "$POD"
    RESULT=$?
    
    if [[ $RESULT -eq 0 ]]; then
        ((SUCCESS++))
    elif [[ $RESULT -eq 1 ]]; then
        ((SKIPPED++))
    else
        ((FAILED++))
    fi
    
    echo >&2
done
set -e

# Summary
if $DRY_RUN; then
    log_info "=== DRY-RUN Summary ==="
else
    log_info "=== Summary ==="
fi

echo "Total pods:     $TOTAL" >&2
echo -e "${GREEN}Successful:${NC}     $SUCCESS" >&2
[[ $SKIPPED -gt 0 ]] && echo -e "${YELLOW}Skipped:${NC}        $SKIPPED" >&2
[[ $FAILED -gt 0 ]] && echo -e "${RED}Failed:${NC}         $FAILED" >&2

[[ $FAILED -gt 0 ]] && exit 1
exit 0
