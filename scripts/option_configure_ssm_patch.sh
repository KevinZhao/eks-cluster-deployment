#!/bin/bash
#
# Configure SSM Patch Manager for EKS nodes with rolling reboot
# This script ensures nodes are patched one at a time to maintain cluster availability
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/0_setup_env.sh"

# Configuration
MAINTENANCE_WINDOW_NAME="${CLUSTER_NAME}-patch-window"
PATCH_GROUP="${PATCH_GROUP:-${CLUSTER_NAME}}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"  # Default: 1 node at a time
MAX_ERRORS="${MAX_ERRORS:-1}"            # Stop if any error
SCHEDULE="${PATCH_SCHEDULE:-cron(0 18 ? * SAT *)}"  # Default: Saturday 18:00 UTC (Sunday 03:00 JST)
DURATION_HOURS="${PATCH_DURATION:-4}"    # Maintenance window duration

log "============================================"
log "SSM Patch Manager Configuration"
log "============================================"
log "Cluster: ${CLUSTER_NAME}"
log "Patch Group: ${PATCH_GROUP}"
log "Max Concurrency: ${MAX_CONCURRENCY}"
log "Schedule: ${SCHEDULE}"
log ""

# Check for existing maintenance window
check_existing_window() {
    aws ssm describe-maintenance-windows \
        --region ${AWS_REGION} \
        --filters "Key=Name,Values=${MAINTENANCE_WINDOW_NAME}" \
        --query 'WindowIdentities[0].WindowId' \
        --output text 2>/dev/null | grep -v "None" || echo ""
}

# Create or update maintenance window
create_maintenance_window() {
    local existing_window=$(check_existing_window)
    
    if [ -n "$existing_window" ] && [ "$existing_window" != "None" ]; then
        log "Updating existing maintenance window: ${existing_window}"
        aws ssm update-maintenance-window \
            --region ${AWS_REGION} \
            --window-id "${existing_window}" \
            --name "${MAINTENANCE_WINDOW_NAME}" \
            --schedule "${SCHEDULE}" \
            --duration ${DURATION_HOURS} \
            --allow-unassociated-targets \
            --no-cli-pager
        echo "${existing_window}"
    else
        log "Creating new maintenance window: ${MAINTENANCE_WINDOW_NAME}"
        aws ssm create-maintenance-window \
            --region ${AWS_REGION} \
            --name "${MAINTENANCE_WINDOW_NAME}" \
            --schedule "${SCHEDULE}" \
            --duration ${DURATION_HOURS} \
            --cutoff 1 \
            --allow-unassociated-targets \
            --query 'WindowId' \
            --output text \
            --no-cli-pager
    fi
}

# Register targets (instances with Patch Group tag)
register_targets() {
    local window_id=$1
    
    # Check if target already exists
    local existing_target=$(aws ssm describe-maintenance-window-targets \
        --region ${AWS_REGION} \
        --window-id "${window_id}" \
        --query "Targets[?contains(Targets[].Values[], '${PATCH_GROUP}')].WindowTargetId" \
        --output text 2>/dev/null | head -1)
    
    if [ -n "$existing_target" ] && [ "$existing_target" != "None" ]; then
        log "Target already registered: ${existing_target}"
        echo "${existing_target}"
    else
        log "Registering target for Patch Group: ${PATCH_GROUP}"
        aws ssm register-target-with-maintenance-window \
            --region ${AWS_REGION} \
            --window-id "${window_id}" \
            --resource-type INSTANCE \
            --targets "Key=tag:Patch Group,Values=${PATCH_GROUP}" \
            --query 'WindowTargetId' \
            --output text \
            --no-cli-pager
    fi
}

# Register patch task with rolling configuration
register_patch_task() {
    local window_id=$1
    local target_id=$2
    
    # Check if task already exists
    local existing_task=$(aws ssm describe-maintenance-window-tasks \
        --region ${AWS_REGION} \
        --window-id "${window_id}" \
        --query "Tasks[?TaskArn=='AWS-RunPatchBaseline'].WindowTaskId" \
        --output text 2>/dev/null | head -1)
    
    if [ -n "$existing_task" ] && [ "$existing_task" != "None" ]; then
        log "Updating existing patch task: ${existing_task}"
        aws ssm update-maintenance-window-task \
            --region ${AWS_REGION} \
            --window-id "${window_id}" \
            --window-task-id "${existing_task}" \
            --max-concurrency "${MAX_CONCURRENCY}" \
            --max-errors "${MAX_ERRORS}" \
            --no-cli-pager
        echo "${existing_task}"
    else
        log "Creating patch task with rolling configuration"
        aws ssm register-task-with-maintenance-window \
            --region ${AWS_REGION} \
            --window-id "${window_id}" \
            --task-arn "AWS-RunPatchBaseline" \
            --task-type "RUN_COMMAND" \
            --targets "Key=WindowTargetIds,Values=${target_id}" \
            --task-invocation-parameters '{"RunCommand":{"Parameters":{"Operation":["Install"],"RebootOption":["RebootIfNeeded"]}}}' \
            --max-concurrency "${MAX_CONCURRENCY}" \
            --max-errors "${MAX_ERRORS}" \
            --priority 1 \
            --query 'WindowTaskId' \
            --output text \
            --no-cli-pager
    fi
}

# Tag EKS nodes with Patch Group
tag_eks_nodes() {
    log "Tagging EKS nodes with Patch Group: ${PATCH_GROUP}"
    
    # Get all node instance IDs
    local instances=$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | cut -d'/' -f5)
    
    for instance in $instances; do
        log "  Tagging instance: ${instance}"
        aws ec2 create-tags \
            --region ${AWS_REGION} \
            --resources "${instance}" \
            --tags "Key=Patch Group,Value=${PATCH_GROUP}" 2>/dev/null || true
    done
}

# Main execution
log "Step 1: Creating/Updating Maintenance Window..."
WINDOW_ID=$(create_maintenance_window)
log "  Window ID: ${WINDOW_ID}"

log ""
log "Step 2: Registering Targets..."
TARGET_ID=$(register_targets "${WINDOW_ID}")
log "  Target ID: ${TARGET_ID}"

log ""
log "Step 3: Registering Patch Task..."
TASK_ID=$(register_patch_task "${WINDOW_ID}" "${TARGET_ID}")
log "  Task ID: ${TASK_ID}"

log ""
log "Step 4: Tagging EKS Nodes..."
tag_eks_nodes

log ""
log "============================================"
log "SSM Patch Configuration Complete"
log "============================================"
log ""
log "Configuration Summary:"
log "  Maintenance Window: ${MAINTENANCE_WINDOW_NAME}"
log "  Window ID: ${WINDOW_ID}"
log "  Schedule: ${SCHEDULE}"
log "  Patch Group: ${PATCH_GROUP}"
log "  Max Concurrency: ${MAX_CONCURRENCY} (rolling reboot)"
log "  Max Errors: ${MAX_ERRORS}"
log ""
log "To view configuration:"
log "  aws ssm describe-maintenance-windows --filters Name=Name,Values=${MAINTENANCE_WINDOW_NAME}"
log ""
log "To manually trigger patching:"
log "  aws ssm start-maintenance-window-execution --window-id ${WINDOW_ID}"
log ""
log "To update concurrency (e.g., to 2 nodes at a time):"
log "  aws ssm update-maintenance-window-task --window-id ${WINDOW_ID} --window-task-id ${TASK_ID} --max-concurrency 2"
log ""
