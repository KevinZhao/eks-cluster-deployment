#!/bin/bash
#
# 验证最新节点的 LVM 配置和执行情况
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}验证 LVM 配置执行${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

export CLUSTER_NAME=${CLUSTER_NAME:-eks-frankfurt-test}
export AWS_REGION=${AWS_REGION:-eu-central-1}

# 获取最新的 NodeClaim
NODECLAIM_NAME=$(kubectl get nodeclaim --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

if [ -z "$NODECLAIM_NAME" ]; then
    echo -e "${RED}未找到 NodeClaim${NC}"
    exit 1
fi

INSTANCE_ID=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.providerID}' 2>/dev/null | cut -d'/' -f5)

if [ -z "$INSTANCE_ID" ]; then
    echo -e "${RED}未找到实例 ID${NC}"
    exit 1
fi

CREATION_TIME=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.metadata.creationTimestamp}')

echo "NodeClaim: $NODECLAIM_NAME"
echo "实例 ID: $INSTANCE_ID"
echo "创建时间: $CREATION_TIME"
echo ""

# 1. 检查节点上实际的 boothook 脚本
echo -e "${YELLOW}=== 1. 检查节点上的 boothook 脚本 ===${NC}"
BOOTHOOK_CONTENT=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["cat /var/lib/cloud/instances/*/boothooks/part-* 2>/dev/null || echo \"No boothook found\""]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text")

echo "$BOOTHOOK_CONTENT"
echo ""

# 分析脚本内容
echo -e "${YELLOW}关键变量检查:${NC}"
if echo "$BOOTHOOK_CONTENT" | grep -q 'if \[ -z "\$\$(lsblk'; then
    echo -e "${GREEN}✓ 发现内联命令替换: if [ -z \"\$\$(lsblk...\" ]${NC}"
elif echo "$BOOTHOOK_CONTENT" | grep -q 'if \[ -z "\$(lsblk'; then
    echo -e "${GREEN}✓ 发现正确的命令替换: if [ -z \"\$(lsblk...\" ]${NC}"
elif echo "$BOOTHOOK_CONTENT" | grep -q 'DATA_DISK=\$\$'; then
    echo -e "${RED}✗ 仍在使用变量方式: DATA_DISK=\$\$${NC}"
else
    echo -e "${YELLOW}⚠ 未识别的脚本格式${NC}"
fi
echo ""

# 2. 查看 cloud-init 日志
echo -e "${YELLOW}=== 2. 检查 cloud-init 执行日志 ===${NC}"
CLOUD_INIT_LOG=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["grep -i \"boothook\\|lvm\\|pvcreate\\|vgcreate\\|data disk\" /var/log/cloud-init-output.log 2>/dev/null | tail -30 || echo \"No logs found\""]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text")

echo "$CLOUD_INIT_LOG"
echo ""

# 3. 检查磁盘状态
echo -e "${YELLOW}=== 3. 检查磁盘配置 ===${NC}"
DISK_INFO=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["echo \"=== lsblk ===\"","lsblk","echo","echo \"=== vgs ===\"","vgs 2>/dev/null || echo \"No VG\"","echo","echo \"=== lvs ===\"","lvs 2>/dev/null || echo \"No LV\"","echo","echo \"=== df /var/lib/containerd ===\"","df -h /var/lib/containerd"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text")

echo "$DISK_INFO"
echo ""

# 4. 手动测试内联命令是否工作
echo -e "${YELLOW}=== 4. 手动测试磁盘检测命令 ===${NC}"
DISK_DETECT_TEST=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["echo \"Testing disk detection:\"","DISK=\$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)","echo \"Detected disk: \$DISK\"","if [ -z \"\$DISK\" ]; then echo \"No disk found\"; else echo \"Disk found: \$DISK\"; fi"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text")

echo "$DISK_DETECT_TEST"
echo ""

# 5. 检查 boothook 执行的退出状态
echo -e "${YELLOW}=== 5. 检查 boothook 执行状态 ===${NC}"
BOOTHOOK_STATUS=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["grep -A 5 -B 5 \"Boothook\" /var/log/cloud-init.log 2>/dev/null | tail -20 || echo \"No status found\""]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text")

echo "$BOOTHOOK_STATUS"
echo ""

# 6. 尝试手动执行 LVM 配置
echo -e "${YELLOW}=== 6. 尝试手动配置 LVM ===${NC}"
read -p "是否尝试手动在节点上配置 LVM? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "执行 LVM 配置..."

    MANUAL_LVM=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["set -x","DATA_DISK=\$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)","echo \"Data disk: \$DATA_DISK\"","if [ -z \"\$DATA_DISK\" ]; then echo \"ERROR: No data disk found\"; exit 1; fi","if vgs vg_data &>/dev/null; then echo \"LVM already configured\"; exit 0; fi","systemctl stop containerd","dnf install -y lvm2","pvcreate \"\$DATA_DISK\"","vgcreate vg_data \"\$DATA_DISK\"","lvcreate -l 100%VG -n lv_containerd vg_data","mkfs.xfs /dev/vg_data/lv_containerd","mkdir -p /var/lib/containerd","mount /dev/vg_data/lv_containerd /var/lib/containerd","echo \"/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2\" >> /etc/fstab","systemctl start containerd","echo \"LVM configuration completed\""]' \
        --region "$AWS_REGION" \
        --output text \
        --query 'Command.CommandId' 2>/dev/null | \
    xargs -I {} sh -c "sleep 10 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query '[StandardOutputContent,StandardErrorContent]' --output text")

    echo "$MANUAL_LVM"
    echo ""

    echo "验证 LVM 配置:"
    sleep 3
    aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["vgs","lvs","df -h /var/lib/containerd"]' \
        --region "$AWS_REGION" \
        --output text \
        --query 'Command.CommandId' 2>/dev/null | \
    xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}验证完成${NC}"
echo -e "${GREEN}========================================${NC}"
