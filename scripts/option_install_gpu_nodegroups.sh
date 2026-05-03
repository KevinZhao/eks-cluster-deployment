#!/bin/bash

set -e
set -o pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Create GPU Managed Node Groups with EFA Support ==="
echo ""
echo "This script creates GPU node groups using AWS Managed Node Groups"
echo "with pre-configured EFA + EFA-only interfaces in Launch Templates."
echo ""
echo "Supported GPU types:"
echo "  • p5.48xlarge:      1 EFA + 31 EFA-only (NetworkCardIndex 0-31)"
echo "  • p5en.48xlarge:    1 EFA + 15 EFA-only (NetworkCardIndex 0-15)"
echo "  • p6-b200.48xlarge: 1 EFA + 7 EFA-only  (NetworkCardIndex 0-7)"
echo "  • p6-b300.48xlarge: 16 EFA-only on NIC 1-16 (NIC 0 = ENA only; MaxEFA=16)"
echo "  • g7e.48xlarge:     1 EFA + 3 EFA-only  (NetworkCardIndex 0-3)"
echo ""
echo "Pricing options (mutually exclusive - choose ONE):"
echo "  • On-Demand:      Standard on-demand pricing (DEPLOY_GPU_OD=true)"
echo "  • Spot:           Cost-effective for fault-tolerant workloads (DEPLOY_GPU_SPOT=true)"
echo "  • ODCR:           Guaranteed capacity, on-demand pricing (DEPLOY_GPU_ODCR=true)"
echo "  • Capacity Block: Time-limited reserved capacity (DEPLOY_GPU_CB=true)"
echo ""

# 1. Load environment
source "${SCRIPT_DIR}/0_setup_env.sh"

export KUBECONFIG="${HOME:-/root}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# Check dependencies
echo ""
echo "Checking required dependencies..."
MISSING_DEPS=()
command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")
command -v aws >/dev/null 2>&1 || MISSING_DEPS+=("aws cli")
command -v python3 >/dev/null 2>&1 || MISSING_DEPS+=("python3")

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    exit 1
fi
echo "All required dependencies are installed"

# 2. Verify cluster exists
echo ""
echo "Verifying EKS cluster exists..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    exit 1
fi

verify_kubectl_context
echo ""

# ===================================================================
# Configuration
# ===================================================================

GPU_INSTANCE_TYPES="${GPU_INSTANCE_TYPES:-p5.48xlarge,p5en.48xlarge,p6-b200.48xlarge,p6-b300.48xlarge,g7e.48xlarge}"
GPU_NODE_DESIRED_CAPACITY="${GPU_NODE_DESIRED_CAPACITY:-0}"
GPU_NODE_MIN_SIZE="${GPU_NODE_MIN_SIZE:-0}"
GPU_NODE_MAX_SIZE="${GPU_NODE_MAX_SIZE:-8}"
GPU_NODE_ROOT_VOLUME_SIZE="${GPU_NODE_ROOT_VOLUME_SIZE:-50}"
GPU_NODE_DATA_VOLUME_SIZE="${GPU_NODE_DATA_VOLUME_SIZE:-100}"

DEPLOY_GPU_OD="${DEPLOY_GPU_OD:-false}"
DEPLOY_GPU_SPOT="${DEPLOY_GPU_SPOT:-true}"
DEPLOY_GPU_ODCR="${DEPLOY_GPU_ODCR:-false}"
DEPLOY_GPU_CB="${DEPLOY_GPU_CB:-false}"

INSTALL_EFA_DEVICE_PLUGIN="${INSTALL_EFA_DEVICE_PLUGIN:-true}"
EFA_DEVICE_PLUGIN_VERSION="${EFA_DEVICE_PLUGIN_VERSION:-v0.5.17}"

# ------------------------------------------------------------
# Placement Group (cluster strategy) — for EFA same-leaf locality
# ------------------------------------------------------------
# GPU_PG_STRATEGY:
#   cluster             force all nodes in a per-AZ cluster PG (default; fail
#                       if EC2 can't fit nodes in PG)
#   cluster_best_effort try cluster PG, fallback to no PG if capacity short
#   none                no PG (old behavior)
GPU_PG_STRATEGY="${GPU_PG_STRATEGY:-cluster}"
GPU_PG_NAME_PREFIX="${GPU_PG_NAME_PREFIX:-${CLUSTER_NAME}}"

# ------------------------------------------------------------
# Topology gate — verify nodes land under same network topology node
# ------------------------------------------------------------
# GPU_TOPOLOGY_GATE:
#   strict  fail and scale NG to 0 on mismatch (default)
#   warn    log a warning but continue
#   off     skip the check entirely
# GPU_TOPOLOGY_GATE_LEVEL: L1 (spine) | L2 (aggregator) | L3 (leaf / ToR)
GPU_TOPOLOGY_GATE="${GPU_TOPOLOGY_GATE:-strict}"
GPU_TOPOLOGY_GATE_LEVEL="${GPU_TOPOLOGY_GATE_LEVEL:-L3}"

# NVIDIA Kubernetes device plugin. Override NVIDIA_DEVICE_PLUGIN_IMAGE when
# deploying to regions where nvcr.io is unreachable (e.g. cn-*) and mirror
# the image into a reachable registry (ECR/Harbor/etc).
NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.15.0}"
NVIDIA_DEVICE_PLUGIN_IMAGE="${NVIDIA_DEVICE_PLUGIN_IMAGE:-nvcr.io/nvidia/k8s-device-plugin:${NVIDIA_DEVICE_PLUGIN_VERSION}}"

# Local NVMe Instance Store LVM configuration.
# When enabled, all Instance Store NVMe disks are striped into one VG/LV
# and mounted at ${GPU_LOCAL_LVM_MOUNT} (default /data) for scratch use
# (training checkpoints, shuffle, dataset cache, etc.).
# Instance Store is ephemeral: state is lost on instance stop/start, so the
# volume is re-initialized via a systemd oneshot on every boot rather than
# via /etc/fstab.
GPU_ENABLE_LOCAL_LVM="${GPU_ENABLE_LOCAL_LVM:-true}"
GPU_LOCAL_LVM_VG_NAME="${GPU_LOCAL_LVM_VG_NAME:-vg_local}"
GPU_LOCAL_LVM_LV_NAME="${GPU_LOCAL_LVM_LV_NAME:-lv_scratch}"
GPU_LOCAL_LVM_MOUNT="${GPU_LOCAL_LVM_MOUNT:-/data}"
GPU_LOCAL_LVM_FS="${GPU_LOCAL_LVM_FS:-xfs}"
GPU_LOCAL_LVM_STRIPE_SIZE_KB="${GPU_LOCAL_LVM_STRIPE_SIZE_KB:-256}"

# Validate: only one pricing option should be enabled (mutually exclusive)
ENABLED_COUNT=0
[ "${DEPLOY_GPU_OD}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[ "${DEPLOY_GPU_SPOT}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[ "${DEPLOY_GPU_ODCR}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[ "${DEPLOY_GPU_CB}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))

if [ "${ENABLED_COUNT}" -gt 1 ]; then
    echo "ERROR: Only ONE pricing option can be enabled at a time"
    echo "  DEPLOY_GPU_OD=${DEPLOY_GPU_OD}"
    echo "  DEPLOY_GPU_SPOT=${DEPLOY_GPU_SPOT}"
    echo "  DEPLOY_GPU_ODCR=${DEPLOY_GPU_ODCR}"
    echo "  DEPLOY_GPU_CB=${DEPLOY_GPU_CB}"
    echo ""
    echo "These are mutually exclusive deployment modes. Please enable only one."
    exit 1
fi

if [ "${ENABLED_COUNT}" -eq 0 ]; then
    echo "ERROR: At least one pricing option must be enabled"
    echo "Set one of: DEPLOY_GPU_OD=true, DEPLOY_GPU_SPOT=true, DEPLOY_GPU_ODCR=true, or DEPLOY_GPU_CB=true"
    exit 1
fi

# Get EFA-only network card count (excluding primary EFA card)
get_efa_only_card_count() {
    local instance_type=$1
    case "$instance_type" in
        p5.48xlarge)      echo 31 ;;   # NetworkCardIndex 1-31
        p5en.48xlarge)    echo 15 ;;   # NetworkCardIndex 1-15
        p6-b200.48xlarge) echo 7 ;;    # NetworkCardIndex 1-7
        p6-b300.48xlarge) echo 16 ;;   # NetworkCardIndex 1-16
        g7e.48xlarge)     echo 3 ;;    # NetworkCardIndex 1-3
        *)                echo 0 ;;
    esac
}

# Convert instance type to resource-safe name (replace dots with dashes)
get_resource_name() {
    echo "${1//./-}"
}

# ===================================================================
# Placement Group helpers
# ===================================================================
# Idempotently ensure a cluster-strategy placement group exists for
# (gpu_type, AZ, suffix). Echoes the PG name on stdout on success,
# or empty string if GPU_PG_STRATEGY=none.
#
# Args:
#   $1 gpu_type    e.g. p5en.48xlarge
#   $2 az          full zone name, e.g. us-west-2c
#   $3 suffix      optional, e.g. "-1"
ensure_cluster_pg() {
    local gpu_type=$1
    local az=$2
    local suffix=${3:-}

    if [ "${GPU_PG_STRATEGY}" = "none" ]; then
        echo ""
        return 0
    fi

    local resource_name=$(get_resource_name "$gpu_type")
    local pg_name="${GPU_PG_NAME_PREFIX}-${resource_name}-${az}${suffix}-cg"

    if aws ec2 describe-placement-groups \
        --region "${AWS_REGION}" \
        --group-names "${pg_name}" &>/dev/null; then
        echo "Placement group ${pg_name} already exists" >&2
    else
        echo "Creating cluster placement group: ${pg_name}" >&2
        aws ec2 create-placement-group \
            --region "${AWS_REGION}" \
            --group-name "${pg_name}" \
            --strategy cluster \
            --tag-specifications "ResourceType=placement-group,Tags=[{Key=Cluster,Value=${CLUSTER_NAME}},{Key=AZ,Value=${az}},{Key=gpu-instance-type,Value=${gpu_type}},{Key=managed-by,Value=eks-cluster-deployment},{Key=business,Value=middleware},{Key=resource,Value=eks}]" \
            >/dev/null
    fi

    echo "${pg_name}"
}

# Delete placement group if empty (idempotent; AWS will refuse if still used).
# Safe to call in teardown paths.
delete_cluster_pg_if_empty() {
    local pg_name=$1
    if [ -z "${pg_name}" ]; then
        return 0
    fi
    aws ec2 delete-placement-group \
        --region "${AWS_REGION}" \
        --group-name "${pg_name}" 2>/dev/null || \
        echo "  (placement group ${pg_name} still has instances or does not exist; skipped)" >&2
}

# Plan the PG for a nodegroup based on strategy and subnet list.
# Echoes PG name on stdout (empty = no PG).
# Cluster-strategy PGs are AZ-specific, so we only attach one when the
# target subnet list resolves to a single AZ. Multi-AZ calls get no PG
# and a warning — user should narrow subnets to get PG.
#
# Args:
#   $1 gpu_type
#   $2 purchase_option  (od|spot|odcr|cb)
#   $3 suffix
#   $4+ one or more subnet IDs
plan_pg_for_nodegroup() {
    local gpu_type=$1
    local purchase_option=$2
    local suffix=$3
    shift 3
    local subnets=("$@")

    if [ "${GPU_PG_STRATEGY}" = "none" ]; then
        echo ""
        return 0
    fi

    if [ ${#subnets[@]} -eq 0 ]; then
        echo ""
        return 0
    fi

    # Resolve AZ for each subnet; cluster PG only valid if all subnets in same AZ
    local azs=()
    for sn in "${subnets[@]}"; do
        local az
        az=$(aws ec2 describe-subnets \
            --region "${AWS_REGION}" \
            --subnet-ids "${sn}" \
            --query 'Subnets[0].AvailabilityZone' \
            --output text 2>/dev/null)
        if [ -n "${az}" ] && [ "${az}" != "None" ]; then
            azs+=("${az}")
        fi
    done

    local unique_azs
    unique_azs=$(printf '%s\n' "${azs[@]}" | sort -u)
    local unique_count
    unique_count=$(echo "${unique_azs}" | wc -l)

    if [ "${unique_count}" -ne 1 ]; then
        echo "  plan_pg: ${unique_count} distinct AZs in subnet list (${unique_azs//$'\n'/,}) — cluster PG requires single AZ; skipping PG" >&2
        echo ""
        return 0
    fi

    local az="${unique_azs}"
    # Full PG suffix includes purchase_option for uniqueness (od/spot/odcr/cb)
    local full_suffix="-${purchase_option}${suffix}"
    ensure_cluster_pg "${gpu_type}" "${az}" "${full_suffix}"
}

# ===================================================================
# Topology gate
# ===================================================================
# Verify all instances in a nodegroup share the same network-topology
# ancestor at the requested level. Uses ec2:DescribeInstanceTopology
# which returns up to 3 NetworkNodes per instance: [spine, aggregator, leaf].
#
# Args:
#   $1 ng_name   EKS nodegroup name
#   $2 gate      strict | warn | off
#   $3 level     L1 | L2 | L3
verify_topology() {
    local ng_name=$1
    local gate=${2:-strict}
    local level=${3:-L3}

    if [ "${gate}" = "off" ]; then
        return 0
    fi

    # Map L1/L2/L3 to array index in NetworkNodes[].
    # describe-instance-topology returns NetworkNodes[] in spine → leaf order.
    local level_idx
    case "${level}" in
        L1) level_idx=0 ;;
        L2) level_idx=1 ;;
        L3) level_idx=2 ;;
        *)  echo "ERROR: invalid GPU_TOPOLOGY_GATE_LEVEL='${level}' (expected L1|L2|L3)"; return 1 ;;
    esac

    echo "Topology gate: verifying NG=${ng_name} at level=${level} (gate=${gate})"

    # Get ASG name → instance IDs
    local asg_name
    asg_name=$(aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --region "${AWS_REGION}" \
        --query 'nodegroup.resources.autoScalingGroups[0].name' \
        --output text 2>/dev/null)

    if [ -z "${asg_name}" ] || [ "${asg_name}" = "None" ]; then
        echo "  WARN: could not resolve ASG for NG ${ng_name}; skipping gate"
        return 0
    fi

    local instance_ids
    instance_ids=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${asg_name}" \
        --region "${AWS_REGION}" \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
        --output text)

    if [ -z "${instance_ids}" ]; then
        echo "  WARN: no InService instances in ASG ${asg_name}; skipping gate"
        return 0
    fi

    local num_instances
    num_instances=$(echo "${instance_ids}" | wc -w)

    if [ "${num_instances}" -lt 2 ]; then
        echo "  only ${num_instances} instance(s); topology gate trivially passes"
        return 0
    fi

    # Query topology
    local topology_json
    topology_json=$(aws ec2 describe-instance-topology \
        --region "${AWS_REGION}" \
        --instance-ids ${instance_ids} \
        --output json 2>/dev/null)

    if [ -z "${topology_json}" ]; then
        echo "  WARN: describe-instance-topology returned empty; skipping gate"
        return 0
    fi

    # Count unique nodes at requested level
    local unique_nodes
    unique_nodes=$(echo "${topology_json}" \
        | jq -r ".Instances[].NetworkNodes[${level_idx}] // \"__missing__\"" \
        | sort -u)
    local unique_count
    unique_count=$(echo "${unique_nodes}" | wc -l)

    # Print the full topology map for operator visibility
    echo "  Topology map (level=${level}):"
    echo "${topology_json}" \
        | jq -r ".Instances[] | \"    \(.InstanceId)  AZ=\(.AvailabilityZone)  L1=\(.NetworkNodes[0])  L2=\(.NetworkNodes[1])  L3=\(.NetworkNodes[2])\""

    if [ "${unique_count}" -gt 1 ]; then
        echo ""
        echo "  ❌ Topology gate FAILED: ${num_instances} instances spread across ${unique_count} ${level} nodes"
        echo "     Unique ${level} nodes:"
        echo "${unique_nodes}" | sed 's/^/       /'
        echo ""

        case "${gate}" in
            strict)
                echo "  strict mode → scaling NG ${ng_name} to 0 to release bad placement"
                aws eks update-nodegroup-config \
                    --cluster-name "${CLUSTER_NAME}" \
                    --nodegroup-name "${ng_name}" \
                    --region "${AWS_REGION}" \
                    --scaling-config minSize=0,maxSize=0,desiredSize=0 \
                    >/dev/null 2>&1 || true
                return 1
                ;;
            warn)
                echo "  warn mode → continuing despite topology mismatch"
                return 0
                ;;
        esac
    fi

    echo "  ✅ Topology gate PASSED: all ${num_instances} instance(s) share the same ${level} node"
    return 0
}

# ===================================================================
# IAM Role Creation
# ===================================================================

create_gpu_node_iam_role() {
    GPU_NODE_ROLE_NAME="GPUNodeRole-${CLUSTER_NAME}"
    GPU_INSTANCE_PROFILE_NAME="${GPU_NODE_ROLE_NAME}"

    if aws iam get-role --role-name "${GPU_NODE_ROLE_NAME}" &>/dev/null; then
        echo "IAM Role ${GPU_NODE_ROLE_NAME} already exists"
    else
        echo "Creating IAM Role: ${GPU_NODE_ROLE_NAME}"

        aws iam create-role \
            --role-name "${GPU_NODE_ROLE_NAME}" \
            --assume-role-policy-document '{
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "ec2.amazonaws.com"},
                    "Action": "sts:AssumeRole"
                }]
            }' \
            --tags Key=Cluster,Value="${CLUSTER_NAME}" Key=Purpose,Value=gpu-nodes Key=business,Value=middleware Key=resource,Value=eks >/dev/null

        echo "IAM Role created"
    fi

    echo "Attaching required policies..."
    aws iam attach-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" 2>/dev/null || true
    aws iam attach-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" 2>/dev/null || true
    aws iam attach-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" 2>/dev/null || true
    aws iam attach-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true

    # Add ec2:DescribeInstances for nodeadm
    aws iam put-role-policy --role-name "${GPU_NODE_ROLE_NAME}" \
        --policy-name "NodeadmDescribeInstances" \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"],
                "Resource": "*"
            }]
        }'

    echo "IAM policies attached"

    # Add GPU Node Role to EKS access entries (required for nodes to join cluster)
    echo "Adding ${GPU_NODE_ROLE_NAME} to EKS access entries..."
    if aws eks describe-access-entry --cluster-name "${CLUSTER_NAME}" --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GPU_NODE_ROLE_NAME}" --region "${AWS_REGION}" &>/dev/null; then
        echo "EKS access entry for ${GPU_NODE_ROLE_NAME} already exists"
    else
        # Wait for IAM role to propagate globally before creating access entry
        echo "Waiting for IAM role to propagate (10 seconds)..."
        sleep 10

        local retry_count=0
        local max_retries=5
        while [ $retry_count -lt $max_retries ]; do
            if aws eks create-access-entry \
                --cluster-name "${CLUSTER_NAME}" \
                --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GPU_NODE_ROLE_NAME}" \
                --type EC2_LINUX \
                --region "${AWS_REGION}" 2>/dev/null; then
                echo "EKS access entry created for ${GPU_NODE_ROLE_NAME}"
                break
            fi
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo "IAM role not yet propagated, retrying in 10 seconds... ($retry_count/$max_retries)"
                sleep 10
            else
                echo "ERROR: Failed to create EKS access entry after $max_retries retries"
                exit 1
            fi
        done
    fi

    GPU_NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${GPU_NODE_ROLE_NAME}"
    echo "GPU Node Role ARN: ${GPU_NODE_ROLE_ARN}"
}

# ===================================================================
# Security Group
# ===================================================================

create_gpu_security_group() {
    GPU_SG_NAME="${CLUSTER_NAME}-gpu-node-sg"

    GPU_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${GPU_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
        --region "${AWS_REGION}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)

    if [ -n "${GPU_SG_ID}" ] && [ "${GPU_SG_ID}" != "None" ]; then
        echo "GPU Security Group already exists: ${GPU_SG_ID}"
    else
        echo "Creating GPU Security Group: ${GPU_SG_NAME}"

        GPU_SG_ID=$(aws ec2 create-security-group \
            --group-name "${GPU_SG_NAME}" \
            --description "Security group for GPU nodes with EFA" \
            --vpc-id "${VPC_ID}" \
            --region "${AWS_REGION}" \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${GPU_SG_NAME}},{Key=Cluster,Value=${CLUSTER_NAME}},{Key=business,Value=middleware},{Key=resource,Value=eks}]" \
            --query 'GroupId' \
            --output text)

        echo "Created GPU Security Group: ${GPU_SG_ID}"
    fi

    # Self-referencing rule for EFA/NCCL traffic (all protocols)
    echo "Ensuring security group rules..."
    local sg_result
    if sg_result=$(aws ec2 authorize-security-group-ingress \
        --group-id "${GPU_SG_ID}" \
        --protocol -1 \
        --source-group "${GPU_SG_ID}" \
        --region "${AWS_REGION}" 2>&1); then
        echo "  Self-ingress rule added"
    elif echo "${sg_result}" | grep -q "already exists"; then
        echo "  Self-ingress rule already exists"
    else
        echo "ERROR: Failed to add self-ingress rule to ${GPU_SG_ID}: ${sg_result}"
        exit 1
    fi

    echo "GPU Security Group configured: ${GPU_SG_ID}"
}

# ===================================================================
# Launch Template Creation (EFA + EFA-only)
# ===================================================================

create_gpu_launch_template() {
    local gpu_type=$1
    local purchase_option=$2
    local capacity_reservation_id=${3:-}
    local suffix=${4:-}     # Optional suffix for multiple reservations (e.g., "-1", "-2")
    local pg_name=${5:-}    # Optional cluster placement-group name (empty = no PG)

    local instance_type="$gpu_type"
    local resource_name=$(get_resource_name "$gpu_type")
    local efa_only_count=$(get_efa_only_card_count "$gpu_type")
    local lt_name="${CLUSTER_NAME}-gpu-${resource_name}-${purchase_option}${suffix}-lt"

    # Capacity Block requires InstanceType to be embedded in the Launch Template.
    # For other modes we leave it out so EKS managed node group accepts --instance-types.
    local embed_instance_type="false"
    if [ "${purchase_option}" = "cb" ]; then
        embed_instance_type="true"
    fi

    echo "Creating Launch Template: ${lt_name}"
    echo "  Instance Type: ${instance_type}"
    echo "  Embed InstanceType in LT: ${embed_instance_type}"
    echo "  EFA-only Cards: ${efa_only_count}"
    if [[ -n "${EC2_KEY_NAME:-}" ]]; then
        echo "  EC2 Key Pair: ${EC2_KEY_NAME}"
    fi

    # Create userdata for node bootstrap (with LVM configuration)
    local userdata_file=$(mktemp /tmp/gpu-userdata.XXXXXX.txt)
    cat > "${userdata_file}" <<EOF_USERDATA
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
# LVM Setup + EKS Bootstrap for GPU nodes
set -ex

exec > >(tee /var/log/gpu-node-bootstrap.log)
exec 2>&1

echo "=== Starting GPU Node LVM Setup ==="

# Stop containerd first
systemctl stop containerd || true

# Wait for EBS data disk to be available (max 60 seconds).
# On GPU instances we must distinguish EBS from Instance Store, because
# both appear as unpartitioned NVMe devices. Use the device model:
#   - EBS:            "Amazon Elastic Block Store"
#   - Instance Store: "Amazon EC2 NVMe Instance Storage"
echo "Waiting for EBS data disk..."
for i in {1..60}; do
  for sys_path in /sys/block/nvme*n1; do
    [ -e "\$sys_path" ] || continue
    MODEL=\$(cat "\$sys_path/device/model" 2>/dev/null | xargs)
    case "\$MODEL" in
      *"Elastic Block Store"*) ;;
      *) continue ;;
    esac
    dev="/dev/\$(basename "\$sys_path")"
    # Skip the root disk (the one with partitions, e.g. /dev/nvme0n1p1)
    PARTS=\$(lsblk -no NAME "\$dev" 2>/dev/null | wc -l)
    if [ "\$PARTS" -eq 1 ]; then
      DISK="\$dev"
      echo "Found EBS data disk: \$DISK (model: \$MODEL)"
      break 2
    fi
  done
  echo "Attempt \$i/60: EBS data disk not found yet, waiting..."
  sleep 1
done

if [ -z "\$DISK" ]; then
  echo "ERROR: No EBS data disk found after 60 seconds"
  echo "Available disks:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
  systemctl start containerd
  exit 1
fi

# Check if LVM already configured
if vgs vg_data &>/dev/null; then
  echo "LVM already configured, mounting..."
  mount /dev/vg_data/lv_containerd /var/lib/containerd || true
  systemctl start containerd
else
  # Install lvm2 and rsync
  echo "Installing lvm2 and rsync..."
  dnf install -y lvm2 rsync

  # Create LVM
  echo "Creating LVM on \$DISK..."
  pvcreate "\$DISK"
  vgcreate vg_data "\$DISK"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd

  # Mount and migrate data (including pre-cached images from AMI)
  echo "Mounting and migrating containerd data..."
  mkdir -p /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /mnt/runtime/containerd

  echo "Copying containerd data (including pre-cached pause image) from AMI..."
  rsync -aHAX /var/lib/containerd/ /mnt/runtime/containerd/ || true

  echo "Unmounting temporary directory"
  umount /mnt/runtime/containerd

  echo "Mounting LV to final destination: /var/lib/containerd"
  mount /dev/vg_data/lv_containerd /var/lib/containerd

  # Add to fstab
  grep -q "lv_containerd" /etc/fstab || \\
    echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

  echo "LVM setup completed successfully"
  df -h /var/lib/containerd
  vgs
  lvs

  # Start containerd
  systemctl start containerd
fi

echo "=== LVM Setup Complete ==="

# ============================================================
# Local Instance Store LVM Setup (scratch volume at ${GPU_LOCAL_LVM_MOUNT})
# ============================================================
# Instance Store is ephemeral (data lost on stop/start) so we do NOT
# write /etc/fstab. Instead we install a systemd oneshot that re-runs
# the init-or-remount logic on every boot.
LOCAL_SSD_TOTAL_GB=0
if [ "${GPU_ENABLE_LOCAL_LVM}" = "true" ]; then
  echo "=== Setting up Local Instance Store LVM ==="

  # Ensure lvm2 is present (usually already installed by EBS LVM step above)
  command -v lvcreate >/dev/null || dnf install -y lvm2

  install -m 0755 /dev/stdin /usr/local/sbin/setup-local-lvm.sh <<'SETUP_LOCAL_LVM'
#!/bin/bash
# Initialize or remount the local Instance Store LVM volume.
# Safe to run on every boot: if the VG/LV no longer exists (fresh stop/start),
# it rebuilds from scratch; otherwise it just remounts.
set -e

VG_NAME="__VG_NAME__"
LV_NAME="__LV_NAME__"
MOUNT_POINT="__MOUNT_POINT__"
FS_TYPE="__FS_TYPE__"
STRIPE_KB="__STRIPE_KB__"

log() { echo "[local-lvm] \$*"; }

# Collect Instance Store NVMe disks by model string (reliable across kernels)
LOCAL_DISKS=()
for sys_path in /sys/block/nvme*n1; do
  [ -e "\$sys_path" ] || continue
  model=\$(cat "\$sys_path/device/model" 2>/dev/null | xargs)
  case "\$model" in
    *"Instance Storage"*) LOCAL_DISKS+=("/dev/\$(basename "\$sys_path")") ;;
  esac
done

if [ \${#LOCAL_DISKS[@]} -eq 0 ]; then
  log "No Instance Store NVMe disks detected; skipping"
  exit 0
fi
log "Detected \${#LOCAL_DISKS[@]} local NVMe disk(s): \${LOCAL_DISKS[*]}"

mkdir -p "\$MOUNT_POINT"

# Fast path: already mounted
if mountpoint -q "\$MOUNT_POINT"; then
  log "\$MOUNT_POINT already mounted"
  exit 0
fi

# If VG still exists from a prior activation this boot, just mount
if vgs "\$VG_NAME" >/dev/null 2>&1; then
  log "VG \$VG_NAME already exists, activating and mounting"
  vgchange -ay "\$VG_NAME"
  mount -o noatime,nodiratime,discard "/dev/\$VG_NAME/\$LV_NAME" "\$MOUNT_POINT"
  exit 0
fi

# Fresh build
log "Building \$VG_NAME across \${#LOCAL_DISKS[@]} disk(s)"
for d in "\${LOCAL_DISKS[@]}"; do
  # Wipe any stale signatures (Instance Store carries over FS headers
  # from previous tenants on the same hardware slot in rare cases)
  wipefs -a "\$d" || true
  pvcreate -ff -y "\$d"
done

vgcreate "\$VG_NAME" "\${LOCAL_DISKS[@]}"

if [ \${#LOCAL_DISKS[@]} -gt 1 ]; then
  lvcreate -y -i "\${#LOCAL_DISKS[@]}" -I "\${STRIPE_KB}" -l 100%FREE -n "\$LV_NAME" "\$VG_NAME"
else
  lvcreate -y -l 100%FREE -n "\$LV_NAME" "\$VG_NAME"
fi

case "\$FS_TYPE" in
  xfs)  mkfs.xfs -f "/dev/\$VG_NAME/\$LV_NAME" ;;
  ext4) mkfs.ext4 -F "/dev/\$VG_NAME/\$LV_NAME" ;;
  *)    log "Unsupported FS: \$FS_TYPE"; exit 1 ;;
esac

mount -o noatime,nodiratime,discard "/dev/\$VG_NAME/\$LV_NAME" "\$MOUNT_POINT"
chmod 1777 "\$MOUNT_POINT"
log "Mounted /dev/\$VG_NAME/\$LV_NAME at \$MOUNT_POINT"
df -h "\$MOUNT_POINT"
SETUP_LOCAL_LVM

  # Substitute config into the script
  sed -i \\
    -e "s|__VG_NAME__|${GPU_LOCAL_LVM_VG_NAME}|g" \\
    -e "s|__LV_NAME__|${GPU_LOCAL_LVM_LV_NAME}|g" \\
    -e "s|__MOUNT_POINT__|${GPU_LOCAL_LVM_MOUNT}|g" \\
    -e "s|__FS_TYPE__|${GPU_LOCAL_LVM_FS}|g" \\
    -e "s|__STRIPE_KB__|${GPU_LOCAL_LVM_STRIPE_SIZE_KB}|g" \\
    /usr/local/sbin/setup-local-lvm.sh

  cat > /etc/systemd/system/setup-local-lvm.service <<'UNIT'
[Unit]
Description=Initialize and mount local NVMe Instance Store LVM
DefaultDependencies=no
After=local-fs-pre.target systemd-udev-settle.service
Before=local-fs.target kubelet.service containerd.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-local-lvm.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=local-fs.target
UNIT

  systemctl daemon-reload
  systemctl enable --now setup-local-lvm.service

  # Compute total local SSD size for node label
  if [ -b "/dev/${GPU_LOCAL_LVM_VG_NAME}/${GPU_LOCAL_LVM_LV_NAME}" ]; then
    LOCAL_SSD_TOTAL_BYTES=\$(blockdev --getsize64 "/dev/${GPU_LOCAL_LVM_VG_NAME}/${GPU_LOCAL_LVM_LV_NAME}" 2>/dev/null || echo 0)
    LOCAL_SSD_TOTAL_GB=\$(( LOCAL_SSD_TOTAL_BYTES / 1024 / 1024 / 1024 ))
  fi
  echo "Local SSD total: \${LOCAL_SSD_TOTAL_GB} GB"
  echo "=== Local Instance Store LVM Setup Complete ==="
else
  echo "Local Instance Store LVM disabled (GPU_ENABLE_LOCAL_LVM=${GPU_ENABLE_LOCAL_LVM})"
fi

# Install lustre-client for FSx Lustre support
echo "=== Installing Lustre Client ==="
dnf install -y lustre-client
modprobe lustre || true
echo "Lustre client installed"

echo "=== Starting EKS Node Bootstrap ==="

# Build kubelet node-labels for local SSD awareness.
# NOTE: kubelet under NodeRestriction can only register labels outside the
# reserved kubernetes.io / k8s.io / node.kubernetes.io prefixes (except for a
# small hardcoded whitelist). So we use the unprefixed "local-ssd" namespace.
# Only emitted when local LVM actually materialized a volume.
NODE_LABEL_FLAGS=""
if [ "\${LOCAL_SSD_TOTAL_GB}" -gt 0 ]; then
  NODE_LABEL_FLAGS="--node-labels=local-ssd=true,local-ssd-size-gb=\${LOCAL_SSD_TOTAL_GB}"
fi

# Create nodeadm config
mkdir -p /etc/eks/nodeadm.d
if [ -n "\${NODE_LABEL_FLAGS}" ]; then
cat > /etc/eks/nodeadm.d/nodeconfig.yaml <<NODECONFIG
---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    apiServerEndpoint: ${CLUSTER_ENDPOINT}
    certificateAuthority: ${CLUSTER_CA}
    cidr: ${SERVICE_IPV4_CIDR}
  kubelet:
    flags:
      - "\${NODE_LABEL_FLAGS}"
NODECONFIG
else
cat > /etc/eks/nodeadm.d/nodeconfig.yaml <<NODECONFIG
---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    apiServerEndpoint: ${CLUSTER_ENDPOINT}
    certificateAuthority: ${CLUSTER_CA}
    cidr: ${SERVICE_IPV4_CIDR}
NODECONFIG
fi

echo "NodeConfig written to /etc/eks/nodeadm.d/nodeconfig.yaml"
cat /etc/eks/nodeadm.d/nodeconfig.yaml

# Run nodeadm init to bootstrap the node
echo "Running nodeadm init..."
nodeadm init --config-source file:///etc/eks/nodeadm.d/nodeconfig.yaml

# Enable services for reboot persistence
echo "Enabling kubelet and containerd services..."
systemctl enable kubelet containerd

echo "=== GPU Node Bootstrap Complete ==="

--==BOUNDARY==--
EOF_USERDATA

    # Base64 encode the userdata
    local userdata_b64=$(base64 -w 0 < "${userdata_file}")

    # Generate Launch Template data using Python
    local lt_data_file=$(mktemp /tmp/lt-data.XXXXXX.json)

    python3 - <<PYSCRIPT > "${lt_data_file}"
import json
import base64

ami_id = "${GPU_AMI_ID}"
gpu_sg_id = "${GPU_SG_ID}"
cluster_sg_id = "${CLUSTER_SG_ID}"
efa_only_count = ${efa_only_count}
capacity_reservation_id = "${capacity_reservation_id}"
userdata_b64 = "${userdata_b64}"
ec2_key_name = "${EC2_KEY_NAME:-}"
instance_type = "${instance_type}"
embed_instance_type = "${embed_instance_type}" == "true"
pg_name = "${pg_name}"

# Network interfaces configuration
# Primary: NetworkCardIndex=0, DeviceIndex=0
#   - Most GPU instance types: InterfaceType=efa (EFA + ENA on same primary NIC)
#   - p6-b300.48xlarge: InterfaceType=interface (ENA only) — Network Card 0 does
#     NOT accept EFA on this type (MaximumEfaInterfaces=16 but MaximumNetworkCards=17;
#     EFA is only allowed on NetworkCardIndex 1..16). Using InterfaceType=efa on
#     NIC 0 yields `AttachmentLimitExceeded: Network Card 0 (requested: 1, limit: 0)`
# Additional: NetworkCardIndex=1..N, DeviceIndex=1, InterfaceType=efa-only
network_interfaces = []

# Primary network card — type depends on the instance
if instance_type == "p6-b300.48xlarge":
    primary_interface_type = "interface"   # pure ENA, no EFA on NIC 0
else:
    primary_interface_type = "efa"         # EFA + ENA on NIC 0

network_interfaces.append({
    "NetworkCardIndex": 0,
    "DeviceIndex": 0,
    "InterfaceType": primary_interface_type,
    "DeleteOnTermination": True,
    "Groups": [gpu_sg_id, cluster_sg_id],
})

# Additional EFA-only network cards
for nci in range(1, efa_only_count + 1):
    network_interfaces.append({
        "NetworkCardIndex": nci,
        "DeviceIndex": 1,
        "InterfaceType": "efa-only",
        "DeleteOnTermination": True,
        "Groups": [gpu_sg_id, cluster_sg_id],
    })

root_volume_size = ${GPU_NODE_ROOT_VOLUME_SIZE}
data_volume_size = ${GPU_NODE_DATA_VOLUME_SIZE}

lt_data = {
    "ImageId": ami_id,
    "UserData": userdata_b64,
    "NetworkInterfaces": network_interfaces,
    "BlockDeviceMappings": [
        {
            "DeviceName": "/dev/xvda",
            "Ebs": {
                "VolumeSize": root_volume_size,
                "VolumeType": "gp3",
                "Encrypted": True,
                "DeleteOnTermination": True
            }
        },
        {
            "DeviceName": "/dev/xvdb",
            "Ebs": {
                "VolumeSize": data_volume_size,
                "VolumeType": "gp3",
                "Iops": 3000,
                "Throughput": 125,
                "Encrypted": True,
                "DeleteOnTermination": True
            }
        }
    ],
    "MetadataOptions": {
        "HttpTokens": "required",
        "HttpPutResponseHopLimit": 2,
        "HttpEndpoint": "enabled"
    },
    "TagSpecifications": [
        {
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name", "Value": "${CLUSTER_NAME}-gpu-${resource_name}-node"},
                {"Key": "kubernetes.io/cluster/${CLUSTER_NAME}", "Value": "owned"},
                {"Key": "gpu-instance-type", "Value": "${gpu_type}"},
                {"Key": "purchase-option", "Value": "${purchase_option}"},
                {"Key": "business", "Value": "middleware"},
                {"Key": "resource", "Value": "eks"}
            ]
        },
        {
            "ResourceType": "volume",
            "Tags": [
                {"Key": "Name", "Value": "${CLUSTER_NAME}-gpu-${resource_name}-volume"},
                {"Key": "kubernetes.io/cluster/${CLUSTER_NAME}", "Value": "owned"},
                {"Key": "business", "Value": "middleware"},
                {"Key": "resource", "Value": "eks"}
            ]
        }
    ]
}

# Add capacity reservation if specified
if capacity_reservation_id:
    lt_data["CapacityReservationSpecification"] = {
        "CapacityReservationTarget": {
            "CapacityReservationId": capacity_reservation_id
        }
    }

# Add EC2 Key Pair if specified
if ec2_key_name:
    lt_data["KeyName"] = ec2_key_name

# Capacity Block requires InstanceType and MarketType=capacity-block inside the Launch Template
if embed_instance_type:
    lt_data["InstanceType"] = instance_type
    lt_data["InstanceMarketOptions"] = {
        "MarketType": "capacity-block"
    }

# Cluster placement group (forces same-leaf placement for EFA locality)
if pg_name:
    lt_data["Placement"] = {
        "GroupName": pg_name,
        "Tenancy": "default"
    }

print(json.dumps(lt_data, indent=2))
PYSCRIPT

    rm -f "${userdata_file}"

    echo "Launch Template data:"
    cat "${lt_data_file}"
    echo ""

    # Check if launch template exists
    if aws ec2 describe-launch-templates \
        --launch-template-names "${lt_name}" \
        --region "${AWS_REGION}" &>/dev/null; then

        echo "Launch Template ${lt_name} exists, creating new version..."

        LT_ID=$(aws ec2 describe-launch-templates \
            --launch-template-names "${lt_name}" \
            --region "${AWS_REGION}" \
            --query 'LaunchTemplates[0].LaunchTemplateId' \
            --output text)

        LT_VERSION=$(aws ec2 create-launch-template-version \
            --launch-template-id "${LT_ID}" \
            --launch-template-data "file://${lt_data_file}" \
            --region "${AWS_REGION}" \
            --query 'LaunchTemplateVersion.VersionNumber' \
            --output text)

        echo "Created new version: ${LT_VERSION}"
    else
        echo "Creating new Launch Template..."

        local lt_result
        lt_result=$(aws ec2 create-launch-template \
            --launch-template-name "${lt_name}" \
            --launch-template-data "file://${lt_data_file}" \
            --region "${AWS_REGION}" \
            --output json)

        LT_ID=$(echo "${lt_result}" | jq -r '.LaunchTemplate.LaunchTemplateId')
        LT_VERSION=$(echo "${lt_result}" | jq -r '.LaunchTemplate.LatestVersionNumber')

        echo "Created Launch Template: ${LT_ID} (version ${LT_VERSION})"
    fi

    rm -f "${lt_data_file}"

    echo "Launch Template ready:"
    echo "  ID: ${LT_ID}"
    echo "  Version: ${LT_VERSION}"
}

# ===================================================================
# Node Group Creation
# ===================================================================

create_gpu_nodegroup() {
    local gpu_type=$1
    local purchase_option=$2
    local lt_id=$3
    local lt_version=$4
    local suffix=${5:-}  # Optional suffix for multiple reservations (e.g., "-1", "-2")
    shift 5
    local subnets=("$@")

    local instance_type="$gpu_type"
    local resource_name=$(get_resource_name "$gpu_type")
    local ng_name="gpu-${resource_name}-${purchase_option}${suffix}"

    # Check if nodegroup exists
    if aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --region "${AWS_REGION}" &>/dev/null; then
        echo "Nodegroup ${ng_name} already exists, skipping"
        return 0
    fi

    echo "Creating nodegroup: ${ng_name}"
    echo "  Instance Type: ${instance_type}"
    echo "  Purchase Option: ${purchase_option}"
    echo "  Subnets: ${subnets[*]}"

    local capacity_type="ON_DEMAND"
    if [ "${purchase_option}" = "spot" ]; then
        capacity_type="SPOT"
    elif [ "${purchase_option}" = "cb" ]; then
        capacity_type="CAPACITY_BLOCK"
    fi

    echo "Creating nodegroup via AWS CLI..."

    # For CAPACITY_BLOCK, InstanceType is specified inside the Launch Template.
    # Passing --instance-types here would conflict with the LT, so omit it.
    local instance_types_arg=(--instance-types "${instance_type}")
    if [ "${purchase_option}" = "cb" ]; then
        instance_types_arg=()
    fi

    aws eks create-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --subnets ${subnets[*]} \
        --node-role "${GPU_NODE_ROLE_ARN}" \
        --launch-template "id=${lt_id},version=${lt_version}" \
        "${instance_types_arg[@]}" \
        --capacity-type "${capacity_type}" \
        --scaling-config "minSize=${GPU_NODE_MIN_SIZE},maxSize=${GPU_NODE_MAX_SIZE},desiredSize=${GPU_NODE_DESIRED_CAPACITY}" \
        --labels "workload-type=gpu,gpu-instance-type=${gpu_type},purchase-option=${purchase_option}" \
        --taints "key=nvidia.com/gpu,value=true,effect=NO_SCHEDULE" \
        --tags "k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/${CLUSTER_NAME}=owned,gpu-instance-type=${gpu_type},business=middleware,resource=eks" \
        --region "${AWS_REGION}"

    echo "Nodegroup ${ng_name} creation initiated"

    echo "Waiting for nodegroup to be active..."
    aws eks wait nodegroup-active \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --region "${AWS_REGION}"

    echo "Nodegroup ${ng_name} created"

    # Topology gate: verify same-leaf (or other level) placement.
    # Runs after NG is ACTIVE — if instances are not yet InService, it
    # will skip rather than fail (InService is strictly after ACTIVE).
    # The gate itself honors GPU_TOPOLOGY_GATE=off|warn|strict.
    verify_topology "${ng_name}" "${GPU_TOPOLOGY_GATE}" "${GPU_TOPOLOGY_GATE_LEVEL}"
}

# ===================================================================
# NVIDIA Device Plugin (kubectl apply)
# ===================================================================

install_nvidia_device_plugin() {
    echo "Installing NVIDIA Device Plugin via kubectl..."

    # Check if already installed
    if kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system &>/dev/null; then
        echo "NVIDIA Device Plugin already installed"
        return 0
    fi

    # Apply custom NVIDIA device plugin with host library symlinks
    # Required for EKS optimized GPU AMI where NVML libraries are on the host
    echo "Applying NVIDIA Device Plugin DaemonSet (with host library symlinks)..."
    echo "  Image: ${NVIDIA_DEVICE_PLUGIN_IMAGE}"
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      nodeSelector:
        workload-type: gpu
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      priorityClassName: system-node-critical
      hostPID: true
      containers:
      - image: ${NVIDIA_DEVICE_PLUGIN_IMAGE}
        name: nvidia-device-plugin-ctr
        command: ["/bin/sh", "-c"]
        args:
        - |
          # Symlink NVIDIA libraries from host to container library paths
          # Required because NVML libs are installed on host, not in container image
          ln -sf /host-lib64/libnvidia-ml.so.* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
          ln -sf /host-lib64/libnvidia-ml.so.* /usr/lib64/ 2>/dev/null || true
          exec /usr/bin/nvidia-device-plugin
        env:
        - name: FAIL_ON_INIT_ERROR
          value: "false"
        - name: PASS_DEVICE_SPECS
          value: "true"
        securityContext:
          privileged: true
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
        - name: host-lib64
          mountPath: /host-lib64
          readOnly: true
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
      - name: host-lib64
        hostPath:
          path: /usr/lib64
EOF

    echo "Waiting for NVIDIA Device Plugin to be ready..."
    for i in {1..30}; do
        local ready=$(kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system \
            -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        local desired=$(kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system \
            -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")

        echo "  NVIDIA Device Plugin: ${ready}/${desired} ready"

        # If no GPU nodes yet (desired=0), plugin is ready
        if [ "${desired}" = "0" ]; then
            echo "NVIDIA Device Plugin installed (waiting for GPU nodes)"
            return 0
        fi

        if [ "${ready}" = "${desired}" ] && [ "${ready}" != "0" ]; then
            echo "NVIDIA Device Plugin is ready"
            return 0
        fi
        sleep 10
    done

    echo "WARNING: NVIDIA Device Plugin may not be fully ready"
}

# ===================================================================
# AWS EFA Kubernetes Device Plugin (kubectl apply)
# ===================================================================

install_efa_device_plugin() {
    if [ "${INSTALL_EFA_DEVICE_PLUGIN}" != "true" ]; then
        echo "EFA Device Plugin installation skipped (INSTALL_EFA_DEVICE_PLUGIN=${INSTALL_EFA_DEVICE_PLUGIN})"
        return 0
    fi

    echo "Installing AWS EFA Kubernetes Device Plugin via kubectl..."

    if kubectl get daemonset aws-efa-k8s-device-plugin-daemonset -n kube-system &>/dev/null; then
        echo "EFA Device Plugin already installed"
        return 0
    fi

    # Region-aware ECR image prefix.
    # China regions: 961992271922 is the standard CN EKS add-on ECR account,
    # but AWS has not always mirrored aws-efa-k8s-device-plugin there. If a
    # CN deployment hits ImagePullBackOff, override EFA_DEVICE_PLUGIN_IMAGE
    # with a reachable registry (e.g. a customer-hosted ECR mirror).
    local efa_image
    if [ -n "${EFA_DEVICE_PLUGIN_IMAGE:-}" ]; then
        efa_image="${EFA_DEVICE_PLUGIN_IMAGE}"
    else
        case "${AWS_REGION}" in
            cn-*) efa_image="961992271922.dkr.ecr.${AWS_REGION}.amazonaws.com.cn/eks/aws-efa-k8s-device-plugin:${EFA_DEVICE_PLUGIN_VERSION}" ;;
            *)    efa_image="602401143452.dkr.ecr.${AWS_REGION}.amazonaws.com/eks/aws-efa-k8s-device-plugin:${EFA_DEVICE_PLUGIN_VERSION}" ;;
        esac
    fi
    echo "  Image: ${efa_image}"

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: aws-efa-k8s-device-plugin-daemonset
  namespace: kube-system
  labels:
    app.kubernetes.io/name: aws-efa-k8s-device-plugin
spec:
  selector:
    matchLabels:
      name: aws-efa-k8s-device-plugin
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: aws-efa-k8s-device-plugin
    spec:
      hostNetwork: true
      nodeSelector:
        workload-type: gpu
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: CriticalAddonsOnly
        operator: Exists
      priorityClassName: system-node-critical
      containers:
      - name: aws-efa-k8s-device-plugin
        image: ${efa_image}
        imagePullPolicy: IfNotPresent
        # Upstream chart uses privileged container; required to open
        # /dev/infiniband/uverbs* and advertise vpc.amazonaws.com/efa.
        securityContext:
          privileged: true
        resources:
          requests:
            cpu: 10m
            memory: 20Mi
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
        - name: infiniband-volume
          mountPath: /dev/infiniband/
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
      - name: infiniband-volume
        hostPath:
          path: /dev/infiniband/
EOF

    echo "Waiting for EFA Device Plugin to be ready..."
    for i in {1..30}; do
        local ready=$(kubectl get daemonset aws-efa-k8s-device-plugin-daemonset -n kube-system \
            -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        local desired=$(kubectl get daemonset aws-efa-k8s-device-plugin-daemonset -n kube-system \
            -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")

        echo "  EFA Device Plugin: ${ready}/${desired} ready"

        if [ "${desired}" = "0" ]; then
            echo "EFA Device Plugin installed (waiting for GPU nodes)"
            return 0
        fi

        if [ "${ready}" = "${desired}" ] && [ "${ready}" != "0" ]; then
            echo "EFA Device Plugin is ready"
            return 0
        fi
        sleep 10
    done

    echo "WARNING: EFA Device Plugin may not be fully ready"
}

# ===================================================================
# Main Execution
# ===================================================================

echo "=== Starting GPU Node Group Installation ==="

# Step 1: Get cluster information
echo ""
echo "Step 1: Gathering cluster information..."

CLUSTER_DESC=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}")
CLUSTER_ENDPOINT=$(echo "${CLUSTER_DESC}" | jq -r '.cluster.endpoint')
CLUSTER_CA=$(echo "${CLUSTER_DESC}" | jq -r '.cluster.certificateAuthority.data')
SERVICE_IPV4_CIDR=$(echo "${CLUSTER_DESC}" | jq -r '.cluster.kubernetesNetworkConfig.serviceIpv4Cidr')
CLUSTER_SG_ID=$(echo "${CLUSTER_DESC}" | jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId')

echo "Cluster Endpoint: ${CLUSTER_ENDPOINT}"
echo "Service CIDR: ${SERVICE_IPV4_CIDR}"
echo "Cluster Security Group: ${CLUSTER_SG_ID}"

# Step 2: Create IAM Role
echo ""
echo "Step 2: Creating GPU Node IAM Role..."
create_gpu_node_iam_role

# Step 3: Create Security Group
echo ""
echo "Step 3: Creating GPU Security Group..."
create_gpu_security_group

# Step 4: Get GPU AMI
echo ""
echo "Step 4: Getting GPU-optimized AMI..."

GPU_AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/nvidia/recommended/image_id" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text)

if [ -z "${GPU_AMI_ID}" ] || [ "${GPU_AMI_ID}" = "None" ]; then
    echo "ERROR: Could not retrieve GPU AMI ID"
    exit 1
fi

echo "GPU AMI ID: ${GPU_AMI_ID}"

# Step 5: Create node groups
echo ""
echo "Step 5: Creating GPU node groups..."
echo "GPU Instance Types: ${GPU_INSTANCE_TYPES}"
echo "Pricing Options: OD=${DEPLOY_GPU_OD}, Spot=${DEPLOY_GPU_SPOT}, ODCR=${DEPLOY_GPU_ODCR}, CB=${DEPLOY_GPU_CB}"

IFS=',' read -ra GPU_TYPE_ARRAY <<< "$GPU_INSTANCE_TYPES"

# Build subnet list
# Collect non-empty private subnets and deduplicate (EKS rejects duplicate subnets).
_raw_subnets=()
[ -n "${PRIVATE_SUBNET_A:-}" ] && _raw_subnets+=("${PRIVATE_SUBNET_A}")
[ -n "${PRIVATE_SUBNET_B:-}" ] && _raw_subnets+=("${PRIVATE_SUBNET_B}")
[ -n "${PRIVATE_SUBNET_C:-}" ] && _raw_subnets+=("${PRIVATE_SUBNET_C}")
[ -n "${PRIVATE_SUBNET_D:-}" ] && _raw_subnets+=("${PRIVATE_SUBNET_D}")
mapfile -t ALL_SUBNETS < <(printf '%s\n' "${_raw_subnets[@]}" | awk 'NF && !seen[$0]++')
unset _raw_subnets

# Subnet map for AZ-specific deployments
declare -A SUBNET_MAP
SUBNET_MAP["a"]="${PRIVATE_SUBNET_A}"
SUBNET_MAP["b"]="${PRIVATE_SUBNET_B}"
[ -n "${PRIVATE_SUBNET_C:-}" ] && SUBNET_MAP["c"]="${PRIVATE_SUBNET_C}"
[ -n "${PRIVATE_SUBNET_D:-}" ] && SUBNET_MAP["d"]="${PRIVATE_SUBNET_D}"

for gpu_type in "${GPU_TYPE_ARRAY[@]}"; do
    gpu_type=$(echo "$gpu_type" | tr -d ' ')
    echo ""
    echo "Processing GPU type: ${gpu_type}"

    efa_count=$(get_efa_only_card_count "$gpu_type")
    if [ "$efa_count" -eq 0 ]; then
        echo "WARNING: Unknown GPU type: ${gpu_type}, skipping"
        continue
    fi

    # Deploy On-Demand node group
    if [ "${DEPLOY_GPU_OD}" = "true" ]; then
        echo ""
        echo "Creating On-Demand node group for ${gpu_type}..."
        od_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "od" "" "${ALL_SUBNETS[@]}")
        create_gpu_launch_template "$gpu_type" "od" "" "" "$od_pg_name"
        create_gpu_nodegroup "$gpu_type" "od" "$LT_ID" "$LT_VERSION" "" "${ALL_SUBNETS[@]}"
    fi

    # Deploy Spot node group
    if [ "${DEPLOY_GPU_SPOT}" = "true" ]; then
        echo ""
        echo "Creating Spot node group for ${gpu_type}..."
        spot_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "spot" "" "${ALL_SUBNETS[@]}")
        create_gpu_launch_template "$gpu_type" "spot" "" "" "$spot_pg_name"
        create_gpu_nodegroup "$gpu_type" "spot" "$LT_ID" "$LT_VERSION" "" "${ALL_SUBNETS[@]}"
    fi

    # Deploy ODCR node group(s) - supports multiple reservations
    if [ "${DEPLOY_GPU_ODCR}" = "true" ]; then
        # Support both legacy single value (ODCR_ID/ODCR_AZ) and new multi-value format (ODCR_IDS/ODCR_AZS)
        odcr_ids_str="${ODCR_IDS:-${ODCR_ID:-}}"
        odcr_azs_str="${ODCR_AZS:-${ODCR_AZ:-}}"

        if [ -z "${odcr_ids_str}" ]; then
            echo "WARNING: No ODCR_IDS or ODCR_ID set, skipping ODCR node groups"
        elif [ -z "${odcr_azs_str}" ]; then
            echo "WARNING: No ODCR_AZS or ODCR_AZ set, skipping ODCR node groups"
        else
            IFS=',' read -ra ODCR_ID_ARRAY <<< "$odcr_ids_str"
            IFS=',' read -ra ODCR_AZ_ARRAY <<< "$odcr_azs_str"

            if [ ${#ODCR_ID_ARRAY[@]} -ne ${#ODCR_AZ_ARRAY[@]} ]; then
                echo "ERROR: ODCR_IDS and ODCR_AZS must have the same number of entries"
                exit 1
            else
                odcr_count=${#ODCR_ID_ARRAY[@]}
                for ((i=0; i<odcr_count; i++)); do
                    odcr_id=$(echo "${ODCR_ID_ARRAY[$i]}" | tr -d ' ')
                    odcr_az=$(echo "${ODCR_AZ_ARRAY[$i]}" | tr -d ' ')
                    odcr_az_suffix="${odcr_az: -1}"
                    odcr_subnet="${SUBNET_MAP[$odcr_az_suffix]:-}"

                    # Create unique suffix: -1, -2, etc. (only if multiple ODCRs)
                    suffix=""
                    if [ $odcr_count -gt 1 ]; then
                        suffix="-$((i+1))"
                    fi

                    echo ""
                    echo "Creating ODCR node group $((i+1))/${odcr_count} for ${gpu_type}..."
                    echo "  ODCR ID: ${odcr_id}"
                    echo "  AZ: ${odcr_az}"

                    if [ -n "${odcr_subnet}" ]; then
                        odcr_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "odcr" "${suffix}" "$odcr_subnet")
                        create_gpu_launch_template "$gpu_type" "odcr" "${odcr_id}" "${suffix}" "$odcr_pg_name"
                        create_gpu_nodegroup "$gpu_type" "odcr" "$LT_ID" "$LT_VERSION" "${suffix}" "$odcr_subnet"
                    else
                        echo "WARNING: No subnet found for ODCR AZ ${odcr_az}"
                    fi
                done
            fi
        fi
    fi

    # Deploy Capacity Block node group(s) - supports multiple reservations
    if [ "${DEPLOY_GPU_CB}" = "true" ]; then
        # Support both legacy single value (CAPACITY_BLOCK_ID/CAPACITY_BLOCK_AZ) and new multi-value format (CAPACITY_BLOCK_IDS/CAPACITY_BLOCK_AZS)
        cb_ids_str="${CAPACITY_BLOCK_IDS:-${CAPACITY_BLOCK_ID:-}}"
        cb_azs_str="${CAPACITY_BLOCK_AZS:-${CAPACITY_BLOCK_AZ:-}}"

        if [ -z "${cb_ids_str}" ]; then
            echo "WARNING: No CAPACITY_BLOCK_IDS or CAPACITY_BLOCK_ID set, skipping CB node groups"
        elif [ -z "${cb_azs_str}" ]; then
            echo "WARNING: No CAPACITY_BLOCK_AZS or CAPACITY_BLOCK_AZ set, skipping CB node groups"
        else
            IFS=',' read -ra CB_ID_ARRAY <<< "$cb_ids_str"
            IFS=',' read -ra CB_AZ_ARRAY <<< "$cb_azs_str"

            if [ ${#CB_ID_ARRAY[@]} -ne ${#CB_AZ_ARRAY[@]} ]; then
                echo "ERROR: CAPACITY_BLOCK_IDS and CAPACITY_BLOCK_AZS must have the same number of entries"
                exit 1
            else
                cb_count=${#CB_ID_ARRAY[@]}
                for ((i=0; i<cb_count; i++)); do
                    cb_id=$(echo "${CB_ID_ARRAY[$i]}" | tr -d ' ')
                    cb_az=$(echo "${CB_AZ_ARRAY[$i]}" | tr -d ' ')
                    cb_az_suffix="${cb_az: -1}"
                    cb_subnet="${SUBNET_MAP[$cb_az_suffix]:-}"

                    # Create unique suffix: -1, -2, etc. (only if multiple CBs)
                    suffix=""
                    if [ $cb_count -gt 1 ]; then
                        suffix="-$((i+1))"
                    fi

                    echo ""
                    echo "Creating Capacity Block node group $((i+1))/${cb_count} for ${gpu_type}..."
                    echo "  CB ID: ${cb_id}"
                    echo "  AZ: ${cb_az}"

                    if [ -n "${cb_subnet}" ]; then
                        cb_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "cb" "${suffix}" "$cb_subnet")
                        create_gpu_launch_template "$gpu_type" "cb" "${cb_id}" "${suffix}" "$cb_pg_name"
                        create_gpu_nodegroup "$gpu_type" "cb" "$LT_ID" "$LT_VERSION" "${suffix}" "$cb_subnet"
                    else
                        echo "WARNING: No subnet found for Capacity Block AZ ${cb_az}"
                    fi
                done
            fi
        fi
    fi
done

# Step 6: Install NVIDIA Device Plugin
echo ""
echo "Step 6: Installing NVIDIA Device Plugin..."
install_nvidia_device_plugin

# Step 7: Install AWS EFA Kubernetes Device Plugin
echo ""
echo "Step 7: Installing AWS EFA Kubernetes Device Plugin..."
install_efa_device_plugin

# Step 8: Summary
echo ""
echo "=== GPU Node Groups Installation Complete ==="
echo ""
echo "Created resources:"
echo "  • IAM Role: ${GPU_NODE_ROLE_NAME}"
echo "  • Security Group: ${GPU_SG_ID}"
echo "  • GPU AMI: ${GPU_AMI_ID}"
echo "  • NVIDIA Device Plugin: nvidia-device-plugin-daemonset (${NVIDIA_DEVICE_PLUGIN_VERSION})"
[ "${INSTALL_EFA_DEVICE_PLUGIN}" = "true" ] && echo "  • EFA Device Plugin: aws-efa-k8s-device-plugin-daemonset (${EFA_DEVICE_PLUGIN_VERSION})"
if [ "${GPU_ENABLE_LOCAL_LVM}" = "true" ]; then
    echo "  • Local NVMe LVM: ${GPU_LOCAL_LVM_VG_NAME}/${GPU_LOCAL_LVM_LV_NAME} (striped, ${GPU_LOCAL_LVM_FS}) → ${GPU_LOCAL_LVM_MOUNT}"
    echo "  • Node labels:    local-ssd=true, local-ssd-size-gb=<total>"
fi
echo ""
echo "Node groups created for:"
for gpu_type in "${GPU_TYPE_ARRAY[@]}"; do
    gpu_type=$(echo "$gpu_type" | tr -d ' ')
    echo "  • ${gpu_type}:"
    [ "${DEPLOY_GPU_OD}" = "true" ] && echo "    - On-Demand (all AZs)"
    [ "${DEPLOY_GPU_SPOT}" = "true" ] && echo "    - Spot (all AZs)"

    if [ "${DEPLOY_GPU_ODCR}" = "true" ]; then
        _odcr_ids_str="${ODCR_IDS:-${ODCR_ID:-}}"
        _odcr_azs_str="${ODCR_AZS:-${ODCR_AZ:-}}"
        if [ -n "${_odcr_ids_str}" ]; then
            IFS=',' read -ra ODCR_SUMMARY_IDS <<< "$_odcr_ids_str"
            IFS=',' read -ra ODCR_SUMMARY_AZS <<< "$_odcr_azs_str"
            for ((j=0; j<${#ODCR_SUMMARY_IDS[@]}; j++)); do
                _suffix_label=""
                [ ${#ODCR_SUMMARY_IDS[@]} -gt 1 ] && _suffix_label="-$((j+1))"
                echo "    - ODCR${_suffix_label} (${ODCR_SUMMARY_AZS[$j]})"
            done
        fi
    fi

    if [ "${DEPLOY_GPU_CB}" = "true" ]; then
        _cb_ids_str="${CAPACITY_BLOCK_IDS:-${CAPACITY_BLOCK_ID:-}}"
        _cb_azs_str="${CAPACITY_BLOCK_AZS:-${CAPACITY_BLOCK_AZ:-}}"
        if [ -n "${_cb_ids_str}" ]; then
            IFS=',' read -ra CB_SUMMARY_IDS <<< "$_cb_ids_str"
            IFS=',' read -ra CB_SUMMARY_AZS <<< "$_cb_azs_str"
            for ((j=0; j<${#CB_SUMMARY_IDS[@]}; j++)); do
                _suffix_label=""
                [ ${#CB_SUMMARY_IDS[@]} -gt 1 ] && _suffix_label="-$((j+1))"
                echo "    - CB${_suffix_label} (${CB_SUMMARY_AZS[$j]})"
            done
        fi
    fi
done
echo ""
echo "To scale up nodes (replace <nodegroup-name> with actual name from above):"
echo "  aws eks update-nodegroup-config --cluster-name ${CLUSTER_NAME} --nodegroup-name <nodegroup-name> --scaling-config minSize=0,maxSize=8,desiredSize=1"
echo ""
echo "To verify nodes:"
echo "  kubectl get nodes -l workload-type=gpu"
echo ""
if [ "${GPU_ENABLE_LOCAL_LVM}" = "true" ]; then
    echo "To verify local NVMe LVM on a node:"
    echo "  kubectl debug node/\${NODE} -it --image=amazonlinux -- chroot /host sh -c 'vgs; lvs; df -h ${GPU_LOCAL_LVM_MOUNT}'"
    echo "  kubectl get nodes -l local-ssd=true -L local-ssd-size-gb"
    echo ""
fi
echo "To verify EFA on node:"
echo "  kubectl debug node/\${NODE} -it --image=amazonlinux -- chroot /host ls /sys/class/infiniband/"
echo ""
echo "To verify EFA device plugin (resource vpc.amazonaws.com/efa):"
echo "  kubectl -n kube-system get ds aws-efa-k8s-device-plugin-daemonset"
echo "  kubectl describe node \${NODE} | grep 'vpc.amazonaws.com/efa'"
echo ""
