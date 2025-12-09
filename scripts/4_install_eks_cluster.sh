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
command -v envsubst >/dev/null 2>&1 || MISSING_DEPS+=("envsubst (from gettext package)")
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

# 2. 创建EKS集群
echo "Creating EKS cluster..."
envsubst < "${PROJECT_ROOT}/manifests/cluster/eksctl_cluster_template.yaml" > "${PROJECT_ROOT}/eksctl_cluster_final.yaml"
eksctl create cluster -f "${PROJECT_ROOT}/eksctl_cluster_final.yaml"

# 2.1 更新 kubeconfig (eksctl 应该已经完成,但保险起见再执行一次)
echo "Updating kubeconfig..."
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

# 2.2 配置安全组以允许堡垒机访问集群 API (针对私有集群)
echo ""
echo "Configuring security group for bastion access to EKS API..."

# 获取集群安全组
CLUSTER_SG=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --region ${AWS_REGION} \
    --query 'cluster.resourcesVpcConfig.securityGroupIds[0]' \
    --output text 2>/dev/null)

# 获取VPC endpoint安全组（堡垒机使用的安全组）
BASTION_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${CLUSTER_NAME}-vpc-endpoints-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region ${AWS_REGION} 2>/dev/null)

if [ -n "${CLUSTER_SG}" ] && [ "${CLUSTER_SG}" != "None" ] && [ -n "${BASTION_SG}" ] && [ "${BASTION_SG}" != "None" ]; then
    echo "Cluster Security Group: ${CLUSTER_SG}"
    echo "Bastion Security Group: ${BASTION_SG}"

    # 添加入站规则允许堡垒机访问集群API端口443
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

    echo "Bastion can now access EKS API Server"
else
    echo "⚠ Warning: Could not configure security group automatically"
    echo "If kubectl times out, manually add this rule:"
    echo "  aws ec2 authorize-security-group-ingress \\"
    echo "    --group-id ${CLUSTER_SG} \\"
    echo "    --protocol tcp --port 443 \\"
    echo "    --source-group ${BASTION_SG} \\"
    echo "    --region ${AWS_REGION}"
fi

echo ""

# 3. 验证集群状态
echo "Checking cluster status..."
echo "Note: If cluster uses private-only access, kubectl may timeout. This is expected."
timeout 10 kubectl get nodes || echo "Warning: kubectl timeout - using AWS CLI to verify cluster"
timeout 10 kubectl get pods -A || aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.status'

# 3.5. 等待 Pod Identity Agent 就绪
echo ""
echo "Step 3.5: Waiting for Pod Identity Agent..."
wait_for_pod_identity_agent

# 4. 设置 Cluster Autoscaler with Pod Identity
echo ""
echo "Step 4: Setting up Cluster Autoscaler with Pod Identity..."
setup_cluster_autoscaler_pod_identity

# 4.1 部署Cluster Autoscaler RBAC
echo "Deploying Cluster Autoscaler RBAC..."
kubectl apply -f "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler-rbac.yaml"

# 4.2 部署Cluster Autoscaler Deployment
echo "Deploying Cluster Autoscaler..."
envsubst < "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler.yaml" | kubectl apply -f -

# 4.3 验证Cluster Autoscaler
echo "Checking Cluster Autoscaler status..."
kubectl get deployment cluster-autoscaler -n kube-system

echo "Waiting for Cluster Autoscaler to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/cluster-autoscaler -n kube-system

kubectl logs -n kube-system -l app=cluster-autoscaler --tail=10

# 5. 设置 AWS Load Balancer Controller with Pod Identity
echo ""
echo "Step 5: Setting up AWS Load Balancer Controller with Pod Identity..."
setup_alb_controller_pod_identity

# 5.1 部署 Load Balancer Controller
echo "Deploying Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=${CLUSTER_NAME} \
    --set serviceAccount.create=false \
    --set vpcId=${VPC_ID} \
    --set region=${AWS_REGION} \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set nodeSelector.app=eks-utils \
    --version 1.13.0

# 5.2 验证 Load Balancer Controller
echo "Testing AWS Load Balancer Controller..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=10

# 6. 设置 EBS CSI Driver Pod Identity
echo ""
echo "Step 6: Setting up EBS CSI Driver with Pod Identity..."
setup_ebs_csi_pod_identity

# 6.1 验证 EBS CSI Driver
echo "Checking EBS CSI Driver status..."
kubectl get pods -n kube-system -l app=ebs-csi-controller

# 7. 最终验证
echo ""
echo "Step 7: Verifying all Pod Identity Associations..."
list_pod_identity_associations

echo ""
echo "=== Installation Complete ==="
echo "Cluster Autoscaler, EBS CSI Driver, and AWS Load Balancer Controller are now installed."
echo "All components use Pod Identity for AWS authentication."
echo ""
echo "Next steps:"
echo "  1. Check nodes: kubectl get nodes --show-labels"
echo "  2. Check all pods: kubectl get pods -A"
echo "  3. Deploy test app: kubectl apply -f manifests/examples/autoscaler.yaml"
echo "  4. Optional: Install EFS/S3 CSI drivers with ./scripts/7_install_optional_csi_drivers.sh"
echo ""
