#!/bin/bash
#
# 检查节点 Ready 状态
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}检查节点 Ready 状态${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

export CLUSTER_NAME=${CLUSTER_NAME:-eks-frankfurt-test}
export AWS_REGION=${AWS_REGION:-eu-central-1}

# 1. 查看所有节点状态
echo -e "${YELLOW}=== 1. 所有节点状态 ===${NC}"
kubectl get nodes -o wide
echo ""

# 2. 查看 NodeClaim 状态
echo -e "${YELLOW}=== 2. NodeClaim 状态 ===${NC}"
kubectl get nodeclaim -o wide
echo ""

# 获取最新的 NodeClaim
NODECLAIM_NAME=$(kubectl get nodeclaim --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

if [ -z "$NODECLAIM_NAME" ]; then
    echo -e "${RED}未找到 NodeClaim${NC}"
    exit 1
fi

echo "最新 NodeClaim: $NODECLAIM_NAME"
echo ""

# 3. 查看 NodeClaim 详细信息
echo -e "${YELLOW}=== 3. NodeClaim 详细信息 ===${NC}"
kubectl get nodeclaim "$NODECLAIM_NAME" -o json | jq -r '.status.conditions[] | "\(.type): \(.status) - \(.message)"'
echo ""

# 4. 获取对应的 Node 名称
NODE_NAME=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")

if [ -z "$NODE_NAME" ]; then
    echo -e "${RED}NodeClaim 尚未关联到 Node${NC}"
    echo ""

    # 检查 NodeClaim 事件
    echo -e "${YELLOW}=== NodeClaim 事件 ===${NC}"
    kubectl describe nodeclaim "$NODECLAIM_NAME" | grep -A 20 "Events:"
    exit 0
fi

echo "对应 Node: $NODE_NAME"
echo ""

# 5. 查看 Node 详细状态
echo -e "${YELLOW}=== 4. Node 状态条件 ===${NC}"
kubectl get node "$NODE_NAME" -o json | jq -r '.status.conditions[] | "\(.type): \(.status) - \(.message)"'
echo ""

# 6. 检查 Node 是否 Ready
NODE_READY=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

if [ "$NODE_READY" = "True" ]; then
    echo -e "${GREEN}✓ 节点已 Ready${NC}"
elif [ "$NODE_READY" = "False" ]; then
    echo -e "${RED}✗ 节点未 Ready${NC}"
    echo ""
    echo -e "${YELLOW}=== 未 Ready 原因 ===${NC}"
    kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
    echo ""
else
    echo -e "${YELLOW}⚠ 节点状态未知${NC}"
fi

echo ""

# 7. 检查节点上的 pods
echo -e "${YELLOW}=== 5. 节点上的 system pods ===${NC}"
kubectl get pods -n kube-system -o wide --field-selector spec.nodeName="$NODE_NAME"
echo ""

# 8. 获取实例 ID 并通过 SSM 检查
INSTANCE_ID=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.providerID}' 2>/dev/null | cut -d'/' -f5)

if [ -z "$INSTANCE_ID" ]; then
    echo -e "${RED}未找到实例 ID${NC}"
    exit 1
fi

echo "实例 ID: $INSTANCE_ID"
echo ""

# 9. 检查节点上的 kubelet 状态
echo -e "${YELLOW}=== 6. Kubelet 服务状态 ===${NC}"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["systemctl status kubelet --no-pager -l"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

# 10. 检查最近的 kubelet 日志
echo -e "${YELLOW}=== 7. Kubelet 最近日志 (最后 30 行) ===${NC}"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["journalctl -u kubelet --no-pager -n 30"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

# 11. 检查 containerd 状态
echo -e "${YELLOW}=== 8. Containerd 服务状态 ===${NC}"
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["systemctl status containerd --no-pager -l"]' \
    --region "$AWS_REGION" \
    --output text \
    --query 'Command.CommandId' 2>/dev/null | \
xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

echo ""

# 12. 检查网络插件 pods
echo -e "${YELLOW}=== 9. CNI/网络插件状态 ===${NC}"
kubectl get pods -n kube-system -l k8s-app=aws-node -o wide | grep -E "NAME|$NODE_NAME" || echo "未找到 aws-node pod"
echo ""
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide | grep -E "NAME|$NODE_NAME" || echo "未找到 kube-proxy pod"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}检查完成${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}分析提示:${NC}"
echo ""
echo "1. 如果 Node Ready 状态为 False，查看原因消息"
echo "2. 检查 kubelet 是否正常运行"
echo "3. 检查 CNI 插件 (aws-node) 是否在节点上运行"
echo "4. 检查 containerd 是否正常运行"
echo "5. 如果节点刚创建不久，可能需要等待几分钟让所有组件启动"
echo ""
