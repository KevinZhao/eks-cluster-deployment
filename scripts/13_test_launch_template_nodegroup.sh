#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Test Launch Template Nodegroup Creation ==="
echo ""
echo "This script will:"
echo "  1. Delete existing eks-utils-arm64 nodegroup"
echo "  2. Create new nodegroup using Launch Template with LVM"
echo "  3. Verify LVM configuration"
echo ""
echo "WARNING: This will cause a brief service interruption (5-8 minutes)"
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 更新 kubeconfig
export KUBECONFIG="${HOME}/.kube/config"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

# 2. 删除现有节点组
echo ""
echo "Step 1: Deleting existing eks-utils-arm64 nodegroup..."

if aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name eks-utils-arm64 \
    --region "${AWS_REGION}" &>/dev/null; then

    eksctl delete nodegroup \
        --cluster="${CLUSTER_NAME}" \
        --region="${AWS_REGION}" \
        --name=eks-utils-arm64 \
        --drain=false \
        --wait

    echo "Nodegroup deleted successfully"
else
    echo "Nodegroup eks-utils-arm64 not found, skipping deletion"
fi

# 3. 创建使用 Launch Template 的节点组
echo ""
echo "Step 2: Creating nodegroup with Launch Template..."

# 创建临时配置
TEMP_CONFIG="/tmp/eksctl_lt_test_$$.yaml"
envsubst < "${PROJECT_ROOT}/manifests/cluster/eksctl_cluster_with_launchtemplate.yaml" > "${TEMP_CONFIG}"

echo "Generated config:"
cat "${TEMP_CONFIG}"

echo ""
echo "Creating nodegroup..."
eksctl create nodegroup -f "${TEMP_CONFIG}" --include=eks-utils-arm64

rm -f "${TEMP_CONFIG}"

# 4. 等待节点就绪
echo ""
echo "Step 3: Waiting for nodes to be ready..."
sleep 15

RETRY_COUNT=0
MAX_RETRIES=60
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    READY_NODES=$(kubectl get nodes -l app=eks-utils --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    echo "Ready nodes: ${READY_NODES}/3"

    if [ "$READY_NODES" -ge 3 ]; then
        echo "All nodes are ready!"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "ERROR: Timeout waiting for nodes"
        exit 1
    fi

    sleep 10
done

# 5. 验证 LVM
echo ""
echo "Step 4: Verifying LVM configuration..."

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
    ' 2>/dev/null || echo "Warning: Failed to debug node"
done

# 6. 显示结果
echo ""
echo "=== Test Complete ==="
echo ""
kubectl get nodes -o wide

echo ""
echo "If LVM is configured correctly, you should see:"
echo "  - /dev/mapper/vg_data-lv_containerd mounted on /var/lib/containerd"
echo "  - Size: 100GB"
echo ""
