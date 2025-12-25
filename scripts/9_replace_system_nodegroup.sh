#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Replace System Nodegroup with x86 + LVM ==="
echo ""
echo "This script will:"
echo "  1. Create Launch Template with LVM user-data using AWS CLI"
echo "  2. Delete existing system nodegroup (eks-utils or eks-utils-arm64)"
echo "  3. Create new x86 nodegroup (m7i.large) with LVM"
echo "  4. Verify LVM configuration"
echo ""
echo "WARNING: This will cause a brief service interruption (5-8 minutes)"
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 更新 kubeconfig
export KUBECONFIG="${HOME}/.kube/config"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

# 2. 获取 EKS 集群信息
echo ""
echo "Step 1: Gathering EKS cluster information..."

CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.endpoint' --output text)
CLUSTER_CA=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.certificateAuthority.data' --output text)
CLUSTER_SG=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

echo "Cluster Endpoint: ${CLUSTER_ENDPOINT}"
echo "Cluster Security Group: ${CLUSTER_SG}"

# 3. 创建 EKS 节点 IAM Role 和 Instance Profile
echo ""
echo "Step 2: Creating EKS Node IAM Role and Instance Profile..."

# 使用固定的名称 EKSNodeRole-eks-frankfurt（不包含 -test 后缀）
NODE_ROLE_NAME="EKSNodeRole-eks-frankfurt"
INSTANCE_PROFILE_NAME="${NODE_ROLE_NAME}"

# 检查 IAM Role 是否已存在（原子性检查）
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

# 检查 Instance Profile 是否已存在（原子性检查）
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

# 4. 获取最新的 EKS optimized AMI for x86_64
echo ""
echo "Step 3: Getting latest EKS optimized AMI..."

AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text)

echo "AMI ID: ${AMI_ID}"

# 5. 创建 user-data 文件（不经过任何模板替换）
echo ""
echo "Step 4: Creating user-data script..."

USERDATA_FILE="/tmp/eks-utils-userdata-$$.sh"
cat > "${USERDATA_FILE}" <<'EOF_USERDATA'
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
  DISK=$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)
  if [ -n "$DISK" ]; then
    echo "Found data disk: $DISK"
    break
  fi
  echo "Attempt $i/60: Data disk not found yet, waiting..."
  sleep 1
done

if [ -z "$DISK" ]; then
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

# Install lvm2
echo "Installing lvm2..."
dnf install -y lvm2

# Create LVM
echo "Creating LVM on $DISK..."
pvcreate "$DISK"
vgcreate vg_data "$DISK"
lvcreate -l 100%VG -n lv_containerd vg_data
mkfs.xfs /dev/vg_data/lv_containerd

# Mount and migrate data
echo "Mounting and migrating containerd data..."
mkdir -p /mnt/runtime/containerd
mount /dev/vg_data/lv_containerd /mnt/runtime/containerd
rsync -aHAX /var/lib/containerd/ /mnt/runtime/containerd/ || true
umount /mnt/runtime/containerd
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

--==BOUNDARY==--
EOF_USERDATA

echo "User-data created at: ${USERDATA_FILE}"

# 6. 创建或更新 Launch Template
echo ""
echo "Step 5: Creating Launch Template..."

LT_NAME="${CLUSTER_NAME}-eks-utils-x86-lt"

# 检查 Launch Template 是否已存在
if aws ec2 describe-launch-templates \
    --launch-template-names "${LT_NAME}" \
    --region "${AWS_REGION}" &>/dev/null; then

    echo "Launch Template ${LT_NAME} already exists, creating new version..."

    LT_ID=$(aws ec2 describe-launch-templates \
        --launch-template-names "${LT_NAME}" \
        --region "${AWS_REGION}" \
        --query 'LaunchTemplates[0].LaunchTemplateId' \
        --output text)

    # 创建新版本（不包含 IAM Instance Profile，由 eksctl 管理）
    echo "Creating Launch Template version without IAM Instance Profile (managed by eksctl)"
    LT_VERSION=$(aws ec2 create-launch-template-version \
        --launch-template-id "${LT_ID}" \
        --launch-template-data "{
          \"ImageId\": \"${AMI_ID}\",
          \"InstanceType\": \"m7i.large\",
          \"UserData\": \"$(base64 -w 0 < ${USERDATA_FILE})\",
          \"BlockDeviceMappings\": [
            {
              \"DeviceName\": \"/dev/xvda\",
              \"Ebs\": {
                \"VolumeSize\": 50,
                \"VolumeType\": \"gp3\",
                \"Encrypted\": true,
                \"DeleteOnTermination\": true
              }
            },
            {
              \"DeviceName\": \"/dev/xvdb\",
              \"Ebs\": {
                \"VolumeSize\": 100,
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
            \"HttpPutResponseHopLimit\": 1
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
    echo "Note: IAM Instance Profile will be managed by eksctl"

    LT_RESULT=$(aws ec2 create-launch-template \
        --launch-template-name "${LT_NAME}" \
        --launch-template-data "{
          \"ImageId\": \"${AMI_ID}\",
          \"InstanceType\": \"m7i.large\",
          \"UserData\": \"$(base64 -w 0 < ${USERDATA_FILE})\",
          \"BlockDeviceMappings\": [
            {
              \"DeviceName\": \"/dev/xvda\",
              \"Ebs\": {
                \"VolumeSize\": 50,
                \"VolumeType\": \"gp3\",
                \"Encrypted\": true,
                \"DeleteOnTermination\": true
              }
            },
            {
              \"DeviceName\": \"/dev/xvdb\",
              \"Ebs\": {
                \"VolumeSize\": 100,
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
            \"HttpPutResponseHopLimit\": 1
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

# 7. 删除现有节点组
echo ""
echo "Step 6: Checking and deleting existing eks-utils nodegroups..."

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
    echo "No existing nodegroups found, skipping deletion step"
else
    echo "Deleting ${#NODEGROUPS_TO_DELETE[@]} nodegroup(s)..."

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

    echo "✓ All nodegroups deleted"
fi

# 8. 创建引用 Launch Template 的节点组配置
echo ""
echo "Step 7: Creating nodegroup with Launch Template..."

# 检查节点组是否已存在
if aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name eks-utils-x86 \
    --region "${AWS_REGION}" &>/dev/null; then
    echo "Nodegroup eks-utils-x86 already exists, skipping creation"
    echo "If you want to recreate it, delete it first and run this script again"
    exit 0
fi

# 获取 AWS Account ID（用于 IAM Role ARN）
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

TEMP_CONFIG="/tmp/eksctl_ng_with_lt_$$.yaml"
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
  - name: eks-utils-x86
    # 引用外部创建的 Launch Template
    launchTemplate:
      id: ${LT_ID}
      version: ${LT_VERSION}
    # 使用已存在的 IAM Role（eksctl 会创建 Instance Profile）
    iam:
      instanceRoleARN: arn:aws:iam::${ACCOUNT_ID}:role/${NODE_ROLE_NAME}
    desiredCapacity: 3
    minSize: 3
    maxSize: 6
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

echo "Generated eksctl config:"
cat "${TEMP_CONFIG}"

echo ""
echo "Creating nodegroup with verbose logging..."
eksctl create nodegroup -f "${TEMP_CONFIG}" --verbose=4 2>&1 | tee /tmp/eksctl_create_nodegroup.log

rm -f "${TEMP_CONFIG}"

# 9. 等待节点就绪
echo ""
echo "Step 8: Waiting for nodes to be ready..."
sleep 15

RETRY_COUNT=0
MAX_RETRIES=60
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # 使用更可靠的方式计数节点
    READY_NODES=$(kubectl get nodes -l app=eks-utils --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
    # 确保是数字
    READY_NODES=${READY_NODES//[^0-9]/}
    READY_NODES=${READY_NODES:-0}

    echo "Ready nodes: ${READY_NODES}/3"

    if [ "$READY_NODES" -ge 3 ]; then
        echo "All nodes are ready!"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "ERROR: Timeout waiting for nodes"
        echo "Current node status:"
        kubectl get nodes -l app=eks-utils
        exit 1
    fi

    sleep 10
done

# 10. 验证 LVM
echo ""
echo "Step 9: Verifying LVM configuration..."

NODES=$(kubectl get nodes -l app=eks-utils -o jsonpath='{.items[*].metadata.name}')

for NODE in $NODES; do
    echo ""
    echo "Checking node: $NODE"

    kubectl debug node/$NODE -it --image=busybox:1.36 -- chroot /host bash -c '
        echo "=== Block Devices ==="
        lsblk
        echo ""
        echo "=== LVM Status ==="
        vgs 2>/dev/null || echo "No VGs"
        lvs 2>/dev/null || echo "No LVs"
        echo ""
        echo "=== Containerd Mount ==="
        df -h /var/lib/containerd
        echo ""
        echo "=== fstab Entry ==="
        grep containerd /etc/fstab 2>/dev/null || echo "No fstab entry"
        echo ""
        echo "=== LVM Setup Log ==="
        tail -20 /var/log/lvm-setup.log 2>/dev/null || echo "No LVM setup log"
    ' 2>/dev/null || echo "Warning: Failed to debug node"
done

# 10. 显示结果
echo ""
echo "=== Deployment Complete ==="
echo ""
kubectl get nodes -o wide

echo ""
echo "Launch Template Information:"
echo "  Name: ${LT_NAME}"
echo "  ID: ${LT_ID}"
echo "  Version: ${LT_VERSION}"
echo ""
echo "If LVM is configured correctly, you should see:"
echo "  - /dev/mapper/vg_data-lv_containerd mounted on /var/lib/containerd"
echo "  - Size: 100GB"
echo ""
