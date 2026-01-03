#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== EKS Cluster Installation with Cluster Autoscaler and EBS CSI Driver ==="

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 设置 KUBECONFIG 环境变量 (确保 kubectl 能找到配置文件)
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.5. 导入 Pod Identity helper 函数
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 1.6. 检查必需的依赖工具
echo "Checking required dependencies..."
MISSING_DEPS=()

command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v eksctl >/dev/null 2>&1 || MISSING_DEPS+=("eksctl")
command -v helm >/dev/null 2>&1 || MISSING_DEPS+=("helm")
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


# ===================================================================
# 主流程开始
# ===================================================================

# Validate VPC and subnets before cluster creation
echo "Validating AWS resources..."
validate_vpc_exists "${VPC_ID}" "${AWS_REGION}"
validate_subnets "${PRIVATE_SUBNETS}" "${VPC_ID}" "${AWS_REGION}"
echo ""

# 2. 创建EKS集群（控制平面）
echo "Step 2: Creating EKS cluster control plane..."

# 检查集群是否已存在
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "⚠️  Cluster '${CLUSTER_NAME}' already exists"
    echo "Skipping cluster creation..."
else
    echo "Creating new cluster..."
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        -e "s/\${K8S_VERSION}/$K8S_VERSION/g" \
        -e "s/\${SERVICE_IPV4_CIDR}/$SERVICE_IPV4_CIDR/g" \
        -e "s/\${VPC_ID}/$VPC_ID/g" \
        -e "s/\${AZ_A}/$AZ_A/g" \
        -e "s/\${AZ_B}/$AZ_B/g" \
        -e "s/\${AZ_C}/$AZ_C/g" \
        -e "s/\${PRIVATE_SUBNET_A}/$PRIVATE_SUBNET_A/g" \
        -e "s/\${PRIVATE_SUBNET_B}/$PRIVATE_SUBNET_B/g" \
        -e "s/\${PRIVATE_SUBNET_C}/$PRIVATE_SUBNET_C/g" \
        -e "s/\${PUBLIC_SUBNET_A}/$PUBLIC_SUBNET_A/g" \
        -e "s/\${PUBLIC_SUBNET_B}/$PUBLIC_SUBNET_B/g" \
        -e "s/\${PUBLIC_SUBNET_C}/$PUBLIC_SUBNET_C/g" \
        -e "s/\${SYSTEM_NODE_LABEL_KEY}/$SYSTEM_NODE_LABEL_KEY/g" \
        -e "s/\${SYSTEM_NODE_LABEL_VALUE}/$SYSTEM_NODE_LABEL_VALUE/g" \
        "${PROJECT_ROOT}/manifests/cluster/eksctl_cluster_template.yaml" > "${PROJECT_ROOT}/eksctl_cluster_final.yaml"
    eksctl create cluster -f "${PROJECT_ROOT}/eksctl_cluster_final.yaml"
fi

# 3. 等待集群控制平面就绪
echo ""
echo "Step 3: Waiting for cluster control plane to be ready..."
aws eks wait cluster-active --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
echo "✓ Cluster control plane is ready"

# 4. 完成
echo ""
echo "=== EKS Cluster Control Plane Created Successfully ==="
echo ""
echo "Cluster Information:"
echo "  Name: ${CLUSTER_NAME}"
echo "  Region: ${AWS_REGION}"
echo "  Version: ${K8S_VERSION}"
echo "  VPC ID: ${VPC_ID}"
echo ""
echo "⚠️  IMPORTANT: System nodegroup NOT created yet"
echo ""
echo "Next steps:"
echo "  1. Create system nodegroup with LVM (REQUIRED):"
echo "     ./scripts/6_create_system_nodegroup.sh"
echo ""
echo "  2. After nodegroup is ready, install addons:"
echo "     ./scripts/7_install_eks_addon.sh"
echo ""
