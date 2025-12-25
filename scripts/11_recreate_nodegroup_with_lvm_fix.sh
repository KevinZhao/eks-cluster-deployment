#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Recreate Nodegroup with LVM Fix ==="
echo ""
echo "This script will:"
echo "  1. Delete existing eks-utils-arm64 nodegroup (without LVM)"
echo "  2. Recreate it with proper LVM configuration"
echo ""
echo "WARNING: This will cause a brief service interruption (2-5 minutes)"
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 更新 kubeconfig 确保连接到正确的集群
echo "Updating kubeconfig for cluster: ${CLUSTER_NAME}"
aws eks update-kubeconfig \
    --region "${AWS_REGION}" \
    --name "${CLUSTER_NAME}"

# 1.2 设置 KUBECONFIG 环境变量
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 2. 删除现有的 eks-utils-arm64 节点组
echo ""
echo "Step 1: Deleting existing eks-utils-arm64 nodegroup (without LVM)..."
echo "This will take 2-3 minutes..."

eksctl delete nodegroup \
    --cluster="${CLUSTER_NAME}" \
    --region="${AWS_REGION}" \
    --name=eks-utils-arm64 \
    --drain=false \
    --wait

echo "Nodegroup deleted successfully"

# 3. 创建新的 Graviton ARM64 节点组（使用修复后的 LVM 配置）
echo ""
echo "Step 2: Creating new Graviton ARM64 nodegroup with LVM..."

# 创建临时配置文件（使用 /tmp 目录避免权限问题）
TEMP_CONFIG="/tmp/eksctl_nodegroup_graviton_lvm_$$.yaml"
cat > "${TEMP_CONFIG}" <<'EOF_TEMPLATE'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: CLUSTER_NAME_PLACEHOLDER
  region: AWS_REGION_PLACEHOLDER
  version: "K8S_VERSION_PLACEHOLDER"

# 使用已经存在的vpc
vpc:
  id: "VPC_ID_PLACEHOLDER"
  subnets:
    private:
      AZ_A_PLACEHOLDER:
        id: "PRIVATE_SUBNET_A_PLACEHOLDER"
      AZ_B_PLACEHOLDER:
        id: "PRIVATE_SUBNET_B_PLACEHOLDER"
      AZ_C_PLACEHOLDER:
        id: "PRIVATE_SUBNET_C_PLACEHOLDER"

# Graviton 系统节点组
managedNodeGroups:
  - name: eks-utils-arm64
    instanceType: m8g.large
    amiFamily: AmazonLinux2023
    desiredCapacity: 3
    minSize: 3
    maxSize: 6
    volumeSize: 50
    volumeType: gp3
    # Additional data disk for containerd
    additionalVolumes:
      - volumeName: "/dev/sdz"
        volumeSize: 100
        volumeType: gp3
    # Mount data disk to /var/lib/containerd using LVM with rsync migration
    preBootstrapCommands:
      - |
        set -euxo pipefail
        systemctl stop containerd || true

        # Auto-detect EBS data disk (exclude root disk nvme0n1)
        DISK=$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)
        if [ -z "$$DISK" ]; then
          echo "No data disk found, skip LVM setup"
          systemctl start containerd
          exit 0
        fi

        echo "Found data disk: $$DISK"

        # Check if LVM already configured
        if vgs vg_data &>/dev/null; then
          echo "LVM already configured"
        else
          # Install lvm2 (not installed by default on AL2023)
          dnf install -y lvm2

          # Create LVM
          pvcreate "$$DISK"
          vgcreate vg_data "$$DISK"
          lvcreate -l 100%VG -n lv_containerd vg_data
          mkfs.xfs /dev/vg_data/lv_containerd
        fi

        # Mount LV to temporary directory and migrate data
        TEMP_MOUNT="/mnt/runtime/containerd"
        mkdir -p "$$TEMP_MOUNT"

        echo "Mounting LV to temporary directory: $$TEMP_MOUNT"
        mount /dev/vg_data/lv_containerd "$$TEMP_MOUNT"

        echo "Copying containerd data (including cached images) from AMI..."
        rsync -aHAX /var/lib/containerd/ "$$TEMP_MOUNT/"

        echo "Unmounting temporary directory"
        umount "$$TEMP_MOUNT"

        echo "Mounting LV to final destination: /var/lib/containerd"
        mount /dev/vg_data/lv_containerd /var/lib/containerd

        # Add to fstab for persistence
        grep -q "lv_containerd" /etc/fstab || \
          echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

        echo "Containerd data migration completed"
        df -h /var/lib/containerd

        # Start containerd with migrated data
        systemctl start containerd
    privateNetworking: true
    subnets:
      - PRIVATE_SUBNET_A_PLACEHOLDER
      - PRIVATE_SUBNET_B_PLACEHOLDER
      - PRIVATE_SUBNET_C_PLACEHOLDER
    labels:
      app: "eks-utils"
      arch: "arm64"
      node-group-type: "system"
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/CLUSTER_NAME_PLACEHOLDER: "owned"
EOF_TEMPLATE

# 替换占位符为实际的环境变量值
sed -i "s/CLUSTER_NAME_PLACEHOLDER/${CLUSTER_NAME}/g" "${TEMP_CONFIG}"
sed -i "s/AWS_REGION_PLACEHOLDER/${AWS_REGION}/g" "${TEMP_CONFIG}"
sed -i "s/K8S_VERSION_PLACEHOLDER/${K8S_VERSION}/g" "${TEMP_CONFIG}"
sed -i "s/VPC_ID_PLACEHOLDER/${VPC_ID}/g" "${TEMP_CONFIG}"
sed -i "s/AZ_A_PLACEHOLDER/${AZ_A}/g" "${TEMP_CONFIG}"
sed -i "s/AZ_B_PLACEHOLDER/${AZ_B}/g" "${TEMP_CONFIG}"
sed -i "s/AZ_C_PLACEHOLDER/${AZ_C}/g" "${TEMP_CONFIG}"
sed -i "s/PRIVATE_SUBNET_A_PLACEHOLDER/${PRIVATE_SUBNET_A}/g" "${TEMP_CONFIG}"
sed -i "s/PRIVATE_SUBNET_B_PLACEHOLDER/${PRIVATE_SUBNET_B}/g" "${TEMP_CONFIG}"
sed -i "s/PRIVATE_SUBNET_C_PLACEHOLDER/${PRIVATE_SUBNET_C}/g" "${TEMP_CONFIG}"

echo "Generated config file at: ${TEMP_CONFIG}"
echo "Config preview:"
head -30 "${TEMP_CONFIG}"

echo ""
echo "Creating Graviton nodegroup with LVM..."
eksctl create nodegroup -f "${TEMP_CONFIG}"

# 清理临时文件
rm -f "${TEMP_CONFIG}"

# 4. 等待节点就绪
echo ""
echo "Step 3: Waiting for nodes to be ready..."
sleep 10

# 等待至少3个节点就绪
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
        echo "ERROR: Timeout waiting for nodes to be ready"
        exit 1
    fi

    sleep 10
done

# 5. 验证 LVM 配置
echo ""
echo "Step 4: Verifying LVM configuration on nodes..."

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
    ' 2>/dev/null || echo "Warning: Failed to debug node $NODE"
done

# 6. 显示最终状态
echo ""
echo "=== Recreation Complete ==="
echo ""
kubectl get nodes -o wide
echo ""
echo "Nodegroup details:"
aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name eks-utils-arm64 \
    --region "${AWS_REGION}" \
    --query 'nodegroup.{Name:nodegroupName,InstanceType:instanceTypes,DesiredSize:scalingConfig.desiredSize,Labels:labels,Status:status}' \
    --output table

echo ""
echo "LVM Configuration:"
echo "  - Volume Group: vg_data"
echo "  - Logical Volume: lv_containerd"
echo "  - Mount Point: /var/lib/containerd"
echo "  - Filesystem: XFS"
echo "  - Size: 100GB (gp3)"
echo ""
echo "Next steps:"
echo "  1. Verify system components: kubectl get pods -A"
echo "  2. Check LVM on each node using the output above"
echo ""
echo "Script completed successfully!"
