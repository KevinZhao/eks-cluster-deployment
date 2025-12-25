#!/bin/bash
#
# 测试 pause 镜像修复方案
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}测试 Pause 镜像修复${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

export CLUSTER_NAME=${CLUSTER_NAME:-eks-frankfurt-test}
export AWS_REGION=${AWS_REGION:-eu-central-1}
export PROJECT_ROOT=${PROJECT_ROOT:-/home/ec2-user/eks-cluster-deployment}

echo "集群: ${CLUSTER_NAME}"
echo "区域: ${AWS_REGION}"
echo ""

# 1. 应用更新的 EC2NodeClass 配置
echo -e "${YELLOW}=== 1. 应用更新的 EC2NodeClass 配置 ===${NC}"

echo "应用 default EC2NodeClass..."
sed "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" "${PROJECT_ROOT}/manifests/karpenter/ec2nodeclass-default.yaml" | kubectl apply -f -

echo ""
echo "应用 graviton EC2NodeClass..."
sed "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" "${PROJECT_ROOT}/manifests/karpenter/ec2nodeclass-graviton.yaml" | kubectl apply -f -

echo ""
echo -e "${GREEN}✓ EC2NodeClass 配置已更新${NC}"
echo ""

# 2. 删除现有的失败 NodeClaim
echo -e "${YELLOW}=== 2. 检查现有 NodeClaim ===${NC}"

NODECLAIMS=$(kubectl get nodeclaim -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -n "$NODECLAIMS" ]; then
    echo "现有 NodeClaims:"
    kubectl get nodeclaim -o wide
    echo ""

    read -p "是否删除所有现有 NodeClaims 以测试新配置? (y/n) " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for NC in $NODECLAIMS; do
            echo "删除 NodeClaim: $NC"
            kubectl delete nodeclaim "$NC" --wait=false
        done
        echo ""
        echo "等待 NodeClaims 终止..."
        sleep 10
        echo -e "${GREEN}✓ NodeClaims 已删除${NC}"
    else
        echo "保留现有 NodeClaims"
    fi
else
    echo "没有现有 NodeClaims"
fi

echo ""

# 3. 创建测试 deployment 触发节点创建
echo -e "${YELLOW}=== 3. 创建测试 Deployment ===${NC}"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test-pause
  labels:
    app: karpenter-test-pause
spec:
  replicas: 1
  selector:
    matchLabels:
      app: karpenter-test-pause
  template:
    metadata:
      labels:
        app: karpenter-test-pause
    spec:
      nodeSelector:
        karpenter.sh/nodepool: default
      containers:
      - name: nginx
        image: nginx:alpine
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF

echo ""
echo -e "${GREEN}✓ 测试 Deployment 已创建${NC}"
echo ""

# 4. 监控节点创建
echo -e "${YELLOW}=== 4. 监控节点创建 ===${NC}"
echo "等待 Karpenter 创建新节点..."
echo ""

for i in {1..30}; do
    NODECLAIM_COUNT=$(kubectl get nodeclaim 2>/dev/null | grep -c default || echo "0")
    if [ "$NODECLAIM_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ 检测到新 NodeClaim${NC}"
        break
    fi
    echo "等待中... ($i/30)"
    sleep 2
done

echo ""
kubectl get nodeclaim -o wide
echo ""

# 5. 等待节点 Ready
echo -e "${YELLOW}=== 5. 等待节点 Ready ===${NC}"

NODECLAIM_NAME=$(kubectl get nodeclaim --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

if [ -z "$NODECLAIM_NAME" ]; then
    echo -e "${RED}未找到 NodeClaim${NC}"
    exit 1
fi

echo "最新 NodeClaim: $NODECLAIM_NAME"
echo ""

# 等待最多 5 分钟
for i in {1..60}; do
    NODE_NAME=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")

    if [ -n "$NODE_NAME" ]; then
        NODE_READY=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

        if [ "$NODE_READY" = "True" ]; then
            echo -e "${GREEN}✓ 节点已 Ready!${NC}"
            echo ""
            kubectl get node "$NODE_NAME" -o wide
            break
        else
            echo "节点状态: $NODE_READY ($i/60)"
        fi
    else
        echo "等待节点注册... ($i/60)"
    fi

    sleep 5
done

echo ""

# 6. 检查节点上的镜像
if [ -n "$NODE_NAME" ]; then
    INSTANCE_ID=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.providerID}' 2>/dev/null | cut -d'/' -f5)

    if [ -n "$INSTANCE_ID" ]; then
        echo -e "${YELLOW}=== 6. 验证 pause 镜像配置 ===${NC}"

        echo "实例 ID: $INSTANCE_ID"
        echo ""

        echo "检查 pause 镜像..."
        aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["echo \"=== Pause images ===\"","ctr -n k8s.io images ls | grep pause","echo","echo \"=== LVM status ===\"","vgs","lvs","df -h /var/lib/containerd"]' \
            --region "$AWS_REGION" \
            --output text \
            --query 'Command.CommandId' 2>/dev/null | \
        xargs -I {} sh -c "sleep 5 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"

        echo ""
    fi
fi

# 7. 检查 pod 状态
echo -e "${YELLOW}=== 7. 检查测试 Pod 状态 ===${NC}"
kubectl get pods -l app=karpenter-test-pause -o wide
echo ""

# 8. 检查 system pods
if [ -n "$NODE_NAME" ]; then
    echo -e "${YELLOW}=== 8. 检查节点上的 system pods ===${NC}"
    kubectl get pods -n kube-system --field-selector spec.nodeName="$NODE_NAME" -o wide
    echo ""
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}测试完成${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}后续操作:${NC}"
echo ""
echo "查看 Karpenter 日志:"
echo "  kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f"
echo ""
echo "清理测试资源:"
echo "  kubectl delete deployment karpenter-test-pause"
echo ""
echo "查看节点详情:"
echo "  kubectl describe node $NODE_NAME"
echo ""
