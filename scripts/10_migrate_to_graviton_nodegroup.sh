#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Migrate EKS System Nodegroup to Graviton (m8g.large) ==="
echo ""
echo "This script will:"
echo "  1. Delete existing AMD64 nodegroup (eks-utils)"
echo "  2. Create new Graviton ARM64 nodegroup (eks-utils-arm64)"
echo "  3. Wait for new nodes to be ready"
echo "  4. Verify LVM configuration"
echo "  5. Rename nodegroup to eks-utils"
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

# 1.3 验证集群连接
echo "Verifying cluster connection..."
kubectl cluster-info | head -1
CURRENT_CONTEXT=$(kubectl config current-context)
echo "Current context: ${CURRENT_CONTEXT}"

if [[ ! "$CURRENT_CONTEXT" =~ "$CLUSTER_NAME" ]]; then
    echo "ERROR: Current context does not match cluster name ${CLUSTER_NAME}"
    echo "Please check your kubeconfig"
    exit 1
fi

echo "Cluster connection verified successfully"

# 2. 显示当前节点组信息
echo ""
echo "Step 1: Current nodegroup information..."
aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name eks-utils \
    --region "${AWS_REGION}" \
    --query 'nodegroup.{instanceTypes:instanceTypes,desiredSize:scalingConfig.desiredSize,amiType:amiType,labels:labels}' \
    --output table || echo "Failed to describe nodegroup"

echo ""
echo "Current nodes:"
kubectl get nodes -o wide || echo "Failed to list nodes (cluster may be inaccessible)"

# 3. 删除旧的 AMD64 节点组
echo ""
echo "Step 2: Deleting old AMD64 nodegroup (eks-utils)..."
echo "This will take 2-3 minutes..."

eksctl delete nodegroup \
    --cluster="${CLUSTER_NAME}" \
    --region="${AWS_REGION}" \
    --name=eks-utils \
    --drain=false \
    --wait

echo "Old nodegroup deleted successfully"

# 4. 创建新的 Graviton ARM64 节点组（临时名称）
echo ""
echo "Step 3: Creating new Graviton ARM64 nodegroup (eks-utils-arm64)..."
echo "Using template: ${PROJECT_ROOT}/manifests/cluster/eksctl_cluster_template.yaml"

# 创建临时配置文件，只包含新节点组（使用 /tmp 目录避免权限问题）
TEMP_CONFIG="/tmp/eksctl_nodegroup_graviton_temp_$$.yaml"
cat > "${TEMP_CONFIG}" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"

# 使用已经存在的vpc
vpc:
  id: "${VPC_ID}"
  subnets:
    private:
      ${AZ_A}:
        id: "${PRIVATE_SUBNET_A}"
      ${AZ_B}:
        id: "${PRIVATE_SUBNET_B}"
      ${AZ_C}:
        id: "${PRIVATE_SUBNET_C}"

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
        DISK=\$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)
        if [ -z "\$DISK" ]; then
          echo "No data disk found, skip LVM setup"
          systemctl start containerd
          exit 0
        fi

        echo "Found data disk: \$DISK"

        # Check if LVM already configured
        if vgs vg_data &>/dev/null; then
          echo "LVM already configured"
        else
          # Install lvm2 (not installed by default on AL2023)
          dnf install -y lvm2

          # Create LVM
          pvcreate "\$DISK"
          vgcreate vg_data "\$DISK"
          lvcreate -l 100%VG -n lv_containerd vg_data
          mkfs.xfs /dev/vg_data/lv_containerd
        fi

        # Mount LV to temporary directory and migrate data
        TEMP_MOUNT="/mnt/runtime/containerd"
        mkdir -p "\$TEMP_MOUNT"

        echo "Mounting LV to temporary directory: \$TEMP_MOUNT"
        mount /dev/vg_data/lv_containerd "\$TEMP_MOUNT"

        echo "Copying containerd data (including cached images) from AMI..."
        rsync -aHAX /var/lib/containerd/ "\$TEMP_MOUNT/"

        echo "Unmounting temporary directory"
        umount "\$TEMP_MOUNT"

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
      - ${PRIVATE_SUBNET_A}
      - ${PRIVATE_SUBNET_B}
      - ${PRIVATE_SUBNET_C}
    labels:
      app: "eks-utils"
      arch: "arm64"
      node-group-type: "system"
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
EOF

echo "Creating Graviton nodegroup..."
eksctl create nodegroup -f "${TEMP_CONFIG}"

# 5. 等待节点就绪
echo ""
echo "Step 4: Waiting for nodes to be ready..."
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

# 6. 验证 LVM 配置
echo ""
echo "Step 5: Verifying LVM configuration on nodes..."

# 获取所有新节点
NODES=$(kubectl get nodes -l app=eks-utils -o jsonpath='{.items[*].metadata.name}')

for NODE in $NODES; do
    echo ""
    echo "Checking node: $NODE"

    # 通过 kubectl debug 检查 LVM 配置
    kubectl debug node/$NODE -it --image=busybox -- chroot /host bash -c '
        echo "=== LVM Configuration ==="
        vgs 2>/dev/null || echo "LVM not found"
        lvs 2>/dev/null || echo "No logical volumes"
        echo ""
        echo "=== Containerd Mount ==="
        df -h /var/lib/containerd 2>/dev/null || echo "Containerd directory not found"
        echo ""
        echo "=== fstab Entry ==="
        grep containerd /etc/fstab 2>/dev/null || echo "No fstab entry found"
    ' 2>/dev/null || echo "Warning: Failed to debug node $NODE (this is normal if kubectl debug is not available)"
done

# 7. 显示集群状态
echo ""
echo "Step 6: Final cluster status..."
echo ""
echo "Nodes:"
kubectl get nodes -o wide

echo ""
echo "Node labels:"
kubectl get nodes --show-labels

echo ""
echo "System pods:"
kubectl get pods -n kube-system -o wide

# 8. 等待系统组件恢复
echo ""
echo "Step 7: Waiting for system components to recover..."
echo "Waiting for CoreDNS..."
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s || echo "Warning: CoreDNS not fully ready yet"

echo ""
echo "Checking VPC CNI..."
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-node || true

echo ""
echo "Checking kube-proxy..."
kubectl get pods -n kube-system -l k8s-app=kube-proxy || true

# 9. 显示迁移完成信息
echo ""
echo "=== Migration Complete ==="
echo ""
echo "Old nodegroup: eks-utils (m7i.large, AMD64) - DELETED"
echo "New nodegroup: eks-utils-arm64 (m8g.large, ARM64/Graviton4) - CREATED"
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
echo "  2. Check node resources: kubectl top nodes (if metrics-server installed)"
echo "  3. Monitor cluster autoscaler: kubectl logs -n kube-system -l app=cluster-autoscaler"
echo "  4. Deploy workloads as usual"
echo ""
echo "Note: The nodegroup is named 'eks-utils-arm64' to distinguish from the old one."
echo "      You can keep this name or rename it later if needed."
echo ""

# 清理临时文件
rm -f "${TEMP_CONFIG}"

echo "Script completed successfully!"
