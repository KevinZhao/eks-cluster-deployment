#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/0_setup_env.sh"

echo "=== Diagnose Node Kubelet Issues ==="
echo ""

# 获取新创建的实例
echo "Step 1: Finding new EC2 instances..."
INSTANCES=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-eks-utils-node" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,LaunchTime,State.Name]' \
    --output text)

if [ -z "$INSTANCES" ]; then
    echo "❌ No running instances found with tag Name=${CLUSTER_NAME}-eks-utils-node"
    exit 1
fi

echo "Found instances:"
echo "$INSTANCES" | while read INSTANCE_ID IP LAUNCH_TIME STATE; do
    echo "  - $INSTANCE_ID ($IP) - Launched: $LAUNCH_TIME"
done
echo ""

# 选择第一个实例进行诊断
INSTANCE_ID=$(echo "$INSTANCES" | head -1 | awk '{print $1}')
echo "Diagnosing instance: $INSTANCE_ID"
echo ""

# 检查 SSM 连接
echo "Step 2: Checking SSM connectivity..."
SSM_STATUS=$(aws ssm describe-instance-information \
    --region "${AWS_REGION}" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "UNKNOWN")

if [ "$SSM_STATUS" == "Online" ]; then
    echo "✓ SSM is online"
else
    echo "⚠️  SSM status: $SSM_STATUS (may take a few minutes after launch)"
    echo ""
    echo "Waiting for SSM to be online..."
    for i in {1..30}; do
        sleep 5
        SSM_STATUS=$(aws ssm describe-instance-information \
            --region "${AWS_REGION}" \
            --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text 2>/dev/null || echo "UNKNOWN")

        if [ "$SSM_STATUS" == "Online" ]; then
            echo "✓ SSM is now online"
            break
        fi
        echo "  Attempt $i/30: Still waiting..."
    done

    if [ "$SSM_STATUS" != "Online" ]; then
        echo "❌ SSM failed to come online after 2.5 minutes"
        echo "   This may indicate:"
        echo "   - SSM agent not running"
        echo "   - Network connectivity issues"
        echo "   - IAM role missing AmazonSSMManagedInstanceCore policy"
        exit 1
    fi
fi
echo ""

# 执行诊断命令
echo "Step 3: Running diagnostics on instance $INSTANCE_ID..."
echo ""

# 创建诊断脚本
cat > /tmp/node_diag_commands.sh <<'DIAG_EOF'
#!/bin/bash

echo "=========================================="
echo "1. LVM Setup Log"
echo "=========================================="
if [ -f /var/log/lvm-setup.log ]; then
    echo "Last 50 lines of LVM setup log:"
    tail -50 /var/log/lvm-setup.log
else
    echo "❌ LVM setup log not found"
fi
echo ""

echo "=========================================="
echo "2. LVM Status"
echo "=========================================="
echo "Volume Groups:"
vgs 2>/dev/null || echo "No VGs found"
echo ""
echo "Logical Volumes:"
lvs 2>/dev/null || echo "No LVs found"
echo ""
echo "Mount status:"
df -h | grep containerd || echo "containerd not mounted"
echo ""

echo "=========================================="
echo "3. Containerd Status"
echo "=========================================="
systemctl status containerd --no-pager || true
echo ""

echo "=========================================="
echo "4. Kubelet Status"
echo "=========================================="
systemctl status kubelet --no-pager || true
echo ""

echo "=========================================="
echo "5. Kubelet Logs (last 50 lines)"
echo "=========================================="
journalctl -u kubelet -n 50 --no-pager || echo "No kubelet logs"
echo ""

echo "=========================================="
echo "6. Cloud-Init Status"
echo "=========================================="
cloud-init status || echo "cloud-init command not available"
echo ""
if [ -f /var/log/cloud-init-output.log ]; then
    echo "Last 50 lines of cloud-init-output.log:"
    tail -50 /var/log/cloud-init-output.log
fi
echo ""

echo "=========================================="
echo "7. Check if bootstrap.sh exists"
echo "=========================================="
if [ -f /etc/eks/bootstrap.sh ]; then
    echo "✓ /etc/eks/bootstrap.sh exists"
else
    echo "❌ /etc/eks/bootstrap.sh NOT found"
fi
echo ""

echo "=========================================="
echo "8. Check kubelet config"
echo "=========================================="
if [ -f /etc/kubernetes/kubelet/kubelet-config.json ]; then
    echo "✓ kubelet config exists"
    cat /etc/kubernetes/kubelet/kubelet-config.json
else
    echo "❌ kubelet config NOT found"
fi
echo ""

echo "=========================================="
echo "9. Network connectivity"
echo "=========================================="
echo "Checking connection to EKS API..."
CLUSTER_ENDPOINT=$(cat /etc/eks/eks.env 2>/dev/null | grep CLUSTER_ENDPOINT | cut -d'=' -f2 | tr -d '"' || echo "NOT_FOUND")
if [ "$CLUSTER_ENDPOINT" != "NOT_FOUND" ]; then
    echo "Cluster endpoint: $CLUSTER_ENDPOINT"
    curl -k -s -o /dev/null -w "HTTP Status: %{http_code}\n" "$CLUSTER_ENDPOINT/version" --max-time 5 || echo "Failed to connect"
else
    echo "⚠️  Cluster endpoint not found in /etc/eks/eks.env"
fi
echo ""

echo "=========================================="
echo "10. Check for disk issues"
echo "=========================================="
echo "Block devices:"
lsblk
echo ""
echo "Disk usage:"
df -h
echo ""

echo "=========================================="
echo "11. System resources"
echo "=========================================="
echo "Memory:"
free -h
echo ""
echo "CPU load:"
uptime
echo ""

DIAG_EOF

chmod +x /tmp/node_diag_commands.sh

echo "Executing diagnostic commands via SSM..."
echo "========================================"
echo ""

aws ssm send-command \
    --region "${AWS_REGION}" \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$INSTANCE_ID" \
    --parameters 'commands=["bash /tmp/node_diag_commands.sh"]' \
    --output text \
    --query 'Command.CommandId' > /tmp/ssm_command_id.txt

COMMAND_ID=$(cat /tmp/ssm_command_id.txt)
echo "Command ID: $COMMAND_ID"
echo "Waiting for command to complete..."
sleep 5

# 等待命令完成
for i in {1..30}; do
    STATUS=$(aws ssm get-command-invocation \
        --region "${AWS_REGION}" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Pending")

    if [ "$STATUS" == "Success" ] || [ "$STATUS" == "Failed" ]; then
        break
    fi
    sleep 2
done

echo ""
echo "========================================"
echo "Diagnostic Output:"
echo "========================================"
echo ""

aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --output text \
    --query 'StandardOutputContent'

echo ""
echo "========================================"
echo "Errors (if any):"
echo "========================================"
aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --output text \
    --query 'StandardErrorContent' || echo "No errors"

rm -f /tmp/node_diag_commands.sh /tmp/ssm_command_id.txt

echo ""
echo "========================================"
echo "Summary & Next Steps"
echo "========================================"
echo ""
echo "Common issues:"
echo "1. User-data didn't run bootstrap.sh - check cloud-init logs"
echo "2. LVM setup failed - containerd can't start"
echo "3. Network issues - can't reach EKS API endpoint"
echo "4. IAM permissions - node can't authenticate"
echo ""
echo "To manually SSH/SSM into the instance:"
echo "  aws ssm start-session --target $INSTANCE_ID --region ${AWS_REGION}"
echo ""
