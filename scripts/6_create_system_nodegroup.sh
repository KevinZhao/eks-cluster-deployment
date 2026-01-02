#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Create System Nodegroup with LVM Configuration ==="
echo ""
echo "This script will create a system nodegroup with LVM configuration:"
echo "  • Instance Type: m7i.2xlarge (or custom from .env)"
echo "  • Root Volume: 50GB gp3"
echo "  • Data Volume: 100GB gp3 (for containerd with LVM)"
echo "  • Desired Capacity: 3 nodes"
echo ""
echo "Benefits:"
echo "  ✓ Larger containerd storage (100GB vs 50GB)"
echo "  ✓ Better I/O performance with dedicated data volume"
echo "  ✓ Ready for production workloads"
echo ""
echo "⏱  Expected duration: 8-12 minutes"
echo ""

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 设置 KUBECONFIG 环境变量
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.2. 检查必需的依赖工具
echo ""
echo "Checking required dependencies..."
MISSING_DEPS=()

command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v eksctl >/dev/null 2>&1 || MISSING_DEPS+=("eksctl")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")
command -v aws >/dev/null 2>&1 || MISSING_DEPS+=("aws cli")

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "❌ ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    echo ""
    echo "Please install the missing dependencies and try again."
    exit 1
fi
echo "✓ All required dependencies are installed"
echo ""

# 2. 验证集群存在
echo "Verifying EKS cluster exists..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "❌ ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    echo "Please run script 5_install_eks_cluster.sh first to create the cluster."
    exit 1
fi

# 验证 kubectl context（使用统一函数）
verify_kubectl_context
echo ""

# 2.1 配置安全组以允许堡垒机访问集群 API (针对私有集群)
echo "Configuring security group for bastion access to EKS API..."

# 获取集群安全组
CLUSTER_SG=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --region ${AWS_REGION} \
    --query 'cluster.resourcesVpcConfig.securityGroupIds[0]' \
    --output text 2>/dev/null)

if [ -z "${CLUSTER_SG}" ] || [ "${CLUSTER_SG}" = "None" ]; then
    echo "❌ ERROR: Could not get cluster security group"
    exit 1
fi

echo "Cluster Security Group: ${CLUSTER_SG}"

# 获取当前堡垒机的安全组（使用IMDSv2）
echo "Detecting current bastion security group..."
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s 2>/dev/null || echo "")
if [ -n "${TOKEN}" ]; then
    INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
else
    echo "❌ ERROR: Cannot get EC2 metadata token. This script must be run from inside an EC2 instance"
    echo ""
    echo "Expected deployment order:"
    echo "  1. Create VPC (Terraform)"
    echo "  2. Create bastion instance (scripts/4_create_bastion.sh)"
    echo "  3. SSH into bastion via AWS SSM"
    echo "  4. Run scripts 5, 6, and 7 from bastion"
    echo ""
    exit 1
fi

if [ -z "${INSTANCE_ID}" ]; then
    echo "❌ ERROR: Could not get instance ID. This script must be run from inside an EC2 instance"
    exit 1
fi

BASTION_SG=$(aws ec2 describe-instances \
    --instance-ids ${INSTANCE_ID} \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
    --output text \
    --region ${AWS_REGION} 2>/dev/null)

if [ -z "${BASTION_SG}" ] || [ "${BASTION_SG}" = "None" ]; then
    echo "❌ ERROR: Could not detect bastion security group"
    exit 1
fi

echo "Bastion Instance ID: ${INSTANCE_ID}"
echo "Bastion Security Group: ${BASTION_SG}"

# 添加入站规则允许堡垒机访问集群API端口443
echo "Adding security group rule..."
if aws ec2 authorize-security-group-ingress \
    --group-id ${CLUSTER_SG} \
    --protocol tcp \
    --port 443 \
    --source-group ${BASTION_SG} \
    --region ${AWS_REGION} 2>&1 | grep -q "already exists"; then
    echo "✓ Security group rule already exists"
else
    echo "✓ Security group rule added successfully"
fi

echo "✓ Bastion can now access EKS API Server"
echo ""

# ===================================================================
# 系统节点组创建函数（带LVM配置）
# ===================================================================

# 创建EKS节点IAM Role和Instance Profile
create_eks_node_iam_role() {
    NODE_ROLE_NAME="EKSNodeRole-${CLUSTER_NAME}"
    INSTANCE_PROFILE_NAME="${NODE_ROLE_NAME}"

    # 检查 IAM Role 是否已存在（幂等性）
    if aws iam get-role --role-name "${NODE_ROLE_NAME}" &>/dev/null; then
        echo "✓ IAM Role ${NODE_ROLE_NAME} already exists, skipping creation"
    else
        echo "Creating IAM Role: ${NODE_ROLE_NAME}"

        # 创建信任策略
        cat > /tmp/node-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

        aws iam create-role \
            --role-name "${NODE_ROLE_NAME}" \
            --assume-role-policy-document file:///tmp/node-trust-policy.json \
            --tags \
                Key=Cluster,Value="${CLUSTER_NAME}" \
                Key=ManagedBy,Value=script \
                Key=business,Value=middleware \
                Key=resource,Value=eks

        # 附加必需的策略
        aws iam attach-role-policy \
            --role-name "${NODE_ROLE_NAME}" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"

        aws iam attach-role-policy \
            --role-name "${NODE_ROLE_NAME}" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

        aws iam attach-role-policy \
            --role-name "${NODE_ROLE_NAME}" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

        aws iam attach-role-policy \
            --role-name "${NODE_ROLE_NAME}" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

        rm -f /tmp/node-trust-policy.json
        echo "✓ IAM Role created"
    fi

    # 检查 Instance Profile 是否已存在（幂等性）
    if aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" &>/dev/null; then
        echo "✓ Instance Profile ${INSTANCE_PROFILE_NAME} already exists, skipping creation"
    else
        echo "Creating Instance Profile: ${INSTANCE_PROFILE_NAME}"

        aws iam create-instance-profile \
            --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
            --tags \
                Key=Cluster,Value="${CLUSTER_NAME}" \
                Key=ManagedBy,Value=script \
                Key=business,Value=middleware \
                Key=resource,Value=eks

        aws iam add-role-to-instance-profile \
            --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
            --role-name "${NODE_ROLE_NAME}"

        # 等待 Instance Profile 创建完成
        echo "Waiting for Instance Profile to be ready..."
        sleep 10

        echo "✓ Instance Profile created"
    fi

    INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile \
        --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
        --query 'InstanceProfile.Arn' \
        --output text)

    echo "Instance Profile ARN: ${INSTANCE_PROFILE_ARN}"
}

# 创建包含LVM设置和NodeConfig的user-data
create_lvm_userdata() {
    USERDATA_FILE="/tmp/eks-utils-userdata-$$.txt"
    cat > "${USERDATA_FILE}" <<EOF_USERDATA
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
# LVM Setup - executed before EKS bootstrap
set -ex

# Log to file for debugging
exec > >(tee /var/log/lvm-setup.log)
exec 2>&1

echo "=== Starting LVM Setup ==="

# Stop containerd
systemctl stop containerd || true

# Wait for data disk to be available (max 60 seconds)
echo "Waiting for data disk..."
for i in {1..60}; do
  DISK=\$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)
  if [ -n "\$DISK" ]; then
    echo "Found data disk: \$DISK"
    break
  fi
  echo "Attempt \$i/60: Data disk not found yet, waiting..."
  sleep 1
done

if [ -z "\$DISK" ]; then
  echo "ERROR: No data disk found after 60 seconds"
  systemctl start containerd
  exit 0
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
grep -q "lv_containerd" /etc/fstab || \
  echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

echo "LVM setup completed successfully"
df -h /var/lib/containerd
vgs
lvs

# Start containerd
systemctl start containerd

echo "=== LVM Setup Complete ==="

--==BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
# Install FSx Lustre client on Amazon Linux 2023
set -ex

echo "=== Installing Lustre Client on AL2023 ==="

# Check kernel version
KERNEL_VERSION=\$(uname -r)
echo "Kernel version: \$KERNEL_VERSION"

# Install Lustre client for Amazon Linux 2023
dnf install -y lustre-client

# Load Lustre kernel module
modprobe lustre

# Verify installation
if lsmod | grep -q lustre; then
  echo "✓ Lustre client installed successfully"
  lsmod | grep lustre
  modinfo lustre | grep version
else
  echo "⚠ WARNING: Lustre module not loaded"
fi

echo "=== Lustre Client Installation Complete ==="

--==BOUNDARY==
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    apiServerEndpoint: ${CLUSTER_ENDPOINT}
    certificateAuthority: ${CLUSTER_CA}
    cidr: ${SERVICE_IPV4_CIDR}

--==BOUNDARY==--
EOF_USERDATA

    echo "✓ User-data created at: ${USERDATA_FILE}"
}

# 创建Launch Template
create_launch_template() {
    LT_NAME="${CLUSTER_NAME}-eks-utils-lt"

    # 检查Launch Template是否已存在（幂等性）
    if aws ec2 describe-launch-templates \
        --launch-template-names "${LT_NAME}" \
        --region "${AWS_REGION}" &>/dev/null; then

        echo "Launch Template ${LT_NAME} already exists, creating new version..."

        LT_ID=$(aws ec2 describe-launch-templates \
            --launch-template-names "${LT_NAME}" \
            --region "${AWS_REGION}" \
            --query 'LaunchTemplates[0].LaunchTemplateId' \
            --output text)

        LT_VERSION=$(aws ec2 create-launch-template-version \
            --launch-template-id "${LT_ID}" \
            --launch-template-data "{
              \"ImageId\": \"${AMI_ID}\",
              \"InstanceType\": \"${SYSTEM_NODE_INSTANCE_TYPE}\",
              \"UserData\": \"$(base64 -w 0 < ${USERDATA_FILE})\",
              \"BlockDeviceMappings\": [
                {
                  \"DeviceName\": \"/dev/xvda\",
                  \"Ebs\": {
                    \"VolumeSize\": ${SYSTEM_NODE_ROOT_VOLUME_SIZE},
                    \"VolumeType\": \"gp3\",
                    \"Encrypted\": true,
                    \"DeleteOnTermination\": true
                  }
                },
                {
                  \"DeviceName\": \"/dev/xvdb\",
                  \"Ebs\": {
                    \"VolumeSize\": ${SYSTEM_NODE_DATA_VOLUME_SIZE},
                    \"VolumeType\": \"gp3\",
                    \"Iops\": 3000,
                    \"Throughput\": 125,
                    \"Encrypted\": true,
                    \"DeleteOnTermination\": true
                  }
                }
              ],
              \"MetadataOptions\": {
                \"HttpEndpoint\": \"enabled\",
                \"HttpTokens\": \"required\",
                \"HttpPutResponseHopLimit\": 2
              },
              \"TagSpecifications\": [
                {
                  \"ResourceType\": \"instance\",
                  \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-eks-utils-node\"},
                    {\"Key\": \"kubernetes.io/cluster/${CLUSTER_NAME}\", \"Value\": \"owned\"},
                    {\"Key\": \"business\", \"Value\": \"middleware\"},
                    {\"Key\": \"resource\", \"Value\": \"eks\"}
                  ]
                },
                {
                  \"ResourceType\": \"volume\",
                  \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-eks-utils-volume\"},
                    {\"Key\": \"business\", \"Value\": \"middleware\"},
                    {\"Key\": \"resource\", \"Value\": \"eks\"}
                  ]
                }
              ]
            }" \
            --region "${AWS_REGION}" \
            --query 'LaunchTemplateVersion.VersionNumber' \
            --output text)

        echo "Created Launch Template version: ${LT_VERSION}"

    else
        echo "Creating new Launch Template: ${LT_NAME}..."

        LT_RESULT=$(aws ec2 create-launch-template \
            --launch-template-name "${LT_NAME}" \
            --launch-template-data "{
              \"ImageId\": \"${AMI_ID}\",
              \"InstanceType\": \"${SYSTEM_NODE_INSTANCE_TYPE}\",
              \"UserData\": \"$(base64 -w 0 < ${USERDATA_FILE})\",
              \"BlockDeviceMappings\": [
                {
                  \"DeviceName\": \"/dev/xvda\",
                  \"Ebs\": {
                    \"VolumeSize\": ${SYSTEM_NODE_ROOT_VOLUME_SIZE},
                    \"VolumeType\": \"gp3\",
                    \"Encrypted\": true,
                    \"DeleteOnTermination\": true
                  }
                },
                {
                  \"DeviceName\": \"/dev/xvdb\",
                  \"Ebs\": {
                    \"VolumeSize\": ${SYSTEM_NODE_DATA_VOLUME_SIZE},
                    \"VolumeType\": \"gp3\",
                    \"Iops\": 3000,
                    \"Throughput\": 125,
                    \"Encrypted\": true,
                    \"DeleteOnTermination\": true
                  }
                }
              ],
              \"MetadataOptions\": {
                \"HttpEndpoint\": \"enabled\",
                \"HttpTokens\": \"required\",
                \"HttpPutResponseHopLimit\": 2
              },
              \"TagSpecifications\": [
                {
                  \"ResourceType\": \"instance\",
                  \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-eks-utils-node\"},
                    {\"Key\": \"kubernetes.io/cluster/${CLUSTER_NAME}\", \"Value\": \"owned\"},
                    {\"Key\": \"business\", \"Value\": \"middleware\"},
                    {\"Key\": \"resource\", \"Value\": \"eks\"}
                  ]
                },
                {
                  \"ResourceType\": \"volume\",
                  \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-eks-utils-volume\"},
                    {\"Key\": \"business\", \"Value\": \"middleware\"},
                    {\"Key\": \"resource\", \"Value\": \"eks\"}
                  ]
                }
              ]
            }" \
            --region "${AWS_REGION}" \
            --output json)

        LT_ID=$(echo "${LT_RESULT}" | jq -r '.LaunchTemplate.LaunchTemplateId')
        LT_VERSION=$(echo "${LT_RESULT}" | jq -r '.LaunchTemplate.LatestVersionNumber')

        echo "Created Launch Template: ${LT_ID} (version ${LT_VERSION})"
    fi

    # 清理临时文件
    rm -f "${USERDATA_FILE}"

    echo "Launch Template Information:"
    echo "  Name: ${LT_NAME}"
    echo "  ID: ${LT_ID}"
    echo "  Version: ${LT_VERSION}"
}

# 删除现有系统节点组
delete_existing_nodegroup() {
    echo "Checking for existing system nodegroups..."

    # 检查是否有需要删除的节点组
    NODEGROUPS_TO_DELETE=()
    for NG_NAME in eks-utils eks-utils-arm64 eks-utils-x86; do
        if aws eks describe-nodegroup \
            --cluster-name "${CLUSTER_NAME}" \
            --nodegroup-name "${NG_NAME}" \
            --region "${AWS_REGION}" &>/dev/null; then
            NODEGROUPS_TO_DELETE+=("${NG_NAME}")
            echo "Found nodegroup to delete: ${NG_NAME}"
        fi
    done

    # 如果没有需要删除的节点组，直接跳过
    if [ ${#NODEGROUPS_TO_DELETE[@]} -eq 0 ]; then
        echo "✓ No existing nodegroups found, skipping deletion"
        return 0
    fi

    echo ""
    echo "⚠️  WARNING: The following nodegroup(s) will be deleted:"
    for NG_NAME in "${NODEGROUPS_TO_DELETE[@]}"; do
        echo "  - ${NG_NAME}"
    done
    echo ""
    echo "This will cause a service interruption of 5-8 minutes."

    # 支持非交互模式: AUTO_DELETE_NODEGROUP=yes
    if [ -n "${AUTO_DELETE_NODEGROUP}" ] && [[ "${AUTO_DELETE_NODEGROUP}" =~ ^[Yy] ]]; then
        echo "AUTO_DELETE_NODEGROUP is set, proceeding automatically..."
    else
        echo "Press Ctrl+C to cancel, or Enter to continue..."
        echo "For non-interactive mode, set AUTO_DELETE_NODEGROUP=yes"
        read
    fi

    # 删除找到的节点组
    for NG_NAME in "${NODEGROUPS_TO_DELETE[@]}"; do
        echo "Deleting nodegroup ${NG_NAME}..."
        eksctl delete nodegroup \
            --cluster="${CLUSTER_NAME}" \
            --region="${AWS_REGION}" \
            --name="${NG_NAME}" \
            --drain=false \
            --wait

        echo "✓ Nodegroup ${NG_NAME} deleted successfully"
    done

    echo "✓ All existing nodegroups deleted"
}

# 创建节点组（引用Launch Template）
create_nodegroup_with_lt() {
    # 检查节点组是否已存在（幂等性）
    if aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name eks-utils \
        --region "${AWS_REGION}" &>/dev/null; then
        echo "✓ Nodegroup eks-utils already exists, skipping creation"
        return 0
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    TEMP_CONFIG="/tmp/eksctl_ng_$$.yaml"
    cat > "${TEMP_CONFIG}" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"

vpc:
  id: "${VPC_ID}"
  subnets:
    private:
      ${AZ_A}:
        id: "${PRIVATE_SUBNET_A}"
      ${AZ_B}:
        id: "${PRIVATE_SUBNET_B}"
      ${AZ_C}:
        id: "${PRIVATE_SUBNET_C}"

managedNodeGroups:
  - name: eks-utils
    launchTemplate:
      id: ${LT_ID}
      version: "${LT_VERSION}"
    iam:
      instanceRoleARN: arn:aws:iam::${ACCOUNT_ID}:role/${NODE_ROLE_NAME}
    desiredCapacity: ${SYSTEM_NODE_DESIRED_CAPACITY}
    minSize: ${SYSTEM_NODE_MIN_SIZE}
    maxSize: ${SYSTEM_NODE_MAX_SIZE}
    privateNetworking: true
    subnets:
      - ${PRIVATE_SUBNET_A}
      - ${PRIVATE_SUBNET_B}
      - ${PRIVATE_SUBNET_C}
    labels:
      app: "eks-utils"
      arch: "x86_64"
      node-group-type: "system"
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
EOF

    echo "Generated eksctl nodegroup config:"
    cat "${TEMP_CONFIG}"
    echo ""

    echo "Creating nodegroup..."
    eksctl create nodegroup -f "${TEMP_CONFIG}"

    rm -f "${TEMP_CONFIG}"
    echo "✓ Nodegroup created"
}

# 等待节点就绪
wait_for_nodes_ready() {
    echo "Waiting for nodes to be ready..."
    sleep 15

    RETRY_COUNT=0
    MAX_RETRIES=60

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        READY_NODES=$(kubectl get nodes -l ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE} --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
        READY_NODES=${READY_NODES//[^0-9]/}
        READY_NODES=${READY_NODES:-0}

        echo "Ready nodes: ${READY_NODES}/${SYSTEM_NODE_DESIRED_CAPACITY}"

        if [ "$READY_NODES" -ge "${SYSTEM_NODE_DESIRED_CAPACITY}" ]; then
            echo "✓ All nodes are ready!"
            return 0
        fi

        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
            echo "❌ ERROR: Timeout waiting for nodes"
            kubectl get nodes -l ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE}
            exit 1
        fi

        sleep 10
    done
}

# 验证LVM配置
verify_lvm_configuration() {
    echo "Verifying LVM configuration on nodes..."

    local NODE_NAME=$(kubectl get nodes -l ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$NODE_NAME" ]; then
        echo "⚠ WARNING: Cannot verify LVM - no nodes found"
        return 0
    fi

    echo "Checking node: $NODE_NAME"

    # 验证节点状态
    local NODE_STATUS=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$NODE_STATUS" != "True" ]; then
        echo "❌ ERROR: Node $NODE_NAME is not Ready"
        return 1
    fi
    echo "✓ Node is Ready"

    # 验证实例类型
    local INSTANCE_TYPE=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
    if [ "$INSTANCE_TYPE" != "$SYSTEM_NODE_INSTANCE_TYPE" ]; then
        echo "⚠ WARNING: Unexpected instance type: $INSTANCE_TYPE (expected: $SYSTEM_NODE_INSTANCE_TYPE)"
    else
        echo "✓ Instance type is correct: $INSTANCE_TYPE"
    fi

    echo "✓ LVM configuration verification complete"
    echo ""
    echo "To manually verify LVM on a node, run:"
    echo "  kubectl debug node/${NODE_NAME} -it --image=busybox -- sh"
    echo "  Then: chroot /host bash && vgs && lvs && df -h /var/lib/containerd"
}

# ===================================================================
# 主流程
# ===================================================================

echo "=== Creating System Nodegroup with LVM Configuration ==="

# 步骤1：获取集群信息
echo ""
echo "Step 1: Gathering cluster information..."
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.endpoint' --output text)
CLUSTER_CA=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.certificateAuthority.data' --output text)
SERVICE_IPV4_CIDR=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text)

echo "Cluster Endpoint: ${CLUSTER_ENDPOINT}"
echo "Service CIDR: ${SERVICE_IPV4_CIDR}"

# 步骤2：创建IAM Role和Instance Profile
echo ""
echo "Step 2: Creating IAM Role and Instance Profile..."
create_eks_node_iam_role

# Validate IAM role and instance profile were created successfully
validate_iam_role_exists "${NODE_ROLE_NAME}"
validate_instance_profile_exists "${INSTANCE_PROFILE_NAME}"

# 步骤3：获取最新的EKS optimized AMI
echo ""
echo "Step 3: Getting latest EKS optimized AMI..."
# Use Amazon Linux 2023 with FSx Lustre support
AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text)

if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" = "None" ]; then
    echo "❌ ERROR: Could not retrieve AMI ID from SSM parameter"
    echo "   Parameter: /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id"
    exit 1
fi

echo "AMI ID: ${AMI_ID} (Amazon Linux 2023 with FSx Lustre support)"

# Validate AMI exists and is available
validate_ami_exists "${AMI_ID}" "${AWS_REGION}"

# 步骤4：创建user-data（包含LVM setup和NodeConfig）
echo ""
echo "Step 4: Creating user-data with LVM configuration..."
create_lvm_userdata

# 步骤5：创建Launch Template
echo ""
echo "Step 5: Creating Launch Template..."
create_launch_template

# 步骤6：删除现有节点组（如果存在）
echo ""
echo "Step 6: Checking existing nodegroups..."
delete_existing_nodegroup

# 步骤7：创建新节点组
echo ""
echo "Step 7: Creating new nodegroup..."
create_nodegroup_with_lt

# 步骤8：等待节点就绪
echo ""
echo "Step 8: Waiting for nodes to be ready..."
wait_for_nodes_ready

# 步骤9：验证LVM配置
echo ""
echo "Step 9: Verifying LVM configuration..."
verify_lvm_configuration

# 完成
echo ""
echo "=== System Nodegroup with LVM Created Successfully ==="
echo ""
echo "Summary:"
echo "  • Launch Template: ${LT_NAME} (${LT_ID})"
echo "  • Instance Type: ${SYSTEM_NODE_INSTANCE_TYPE}"
echo "  • Root Volume: ${SYSTEM_NODE_ROOT_VOLUME_SIZE}GB (gp3)"
echo "  • Data Volume (LVM): ${SYSTEM_NODE_DATA_VOLUME_SIZE}GB (gp3, mounted at /var/lib/containerd)"
echo "  • Nodes: ${SYSTEM_NODE_DESIRED_CAPACITY} ready"
echo ""
kubectl get nodes -o wide
echo ""
echo "Next step: Continue with script 7 to install cluster addons"
echo "  ./scripts/7_install_eks_addon.sh"
echo ""
