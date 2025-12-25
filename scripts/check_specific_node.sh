#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/0_setup_env.sh"

INSTANCE_ID="${1:-i-06aa6672d685cc80e}"

echo "=== Checking Node: $INSTANCE_ID ==="
echo ""

# 检查实例状态
echo "Step 1: Checking instance status..."
INSTANCE_INFO=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].{State:State.Name,IP:PrivateIpAddress,LaunchTime:LaunchTime,Type:InstanceType}' \
    --output json 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "❌ Failed to describe instance $INSTANCE_ID"
    exit 1
fi

echo "$INSTANCE_INFO" | jq .
echo ""

# 检查 SSM 连接
echo "Step 2: Checking SSM connectivity..."
SSM_STATUS=$(aws ssm describe-instance-information \
    --region "${AWS_REGION}" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "UNKNOWN")

echo "SSM Status: $SSM_STATUS"

if [ "$SSM_STATUS" != "Online" ]; then
    echo "⚠️  SSM is not online, waiting up to 2 minutes..."
    for i in {1..24}; do
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
        echo "  Attempt $i/24..."
    done

    if [ "$SSM_STATUS" != "Online" ]; then
        echo "❌ SSM failed to come online"
        exit 1
    fi
fi
echo ""

# 创建诊断脚本
echo "Step 3: Running diagnostics on $INSTANCE_ID..."
echo ""

cat > /tmp/check_node_$$sh <<'CHECK_EOF'
#!/bin/bash

echo "========================================"
echo "System Information"
echo "========================================"
echo "Hostname: $(hostname)"
echo "Uptime: $(uptime)"
echo ""

echo "========================================"
echo "1. LVM Setup Log"
echo "========================================"
if [ -f /var/log/lvm-setup.log ]; then
    echo "✓ LVM setup log exists"
    echo ""
    tail -100 /var/log/lvm-setup.log
else
    echo "❌ LVM setup log NOT found"
fi
echo ""

echo "========================================"
echo "2. LVM Status"
echo "========================================"
echo "Volume Groups:"
vgs 2>/dev/null || echo "❌ No VGs found or lvm2 not installed"
echo ""
echo "Logical Volumes:"
lvs 2>/dev/null || echo "❌ No LVs found"
echo ""
echo "Mounts:"
mount | grep -E "containerd|vg_data" || echo "⚠️  No LVM mounts found"
echo ""
echo "Disk usage:"
df -h | grep -E "Filesystem|containerd|vg_data" || df -h /var/lib/containerd 2>/dev/null || echo "⚠️  containerd directory not mounted on LVM"
echo ""

echo "========================================"
echo "3. Block Devices"
echo "========================================"
lsblk
echo ""

echo "========================================"
echo "4. Containerd Status"
echo "========================================"
systemctl status containerd --no-pager -l || echo "❌ Containerd check failed"
echo ""
echo "Containerd service enabled:"
systemctl is-enabled containerd 2>/dev/null || echo "Not enabled"
echo ""

echo "========================================"
echo "5. Kubelet Status"
echo "========================================"
systemctl status kubelet --no-pager -l || echo "❌ Kubelet check failed"
echo ""
echo "Kubelet service enabled:"
systemctl is-enabled kubelet 2>/dev/null || echo "Not enabled"
echo ""

echo "========================================"
echo "6. Kubelet Logs (last 100 lines)"
echo "========================================"
journalctl -u kubelet -n 100 --no-pager 2>/dev/null || echo "❌ No kubelet logs available"
echo ""

echo "========================================"
echo "7. Kubelet Configuration"
echo "========================================"
if [ -f /etc/kubernetes/kubelet/kubelet-config.json ]; then
    echo "✓ Kubelet config exists:"
    cat /etc/kubernetes/kubelet/kubelet-config.json
else
    echo "❌ Kubelet config NOT found at /etc/kubernetes/kubelet/kubelet-config.json"
fi
echo ""

if [ -f /etc/systemd/system/kubelet.service.d/10-kubelet-args.conf ]; then
    echo "✓ Kubelet service override exists:"
    cat /etc/systemd/system/kubelet.service.d/10-kubelet-args.conf
else
    echo "⚠️  No kubelet service override found"
fi
echo ""

echo "========================================"
echo "8. Node Config (nodeadm)"
echo "========================================"
if [ -f /etc/eks/bootstrap.sh ]; then
    echo "⚠️  Old bootstrap.sh found (AL2 style)"
fi

if [ -f /etc/eks/nodeadm.yaml ]; then
    echo "✓ nodeadm config exists (AL2023 style):"
    cat /etc/eks/nodeadm.yaml
else
    echo "⚠️  nodeadm.yaml NOT found"
fi
echo ""

echo "========================================"
echo "9. Cloud-Init Status"
echo "========================================"
cloud-init status --long 2>/dev/null || echo "cloud-init command not available"
echo ""

if [ -f /var/log/cloud-init-output.log ]; then
    echo "Cloud-init output log (last 100 lines):"
    tail -100 /var/log/cloud-init-output.log
else
    echo "❌ cloud-init-output.log NOT found"
fi
echo ""

echo "========================================"
echo "10. Network Connectivity"
echo "========================================"
echo "Checking DNS resolution..."
nslookup eks.amazonaws.com 2>/dev/null || echo "⚠️  DNS resolution failed"
echo ""

if [ -f /etc/eks/nodeadm.yaml ]; then
    CLUSTER_ENDPOINT=$(grep apiServerEndpoint /etc/eks/nodeadm.yaml 2>/dev/null | awk '{print $2}' || echo "")
    if [ -n "$CLUSTER_ENDPOINT" ]; then
        echo "Testing connection to EKS API: $CLUSTER_ENDPOINT"
        curl -k -s -o /dev/null -w "HTTP Status: %{http_code}\n" "$CLUSTER_ENDPOINT/version" --max-time 5 || echo "❌ Failed to connect"
    fi
fi
echo ""

echo "========================================"
echo "11. IAM Instance Profile"
echo "========================================"
echo "Checking instance metadata..."
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
INSTANCE_PROFILE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
if [ -n "$INSTANCE_PROFILE" ]; then
    echo "✓ Instance profile attached: $INSTANCE_PROFILE"
    echo "Testing IAM credentials..."
    curl -H "X-aws-ec2-metadata-token: $TOKEN" -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/$INSTANCE_PROFILE" | jq -r '.Code' 2>/dev/null || echo "⚠️  Unable to parse credentials"
else
    echo "❌ No instance profile attached"
fi
echo ""

echo "========================================"
echo "12. System Resources"
echo "========================================"
echo "Memory:"
free -h
echo ""
echo "CPU:"
uptime
echo ""
echo "Disk I/O:"
iostat -x 1 2 2>/dev/null || echo "iostat not available"
echo ""

echo "========================================"
echo "13. Check for specific errors"
echo "========================================"
echo "Checking for common error patterns in logs..."
echo ""
echo "Containerd errors:"
journalctl -u containerd -n 50 --no-pager 2>/dev/null | grep -i "error\|fail\|fatal" | tail -10 || echo "None found"
echo ""
echo "Kubelet errors:"
journalctl -u kubelet -n 50 --no-pager 2>/dev/null | grep -i "error\|fail\|fatal" | tail -10 || echo "None found"
echo ""

echo "========================================"
echo "Summary"
echo "========================================"
echo "Checks:"
echo -n "  LVM: "
if vgs vg_data &>/dev/null; then echo "✓"; else echo "❌"; fi

echo -n "  Containerd: "
if systemctl is-active containerd &>/dev/null; then echo "✓"; else echo "❌"; fi

echo -n "  Kubelet: "
if systemctl is-active kubelet &>/dev/null; then echo "✓"; else echo "❌"; fi

echo -n "  IAM Profile: "
if [ -n "$INSTANCE_PROFILE" ]; then echo "✓"; else echo "❌"; fi

echo ""

CHECK_EOF

chmod +x /tmp/check_node_$$.sh

# 通过 SSM 执行诊断
COMMAND_ID=$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$INSTANCE_ID" \
    --parameters "commands=[$(cat /tmp/check_node_$$.sh | jq -Rs .)]" \
    --output text \
    --query 'Command.CommandId')

echo "Command ID: $COMMAND_ID"
echo "Waiting for command to complete..."
echo ""

# 等待命令完成
for i in {1..60}; do
    STATUS=$(aws ssm get-command-invocation \
        --region "${AWS_REGION}" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Pending")

    if [ "$STATUS" == "Success" ] || [ "$STATUS" == "Failed" ]; then
        break
    fi

    if [ $((i % 5)) -eq 0 ]; then
        echo "  Status: $STATUS (attempt $i/60)"
    fi
    sleep 2
done

echo ""
echo "========================================"
echo "Command Output"
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
echo "Command Errors (if any)"
echo "========================================"
echo ""

ERRORS=$(aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --output text \
    --query 'StandardErrorContent')

if [ -n "$ERRORS" ] && [ "$ERRORS" != "None" ]; then
    echo "$ERRORS"
else
    echo "No errors"
fi

rm -f /tmp/check_node_$$.sh

echo ""
echo "========================================"
echo "Next Steps"
echo "========================================"
echo ""
echo "To manually connect to the instance:"
echo "  aws ssm start-session --target $INSTANCE_ID --region ${AWS_REGION}"
echo ""
echo "Common fixes:"
echo "  1. If kubelet not running: sudo systemctl start kubelet"
echo "  2. If containerd not running: sudo systemctl start containerd"
echo "  3. Check cloud-init: sudo cloud-init status --wait"
echo ""
