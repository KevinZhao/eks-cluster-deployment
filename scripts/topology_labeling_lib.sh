#!/bin/bash
# topology_labeling_lib.sh — EFA network-topology labeling library
#
# Label K8s nodes with depth-aware network-topology IDs so multi-node
# workloads (NCCL all-reduce, PD-disagg, UCCL-EP, DeepEP alltoall) can
# pin themselves to a single leaf via nodeAffinity.
#
# Source of truth (since EKS 1.31+): the cloud-controller-manager
# automatically writes these labels on every joined node:
#   topology.k8s.aws/network-node-layer-1 = <spine,        AWS index 0>
#   topology.k8s.aws/network-node-layer-2 = <aggregator>
#   topology.k8s.aws/network-node-layer-3 = <leaf on 3-layer / agg on 4-layer>
#   topology.k8s.aws/network-node-layer-4 = <leaf on 4-layer fabric only>
#   topology.k8s.aws/zone-id              = <usw2-az1, etc.>
#
# AWS uses "layer-1 = top of fabric" (forward index). Workloads that want
# distance-from-instance semantics (level-1 = closest = leaf) need a
# reverse-numbered overlay so the same nodeAffinity YAML works on both
# 3-layer (p5/Euclid) and 4-layer (p5en/p6 on 10p10u) fabrics.
#
# Labels written by this lib (overlay on top of AWS-native):
#   network-topology/depth=<3|4|5>             length of layer-N chain
#   network-topology/level-1=<leaf-id>         distance-1, always present
#   network-topology/level-2=<id>              distance-2, etc.
#   network-topology/level-N=<id>              distance-N, only if depth>=N
#   efa-leaf-id=<level-1>                      back-compat alias
#   efa-az=<us-west-2c>                        back-compat alias
#
# Mapping: our level-N == AWS layer-(depth - N + 1)
#   depth=3 (p5):    level-1 ← layer-3, level-2 ← layer-2, level-3 ← layer-1
#   depth=4 (p6):    level-1 ← layer-4, level-2 ← layer-3, level-3 ← layer-2, level-4 ← layer-1
#
# Why this is better than calling DescribeInstanceTopology ourselves:
#   - kubectl-only: no eks:DescribeNodegroup, ec2:DescribeInstanceTopology,
#     autoscaling:DescribeAutoScalingGroups required (some SCP-locked
#     environments forbid these)
#   - one round-trip: pull all node labels in one `kubectl get nodes` call
#   - already populated when node Ready: cloud-controller-manager writes
#     these on Initialize, so they're up well before our labeling runs
#   - tracks future fabric depth growth automatically (layer-5+ supported)
#
# Sourced by: option_install_gpu_nodegroups.sh, option_label_nodegroup_topology.sh
#
# Required env:   CLUSTER_NAME, AWS_REGION, KUBECONFIG
# Required tools: kubectl, jq  (aws CLI used only by verify_topology fallback)

set -e
set -o pipefail

# Maximum depth this library supports for label expansion / clearing. AWS
# fabrics are 3 or 4 today; 8 is a comfortable upper bound that survives a
# fabric-replacement event without code changes.
TOPO_MAX_DEPTH="${TOPO_MAX_DEPTH:-8}"

# ===================================================================
# Internal: list K8s nodes belonging to an EKS nodegroup
# ===================================================================
# Echoes node names, one per line. Uses the EKS-managed label
# `eks.amazonaws.com/nodegroup`, which managed node groups stamp on every
# joined node. Returns empty if no nodes match.
_topo_get_ng_node_names() {
    local ng_name=$1
    kubectl get nodes \
        -l "eks.amazonaws.com/nodegroup=${ng_name}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

# ===================================================================
# Internal: wait until N nodes in an NG have AWS topology labels
# ===================================================================
# AWS cloud-controller-manager writes topology.k8s.aws/network-node-layer-1
# on every node when it Initializes. We wait for that label, not just for
# the node to exist — labeling without it would yield a no-op.
#
# Returns 0 once at least one node in the NG carries layer-1, 1 on timeout.
_topo_wait_aws_topology_labels() {
    local ng_name=$1
    local timeout=${TOPO_K8S_JOIN_TIMEOUT_SEC:-300}

    local deadline=$(( $(date +%s) + timeout ))
    while [ $(date +%s) -lt ${deadline} ]; do
        # Count nodes in this NG that already have AWS-native layer-1 label
        local labeled
        labeled=$(kubectl get nodes \
            -l "eks.amazonaws.com/nodegroup=${ng_name},topology.k8s.aws/network-node-layer-1" \
            -o name 2>/dev/null | wc -l)
        if [ "${labeled}" -gt 0 ]; then
            return 0
        fi

        # Also tolerate nodes still joining: just count any nodes in NG
        local total
        total=$(kubectl get nodes \
            -l "eks.amazonaws.com/nodegroup=${ng_name}" \
            -o name 2>/dev/null | wc -l)
        echo "  waiting for AWS topology labels: ${labeled}/${total} nodes have topology.k8s.aws/network-node-layer-1" >&2
        sleep 10
    done
    return 1
}

# ===================================================================
# Internal: read AWS-native topology labels from a node, emit our schema
# ===================================================================
# Echoes a JSON array, one entry per node, with both the AWS-native
# layers[] (forward: layers[0]=spine) and the reverse-numbered levels[]
# (levels[0]=leaf, our schema). Includes depth and az for convenience.
#
# Args:
#   $1 ng_name (used as kubectl label selector)
#
# Output:
#   [{
#     node:    "ip-10-0-12-145.us-west-2.compute.internal",
#     az:      "us-west-2b",
#     zone_id: "usw2-az2",
#     depth:   4,
#     layers:  ["nn-spine", "nn-bg", "nn-agg", "nn-leaf"],   # AWS forward
#     levels:  ["nn-leaf", "nn-agg", "nn-bg", "nn-spine"],   # ours (reverse)
#     leaf:    "nn-leaf"
#   }, ...]
#
# The jq pipeline:
#   1. select nodes that have at least topology.k8s.aws/network-node-layer-1
#   2. for each such node, collect labels matching ^topology.k8s.aws/network-node-layer-([0-9]+)$
#      into a sparse array indexed by N (1-based)
#   3. compact + sort by N → forward layers[]
#   4. reverse → levels[]
_topo_query_from_k8s_labels() {
    local ng_name=$1

    kubectl get nodes \
        -l "eks.amazonaws.com/nodegroup=${ng_name},topology.k8s.aws/network-node-layer-1" \
        -o json 2>/dev/null \
        | jq '
          [.items[]
           | . as $node
           | ($node.metadata.labels
              | to_entries
              | map(select(.key | test("^topology\\.k8s\\.aws/network-node-layer-[0-9]+$")))
              | map({
                  n: (.key | capture("network-node-layer-(?<n>[0-9]+)$") | .n | tonumber),
                  v: .value
                })
              | sort_by(.n)
              | map(.v)) as $layers
           | {
               node:    $node.metadata.name,
               az:      ($node.metadata.labels["topology.kubernetes.io/zone"]
                         // $node.metadata.labels["failure-domain.beta.kubernetes.io/zone"]
                         // "unknown"),
               zone_id: ($node.metadata.labels["topology.k8s.aws/zone-id"] // "unknown"),
               depth:   ($layers | length),
               layers:  $layers,
               levels:  ($layers | reverse),
               leaf:    ($layers | last)
             }
           | select(.depth > 0)]'
}

# ===================================================================
# Internal: backwards-compatible alias used by clear_leaf_labels
# ===================================================================
# Old code path used to resolve ASG → instance IDs → K8s node name.
# clear_leaf_labels now scopes via NG label directly, so this helper
# is unused by the modern code. Kept as a thin wrapper for any out-of-
# tree callers that were sourcing this lib.
_topo_get_ng_instance_ids() {
    local ng_name=$1
    kubectl get nodes \
        -l "eks.amazonaws.com/nodegroup=${ng_name}" \
        -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' 2>/dev/null \
        | awk -F/ 'NF{print $NF}'
}

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

    # Wait for AWS-native topology labels (cloud-controller-manager writes
    # them on node Initialize). Without these, we have nothing to overlay.
    if ! _topo_wait_aws_topology_labels "${ng_name}"; then
        echo "  WARN: timed out waiting for AWS topology labels on NG ${ng_name}; labeling what's available" >&2
    fi

    # Query node topology directly from K8s labels
    local topo_json
    topo_json=$(_topo_query_from_k8s_labels "${ng_name}")
    if [ -z "${topo_json}" ] || [ "${topo_json}" = "null" ]; then
        echo "  ERROR: no nodes in NG ${ng_name} have AWS topology labels; cannot label"
        return 1
    fi

    local node_count
    node_count=$(echo "${topo_json}" | jq 'length')
    if [ "${node_count}" -eq 0 ]; then
        echo "  no nodes with topology labels in NG ${ng_name}; skipping"
        return 0
    fi
    echo "  found ${node_count} node(s) with AWS topology labels"

    # Iterate per node. Each line emitted by jq is:
    #   <node> <az> <depth> <level1>,<level2>,...,<levelN>
    local labeled_count=0
    while IFS=$'\t' read -r k8s_node az depth levels_csv; do
        [ -z "${k8s_node}" ] && continue

        if [ -z "${depth}" ] || [ "${depth}" = "0" ] || [ "${depth}" = "null" ]; then
            echo "  WARN: ${k8s_node} has no AWS topology layers (skipping)" >&2
            continue
        fi

        # Build the label arg list. levels_csv is reverse-numbered already
        # (levels[0] = leaf), so emit level-(i+1) for each item.
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
        | jq -r '.[] | [.node, .az, .depth, (.levels | join(","))] | @tsv')

    if [ "${mode}" = "label" ]; then
        echo "  labeled ${labeled_count} node(s)"
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
