#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== EKS Cluster Installation with Cluster Autoscaler and EBS CSI Driver ==="

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 2. 创建EKS集群
echo "Creating EKS cluster..."
envsubst < "${PROJECT_ROOT}/manifests/cluster/eksctl_cluster_template.yaml" > "${PROJECT_ROOT}/eksctl_cluster_final.yaml"
eksctl create cluster -f "${PROJECT_ROOT}/eksctl_cluster_final.yaml"

# 3. 验证集群状态
echo "Checking cluster status..."
kubectl get nodes
kubectl get pods -A

# 4. 部署Cluster Autoscaler RBAC
echo "Deploying Cluster Autoscaler RBAC..."
kubectl apply -f "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler-rbac.yaml"

# 5. 部署Cluster Autoscaler
echo "Deploying Cluster Autoscaler..."
envsubst < "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler.yaml" | kubectl apply -f -

# 6. 验证Cluster Autoscaler
echo "Checking Cluster Autoscaler status..."
kubectl get deployment cluster-autoscaler -n kube-system

echo "Waiting for Cluster Autoscaler to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/cluster-autoscaler -n kube-system

kubectl logs -n kube-system -l app=cluster-autoscaler --tail=5

# 7. 安装AWS Load Balancer Controller
echo "Installing AWS Load Balancer Controller..."

# 下载IAM policy
curl -o "${PROJECT_ROOT}/iam_policy.json" https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/install/iam_policy.json

# 创建policy
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME} \
    --policy-document file://${PROJECT_ROOT}/iam_policy.json || echo "Policy already exists"

# 创建service account
eksctl create iamserviceaccount \
    --cluster=${CLUSTER_NAME} \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME} \
    --override-existing-serviceaccounts \
    --region ${AWS_DEFAULT_REGION} \
    --role-name AWSLoadBalancerControllerRole-${CLUSTER_NAME} \
    --approve

# 部署load balancer controller
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

# 8. 验证EBS CSI Driver
echo "Step 8: Checking EBS CSI Driver..."
kubectl get pods -n kube-system -l app=ebs-csi-controller

# 9. 迁移到Pod Identity (推荐)
echo "Step 9: Migrating addons to Pod Identity..."
eksctl utils migrate-to-pod-identity --cluster=${CLUSTER_NAME} --region=${AWS_DEFAULT_REGION} --approve

# 10. 测试AWS Load Balancer Controller
echo "Step 10: Testing AWS Load Balancer Controller..."
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=5

echo "Step 10: Deploying test application for Load Balancer Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/examples/2048/2048_full.yaml

echo "Step 10: Waiting for ingress to be ready..."
sleep 30
kubectl get ingress -n game-2048

echo "=== Installation Complete ==="
echo "Cluster Autoscaler, EBS CSI Driver, and AWS Load Balancer Controller are now installed and configured."
echo "All components have been migrated to Pod Identity for better security."
