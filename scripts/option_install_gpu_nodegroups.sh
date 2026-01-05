#!/bin/bash

set -e

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
echo ""
echo "Pricing options (mutually exclusive - choose ONE):"
echo "  • Spot:           Cost-effective for fault-tolerant workloads (DEPLOY_GPU_SPOT=true)"
echo "  • ODCR:           Guaranteed capacity, on-demand pricing (DEPLOY_GPU_ODCR=true)"
echo "  • Capacity Block: Time-limited reserved capacity (DEPLOY_GPU_CB=true)"
echo ""

# 1. Load environment
source "${SCRIPT_DIR}/0_setup_env.sh"

export KUBECONFIG="${HOME}/.kube/config"
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

GPU_INSTANCE_TYPES="${GPU_INSTANCE_TYPES:-p5,p5en,p6}"
GPU_NODE_DESIRED_CAPACITY="${GPU_NODE_DESIRED_CAPACITY:-0}"
GPU_NODE_MIN_SIZE="${GPU_NODE_MIN_SIZE:-0}"
GPU_NODE_MAX_SIZE="${GPU_NODE_MAX_SIZE:-8}"
GPU_NODE_ROOT_VOLUME_SIZE="${GPU_NODE_ROOT_VOLUME_SIZE:-50}"
GPU_NODE_DATA_VOLUME_SIZE="${GPU_NODE_DATA_VOLUME_SIZE:-100}"

DEPLOY_GPU_SPOT="${DEPLOY_GPU_SPOT:-true}"
DEPLOY_GPU_ODCR="${DEPLOY_GPU_ODCR:-false}"
DEPLOY_GPU_CB="${DEPLOY_GPU_CB:-false}"

# Validate: only one pricing option should be enabled (mutually exclusive)
ENABLED_COUNT=0
[ "${DEPLOY_GPU_SPOT}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[ "${DEPLOY_GPU_ODCR}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
[ "${DEPLOY_GPU_CB}" = "true" ] && ENABLED_COUNT=$((ENABLED_COUNT + 1))

if [ "${ENABLED_COUNT}" -gt 1 ]; then
    echo "ERROR: Only ONE pricing option can be enabled at a time"
    echo "  DEPLOY_GPU_SPOT=${DEPLOY_GPU_SPOT}"
    echo "  DEPLOY_GPU_ODCR=${DEPLOY_GPU_ODCR}"
    echo "  DEPLOY_GPU_CB=${DEPLOY_GPU_CB}"
    echo ""
    echo "These are mutually exclusive deployment modes. Please enable only one."
    exit 1
fi

if [ "${ENABLED_COUNT}" -eq 0 ]; then
    echo "ERROR: At least one pricing option must be enabled"
    echo "Set one of: DEPLOY_GPU_SPOT=true, DEPLOY_GPU_ODCR=true, or DEPLOY_GPU_CB=true"
    exit 1
fi

# Get EFA-only network card count (excluding primary EFA card)
get_efa_only_card_count() {
    local gpu_type=$1
    case "$gpu_type" in
        p5)   echo 31 ;;   # NetworkCardIndex 1-31
        p5en) echo 15 ;;   # NetworkCardIndex 1-15
        p6)   echo 7 ;;    # NetworkCardIndex 1-7
        *)    echo 0 ;;
    esac
}

# Get full instance type name
get_instance_type() {
    local gpu_type=$1
    case "$gpu_type" in
        p5)   echo "p5.48xlarge" ;;
        p5en) echo "p5en.48xlarge" ;;
        p6)   echo "p6-b200.48xlarge" ;;
        *)    echo "" ;;
    esac
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
        aws eks create-access-entry \
            --cluster-name "${CLUSTER_NAME}" \
            --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GPU_NODE_ROLE_NAME}" \
            --type EC2_LINUX \
            --region "${AWS_REGION}"
        echo "EKS access entry created for ${GPU_NODE_ROLE_NAME}"
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
    aws ec2 authorize-security-group-ingress \
        --group-id "${GPU_SG_ID}" \
        --protocol -1 \
        --source-group "${GPU_SG_ID}" \
        --region "${AWS_REGION}" 2>&1 | grep -q "already exists" && echo "  Self-ingress rule exists" || echo "  Self-ingress rule added"

    echo "GPU Security Group configured: ${GPU_SG_ID}"
}

# ===================================================================
# Launch Template Creation (EFA + EFA-only)
# ===================================================================

create_gpu_launch_template() {
    local gpu_type=$1
    local purchase_option=$2
    local capacity_reservation_id=${3:-}
    local suffix=${4:-}  # Optional suffix for multiple reservations (e.g., "-1", "-2")

    local instance_type=$(get_instance_type "$gpu_type")
    local efa_only_count=$(get_efa_only_card_count "$gpu_type")
    local lt_name="${CLUSTER_NAME}-gpu-${gpu_type}-${purchase_option}${suffix}-lt"

    echo "Creating Launch Template: ${lt_name}"
    echo "  Instance Type: ${instance_type}"
    echo "  EFA-only Cards: ${efa_only_count}"

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

# Wait for data disk to be available (max 60 seconds)
# Find NVMe disk that has NO partitions (the data disk is unpartitioned)
echo "Waiting for data disk..."
for i in {1..60}; do
  # Find all NVMe disks, then filter to those without partitions
  for dev in \$(lsblk -dpno NAME | grep nvme); do
    # Check if this disk has any partitions
    PARTS=\$(lsblk -no NAME "\$dev" 2>/dev/null | wc -l)
    if [ "\$PARTS" -eq 1 ]; then
      # Only the disk itself, no partitions - this is our data disk
      DISK="\$dev"
      echo "Found unpartitioned data disk: \$DISK"
      break 2
    fi
  done
  echo "Attempt \$i/60: Data disk not found yet, waiting..."
  sleep 1
done

if [ -z "\$DISK" ]; then
  echo "ERROR: No unpartitioned data disk found after 60 seconds"
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
  exit 0
fi

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

echo "=== LVM Setup Complete ==="

# Install lustre-client for FSx Lustre support
echo "=== Installing Lustre Client ==="
dnf install -y lustre-client
modprobe lustre || true
echo "Lustre client installed"

echo "=== Starting EKS Node Bootstrap ==="

# Create nodeadm config
mkdir -p /etc/eks/nodeadm.d
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

echo "NodeConfig written to /etc/eks/nodeadm.d/nodeconfig.yaml"
cat /etc/eks/nodeadm.d/nodeconfig.yaml

# Run nodeadm init to bootstrap the node
echo "Running nodeadm init..."
nodeadm init --config-source file:///etc/eks/nodeadm.d/nodeconfig.yaml

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

# Network interfaces configuration
# Primary: NetworkCardIndex=0, DeviceIndex=0, InterfaceType=efa (not efa-only!)
# Additional: NetworkCardIndex=1..N, DeviceIndex=1, InterfaceType=efa-only
network_interfaces = []

# Primary network card (EFA with ENA capability)
network_interfaces.append({
    "NetworkCardIndex": 0,
    "DeviceIndex": 0,
    "InterfaceType": "efa",
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
                {"Key": "Name", "Value": "${CLUSTER_NAME}-gpu-${gpu_type}-node"},
                {"Key": "kubernetes.io/cluster/${CLUSTER_NAME}", "Value": "owned"},
                {"Key": "gpu-family", "Value": "${gpu_type}"},
                {"Key": "purchase-option", "Value": "${purchase_option}"},
                {"Key": "business", "Value": "middleware"},
                {"Key": "resource", "Value": "eks"}
            ]
        },
        {
            "ResourceType": "volume",
            "Tags": [
                {"Key": "Name", "Value": "${CLUSTER_NAME}-gpu-${gpu_type}-volume"},
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

        local lt_result=$(aws ec2 create-launch-template \
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

    local ng_name="gpu-${gpu_type}-${purchase_option}${suffix}"
    local instance_type=$(get_instance_type "$gpu_type")

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
    fi

    echo "Creating nodegroup via AWS CLI..."

    aws eks create-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --subnets ${subnets[*]} \
        --node-role "${GPU_NODE_ROLE_ARN}" \
        --launch-template "id=${lt_id},version=${lt_version}" \
        --instance-types "${instance_type}" \
        --capacity-type "${capacity_type}" \
        --scaling-config "minSize=${GPU_NODE_MIN_SIZE},maxSize=${GPU_NODE_MAX_SIZE},desiredSize=${GPU_NODE_DESIRED_CAPACITY}" \
        --labels "workload-type=gpu,gpu-family=${gpu_type},purchase-option=${purchase_option}" \
        --taints "key=nvidia.com/gpu,value=true,effect=NO_SCHEDULE" \
        --tags "k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/${CLUSTER_NAME}=owned,gpu-family=${gpu_type},business=middleware,resource=eks" \
        --region "${AWS_REGION}"

    echo "Nodegroup ${ng_name} creation initiated"

    echo "Waiting for nodegroup to be active..."
    aws eks wait nodegroup-active \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${ng_name}" \
        --region "${AWS_REGION}" || echo "WARNING: Nodegroup may still be creating"

    echo "Nodegroup ${ng_name} created"
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
    kubectl apply -f - <<'EOF'
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
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.15.0
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
echo "Pricing Options: Spot=${DEPLOY_GPU_SPOT}, ODCR=${DEPLOY_GPU_ODCR}, CB=${DEPLOY_GPU_CB}"

IFS=',' read -ra GPU_TYPE_ARRAY <<< "$GPU_INSTANCE_TYPES"

# Build subnet list
ALL_SUBNETS=("${PRIVATE_SUBNET_A}" "${PRIVATE_SUBNET_B}")
[ -n "${PRIVATE_SUBNET_C:-}" ] && ALL_SUBNETS+=("${PRIVATE_SUBNET_C}")
[ -n "${PRIVATE_SUBNET_D:-}" ] && ALL_SUBNETS+=("${PRIVATE_SUBNET_D}")

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

    instance_type=$(get_instance_type "$gpu_type")
    if [ -z "$instance_type" ]; then
        echo "WARNING: Unknown GPU type: ${gpu_type}, skipping"
        continue
    fi

    # Deploy Spot node group
    if [ "${DEPLOY_GPU_SPOT}" = "true" ]; then
        echo ""
        echo "Creating Spot node group for ${gpu_type}..."
        create_gpu_launch_template "$gpu_type" "spot" "" ""
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
            else
                local odcr_count=${#ODCR_ID_ARRAY[@]}
                for ((i=0; i<odcr_count; i++)); do
                    local odcr_id=$(echo "${ODCR_ID_ARRAY[$i]}" | tr -d ' ')
                    local odcr_az=$(echo "${ODCR_AZ_ARRAY[$i]}" | tr -d ' ')
                    local odcr_az_suffix="${odcr_az: -1}"
                    local odcr_subnet="${SUBNET_MAP[$odcr_az_suffix]:-}"

                    # Create unique suffix: -1, -2, etc. (only if multiple ODCRs)
                    local suffix=""
                    if [ $odcr_count -gt 1 ]; then
                        suffix="-$((i+1))"
                    fi

                    echo ""
                    echo "Creating ODCR node group $((i+1))/${odcr_count} for ${gpu_type}..."
                    echo "  ODCR ID: ${odcr_id}"
                    echo "  AZ: ${odcr_az}"

                    if [ -n "${odcr_subnet}" ]; then
                        create_gpu_launch_template "$gpu_type" "odcr" "${odcr_id}" "${suffix}"
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
            else
                local cb_count=${#CB_ID_ARRAY[@]}
                for ((i=0; i<cb_count; i++)); do
                    local cb_id=$(echo "${CB_ID_ARRAY[$i]}" | tr -d ' ')
                    local cb_az=$(echo "${CB_AZ_ARRAY[$i]}" | tr -d ' ')
                    local cb_az_suffix="${cb_az: -1}"
                    local cb_subnet="${SUBNET_MAP[$cb_az_suffix]:-}"

                    # Create unique suffix: -1, -2, etc. (only if multiple CBs)
                    local suffix=""
                    if [ $cb_count -gt 1 ]; then
                        suffix="-$((i+1))"
                    fi

                    echo ""
                    echo "Creating Capacity Block node group $((i+1))/${cb_count} for ${gpu_type}..."
                    echo "  CB ID: ${cb_id}"
                    echo "  AZ: ${cb_az}"

                    if [ -n "${cb_subnet}" ]; then
                        create_gpu_launch_template "$gpu_type" "cb" "${cb_id}" "${suffix}"
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

# Step 7: Summary
echo ""
echo "=== GPU Node Groups Installation Complete ==="
echo ""
echo "Created resources:"
echo "  • IAM Role: ${GPU_NODE_ROLE_NAME}"
echo "  • Security Group: ${GPU_SG_ID}"
echo "  • GPU AMI: ${GPU_AMI_ID}"
echo ""
echo "Node groups created for:"
for gpu_type in "${GPU_TYPE_ARRAY[@]}"; do
    gpu_type=$(echo "$gpu_type" | tr -d ' ')
    echo "  • ${gpu_type}:"
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
echo "To scale up nodes:"
echo "  aws eks update-nodegroup-config --cluster-name ${CLUSTER_NAME} --nodegroup-name gpu-p5-spot --scaling-config minSize=0,maxSize=8,desiredSize=1"
echo ""
echo "To verify nodes:"
echo "  kubectl get nodes -l workload-type=gpu"
echo ""
echo "To verify EFA:"
echo "  kubectl debug node/\${NODE} -it --image=amazonlinux -- chroot /host ls /sys/class/infiniband/"
echo ""
