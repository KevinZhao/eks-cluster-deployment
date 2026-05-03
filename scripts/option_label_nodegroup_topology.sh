#!/bin/bash
# option_label_nodegroup_topology.sh — standalone tool
#
# Stamp efa-leaf-id + efa-az labels onto K8s nodes of an existing
# EKS nodegroup by querying ec2:DescribeInstanceTopology.
#
# Use this tool when:
#   - You already have a running NG (created before P3 was deployed)
#   - An ASG replaced Spot instances; new nodes lack the labels
#   - You want to re-verify / re-stamp after a manual node replacement
#   - You just want to print a leaf inventory without labeling
#
# Usage:
#   option_label_nodegroup_topology.sh <ng_name> [action]
#
#   action:
#     label        (default) stamp labels + print inventory
#     report       print what WOULD be labeled without touching nodes
#     inventory    only print cluster-wide leaf inventory
#     clear        remove efa-leaf-id + efa-az labels from nodes in this NG
#
#   Special:
#     --all-ngs    iterate over every EKS NG in the cluster and label
#                  each one (useful for "first-time rollout")
#
# Env:
#   CLUSTER_NAME, AWS_REGION, KUBECONFIG  (loaded from 0_setup_env.sh)
#   TOPO_INVENTORY_OUT=/tmp/leaf-inv.json (optional JSON output)

set -e
set -o pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load env + lib
# shellcheck source=0_setup_env.sh
source "${SCRIPT_DIR}/0_setup_env.sh"
# shellcheck source=topology_labeling_lib.sh
source "${SCRIPT_DIR}/topology_labeling_lib.sh"

export KUBECONFIG="${HOME:-/root}/.kube/config"

# ----------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------
usage() {
    cat <<'EOF'
Usage:
  option_label_nodegroup_topology.sh <ng_name> [action]
  option_label_nodegroup_topology.sh --all-ngs [action]

  action:
    label       (default) stamp efa-leaf-id/efa-az labels + print inventory
    report      dry-run: print what WOULD be labeled
    inventory   only print cluster-wide leaf inventory (no labeling)
    clear       remove efa-leaf-id/efa-az labels from nodes in NG

Examples:
  # Label one NG then show inventory
  ./option_label_nodegroup_topology.sh gpu-p5en-48xlarge-spot-az3

  # First-time rollout across every NG
  ./option_label_nodegroup_topology.sh --all-ngs label

  # Just see what's where
  ./option_label_nodegroup_topology.sh --all-ngs inventory

  # Reset labels on a NG before re-labeling
  ./option_label_nodegroup_topology.sh gpu-p5en-48xlarge-spot-az3 clear
EOF
    exit 1
}

[ $# -lt 1 ] && usage

FIRST_ARG=$1
ACTION=${2:-label}

case "${ACTION}" in
    label|report|inventory|clear) ;;
    *) echo "ERROR: unknown action '${ACTION}'"; usage ;;
esac

# Pre-flight
for tool in aws jq kubectl; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "ERROR: missing dependency: ${tool}"; exit 1
    }
done

if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    exit 1
fi

# ----------------------------------------------------------
# Mode dispatch
# ----------------------------------------------------------
if [ "${FIRST_ARG}" = "--all-ngs" ]; then
    echo "Iterating over all NGs in cluster ${CLUSTER_NAME}..."
    NGS=$(aws eks list-nodegroups \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" \
        --query 'nodegroups[]' --output text)
    if [ -z "${NGS}" ]; then
        echo "No nodegroups found."
        exit 0
    fi

    for ng in ${NGS}; do
        echo ""
        echo "=========================================="
        echo "NG: ${ng}  action=${ACTION}"
        echo "=========================================="
        case "${ACTION}" in
            label)
                label_nodegroup_by_leaf "${ng}" label
                ;;
            report)
                label_nodegroup_by_leaf "${ng}" report-only
                ;;
            inventory)
                # Inventory is cluster-wide; run once after loop
                ;;
            clear)
                clear_leaf_labels "${ng}"
                ;;
        esac
    done

    # Cluster-wide inventory always printed after any --all-ngs run
    if [ "${ACTION}" != "clear" ]; then
        print_leaf_inventory
    fi

else
    NG_NAME="${FIRST_ARG}"
    # Validate NG exists
    if ! aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${NG_NAME}" \
        --region "${AWS_REGION}" &>/dev/null; then
        echo "ERROR: NG '${NG_NAME}' not found in cluster ${CLUSTER_NAME}"
        exit 1
    fi

    case "${ACTION}" in
        label)
            label_nodegroup_by_leaf "${NG_NAME}" label
            print_leaf_inventory
            ;;
        report)
            label_nodegroup_by_leaf "${NG_NAME}" report-only
            ;;
        inventory)
            print_leaf_inventory
            ;;
        clear)
            clear_leaf_labels "${NG_NAME}"
            ;;
    esac
fi

echo ""
echo "Done."
