#!/bin/bash
#
# 检查 Karpenter 节点的 user-data 和 LVM 执行情况
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}检查 Karpenter 节点 LVM 配置${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

export CLUSTER_NAME=${CLUSTER_NAME:-eks-frankfurt-test}
export AWS_REGION=${AWS_REGION:-eu-central-1}

# 获取最新的 NodeClaim
NODECLAIM_NAME=$(kubectl get nodeclaim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$NODECLAIM_NAME" ]; then
    echo -e "${RED}未找到 NodeClaim${NC}"
    exit 1
fi

echo "NodeClaim: $NODECLAIM_NAME"

# 获取实例 ID
INSTANCE_ID=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.providerID}' 2>/dev/null | cut -d'/' -f5)

if [ -z "$INSTANCE_ID" ]; then
    echo -e "${RED}未找到实例 ID${NC}"
    exit 1
fi

echo "实例 ID: $INSTANCE_ID"
echo ""

# 1. 检查实例的磁盘配置
echo -e "${YELLOW}=== 1. 检查实例磁盘配置 ===${NC}"
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[*].[DeviceName,Ebs.VolumeId]' \
    --output table

echo ""

# 2. 获取并显示 user-data
echo -e "${YELLOW}=== 2. 检查实例 user-data ===${NC}"
USER_DATA=$(aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute userData \
    --region "$AWS_REGION" \
    --query 'UserData.Value' \
    --output text 2>/dev/null | base64 -d)

if [ -n "$USER_DATA" ]; then
    echo "User-data 中的 LVM 脚本部分:"
    echo "================================"
    echo "$USER_DATA" | grep -A 40 "Auto-detect EBS data disk" || echo "未找到 LVM 脚本"
    echo "================================"
    echo ""

    # 检查关键变量
    echo "检查关键变量的值:"
    echo ""

    if echo "$USER_DATA" | grep -q 'DATA_DISK=\$\$'; then
        echo -e "${YELLOW}⚠ 发现 DATA_DISK=\$\$ (使用了 \$\$ 转义)${NC}"
        echo "   sed 替换后应该变成: DATA_DISK=\$"
        echo ""
    fi

    if echo "$USER_DATA" | grep -q 'if \[ -z "\$\$DATA_DISK"'; then
        echo -e "${RED}✗ 发现 if [ -z \"\$\$DATA_DISK\" ] (错误的引用方式)${NC}"
        echo "   sed 替换后会变成: if [ -z \"\$DATA_DISK\" ]"
        echo ""
    fi

    # 显示实际的条件判断行
    echo "实际的条件判断语句:"
    echo "$USER_DATA" | grep -E "if \[ -z|DATA_DISK=" | head -5
    echo ""
else
    echo -e "${RED}无法获取 user-data${NC}"
fi

echo ""

# 3. 检查 console output 中的 LVM 执行日志
echo -e "${YELLOW}=== 3. 检查 console output 中的 LVM 日志 ===${NC}"
CONSOLE_OUTPUT=$(aws ec2 get-console-output \
    --instance-id "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --output text 2>/dev/null || echo "")

if [ -n "$CONSOLE_OUTPUT" ]; then
    echo "Cloud-init boothook 相关日志:"
    echo "================================"
    echo "$CONSOLE_OUTPUT" | grep -A 10 -B 5 "boothook\|Auto-detect\|DATA_DISK\|lvm\|pvcreate\|vgcreate" | tail -50
    echo "================================"
    echo ""
else
    echo -e "${YELLOW}Console output 暂不可用${NC}"
fi

echo ""

# 4. 通过 SSM 检查节点上的实际配置
echo -e "${YELLOW}=== 4. 检查节点上的磁盘和 LVM 状态 ===${NC}"

echo "磁盘列表:"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["lsblk"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

echo "LVM 状态:"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["vgs 2>/dev/null || echo \"No VG found\"","lvs 2>/dev/null || echo \"No LV found\""]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

echo "Containerd 数据目录:"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["df -h /var/lib/containerd"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

echo "检查 boothook 脚本文件:"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["ls -la /var/lib/cloud/instances/*/boothooks/ 2>/dev/null || echo \"No boothooks found\""]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

echo "查看实际的 boothook 脚本内容:"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["cat /var/lib/cloud/instances/*/boothooks/part-* 2>/dev/null | head -30"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}检查完成${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}分析提示:${NC}"
echo ""
echo "1. 如果 user-data 中看到 DATA_DISK=\$\$，说明 sed 替换正确"
echo "   - sed 会把 \$\$ 转换为 \$ (单个美元符号)"
echo "   - 在 shell 执行时，\$ 后面跟着普通字符会被当作变量引用"
echo ""
echo "2. 如果 boothook 脚本中看到 DATA_DISK=\$，说明转换正确"
echo "   - 应该能正确执行命令替换"
echo ""
echo "3. 如果磁盘列表中有 nvme1n1 但 LVM 未配置，可能原因:"
echo "   - Boothook 脚本执行失败"
echo "   - 变量展开问题"
echo "   - 脚本逻辑错误"
echo ""
