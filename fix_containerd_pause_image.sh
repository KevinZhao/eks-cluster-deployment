#!/bin/bash
#
# 修复 containerd pause 镜像配置问题
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}修复 Containerd Pause 镜像配置${NC}"
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

echo "NodeClaim: $NODECLAIM_NAME"
echo "实例 ID: $INSTANCE_ID"
echo ""

# 1. 检查当前的 containerd 配置
echo -e "${YELLOW}=== 1. 检查 containerd 配置 ===${NC}"
CONTAINERD_CONFIG=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["cat /etc/containerd/config.toml | grep -A 5 sandbox_image || echo \"No sandbox_image config\""]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text")

echo "$CONTAINERD_CONFIG"
echo ""

# 2. 检查是否有 ECR 镜像
echo -e "${YELLOW}=== 2. 检查可用的 pause 镜像 ===${NC}"
PAUSE_IMAGES=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["ctr -n k8s.io images ls | grep pause || echo \"No pause images\""]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text")

echo "$PAUSE_IMAGES"
echo ""

# 3. 检查 containerd 服务状态
echo -e "${YELLOW}=== 3. Containerd 服务状态 ===${NC}"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["systemctl status containerd --no-pager | head -20"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

# 4. 手动拉取正确的 pause 镜像
echo -e "${YELLOW}=== 4. 手动拉取 pause 镜像 ===${NC}"

# 获取 EKS pause 镜像地址
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_ENDPOINT="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
PAUSE_IMAGE="public.ecr.aws/eks-distro/kubernetes/pause:3.9"

echo "拉取 pause 镜像: $PAUSE_IMAGE"
echo ""

PULL_RESULT=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"ctr -n k8s.io images pull $PAUSE_IMAGE\",\"ctr -n k8s.io images ls | grep pause\"]" \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 5 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query '[StandardOutputContent,StandardErrorContent]' --output text")

echo "$PULL_RESULT"
echo ""

# 5. 更新 containerd 配置指向正确的镜像
echo -e "${YELLOW}=== 5. 更新 containerd 配置 ===${NC}"

UPDATE_CONFIG=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"# Backup original config\",\"cp /etc/containerd/config.toml /etc/containerd/config.toml.bak\",\"# Update sandbox_image\",\"sed -i 's|sandbox_image = .*|sandbox_image = \\\"$PAUSE_IMAGE\\\"|' /etc/containerd/config.toml\",\"# Show the change\",\"grep sandbox_image /etc/containerd/config.toml\",\"# Restart containerd\",\"systemctl restart containerd\",\"sleep 3\",\"systemctl status containerd --no-pager | head -10\"]" \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 8 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query '[StandardOutputContent,StandardErrorContent]' --output text")

echo "$UPDATE_CONFIG"
echo ""

# 6. 等待节点 Ready
echo -e "${YELLOW}=== 6. 等待节点 Ready ===${NC}"
echo "等待 30 秒让 kubelet 重新初始化..."
sleep 30

NODE_NAME=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")

if [ -n "$NODE_NAME" ]; then
    echo "检查节点状态:"
    kubectl get node "$NODE_NAME" -o wide
    echo ""

    NODE_READY=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

    if [ "$NODE_READY" = "True" ]; then
        echo -e "${GREEN}✓ 节点已 Ready!${NC}"
    else
        echo -e "${YELLOW}⚠ 节点仍未 Ready，继续检查...${NC}"
        echo ""
        echo "节点状态条件:"
        kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions}' | jq .
        echo ""

        echo "System pods 状态:"
        kubectl get pods -n kube-system -o wide --field-selector spec.nodeName="$NODE_NAME"
    fi
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}修复完成${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}如果节点仍未 Ready:${NC}"
echo ""
echo "1. 检查 aws-node (CNI) pod 日志:"
echo "   kubectl logs -n kube-system -l k8s-app=aws-node --field-selector spec.nodeName=$NODE_NAME"
echo ""
echo "2. 检查 kubelet 日志:"
echo "   # 通过 SSM 连接到节点"
echo "   aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION"
echo "   # 查看日志"
echo "   journalctl -u kubelet -f"
echo ""
