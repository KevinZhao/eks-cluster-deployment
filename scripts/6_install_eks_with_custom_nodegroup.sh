#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== EKS Cluster Installation with Custom Launch Template for App Nodegroup ==="

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.5. 导入 Pod Identity helper 函数
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 2. 检查是否提供了 SSH Key
if [ -z "$SSH_KEY_NAME" ]; then
    echo "Warning: SSH_KEY_NAME not set in .env file"
    echo "Nodes will be created without SSH key access"
    echo "Press Ctrl+C to cancel, or Enter to continue..."
    read
fi

# 3. 创建 Launch Template
echo "Step 1: Creating Launch Template with Terraform..."
cd "${PROJECT_ROOT}/terraform/launch-template"

# 创建 terraform.tfvars
cat > terraform.tfvars <<EOF
aws_region   = "${AWS_REGION}"
cluster_name = "${CLUSTER_NAME}"
k8s_version  = "${K8S_VERSION}"
vpc_id       = "${VPC_ID}"

# Instance Configuration
instance_type = "${APP_INSTANCE_TYPE:-c8g.large}"
key_name      = "${SSH_KEY_NAME}"

# Root Volume
root_volume_size       = ${ROOT_VOLUME_SIZE:-30}
root_volume_type       = "${ROOT_VOLUME_TYPE:-gp3}"
root_volume_iops       = ${ROOT_VOLUME_IOPS:-3000}
root_volume_throughput = ${ROOT_VOLUME_THROUGHPUT:-125}

# Data Volume
data_volume_size       = ${DATA_VOLUME_SIZE:-100}
data_volume_type       = "${DATA_VOLUME_TYPE:-gp3}"
data_volume_iops       = ${DATA_VOLUME_IOPS:-3000}
data_volume_throughput = ${DATA_VOLUME_THROUGHPUT:-125}

# Monitoring
enable_monitoring = ${ENABLE_MONITORING:-false}

# Custom User Data
custom_userdata = <<-EOT
${CUSTOM_USERDATA:-# No custom userdata}
EOT

common_tags = {
  Environment = "${ENVIRONMENT:-production}"
  ManagedBy   = "terraform"
  Project     = "${PROJECT_NAME:-eks-cluster}"
}
EOF

echo "Initializing Terraform..."
terraform init

echo "Creating Launch Template..."
terraform apply -auto-approve

# 获取 Launch Template 信息
LAUNCH_TEMPLATE_ID=$(terraform output -raw launch_template_id)
LAUNCH_TEMPLATE_VERSION=$(terraform output -raw launch_template_latest_version)

echo "Launch Template created: $LAUNCH_TEMPLATE_ID (version: $LAUNCH_TEMPLATE_VERSION)"

cd "${PROJECT_ROOT}"

# 4. 创建基础 EKS 集群（不包含 app nodegroup）
echo ""
echo "Step 2: Creating EKS cluster with eks-utils nodegroup..."
envsubst < "${PROJECT_ROOT}/manifests/cluster/eksctl_cluster_base.yaml" > "${PROJECT_ROOT}/eksctl_cluster_base_final.yaml"
eksctl create cluster -f "${PROJECT_ROOT}/eksctl_cluster_base_final.yaml"

# 5. 验证集群状态
echo ""
echo "Step 3: Checking cluster status..."
kubectl get nodes
kubectl get pods -A

# 6. 等待集群完全就绪
echo "Waiting for cluster to be fully ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# 6.5. 等待 Pod Identity Agent 就绪并设置组件
echo ""
echo "Step 3.5: Waiting for Pod Identity Agent..."
wait_for_pod_identity_agent

echo ""
echo "Step 3.6: Setting up Cluster Autoscaler with Pod Identity..."
setup_cluster_autoscaler_pod_identity

echo ""
echo "Step 3.7: Setting up EBS CSI Driver with Pod Identity..."
setup_ebs_csi_pod_identity

echo ""
echo "Step 3.8: Setting up AWS Load Balancer Controller with Pod Identity..."
setup_alb_controller_pod_identity

# 7. 创建 app nodegroup（使用自定义 Launch Template）
echo ""
echo "Step 4: Creating app nodegroup with custom Launch Template..."
export LAUNCH_TEMPLATE_ID
export LAUNCH_TEMPLATE_VERSION

# 注意：环境变量映射已在 0_setup_env.sh 中自动处理
# PRIVATE_SUBNET_2A 已自动映射为 PRIVATE_SUBNET_A

envsubst < "${PROJECT_ROOT}/manifests/cluster/eksctl_nodegroup_app.yaml" > "${PROJECT_ROOT}/eksctl_nodegroup_app_final.yaml"
eksctl create nodegroup -f "${PROJECT_ROOT}/eksctl_nodegroup_app_final.yaml"

# 8. 验证 app nodegroup
echo ""
echo "Step 5: Verifying app nodegroup..."
kubectl get nodes -l workload=user-apps --show-labels

# 9. 部署 Cluster Autoscaler RBAC
echo ""
echo "Step 6: Deploying Cluster Autoscaler RBAC..."
kubectl apply -f "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler-rbac.yaml"

# 10. 部署 Cluster Autoscaler
echo ""
echo "Step 7: Deploying Cluster Autoscaler..."
envsubst < "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler.yaml" | kubectl apply -f -

# 11. 验证 Cluster Autoscaler
echo "Checking Cluster Autoscaler status..."
kubectl wait --for=condition=available --timeout=300s deployment/cluster-autoscaler -n kube-system
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=10

# 12. 部署 AWS Load Balancer Controller
echo ""
echo "Step 8: Deploying AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=${CLUSTER_NAME} \
    --set serviceAccount.create=false \
    --set vpcId=${VPC_ID} \
    --set region=${AWS_DEFAULT_REGION} \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set nodeSelector.app=eks-utils \
    --version 1.13.0

# 13. 验证组件
echo ""
echo "Step 9: Verifying all components..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=10

echo ""
echo "Checking EBS CSI Driver..."
kubectl get pods -n kube-system -l app=ebs-csi-controller

echo ""
echo "Listing all Pod Identity Associations..."
list_pod_identity_associations

# 16. 显示最终状态
echo ""
echo "=== Installation Complete ==="
echo ""
echo "Cluster Information:"
echo "  Cluster Name: ${CLUSTER_NAME}"
echo "  Region: ${AWS_DEFAULT_REGION}"
echo "  Kubernetes Version: ${K8S_VERSION}"
echo ""
echo "Nodegroups:"
echo "  - eks-utils: System components (Intel m7i.large)"
echo "  - app: Application workloads (Graviton c8g.large) with custom launch template"
echo ""
echo "Launch Template:"
echo "  ID: ${LAUNCH_TEMPLATE_ID}"
echo "  Version: ${LAUNCH_TEMPLATE_VERSION}"
echo ""
echo "Authentication:"
echo "  - All components use Pod Identity (for AWS authentication)"
echo "  - Cluster Autoscaler, EBS CSI Driver, and AWS LB Controller configured"
echo ""
echo "Next steps:"
echo "  1. Check nodes: kubectl get nodes --show-labels"
echo "  2. Check all pods: kubectl get pods -A"
echo "  3. Deploy test app: kubectl apply -f manifests/examples/autoscaler.yaml"
echo "  4. Optional: Install EFS/S3 CSI drivers with ./scripts/7_install_optional_csi_drivers.sh"
echo ""
echo "To update Launch Template:"
echo "  1. cd terraform/launch-template"
echo "  2. Edit terraform.tfvars"
echo "  3. terraform apply"
echo "  4. Update nodegroup: eksctl upgrade nodegroup --cluster=${CLUSTER_NAME} --name=app --region=${AWS_DEFAULT_REGION}"
echo ""
