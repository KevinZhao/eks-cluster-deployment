#!/bin/bash

set -e

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "================================================"
echo "Spider Example - EKS Cluster Deployment"
echo "================================================"
echo ""
echo "This will deploy an EKS cluster with:"
echo "  - Custom SSH Key: spider"
echo "  - 1000GB data disk mounted at /data"
echo "  - Pre-installed tools for web scraping"
echo "  - Optimized system configuration"
echo ""

# 1. 检查 spider key 是否存在
echo "Step 0: Checking prerequisites..."
if ! aws ec2 describe-key-pairs --key-names spider --region ap-southeast-1 >/dev/null 2>&1; then
    echo ""
    echo "❌ ERROR: SSH key 'spider' not found in AWS!"
    echo ""
    echo "Please create the key pair first:"
    echo "  Option 1 - Import existing key:"
    echo "    aws ec2 import-key-pair --key-name spider --public-key-material fileb://~/.ssh/spider.pem.pub --region ap-southeast-1"
    echo ""
    echo "  Option 2 - Create new key:"
    echo "    aws ec2 create-key-pair --key-name spider --region ap-southeast-1 --query 'KeyMaterial' --output text > spider.pem"
    echo "    chmod 400 spider.pem"
    echo ""
    exit 1
else
    echo "✓ SSH key 'spider' found"
fi

# 2. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 2.5. 导入 Pod Identity helper 函数
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 3. 创建 Launch Template
echo ""
echo "================================================"
echo "Step 1: Creating Launch Template for Spider nodes"
echo "================================================"
cd "${PROJECT_ROOT}/terraform/launch-template"

# 复制 spider 示例配置
cp terraform.tfvars.spider-example terraform.tfvars

echo "Launch Template Configuration:"
echo "  - Instance Type: c8g.large (ARM64 Graviton3)"
echo "  - SSH Key: spider"
echo "  - Root Volume: 30GB gp3"
echo "  - Data Volume: 1000GB gp3"
echo "  - Custom UserData: Pre-installed scraping tools"
echo ""

read -p "Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 1
fi

echo "Initializing Terraform..."
terraform init

echo "Planning Terraform changes..."
terraform plan

echo "Creating Launch Template..."
terraform apply -auto-approve

# 获取 Launch Template 信息
LAUNCH_TEMPLATE_ID=$(terraform output -raw launch_template_id)
LAUNCH_TEMPLATE_VERSION=$(terraform output -raw launch_template_latest_version)

echo ""
echo "✓ Launch Template created successfully!"
echo "  ID: $LAUNCH_TEMPLATE_ID"
echo "  Version: $LAUNCH_TEMPLATE_VERSION"

cd "${PROJECT_ROOT}"

# 4. 创建基础 EKS 集群
echo ""
echo "================================================"
echo "Step 2: Creating EKS Cluster"
echo "================================================"
echo "This will take approximately 15-20 minutes..."
echo ""

envsubst < "${PROJECT_ROOT}/manifests/cluster/eksctl_cluster_base.yaml" > "${PROJECT_ROOT}/eksctl_cluster_base_final.yaml"

echo "Starting cluster creation..."
eksctl create cluster -f "${PROJECT_ROOT}/eksctl_cluster_base_final.yaml"

echo "✓ Base cluster created successfully!"

# 5. 验证集群
echo ""
echo "================================================"
echo "Step 3: Verifying Cluster"
echo "================================================"

echo "Nodes:"
kubectl get nodes --show-labels

echo ""
echo "Pods:"
kubectl get pods -A

echo ""
echo "Waiting for all nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "✓ Cluster is ready!"

# 5.5. 等待 Pod Identity Agent 就绪并设置组件
echo ""
echo "================================================"
echo "Step 3.5: Setting up Pod Identity for AWS Components"
echo "================================================"

wait_for_pod_identity_agent

echo ""
echo "Setting up Cluster Autoscaler with Pod Identity..."
setup_cluster_autoscaler_pod_identity

echo ""
echo "Setting up EBS CSI Driver with Pod Identity..."
setup_ebs_csi_pod_identity

echo ""
echo "Setting up AWS Load Balancer Controller with Pod Identity..."
setup_alb_controller_pod_identity

echo "✓ Pod Identity setup complete!"

# 6. 创建 Spider nodegroup
echo ""
echo "================================================"
echo "Step 4: Creating Spider Nodegroup"
echo "================================================"
echo "This will take approximately 5-10 minutes..."
echo ""

export LAUNCH_TEMPLATE_ID
export LAUNCH_TEMPLATE_VERSION

# 注意：环境变量映射已在 0_setup_env.sh 中自动处理
# PRIVATE_SUBNET_2A 已自动映射为 PRIVATE_SUBNET_A

envsubst < "${PROJECT_ROOT}/manifests/cluster/eksctl_nodegroup_app.yaml" > "${PROJECT_ROOT}/eksctl_nodegroup_spider_final.yaml"

echo "Starting Spider nodegroup creation..."
eksctl create nodegroup -f "${PROJECT_ROOT}/eksctl_nodegroup_spider_final.yaml"

echo "✓ Spider nodegroup created successfully!"

# 7. 验证 Spider nodes
echo ""
echo "================================================"
echo "Step 5: Verifying Spider Nodes"
echo "================================================"

echo "Spider nodes:"
kubectl get nodes -l workload=user-apps -o wide

echo ""
echo "Checking node details..."
SPIDER_NODE=$(kubectl get nodes -l workload=user-apps -o jsonpath='{.items[0].metadata.name}')
kubectl describe node $SPIDER_NODE | grep -A 10 "Labels:"

# 8. 部署 Cluster Autoscaler
echo ""
echo "================================================"
echo "Step 6: Deploying Cluster Autoscaler"
echo "================================================"

kubectl apply -f "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler-rbac.yaml"
envsubst < "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler.yaml" | kubectl apply -f -

echo "Waiting for Cluster Autoscaler to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/cluster-autoscaler -n kube-system
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=10

echo "✓ Cluster Autoscaler deployed!"

# 9. 部署 AWS Load Balancer Controller
echo ""
echo "================================================"
echo "Step 7: Deploying AWS Load Balancer Controller"
echo "================================================"

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

echo "Waiting for AWS Load Balancer Controller to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=10

echo "✓ AWS Load Balancer Controller deployed!"

# 10. 验证所有 Pod Identity Associations
echo ""
echo "================================================"
echo "Step 8: Verifying Pod Identity Associations"
echo "================================================"

list_pod_identity_associations

echo "✓ All Pod Identity Associations configured!"

# 11. 显示最终信息
echo ""
echo "================================================"
echo "🎉 Deployment Completed Successfully!"
echo "================================================"
echo ""
echo "Cluster Information:"
echo "  Cluster Name: ${CLUSTER_NAME}"
echo "  Region: ${AWS_DEFAULT_REGION}"
echo "  Kubernetes Version: ${K8S_VERSION}"
echo ""
echo "Nodegroups:"
echo "  ✓ eks-utils: 3 nodes (Intel m7i.large) - System components"
echo "  ✓ app (Spider): 3 nodes (Graviton c8g.large) - Application workloads"
echo ""
echo "Launch Template:"
echo "  ID: ${LAUNCH_TEMPLATE_ID}"
echo "  Version: ${LAUNCH_TEMPLATE_VERSION}"
echo "  SSH Key: spider"
echo "  Data Disk: 1000GB mounted at /data"
echo ""
echo "Authentication:"
echo "  ✓ All components use Pod Identity for AWS authentication"
echo "  ✓ Cluster Autoscaler, EBS CSI Driver, AWS LB Controller configured"
echo ""
echo "================================================"
echo "Quick Access Commands:"
echo "================================================"
echo ""
echo "# List all nodes"
echo "kubectl get nodes -o wide"
echo ""
echo "# List Spider nodes"
echo "kubectl get nodes -l workload=user-apps"
echo ""
echo "# SSH to a Spider node (using SSM)"
echo "INSTANCE_ID=\$(aws ec2 describe-instances --filters \"Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned\" \"Name=tag:Name,Values=*app-node*\" --query 'Reservations[0].Instances[0].InstanceId' --output text)"
echo "aws ssm start-session --target \$INSTANCE_ID"
echo ""
echo "# Or using SSH (if security group allows)"
echo "NODE_IP=\$(kubectl get nodes -l workload=user-apps -o jsonpath='{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}')"
echo "ssh -i spider.pem ec2-user@\$NODE_IP"
echo ""
echo "================================================"
echo "Verify Spider Node Configuration:"
echo "================================================"
echo ""
echo "# Check if data disk is mounted"
echo "kubectl debug node/$SPIDER_NODE -it --image=busybox -- df -h"
echo ""
echo "# View node initialization log"
echo "aws ssm start-session --target \$INSTANCE_ID"
echo "# Then run: cat /var/log/spider-node-init.log"
echo ""
echo "# Check Spider configuration"
echo "# cat /data/spider/config/spider.conf"
echo ""
echo "# Run health check"
echo "# /usr/local/bin/spider-monitor.sh"
echo ""
echo "================================================"
echo "Next Steps:"
echo "================================================"
echo ""
echo "1. Deploy your Spider application:"
echo "   kubectl apply -f your-spider-deployment.yaml"
echo ""
echo "2. Test autoscaling:"
echo "   kubectl apply -f manifests/examples/autoscaler.yaml"
echo "   kubectl scale deployment autoscaler-test --replicas=10"
echo ""
echo "3. View logs:"
echo "   kubectl logs -n kube-system -l app=cluster-autoscaler --tail=20"
echo ""
echo "4. Access node via SSM Session Manager (no SSH needed):"
echo "   aws ssm start-session --target <instance-id>"
echo ""
echo "================================================"
echo "Estimated Monthly Cost:"
echo "================================================"
echo "  EKS Control Plane:           \$72.00"
echo "  eks-utils (3x m7i.large):   \$263.00"
echo "  app (3x c8g.large):          \$180.00"
echo "  Root volumes (6x 30GB):       \$18.00"
echo "  Data volumes (3x 1000GB):    \$300.00"
echo "  NAT Gateways (3):             \$96.00"
echo "  CloudWatch Logs:              \$30.00"
echo "  ─────────────────────────────────────"
echo "  Total (approximate):         \$959.00/month"
echo ""
echo "💡 Tip: Use Spot instances for app nodes to save ~70%"
echo "================================================"
