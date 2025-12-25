#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Manually Fix LVM on Existing Nodes ==="
echo ""
echo "This script will:"
echo "  1. Connect to each node via SSM"
echo "  2. Run LVM setup script directly on the node"
echo "  3. Restart containerd with new mount"
echo ""
echo "WARNING: This will briefly restart containerd on each node"
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 更新 kubeconfig
export KUBECONFIG="${HOME}/.kube/config"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

# 2. 获取所有 eks-utils-arm64 节点的实例 ID
echo ""
echo "Step 1: Getting instance IDs for eks-utils-arm64 nodes..."

INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters \
        "Name=tag:eks:nodegroup-name,Values=eks-utils-arm64" \
        "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

if [ -z "$INSTANCE_IDS" ]; then
    echo "ERROR: No running instances found for nodegroup eks-utils-arm64"
    exit 1
fi

echo "Found instances: $INSTANCE_IDS"

# 3. 为每个实例创建 LVM 配置脚本
LVM_SETUP_SCRIPT=$(cat <<'EOF_SCRIPT'
#!/bin/bash
set -euxo pipefail

echo "=== Starting LVM Setup ==="

# Stop containerd
systemctl stop containerd

# Auto-detect EBS data disk (exclude root disk nvme0n1)
DISK=$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)

if [ -z "$DISK" ]; then
  echo "ERROR: No data disk found"
  systemctl start containerd
  exit 1
fi

echo "Found data disk: $DISK"

# Check if LVM already configured
if vgs vg_data &>/dev/null; then
  echo "LVM already configured, skipping"
  systemctl start containerd
  exit 0
fi

# Install lvm2
if ! command -v lvm &>/dev/null; then
    echo "Installing lvm2..."
    dnf install -y lvm2
fi

# Create LVM
echo "Creating LVM..."
pvcreate "$DISK"
vgcreate vg_data "$DISK"
lvcreate -l 100%VG -n lv_containerd vg_data
mkfs.xfs /dev/vg_data/lv_containerd

# Mount LV to temporary directory and migrate data
TEMP_MOUNT="/mnt/runtime/containerd"
mkdir -p "$TEMP_MOUNT"

echo "Mounting LV to temporary directory: $TEMP_MOUNT"
mount /dev/vg_data/lv_containerd "$TEMP_MOUNT"

echo "Copying containerd data..."
rsync -aHAX /var/lib/containerd/ "$TEMP_MOUNT/" || echo "Warning: rsync had some errors, continuing..."

echo "Unmounting temporary directory"
umount "$TEMP_MOUNT"

echo "Mounting LV to final destination: /var/lib/containerd"
mount /dev/vg_data/lv_containerd /var/lib/containerd

# Add to fstab
grep -q "lv_containerd" /etc/fstab || \
  echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

echo "LVM setup completed successfully"
df -h /var/lib/containerd

# Verify LVM
vgs
lvs

# Start containerd
systemctl start containerd
systemctl status containerd --no-pager

echo "=== LVM Setup Complete ==="
EOF_SCRIPT
)

# 4. 在每个实例上执行 LVM 配置
for INSTANCE_ID in $INSTANCE_IDS; do
    echo ""
    echo "=========================================="
    echo "Processing instance: $INSTANCE_ID"
    echo "=========================================="

    # 获取节点名称
    NODE_NAME=$(aws ec2 describe-instances \
        --region "${AWS_REGION}" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PrivateDnsName' \
        --output text | sed 's/.compute.internal/.compute.internal/')

    echo "Node name: $NODE_NAME"

    # 通过 SSM 执行脚本
    echo "Executing LVM setup script via SSM..."

    COMMAND_ID=$(aws ssm send-command \
        --region "${AWS_REGION}" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"$LVM_SETUP_SCRIPT\"]" \
        --query 'Command.CommandId' \
        --output text)

    echo "Command ID: $COMMAND_ID"
    echo "Waiting for command to complete..."

    # 等待命令完成
    sleep 5

    for i in {1..30}; do
        STATUS=$(aws ssm get-command-invocation \
            --region "${AWS_REGION}" \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --query 'Status' \
            --output text 2>/dev/null || echo "Pending")

        echo "  Status: $STATUS"

        if [ "$STATUS" = "Success" ]; then
            echo "✓ Command completed successfully"

            # 获取输出
            echo ""
            echo "Command output:"
            aws ssm get-command-invocation \
                --region "${AWS_REGION}" \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardOutputContent' \
                --output text

            break
        elif [ "$STATUS" = "Failed" ]; then
            echo "✗ Command failed"

            # 获取错误输出
            echo ""
            echo "Error output:"
            aws ssm get-command-invocation \
                --region "${AWS_REGION}" \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardErrorContent' \
                --output text

            echo ""
            echo "WARNING: LVM setup failed for instance $INSTANCE_ID"
            break
        fi

        sleep 2
    done

    echo ""
done

# 5. 验证所有节点
echo ""
echo "Step 2: Verifying LVM configuration on all nodes..."
echo ""

kubectl get nodes -l app=eks-utils -o wide

echo ""
echo "=== Manual LVM Fix Complete ==="
echo ""
echo "Please verify LVM configuration by running:"
echo "  kubectl debug node/<node-name> -it --image=busybox:1.36 -- chroot /host bash -c 'df -h /var/lib/containerd && vgs && lvs'"
echo ""
