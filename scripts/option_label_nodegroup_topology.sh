#!/bin/bash
# option_label_nodegroup_topology.sh — standalone tool
#
# Stamp depth-aware network-topology/level-N labels (plus efa-leaf-id /
# efa-az aliases) onto K8s nodes of an existing EKS nodegroup by
# querying ec2:DescribeInstanceTopology.
#
# Labels written per node (see topology_labeling_lib.sh for the spec):
#   network-topology/depth=<3|4|5>
#   network-topology/level-1=<id>      ← leaf (closest), always present
#   network-topology/level-2=<id>      ← one above leaf
#   network-topology/level-3=<id>      ← only if depth >= 3
#   network-topology/level-4=<id>      ← only if depth >= 4 (4-layer fabric only)
#   efa-leaf-id=<level-1>              ← back-compat alias
#   efa-az=<az>                        ← back-compat
#
# Use this tool when:
#   - You already have a running NG and want to (re-)stamp topology labels
#   - An ASG replaced Spot instances; new nodes lack the labels
#   - You want to re-verify / re-stamp after a manual node replacement
#   - You just want to print a topology inventory without labeling
#
# Usage:
#   option_label_nodegroup_topology.sh <ng_name> [action] [level]
#
#   action:
#     label        (default) stamp labels + print inventory at level-1 (leaf)
#     report       print what WOULD be labeled without touching nodes
#     inventory    only print cluster-wide topology inventory
#     clear        remove all topology labels from nodes in this NG
#
#   level: (only meaningful for label / inventory)
#     1            (default) group inventory by leaf (tightest affinity)
#     2..N         group inventory by Nth-from-leaf level
#
#   Special:
#     --all-ngs    iterate over every EKS NG in the cluster
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
  option_label_nodegroup_topology.sh <ng_name> [action] [level]
  option_label_nodegroup_topology.sh --all-ngs [action] [level]

  action:
    label       (default) stamp network-topology/level-N labels + print inventory
    report      dry-run: print what WOULD be labeled
    inventory   only print cluster-wide topology inventory (no labeling)
    clear       remove all topology labels from nodes in NG

  level (default 1):
    1           group inventory by leaf (tightest affinity, e.g. 8x p6 same T1)
    2           group inventory by one-above-leaf
    3..N        further up the tree

Examples:
  # Label one NG then show leaf-level inventory (default)
  ./option_label_nodegroup_topology.sh gpu-p5en-48xlarge-spot-az3

  # See inventory grouped by level-2 (aggregator on 4-layer fabrics)
  ./option_label_nodegroup_topology.sh --all-ngs inventory 2

  # First-time rollout across every NG
  ./option_label_nodegroup_topology.sh --all-ngs label

  # Just see what's where, leaf-level
  ./option_label_nodegroup_topology.sh --all-ngs inventory

  # Reset labels on a NG before re-labeling
  ./option_label_nodegroup_topology.sh gpu-p5en-48xlarge-spot-az3 clear
EOF
    exit 1
}

[ $# -lt 1 ] && usage

FIRST_ARG=$1
ACTION=${2:-label}
LEVEL=${3:-1}

case "${ACTION}" in
    label|report|inventory|clear) ;;
    *) echo "ERROR: unknown action '${ACTION}'"; usage ;;
esac

# Validate level is a positive integer
if ! [[ "${LEVEL}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: level must be a positive integer (got '${LEVEL}')"
    usage
fi

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
        print_leaf_inventory 2 "${LEVEL}"
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
            print_leaf_inventory 2 "${LEVEL}"
            ;;
        report)
            label_nodegroup_by_leaf "${NG_NAME}" report-only
            ;;
        inventory)
            print_leaf_inventory 2 "${LEVEL}"
            ;;
        clear)
            clear_leaf_labels "${NG_NAME}"
            ;;
    esac
fi

echo ""
echo "Done."
