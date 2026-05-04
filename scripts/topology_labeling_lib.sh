#!/bin/bash
# topology_labeling_lib.sh — EFA network-topology labeling library
#
# Label K8s nodes with their AWS L3 (leaf) network-topology node ID
# so that multi-node workloads (PD-disagg, NCCL all-reduce, UCCL-EP,
# DeepEP alltoall) can pin themselves to a single leaf via nodeAffinity.
#
# Real-world: cluster placement groups on p5en/p6-class instances
# pack only to L2 (aggregator), not L3 (leaf). This lib fills the gap
# by reading DescribeInstanceTopology post-placement and stamping the
# true leaf ID onto each K8s node.
#
# This lib is intentionally transport-agnostic: sourced by the ASG
# bootstrap script (option_install_gpu_nodegroups.sh), by the standalone
# re-labeling tool (option_label_nodegroup_topology.sh), and in the
# future by a K8s DaemonSet / node-init container when a Karpenter-like
# pod-driven provisioner enters the picture.
#
# Required env: CLUSTER_NAME, AWS_REGION, KUBECONFIG
# Required tools: aws, jq, kubectl

set -e
set -o pipefail

# ===================================================================
# Internal: resolve ASG → InService instance IDs
# ===================================================================
_topo_get_ng_instance_ids() {
    local ng_name=$1

    local asg_name
    asg_name=$(aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --region "${AWS_REGION}" \
        --query 'nodegroup.resources.autoScalingGroups[0].name' \
        --output text 2>/dev/null)

    if [ -z "${asg_name}" ] || [ "${asg_name}" = "None" ]; then
        return 1
    fi

    aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${asg_name}" \
        --region "${AWS_REGION}" \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
        --output text
}

# ===================================================================
# Internal: wait for N instances to appear as K8s nodes (joined)
# ===================================================================
# Returns 0 if all instances resolve to K8s nodes within timeout, 1 otherwise.
_topo_wait_k8s_join() {
    local expected_count=$1
    shift
    local instance_ids=("$@")
    local timeout=${TOPO_K8S_JOIN_TIMEOUT_SEC:-300}

    local deadline=$(( $(date +%s) + timeout ))
    while [ $(date +%s) -lt ${deadline} ]; do
        local joined=0
        for inst_id in "${instance_ids[@]}"; do
            if kubectl get nodes -o json 2>/dev/null \
                | jq -e --arg id "${inst_id}" \
                    '.items[] | select(.spec.providerID | endswith($id))' \
                    >/dev/null 2>&1; then
                joined=$((joined + 1))
            fi
        done

        if [ "${joined}" -ge "${expected_count}" ]; then
            return 0
        fi

        echo "  waiting for K8s node join: ${joined}/${expected_count}" >&2
        sleep 10
    done
    return 1
}

# ===================================================================
# Internal: query DescribeInstanceTopology for a set of instances
# ===================================================================
# Echoes a JSON array: [{id, leaf, aggregator, spine, az}, ...]
_topo_query() {
    local instance_ids="$*"
    [ -z "${instance_ids}" ] && return 0

    local raw
    raw=$(aws ec2 describe-instance-topology \
        --region "${AWS_REGION}" \
        --instance-ids ${instance_ids} \
        --output json 2>/dev/null)

    [ -z "${raw}" ] && return 0

    echo "${raw}" | jq '[.Instances[] | {
        id:         .InstanceId,
        spine:      .NetworkNodes[0],
        aggregator: .NetworkNodes[1],
        leaf:       .NetworkNodes[2],
        az:         .AvailabilityZone,
        zone_id:    .ZoneId
    }]'
}

# ===================================================================
# Internal: resolve instance_id → K8s node name
# ===================================================================
_topo_k8s_node_for_instance() {
    local inst_id=$1
    kubectl get nodes -o json 2>/dev/null \
        | jq -r --arg id "${inst_id}" \
            '.items[] | select(.spec.providerID | endswith($id)) | .metadata.name' \
        | head -1
}

# ===================================================================
# Public: label_nodegroup_by_leaf
# ===================================================================
# Given an EKS nodegroup name, queries DescribeInstanceTopology for its
# InService instances and stamps each corresponding K8s node with:
#   efa-leaf-id=<nn-xxx>        (true L3 network-topology node ID)
#   efa-az=<us-west-2c>         (AZ for workload hard-rule enforcement)
#
# Args:
#   $1 ng_name
#   $2 (optional) mode — "label" (default) | "report-only"
#
# Exit:  0 on success, 1 on any hard error.
label_nodegroup_by_leaf() {
    local ng_name=$1
    local mode=${2:-label}

    echo "Topology labeling: NG=${ng_name} mode=${mode}"

    local instance_ids
    instance_ids=$(_topo_get_ng_instance_ids "${ng_name}") || {
        echo "  WARN: could not resolve ASG for NG ${ng_name}; skipping"
        return 0
    }

    if [ -z "${instance_ids}" ]; then
        echo "  no InService instances in NG ${ng_name}; skipping"
        return 0
    fi

    # shellcheck disable=SC2206
    local inst_arr=(${instance_ids})
    local inst_count=${#inst_arr[@]}
    echo "  found ${inst_count} InService instance(s): ${instance_ids}"

    # Ensure K8s nodes have joined (labeling needs node objects to exist)
    if ! _topo_wait_k8s_join "${inst_count}" "${inst_arr[@]}"; then
        echo "  WARN: not all instances joined K8s within timeout; labeling what's available" >&2
    fi

    # Query topology
    local topo_json
    topo_json=$(_topo_query ${instance_ids})
    if [ -z "${topo_json}" ] || [ "${topo_json}" = "null" ]; then
        echo "  ERROR: DescribeInstanceTopology returned empty; cannot label"
        return 1
    fi

    # Label nodes
    local labeled_count=0
    local missing_count=0
    while read -r inst_id leaf_id az; do
        [ -z "${inst_id}" ] && continue

        # Guard against instances with no topology data returned
        if [ "${leaf_id}" = "null" ] || [ -z "${leaf_id}" ]; then
            echo "  WARN: ${inst_id} has no L3 topology node in API response" >&2
            continue
        fi

        local k8s_node
        k8s_node=$(_topo_k8s_node_for_instance "${inst_id}")
        if [ -z "${k8s_node}" ]; then
            echo "  WARN: K8s node for ${inst_id} not found (not yet joined?)" >&2
            missing_count=$((missing_count + 1))
            continue
        fi

        if [ "${mode}" = "report-only" ]; then
            echo "  [report] ${k8s_node}  efa-leaf-id=${leaf_id}  efa-az=${az}"
        else
            kubectl label node "${k8s_node}" \
                "efa-leaf-id=${leaf_id}" \
                "efa-az=${az}" \
                --overwrite >/dev/null
            echo "  labeled ${k8s_node}  efa-leaf-id=${leaf_id}  efa-az=${az}"
            labeled_count=$((labeled_count + 1))
        fi
    done < <(echo "${topo_json}" \
        | jq -r '.[] | "\(.id) \(.leaf) \(.az)"')

    if [ "${mode}" = "label" ]; then
        echo "  labeled ${labeled_count} node(s) ; ${missing_count} instance(s) had no K8s node"
    fi

    return 0
}

# ===================================================================
# Public: print_leaf_inventory
# ===================================================================
# Prints a cluster-wide inventory of labeled nodes, grouped by leaf.
# Highlights leaves with >=2 nodes (eligible for multi-node workloads).
#
# Args:
#   $1 (optional) min_size — threshold for "multi-node eligible" (default 2)
#
# Writes:
#   - human-readable inventory to stdout
#   - machine-readable JSON to TOPO_INVENTORY_OUT (default stderr-less path)
print_leaf_inventory() {
    local min_size=${1:-2}

    local inv
    inv=$(kubectl get nodes -o json 2>/dev/null | jq -r '
        [.items[]
         | select(.metadata.labels["efa-leaf-id"])
         | {
             node: .metadata.name,
             leaf: .metadata.labels["efa-leaf-id"],
             az:   (.metadata.labels["efa-az"] // "unknown"),
             inst: (.spec.providerID | split("/") | .[-1])
           }]
        | group_by(.leaf)
        | map({
            leaf: .[0].leaf,
            az:   .[0].az,
            count: length,
            nodes: [.[] | {name: .node, inst: .inst}]
          })
        | sort_by(-.count)')

    local inv_count
    inv_count=$(echo "${inv}" | jq 'length')

    if [ "${inv_count}" -eq 0 ]; then
        echo ""
        echo "=== Leaf inventory: no labeled nodes found ==="
        echo "(Did label_nodegroup_by_leaf run successfully?)"
        return 0
    fi

    echo ""
    echo "=== Leaf inventory (cluster-wide) ==="
    printf "%-40s  %-12s  %-6s  %s\n" "LEAF" "AZ" "COUNT" "NODES"
    echo "${inv}" | jq -r '.[] |
        "\(.leaf)\t\(.az)\t\(.count)\t\(.nodes | map(.name) | join(","))"' \
        | while IFS=$'\t' read -r leaf az count nodes; do
            printf "%-40s  %-12s  %-6s  %s\n" "${leaf}" "${az}" "${count}" "${nodes}"
        done

    echo ""
    echo "=== Multi-node-eligible leaves (>= ${min_size} nodes same leaf) ==="
    local eligible
    eligible=$(echo "${inv}" | jq --arg min "${min_size}" \
        '[.[] | select(.count >= ($min|tonumber))]')
    local eligible_count
    eligible_count=$(echo "${eligible}" | jq 'length')

    if [ "${eligible_count}" -eq 0 ]; then
        echo "  (none — all leaves have fewer than ${min_size} nodes)"
    else
        echo "${eligible}" | jq -r '.[] |
            "  ✅ efa-leaf-id=\(.leaf)  AZ=\(.az)  \(.count) nodes"'
        echo ""
        echo "Workload nodeAffinity snippet (copy-paste):"
        local first_leaf first_az
        first_leaf=$(echo "${eligible}" | jq -r '.[0].leaf')
        first_az=$(echo "${eligible}" | jq -r '.[0].az')
        cat <<YAML
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - { key: efa-leaf-id, operator: In, values: [${first_leaf}] }
          - { key: efa-az,      operator: In, values: [${first_az}] }
YAML
    fi

    # Optional machine-readable output
    if [ -n "${TOPO_INVENTORY_OUT:-}" ]; then
        echo "${inv}" > "${TOPO_INVENTORY_OUT}"
        echo ""
        echo "Wrote JSON inventory to ${TOPO_INVENTORY_OUT}"
    fi
}

# ===================================================================
# Public: clear_leaf_labels
# ===================================================================
# Removes efa-leaf-id and efa-az labels from all nodes in a nodegroup,
# or cluster-wide if no ng_name is given. Useful before re-labeling
# when instances have been replaced (Spot reclaim, NG reconfig).
clear_leaf_labels() {
    local ng_name=${1:-}

    local nodes
    if [ -n "${ng_name}" ]; then
        local instance_ids
        instance_ids=$(_topo_get_ng_instance_ids "${ng_name}") || return 0
        for inst_id in ${instance_ids}; do
            local k8s_node
            k8s_node=$(_topo_k8s_node_for_instance "${inst_id}")
            [ -n "${k8s_node}" ] && nodes+=" ${k8s_node}"
        done
    else
        nodes=$(kubectl get nodes -l efa-leaf-id \
            -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null)
    fi

    if [ -z "${nodes}" ]; then
        echo "No nodes with efa-leaf-id label; nothing to clear"
        return 0
    fi

    for n in ${nodes}; do
        kubectl label node "${n}" efa-leaf-id- efa-az- --overwrite >/dev/null 2>&1 || true
        echo "  cleared labels on ${n}"
    done
}
