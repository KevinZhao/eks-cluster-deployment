#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Installing GPU Support for Karpenter ==="
echo ""
echo "This script will:"
echo "  • Add EFA permissions to KarpenterNodeRole"
echo "  • Deploy GPU EC2NodeClass (P5/P5en/P6)"
echo "  • Deploy GPU NodePools (on-demand, spot, ODCR, capacity-block)"
echo "  • Deploy EFA multi-NIC setup DaemonSet"
echo ""

# 1. 加载环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 设置 KUBECONFIG
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 2. 验证 Karpenter 已安装
echo ""
echo "Step 1: Verifying Karpenter is installed..."

if ! kubectl get deployment karpenter -n kube-system &>/dev/null; then
    echo "❌ ERROR: Karpenter is not installed"
    echo "Please run ./scripts/option_install_karpenter.sh first"
    exit 1
fi
echo "✓ Karpenter is installed"

# 验证 kubectl context
verify_kubectl_context

# 3. 添加 EFA 权限到 KarpenterNodeRole
echo ""
echo "Step 2: Adding EFA permissions to KarpenterNodeRole..."

KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
EFA_POLICY_NAME="KarpenterNodeEFAPolicy-${CLUSTER_NAME}"

# 检查角色是否存在
if ! aws iam get-role --role-name "${KARPENTER_NODE_ROLE}" &>/dev/null; then
    echo "❌ ERROR: KarpenterNodeRole not found: ${KARPENTER_NODE_ROLE}"
    exit 1
fi

# 创建 EFA 权限策略
EFA_POLICY_FILE=$(mktemp /tmp/efa-policy.XXXXXX.json)
cat > "${EFA_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:AttachNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# 检查策略是否已存在
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${EFA_POLICY_NAME}" &>/dev/null; then
    echo "  EFA policy already exists, updating..."

    # 删除旧版本
    POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${EFA_POLICY_NAME}"
    OLD_VERSIONS=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
        --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
    for VERSION in $OLD_VERSIONS; do
        aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${VERSION}" 2>/dev/null || true
    done

    aws iam create-policy-version \
        --policy-arn "${POLICY_ARN}" \
        --policy-document "file://${EFA_POLICY_FILE}" \
        --set-as-default
else
    echo "  Creating EFA policy..."
    aws iam create-policy \
        --policy-name "${EFA_POLICY_NAME}" \
        --policy-document "file://${EFA_POLICY_FILE}" \
        --tags Key=ManagedBy,Value=karpenter Key=Cluster,Value="${CLUSTER_NAME}"
fi

rm -f "${EFA_POLICY_FILE}"

# 附加策略到角色
echo "  Attaching EFA policy to ${KARPENTER_NODE_ROLE}..."
aws iam attach-role-policy \
    --role-name "${KARPENTER_NODE_ROLE}" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${EFA_POLICY_NAME}" 2>/dev/null || true

echo "✓ EFA permissions configured"

# 4. 部署 GPU EC2NodeClass
echo ""
echo "Step 3: Deploying GPU EC2NodeClass..."

# 部署标准 GPU EC2NodeClass (用于 on-demand 和 spot)
echo "  Deploying EC2NodeClass: gpu..."
kubectl kustomize "${PROJECT_ROOT}/manifests/karpenter/gpu-nodeclass/overlays/default" | \
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" | kubectl apply -f -

# 部署 Capacity Block EC2NodeClass (可选)
if [ -n "${CAPACITY_BLOCK_ID}" ]; then
    echo "  Deploying EC2NodeClass: gpu-cb..."
    kubectl kustomize "${PROJECT_ROOT}/manifests/karpenter/gpu-nodeclass/overlays/cb" | \
        sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
            -e "s/\${AWS_REGION}/$AWS_REGION/g" \
            -e "s/\${CAPACITY_BLOCK_ID}/$CAPACITY_BLOCK_ID/g" | kubectl apply -f -
fi

# 部署 ODCR EC2NodeClass (可选)
if [ -n "${ODCR_ID}" ]; then
    echo "  Deploying EC2NodeClass: gpu-odcr..."
    kubectl kustomize "${PROJECT_ROOT}/manifests/karpenter/gpu-nodeclass/overlays/odcr" | \
        sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
            -e "s/\${AWS_REGION}/$AWS_REGION/g" \
            -e "s/\${ODCR_ID}/$ODCR_ID/g" | kubectl apply -f -
fi

echo "✓ GPU EC2NodeClass deployed"

# 5. 部署 GPU NodePools
echo ""
echo "Step 4: Deploying GPU NodePools..."

# On-Demand NodePool
if [ "${DEPLOY_GPU_ONDEMAND:-true}" = "true" ]; then
    echo "  Deploying GPU on-demand NodePool..."
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        "${PROJECT_ROOT}/manifests/karpenter/nodepool-gpu-ondemand.yaml" | kubectl apply -f -
fi

# Spot NodePool
if [ "${DEPLOY_GPU_SPOT:-true}" = "true" ]; then
    echo "  Deploying GPU spot NodePool..."
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        "${PROJECT_ROOT}/manifests/karpenter/nodepool-gpu-spot.yaml" | kubectl apply -f -
fi

# ODCR NodePool (optional, requires ODCR_ID)
if [ -n "${ODCR_ID}" ]; then
    echo "  Deploying GPU ODCR NodePool..."
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        -e "s/\${ODCR_ID}/$ODCR_ID/g" \
        "${PROJECT_ROOT}/manifests/karpenter/nodepool-gpu-odcr.yaml" | kubectl apply -f -
fi

# Capacity Block NodePool (optional, requires CAPACITY_BLOCK_ID)
if [ -n "${CAPACITY_BLOCK_ID}" ]; then
    echo "  Deploying GPU capacity-block NodePool..."
    sed -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
        -e "s/\${AWS_REGION}/$AWS_REGION/g" \
        -e "s/\${CAPACITY_BLOCK_ID}/$CAPACITY_BLOCK_ID/g" \
        "${PROJECT_ROOT}/manifests/karpenter/nodepool-gpu-capacity-block.yaml" | kubectl apply -f -
fi

echo "✓ GPU NodePools deployed"

# 6. 部署 EFA Setup DaemonSet
echo ""
echo "Step 5: Deploying GPU EFA Setup DaemonSet..."

kubectl apply -f "${PROJECT_ROOT}/manifests/karpenter/gpu-efa-setup-daemonset.yaml"

echo "✓ EFA Setup DaemonSet deployed"

# 7. 验证
echo ""
echo "Step 6: Verifying GPU support installation..."

echo ""
echo "GPU EC2NodeClasses:"
kubectl get ec2nodeclass | grep -E "^gpu-" || echo "  (none deployed yet)"

echo ""
echo "GPU NodePools:"
kubectl get nodepool | grep -E "^gpu-" || echo "  (none deployed yet)"

echo ""
echo "EFA Setup DaemonSet:"
kubectl get daemonset gpu-efa-setup -n kube-system 2>/dev/null || echo "  Waiting for GPU nodes..."

echo ""
echo "=== GPU Support Installation Complete ==="
echo ""
echo "GPU Instance Types Supported:"
echo "  • P5.48xlarge: 8x H100, 31 EFA interfaces"
echo "  • P5en.48xlarge: 8x H200, 15 EFA interfaces"
echo "  • P6-b200.48xlarge: 8x B200, 7 EFA interfaces"
echo ""
echo "NodePools deployed:"
[ "${DEPLOY_GPU_ONDEMAND:-true}" = "true" ] && echo "  • gpu-ondemand: On-demand GPU instances"
[ "${DEPLOY_GPU_SPOT:-true}" = "true" ] && echo "  • gpu-spot: Spot GPU instances (cost savings)"
[ -n "${ODCR_ID}" ] && echo "  • gpu-odcr: On-Demand Capacity Reservation"
[ -n "${CAPACITY_BLOCK_ID}" ] && echo "  • gpu-capacity-block: Capacity Block reservation"
echo ""
echo "EFA Multi-NIC:"
echo "  • DaemonSet will automatically attach EFA interfaces when GPU nodes start"
echo "  • Check status: kubectl get pods -n kube-system -l app=gpu-efa-setup"
echo ""
echo "Next steps:"
echo "  1. Deploy a GPU workload with nodeSelector: workload-type: gpu"
echo "  2. Monitor node provisioning: kubectl get nodes -w"
echo "  3. Check EFA setup logs: kubectl logs -n kube-system -l app=gpu-efa-setup"
echo ""
