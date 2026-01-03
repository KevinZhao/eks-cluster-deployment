#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== EKS Addons Installation (Cluster Autoscaler, Load Balancer Controller, EBS CSI Driver) ==="

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 设置 KUBECONFIG 环境变量 (确保 kubectl 能找到配置文件)
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.2. 导入 Pod Identity helper 函数
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 1.3. 检查必需的依赖工具
echo "Checking required dependencies..."
MISSING_DEPS=()

command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v aws >/dev/null 2>&1 || MISSING_DEPS+=("aws cli")
command -v helm >/dev/null 2>&1 || MISSING_DEPS+=("helm")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")

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

# 2. 验证集群存在并更新 kubeconfig
echo "Verifying EKS cluster exists and updating kubeconfig..."
validate_eks_cluster_exists "${CLUSTER_NAME}" "${AWS_REGION}"

# 验证 kubectl context（使用统一函数）
verify_kubectl_context
echo ""
echo "Note: Security group configuration for bastion access should have been"
echo "      completed in script 6_create_system_nodegroup.sh"
echo ""

# 3. 验证集群状态
echo "Checking cluster status..."
echo "Note: If cluster uses private-only access, kubectl may timeout. This is expected."
timeout 10 kubectl get nodes || echo "Warning: kubectl timeout - using AWS CLI to verify cluster"
timeout 10 kubectl get pods -A || aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.status'

# 3.1. 等待 Pod Identity Agent 就绪
echo ""
echo "Step 3.1: Waiting for Pod Identity Agent..."
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
sed -e "s|\${CLUSTER_NAME}|$CLUSTER_NAME|g" \
    -e "s|\${AWS_REGION}|$AWS_REGION|g" \
    -e "s|\${CLUSTER_AUTOSCALER_VERSION}|$CLUSTER_AUTOSCALER_VERSION|g" \
    -e "s|\${SYSTEM_NODE_LABEL_KEY}|$SYSTEM_NODE_LABEL_KEY|g" \
    -e "s|\${SYSTEM_NODE_LABEL_VALUE}|$SYSTEM_NODE_LABEL_VALUE|g" \
    "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler.yaml" | kubectl apply -f -

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
    --set "nodeSelector.${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE}" \
    --set replicaCount=2 \
    --set podDisruptionBudget.minAvailable=1 \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.memory=256Mi \
    --set "affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchLabels.app\.kubernetes\.io/name=aws-load-balancer-controller" \
    --set "affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey=kubernetes.io/hostname" \
    --version "${ALB_CONTROLLER_CHART_VERSION}"

# 5.2 验证 Load Balancer Controller
echo "Testing AWS Load Balancer Controller..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=10

# 6. 设置 EBS CSI Driver Pod Identity
echo ""
echo "Step 6: Setting up EBS CSI Driver with Pod Identity..."
setup_ebs_csi_pod_identity

# 6.1 安装 EBS CSI Driver Addon
echo "Installing EBS CSI Driver addon..."
EBS_CSI_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-ebs-csi-driver-role"

# 创建 addon 配置 - 确保 controller 运行在系统节点上（使用 mktemp 避免临时文件冲突）
EBS_CSI_CONFIG_FILE=$(mktemp /tmp/ebs-csi-addon-config.XXXXXX.json)
trap "rm -f ${EBS_CSI_CONFIG_FILE}" EXIT

cat > "${EBS_CSI_CONFIG_FILE}" <<EOF
{
  "controller": {
    "nodeSelector": {
      "${SYSTEM_NODE_LABEL_KEY}": "${SYSTEM_NODE_LABEL_VALUE}"
    }
  }
}
EOF

echo "EBS CSI Driver will be configured to run on system nodes (${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE})"

# 检查 addon 是否已存在
if aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name aws-ebs-csi-driver --region ${AWS_REGION} &>/dev/null; then
    echo "EBS CSI Driver addon already exists, updating..."
    aws eks update-addon \
        --cluster-name ${CLUSTER_NAME} \
        --addon-name aws-ebs-csi-driver \
        --service-account-role-arn ${EBS_CSI_ROLE_ARN} \
        --configuration-values "file://${EBS_CSI_CONFIG_FILE}" \
        --region ${AWS_REGION} \
        --resolve-conflicts OVERWRITE || echo "Update may have failed, but continuing..."
else
    echo "Creating EBS CSI Driver addon..."
    aws eks create-addon \
        --cluster-name ${CLUSTER_NAME} \
        --addon-name aws-ebs-csi-driver \
        --service-account-role-arn ${EBS_CSI_ROLE_ARN} \
        --configuration-values "file://${EBS_CSI_CONFIG_FILE}" \
        --region ${AWS_REGION} \
        --resolve-conflicts OVERWRITE
fi

# 清理临时文件
rm -f "${EBS_CSI_CONFIG_FILE}"

# 6.2 等待 addon 就绪
wait_for_eks_addon "aws-ebs-csi-driver"

# 6.3 清理 IRSA annotation 避免与 Pod Identity 冲突
echo "Removing IRSA annotation from service account (if exists)..."
kubectl annotate sa -n kube-system ebs-csi-controller-sa eks.amazonaws.com/role-arn- --overwrite 2>/dev/null || echo "No IRSA annotation to remove"

# 6.4 重启 EBS CSI Controller 使 Pod Identity 生效
echo "Checking if EBS CSI Controller needs restart..."
# 只有在 IRSA annotation 被移除或 addon 刚刚创建时才重启
if kubectl get sa -n kube-system ebs-csi-controller-sa -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null | grep -q "arn:aws"; then
    echo "IRSA annotation still exists, restarting controller..."
    kubectl rollout restart deployment/ebs-csi-controller -n kube-system
    kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=120s
else
    echo "✓ EBS CSI Controller already using Pod Identity, no restart needed"
    # 但仍然等待部署就绪
    kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=120s
fi

# 6.5 验证 EBS CSI Driver
echo "Checking EBS CSI Driver pods..."
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# 6.6 创建自定义 StorageClass
echo ""
echo "Step 6.6: Creating custom StorageClasses (gp3, io2)..."
echo "Applying gp3 and io2 StorageClasses with IO2_IOPS=${IO2_IOPS}..."
sed -e "s/\${IO2_IOPS}/$IO2_IOPS/g" \
    "${PROJECT_ROOT}/manifests/storage/storageclass.yaml" | kubectl apply -f -

# 6.7 将 gp3 设为默认 StorageClass 并清理旧的 gp2
echo "Setting gp3 as default StorageClass..."

# 删除旧的 gp2 StorageClass (in-tree provisioner, 已废弃)
if kubectl get storageclass gp2 &>/dev/null; then
    echo "Removing deprecated gp2 StorageClass (in-tree provisioner)..."
    kubectl delete storageclass gp2 || echo "Warning: Failed to delete gp2, may have PVs using it"
    echo "✓ Deprecated gp2 StorageClass removed"
fi

echo "✓ StorageClasses configured:"
kubectl get storageclass

# 6.8 安装 Metrics Server (EKS Managed Addon)
echo ""
echo "Step 6.8: Installing Metrics Server addon..."

# 创建 metrics-server addon 配置（确保运行在系统节点上）
METRICS_SERVER_CONFIG_FILE=$(mktemp /tmp/metrics-server-config.XXXXXX.json)
cat > "${METRICS_SERVER_CONFIG_FILE}" <<EOF
{
  "nodeSelector": {
    "${SYSTEM_NODE_LABEL_KEY}": "${SYSTEM_NODE_LABEL_VALUE}"
  }
}
EOF

# 检查 addon 是否已存在
if aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name metrics-server --region ${AWS_REGION} &>/dev/null; then
    echo "Metrics Server addon already exists, updating..."
    aws eks update-addon \
        --cluster-name ${CLUSTER_NAME} \
        --addon-name metrics-server \
        --configuration-values "file://${METRICS_SERVER_CONFIG_FILE}" \
        --region ${AWS_REGION} \
        --resolve-conflicts OVERWRITE || echo "Update may have failed, but continuing..."
else
    echo "Creating Metrics Server addon..."
    aws eks create-addon \
        --cluster-name ${CLUSTER_NAME} \
        --addon-name metrics-server \
        --configuration-values "file://${METRICS_SERVER_CONFIG_FILE}" \
        --region ${AWS_REGION} \
        --resolve-conflicts OVERWRITE
fi

rm -f "${METRICS_SERVER_CONFIG_FILE}"

# 等待 addon 就绪
wait_for_eks_addon "metrics-server"

# 验证 metrics 功能
echo "Verifying Metrics Server functionality..."
sleep 10
if kubectl top nodes &>/dev/null; then
    echo "✓ Metrics Server is working correctly"
    kubectl top nodes
else
    echo "Note: Metrics Server may need more time to collect metrics (this is normal on first install)"
    echo "You can verify later with: kubectl top nodes"
fi

# 7. 最终验证
echo ""
echo "Step 7: Verifying all Pod Identity Associations..."
list_pod_identity_associations

echo ""
echo "=== EKS Addons Installation Complete ==="
echo "✓ Cluster Autoscaler installed and configured"
echo "✓ AWS Load Balancer Controller installed and configured"
echo "✓ EBS CSI Driver addon installed and configured"
echo "✓ Metrics Server installed and configured"
echo "✓ StorageClasses configured: gp3 (default), io2 (deprecated gp2 removed)"
echo "✓ All components use Pod Identity for AWS authentication"
echo ""
echo "Next steps:"
echo "  1. Check nodes: kubectl get nodes --show-labels"
echo "  2. Check all pods: kubectl get pods -A"
echo "  3. Verify metrics: kubectl top nodes"
echo "  4. Deploy test app: kubectl apply -f manifests/examples/autoscaler.yaml"
echo "  5. Optional: Install EFS/S3 CSI drivers with ./scripts/option_install_csi_drivers.sh"
echo "  6. Optional: Install Karpenter with ./scripts/option_install_karpenter.sh"
echo ""