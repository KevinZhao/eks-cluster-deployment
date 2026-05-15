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
# Echoes a JSON array, one entry per instance:
#   [{
#     id:      "i-xxx",
#     az:      "us-west-2c",
#     zone_id: "usw2-az1",
#     depth:   3 | 4 | 5,                       # length of NetworkNodes[]
#     levels:  ["nn-leaf","nn-l2","nn-l3", ...] # reversed: levels[0]=leaf
#     leaf:    "nn-leaf"                        # convenience alias = levels[0]
#   }, ...]
#
# Reversing NetworkNodes[] is the key trick: it makes "level N" mean
# "N levels up from the instance" regardless of fabric depth.
#   p5  (3-layer):   NetworkNodes=[spine, aggregator, leaf]
#                    levels=[leaf, aggregator, spine]
#   p6/p5en (4-layer): NetworkNodes=[spine, BG, aggregator, leaf]
#                    levels=[leaf, aggregator, BG, spine]
# Workloads target levels[0] for tightest affinity (same leaf), levels[1]
# for next-best, etc. — same YAML works on both fabrics.
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
        id:      .InstanceId,
        az:      .AvailabilityZone,
        zone_id: .ZoneId,
        depth:   (.NetworkNodes | length),
        levels:  (.NetworkNodes | reverse),
        leaf:    (.NetworkNodes | last)
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
#
#   network-topology/depth=<3|4|5>
#   network-topology/level-1=<id>      ← leaf, distance-1 from instance (always)
#   network-topology/level-2=<id>      ← distance-2 (aggregator on 3+ depth)
#   network-topology/level-3=<id>      ← distance-3 (BG on 4-depth, spine on 3-depth)
#   network-topology/level-4=<id>      ← distance-4 (spine on 4-depth)
#   network-topology/level-N=<id>      ← distance-N, only emitted if depth>=N
#
# Plus convenience aliases (back-compat with existing manifests/tooling):
#   efa-leaf-id=<level-1>
#   efa-az=<az>
#
# Distance-from-instance numbering (level-1 = closest = leaf) keeps the
# same workload YAML working on:
#   - p5  (3-layer fabric: NetworkNodes=[spine, aggregator, leaf])
#   - p6/p5en (4-layer fabric: NetworkNodes=[spine, BG, aggregator, leaf])
#   - any future N-layer fabric
# Without this, hardcoding NetworkNodes[2] as leaf produces wrong labels
# on 4-layer fabrics (yields aggregator instead of leaf).
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

    # Iterate per instance. Each line emitted by jq is:
    #   <inst_id> <az> <depth> <level1> <level2> ... <levelN>
    # — depth dictates how many level-* labels to stamp.
    local labeled_count=0
    local missing_count=0
    while IFS=$'\t' read -r inst_id az depth levels_csv; do
        [ -z "${inst_id}" ] && continue

        if [ -z "${depth}" ] || [ "${depth}" = "0" ] || [ "${depth}" = "null" ]; then
            echo "  WARN: ${inst_id} has no NetworkNodes in API response" >&2
            continue
        fi

        local k8s_node
        k8s_node=$(_topo_k8s_node_for_instance "${inst_id}")
        if [ -z "${k8s_node}" ]; then
            echo "  WARN: K8s node for ${inst_id} not found (not yet joined?)" >&2
            missing_count=$((missing_count + 1))
            continue
        fi

        # Build the label arg list. Levels are CSV-encoded so we can keep
        # the read loop on a single line per instance.
        local label_args=(
            "network-topology/depth=${depth}"
            "efa-az=${az}"
        )
        local i=1
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206
        local lvl_arr=(${levels_csv})
        IFS="${IFS_save}"
        local leaf_id=""
        for lvl in "${lvl_arr[@]}"; do
            [ -z "${lvl}" ] && { i=$((i + 1)); continue; }
            label_args+=("network-topology/level-${i}=${lvl}")
            [ "${i}" = "1" ] && leaf_id="${lvl}"
            i=$((i + 1))
        done
        # leaf-id alias (= level-1) for back-compat
        if [ -n "${leaf_id}" ]; then
            label_args+=("efa-leaf-id=${leaf_id}")
        fi

        if [ "${mode}" = "report-only" ]; then
            echo "  [report] ${k8s_node}  depth=${depth}  leaf=${leaf_id}  az=${az}  levels=[${levels_csv}]"
        else
            kubectl label node "${k8s_node}" "${label_args[@]}" --overwrite >/dev/null
            echo "  labeled ${k8s_node}  depth=${depth}  leaf=${leaf_id}  az=${az}"
            labeled_count=$((labeled_count + 1))
        fi
    done < <(echo "${topo_json}" \
        | jq -r '.[] | [.id, .az, .depth, (.levels | join(","))] | @tsv')

    if [ "${mode}" = "label" ]; then
        echo "  labeled ${labeled_count} node(s) ; ${missing_count} instance(s) had no K8s node"
    fi

    return 0
}

# ===================================================================
# Public: print_leaf_inventory
# ===================================================================
# Prints a cluster-wide inventory of labeled nodes, grouped by the
# requested topology level. Default groups by level-1 (leaf), which is
# the tightest affinity unit and the right answer for NCCL all-reduce
# / PD-disagg on both 3-layer (p5) and 4-layer (p5en/p6) fabrics.
#
# Args:
#   $1 (optional) min_size — threshold for "multi-node eligible" (default 2)
#   $2 (optional) level    — 1..N, the network-topology/level-N label
#                             to group by (default 1 = leaf)
#
# Writes:
#   - human-readable inventory to stdout
#   - machine-readable JSON to TOPO_INVENTORY_OUT (optional)
print_leaf_inventory() {
    local min_size=${1:-2}
    local group_level=${2:-1}
    local group_label="network-topology/level-${group_level}"

    # Pull the label key into jq via --arg; jq can't index labels by a
    # computed string otherwise.
    local inv
    inv=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg key "${group_label}" '
        [.items[]
         | select(.metadata.labels[$key])
         | {
             node:  .metadata.name,
             group: .metadata.labels[$key],
             az:    (.metadata.labels["efa-az"] // "unknown"),
             leaf:  (.metadata.labels["network-topology/level-1"]
                     // .metadata.labels["efa-leaf-id"]
                     // "unknown"),
             depth: (.metadata.labels["network-topology/depth"] // "?"),
             inst:  (.spec.providerID | split("/") | .[-1])
           }]
        | group_by(.group)
        | map({
            group: .[0].group,
            az:    .[0].az,
            depth: .[0].depth,
            count: length,
            nodes: [.[] | {name: .node, inst: .inst, leaf: .leaf}]
          })
        | sort_by(-.count)')

    local inv_count
    inv_count=$(echo "${inv}" | jq 'length')

    if [ "${inv_count}" -eq 0 ]; then
        echo ""
        echo "=== Topology inventory (level-${group_level}): no labeled nodes found ==="
        echo "(Did label_nodegroup_by_leaf run successfully? Check that nodes have the '${group_label}' label.)"
        return 0
    fi

    echo ""
    echo "=== Topology inventory (cluster-wide, grouped by ${group_label}) ==="
    printf "%-40s  %-12s  %-6s  %-6s  %s\n" "GROUP-ID" "AZ" "DEPTH" "COUNT" "NODES"
    echo "${inv}" | jq -r '.[] |
        "\(.group)\t\(.az)\t\(.depth)\t\(.count)\t\(.nodes | map(.name) | join(","))"' \
        | while IFS=$'\t' read -r grp az depth count nodes; do
            printf "%-40s  %-12s  %-6s  %-6s  %s\n" "${grp}" "${az}" "${depth}" "${count}" "${nodes}"
        done

    echo ""
    echo "=== Multi-node-eligible groups at level-${group_level} (>= ${min_size} nodes) ==="
    local eligible
    eligible=$(echo "${inv}" | jq --arg min "${min_size}" \
        '[.[] | select(.count >= ($min|tonumber))]')
    local eligible_count
    eligible_count=$(echo "${eligible}" | jq 'length')

    if [ "${eligible_count}" -eq 0 ]; then
        echo "  (none — all groups have fewer than ${min_size} nodes)"
    else
        echo "${eligible}" | jq -r --arg key "${group_label}" '.[] |
            "  ✅ \($key)=\(.group)  AZ=\(.az)  \(.count) nodes"'
        echo ""
        echo "Workload nodeAffinity snippet (copy-paste):"
        local first_group first_az
        first_group=$(echo "${eligible}" | jq -r '.[0].group')
        first_az=$(echo "${eligible}" | jq -r '.[0].az')
        cat <<YAML
  # Tightest affinity (level-${group_level}). For graceful fallback,
  # add additional nodeSelectorTerms with level-2, level-3 etc.
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - { key: ${group_label}, operator: In, values: [${first_group}] }
          - { key: efa-az,         operator: In, values: [${first_az}] }
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
# Removes all topology labels (network-topology/level-N for N=1..8,
# network-topology/depth, efa-leaf-id, efa-az) from nodes in the
# given nodegroup, or cluster-wide if no ng_name is given. Useful
# before re-labeling when instances have been replaced (Spot reclaim,
# NG reconfig).
#
# We strip levels 1..8 unconditionally; AWS fabrics in production are
# 3 or 4 levels today, 8 is a comfortable upper bound for future depth
# growth without needing to first inspect each node's depth.
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
        # Match either modern (network-topology/level-1) or legacy
        # (efa-leaf-id) labeled nodes.
        nodes=$(kubectl get nodes -l 'network-topology/level-1' \
            -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null)
        local legacy_nodes
        legacy_nodes=$(kubectl get nodes -l efa-leaf-id \
            -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null)
        # Concatenate + dedupe
        nodes=$(printf '%s\n%s\n' "${nodes}" "${legacy_nodes}" | awk 'NF && !seen[$0]++')
    fi

    if [ -z "${nodes}" ]; then
        echo "No nodes with topology labels; nothing to clear"
        return 0
    fi

    # Build the label-removal arg list once.
    local strip_args=(
        "network-topology/depth-"
        "efa-leaf-id-"
        "efa-az-"
    )
    local i
    for i in 1 2 3 4 5 6 7 8; do
        strip_args+=("network-topology/level-${i}-")
    done

    for n in ${nodes}; do
        kubectl label node "${n}" "${strip_args[@]}" --overwrite >/dev/null 2>&1 || true
        echo "  cleared labels on ${n}"
    done
}
