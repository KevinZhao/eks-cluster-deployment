#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Installing Karpenter on EKS Cluster ==="

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 设置 KUBECONFIG 环境变量
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.5. 导入 Pod Identity helper 函数
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 2. 验证集群存在并更新 kubeconfig
echo "Step 1: Checking if cluster exists and updating kubeconfig..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "❌ ERROR: Cluster ${CLUSTER_NAME} does not exist"
    exit 1
fi

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
echo "✓ Cluster ${CLUSTER_NAME} exists and kubeconfig updated"

# 2.5. 验证kubectl访问权限
echo ""
echo "Step 1.5: Verifying kubectl access to cluster..."
if ! kubectl get nodes &>/dev/null; then
    echo "❌ ERROR: Cannot access cluster with kubectl"
    echo ""
    echo "This usually means:"
    echo "  1. You don't have permission to access the cluster"
    echo "  2. Security groups are not configured correctly"
    echo "  3. You're not running from within the VPC"
    echo ""
    echo "If running from a bastion host, ensure:"
    echo "  - Bastion security group can access EKS API (port 443)"
    echo "  - Bastion IAM role has EKS cluster access"
    echo ""
    echo "To configure access, run: ./scripts/create_bastion.sh"
    exit 1
fi
echo "✓ kubectl access verified"

# 3. 获取集群信息
echo ""
echo "Step 2: Getting cluster information..."
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "cluster.endpoint" --output text)
OIDC_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

echo "  Cluster Endpoint: ${CLUSTER_ENDPOINT}"
echo "  OIDC Endpoint: ${OIDC_ENDPOINT}"
echo "  AWS Account ID: ${AWS_ACCOUNT_ID}"

# 4. 设置 Karpenter 版本
KARPENTER_VERSION="${KARPENTER_VERSION:-1.8.3}"
echo ""
echo "Step 3: Installing Karpenter version ${KARPENTER_VERSION}..."

# 5. 创建 Karpenter Node IAM Role
echo ""
echo "Step 4: Creating Karpenter Node IAM Role..."

KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"

# 检查角色是否已存在
if aws iam get-role --role-name "${KARPENTER_NODE_ROLE}" &>/dev/null; then
    echo "  Role ${KARPENTER_NODE_ROLE} already exists, skipping creation"
else
    echo "  Creating IAM role ${KARPENTER_NODE_ROLE}..."

    # 创建信任策略
    cat > /tmp/karpenter-node-trust-policy.json <<EOF
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
        --role-name "${KARPENTER_NODE_ROLE}" \
        --assume-role-policy-document file:///tmp/karpenter-node-trust-policy.json \
        --tags \
            Key=ManagedBy,Value=karpenter \
            Key=Cluster,Value="${CLUSTER_NAME}" \
            Key=business,Value=middleware \
            Key=resource,Value=eks

    # 附加必需的策略
    aws iam attach-role-policy \
        --role-name "${KARPENTER_NODE_ROLE}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"

    aws iam attach-role-policy \
        --role-name "${KARPENTER_NODE_ROLE}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

    aws iam attach-role-policy \
        --role-name "${KARPENTER_NODE_ROLE}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

    aws iam attach-role-policy \
        --role-name "${KARPENTER_NODE_ROLE}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

    echo "  ✓ IAM role ${KARPENTER_NODE_ROLE} created successfully"
fi

# 创建 Instance Profile（如果不存在）
echo "  Creating Instance Profile for ${KARPENTER_NODE_ROLE}..."
if ! aws iam get-instance-profile --instance-profile-name "${KARPENTER_NODE_ROLE}" &>/dev/null; then
    aws iam create-instance-profile \
        --instance-profile-name "${KARPENTER_NODE_ROLE}" \
        --tags \
            Key=ManagedBy,Value=karpenter \
            Key=Cluster,Value="${CLUSTER_NAME}" \
            Key=business,Value=middleware \
            Key=resource,Value=eks

    aws iam add-role-to-instance-profile \
        --instance-profile-name "${KARPENTER_NODE_ROLE}" \
        --role-name "${KARPENTER_NODE_ROLE}"

    echo "  ✓ Instance Profile ${KARPENTER_NODE_ROLE} created successfully"
else
    echo "  Instance Profile ${KARPENTER_NODE_ROLE} already exists"
fi

# 6. 创建 Karpenter Controller IAM Policy
echo ""
echo "Step 5: Creating Karpenter Controller IAM Policy..."

KARPENTER_CONTROLLER_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"

# 生成策略文档
cat > /tmp/karpenter-controller-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate",
        "ec2:CreateTags",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:DeleteLaunchTemplate"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster"
      ],
      "Resource": "arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:SetQueueAttributes",
        "sqs:TagQueue"
      ],
      "Resource": "arn:aws:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:Karpenter-${CLUSTER_NAME}-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "events:PutRule",
        "events:PutTargets",
        "events:DeleteRule",
        "events:RemoveTargets",
        "events:DescribeRule"
      ],
      "Resource": [
        "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/KarpenterInterruptionQueue-${CLUSTER_NAME}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "pricing:GetProducts"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:GetInstanceProfile",
        "iam:CreateInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:ListInstanceProfiles",
        "iam:ListInstanceProfileTags"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# 检查策略是否已存在
if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" &>/dev/null; then
    echo "  Policy ${KARPENTER_CONTROLLER_POLICY} already exists, updating to latest version..."

    # 创建新版本并设为默认
    aws iam create-policy-version \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}" \
        --policy-document file:///tmp/karpenter-controller-policy.json \
        --set-as-default

    echo "  ✓ IAM policy updated to new version"
else
    echo "  Creating IAM policy ${KARPENTER_CONTROLLER_POLICY}..."

    aws iam create-policy \
        --policy-name "${KARPENTER_CONTROLLER_POLICY}" \
        --policy-document file:///tmp/karpenter-controller-policy.json \
        --tags Key=ManagedBy,Value=karpenter Key=Cluster,Value="${CLUSTER_NAME}"

    echo "  ✓ IAM policy ${KARPENTER_CONTROLLER_POLICY} created successfully"
fi

# 7. 创建 Karpenter Controller IAM Role
echo ""
echo "Step 6: Creating Karpenter Controller IAM Role..."

KARPENTER_CONTROLLER_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"

# 检查角色是否已存在
if aws iam get-role --role-name "${KARPENTER_CONTROLLER_ROLE}" &>/dev/null; then
    echo "  Role ${KARPENTER_CONTROLLER_ROLE} already exists, skipping creation"
else
    echo "  Creating IAM role ${KARPENTER_CONTROLLER_ROLE}..."

    # 创建信任策略 (Pod Identity)
    cat > /tmp/karpenter-controller-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF

    aws iam create-role \
        --role-name "${KARPENTER_CONTROLLER_ROLE}" \
        --assume-role-policy-document file:///tmp/karpenter-controller-trust-policy.json \
        --tags Key=ManagedBy,Value=karpenter Key=Cluster,Value="${CLUSTER_NAME}"

    # 附加 Karpenter Controller Policy
    aws iam attach-role-policy \
        --role-name "${KARPENTER_CONTROLLER_ROLE}" \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY}"

    echo "  ✓ IAM role ${KARPENTER_CONTROLLER_ROLE} created successfully"
fi

# 8. 使用 Pod Identity 创建 Karpenter Service Account 关联
echo ""
echo "Step 7: Setting up Karpenter with Pod Identity..."

KARPENTER_NAMESPACE="kube-system"
KARPENTER_SA="karpenter"

# 创建 Service Account（如果不存在）
if ! kubectl get sa "${KARPENTER_SA}" -n "${KARPENTER_NAMESPACE}" &>/dev/null; then
    kubectl create serviceaccount "${KARPENTER_SA}" -n "${KARPENTER_NAMESPACE}"
    echo "  ✓ Service Account ${KARPENTER_SA} created"
else
    echo "  Service Account ${KARPENTER_SA} already exists"
fi

# 创建 Pod Identity Association
echo "  Creating Pod Identity Association for Karpenter..."

# 检查是否已存在
EXISTING_ASSOCIATION=$(aws eks list-pod-identity-associations \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace "${KARPENTER_NAMESPACE}" \
    --region "${AWS_REGION}" \
    --query "associations[?serviceAccount=='${KARPENTER_SA}'].associationId" \
    --output text 2>/dev/null)

if [ -z "$EXISTING_ASSOCIATION" ]; then
    aws eks create-pod-identity-association \
        --cluster-name "${CLUSTER_NAME}" \
        --namespace "${KARPENTER_NAMESPACE}" \
        --service-account "${KARPENTER_SA}" \
        --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KARPENTER_CONTROLLER_ROLE}" \
        --region "${AWS_REGION}"
    echo "  ✓ Pod Identity Association created successfully"
else
    echo "  Pod Identity Association already exists (ID: ${EXISTING_ASSOCIATION})"
fi

# 9. 为子网和安全组打标签
echo ""
echo "Step 8: Tagging subnets and security groups for Karpenter discovery..."

# 获取集群的安全组
CLUSTER_SG=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

# 标记子网
for SUBNET in ${PRIVATE_SUBNET_A} ${PRIVATE_SUBNET_B} ${PRIVATE_SUBNET_C}; do
    aws ec2 create-tags \
        --resources "${SUBNET}" \
        --tags Key=karpenter.sh/discovery,Value="${CLUSTER_NAME}" \
        --region "${AWS_REGION}"
    echo "  ✓ Tagged subnet ${SUBNET}"
done

# 标记安全组
aws ec2 create-tags \
    --resources "${CLUSTER_SG}" \
    --tags Key=karpenter.sh/discovery,Value="${CLUSTER_NAME}" \
    --region "${AWS_REGION}"
echo "  ✓ Tagged security group ${CLUSTER_SG}"

# 10. 安装 Karpenter Helm Chart
echo ""
echo "Step 9: Installing Karpenter Helm Chart..."

# 注意: Karpenter v1.x 使用 OCI registry，不需要添加 helm repo
# 安装 Karpenter - 确保只运行在系统节点组
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --namespace "${KARPENTER_NAMESPACE}" \
    --version "${KARPENTER_VERSION}" \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
    --set "serviceAccount.create=false" \
    --set "serviceAccount.name=${KARPENTER_SA}" \
    --set "replicas=2" \
    --set "nodeSelector.node-group-type=system" \
    --set "tolerations[0].key=CriticalAddonsOnly" \
    --set "tolerations[0].operator=Exists" \
    --set "tolerations[1].key=node.kubernetes.io/not-ready" \
    --set "tolerations[1].operator=Exists" \
    --set "tolerations[1].effect=NoExecute" \
    --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=karpenter.sh/nodepool" \
    --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=DoesNotExist" \
    --timeout 10m \
    --wait

# Note: Removed settings.interruptionQueue as SQS queue is not created by default
# To enable interruption handling, create an SQS queue and EventBridge rules manually

echo "  ✓ Karpenter Helm Chart installed successfully"

# 11. 等待 Karpenter Pods 就绪
echo ""
echo "Step 10: Waiting for Karpenter pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=karpenter -n "${KARPENTER_NAMESPACE}" --timeout=300s

# 12. 部署 EC2NodeClass 和 NodePool
echo ""
echo "Step 11: Deploying EC2NodeClass and NodePool..."

# 替换环境变量 - 使用sed而不是envsubst来避免破坏userData中的$$变量
export CLUSTER_NAME
export AWS_REGION

# 部署 Graviton 专用配置 (r8g.8xlarge)
if [ "${DEPLOY_GRAVITON_NODEPOOL:-true}" = "true" ]; then
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        -e "s/\${ENVIRONMENT}/${ENVIRONMENT:-prod}/g" \
        "${PROJECT_ROOT}/manifests/karpenter/ec2nodeclass-graviton.yaml" | kubectl apply -f -
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        "${PROJECT_ROOT}/manifests/karpenter/nodepool-graviton.yaml" | kubectl apply -f -
    echo "  ✓ Graviton EC2NodeClass and NodePool deployed (r8g.8xlarge)"
fi

# 可选：部署 x86 专用配置 (r7i.8xlarge)
if [ "${DEPLOY_X86_NODEPOOL:-true}" = "true" ]; then
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        -e "s/\${ENVIRONMENT}/${ENVIRONMENT:-prod}/g" \
        "${PROJECT_ROOT}/manifests/karpenter/ec2nodeclass-x86.yaml" | kubectl apply -f -
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        "${PROJECT_ROOT}/manifests/karpenter/nodepool-x86.yaml" | kubectl apply -f -
    echo "  ✓ x86 EC2NodeClass and NodePool deployed (r7i.8xlarge)"
fi

# 13. 验证安装
echo ""
echo "Step 12: Verifying Karpenter installation..."

echo ""
echo "Karpenter Pods:"
kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter

echo ""
echo "EC2NodeClasses:"
kubectl get ec2nodeclass

echo ""
echo "NodePools:"
kubectl get nodepool

# 14. 显示最终状态
echo ""
echo "=== Karpenter Installation Complete ==="
echo ""
echo "Karpenter Information:"
echo "  Version: ${KARPENTER_VERSION}"
echo "  Namespace: ${KARPENTER_NAMESPACE}"
echo "  Service Account: ${KARPENTER_SA}"
echo "  Controller IAM Role: ${KARPENTER_CONTROLLER_ROLE}"
echo "  Node IAM Role: ${KARPENTER_NODE_ROLE}"
echo ""
echo "Installed NodePools:"
if [ "${DEPLOY_GRAVITON_NODEPOOL:-true}" = "true" ]; then
    echo "  - graviton: ARM64 only (r8g.8xlarge)"
fi
if [ "${DEPLOY_X86_NODEPOOL:-true}" = "true" ]; then
    echo "  - x86: x86-64 only (r7i.8xlarge)"
fi
echo ""
echo "Features:"
echo "  - Additional 100GB data disk attached (manual LVM setup required)"
echo "  - EBS volume encryption enabled"
echo "  - Pod Identity authentication"
echo "  - Architecture-specific node pools (ARM64 & x86_64)"
echo ""
echo "Next steps:"
echo "  1. Check Karpenter logs: kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter"
echo "  2. Test provisioning: kubectl scale deployment inflate --replicas=10"
echo "  3. Monitor nodes: kubectl get nodes -w"
echo "  4. Customize NodePools: edit manifests/karpenter/*.yaml and reapply"
echo ""
