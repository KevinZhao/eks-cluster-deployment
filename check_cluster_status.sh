#!/bin/bash
#
# 检查集群状态
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}检查集群状态${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

export CLUSTER_NAME=${CLUSTER_NAME:-eks-frankfurt-test}
export AWS_REGION=${AWS_REGION:-eu-central-1}

# 1. 检查节点状态
echo -e "${YELLOW}=== 1. 节点状态 ===${NC}"
kubectl get nodes -o wide
echo ""

# 2. 检查节点标签
echo -e "${YELLOW}=== 2. 节点标签 (node-group-type) ===${NC}"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.node-group-type}{"\t"}{.metadata.labels.app}{"\t"}{.metadata.labels.arch}{"\n"}{end}' | column -t
echo ""

# 3. 检查 Karpenter pods
echo -e "${YELLOW}=== 3. Karpenter Pods ===${NC}"
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o wide
echo ""

# 4. 检查 Karpenter 运行在哪些节点
echo -e "${YELLOW}=== 4. Karpenter Pod 节点调度 ===${NC}"
for pod in $(kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[*].metadata.name}'); do
    NODE=$(kubectl get pod -n kube-system $pod -o jsonpath='{.spec.nodeName}')
    NODE_LABELS=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.node-group-type}')
    echo "Pod: $pod"
    echo "  Node: $NODE"
    echo "  node-group-type: $NODE_LABELS"
    echo ""
done

# 5. 检查 NodeClaims
echo -e "${YELLOW}=== 5. NodeClaims ===${NC}"
kubectl get nodeclaim -o wide 2>/dev/null || echo "没有 NodeClaims"
echo ""

# 6. 检查 EC2NodeClass
echo -e "${YELLOW}=== 6. EC2NodeClass ===${NC}"
kubectl get ec2nodeclass -o wide
echo ""

# 7. 检查 NodePool
echo -e "${YELLOW}=== 7. NodePool ===${NC}"
kubectl get nodepool -o wide
echo ""

# 8. 检查系统 pods 分布
echo -e "${YELLOW}=== 8. 关键系统 Pods 分布 ===${NC}"
echo "CoreDNS:"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
echo ""

echo "AWS Load Balancer Controller:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o wide 2>/dev/null || echo "未安装"
echo ""

echo "Cluster Autoscaler:"
kubectl get pods -n kube-system -l app=cluster-autoscaler -o wide 2>/dev/null || echo "未安装"
echo ""

# 9. 检查最新节点的 LVM 状态
echo -e "${YELLOW}=== 9. 最新 Karpenter 节点 LVM 状态 ===${NC}"
LATEST_NODECLAIM=$(kubectl get nodeclaim --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

if [ -n "$LATEST_NODECLAIM" ]; then
    INSTANCE_ID=$(kubectl get nodeclaim "$LATEST_NODECLAIM" -o jsonpath='{.status.providerID}' 2>/dev/null | cut -d'/' -f5)
    if [ -n "$INSTANCE_ID" ]; then
        echo "最新 NodeClaim: $LATEST_NODECLAIM"
        echo "实例 ID: $INSTANCE_ID"
        echo ""

        echo "LVM 状态:"
        aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["vgs","lvs","df -h /var/lib/containerd","echo","echo \"=== Pause images ===\"","ctr -n k8s.io images ls | grep pause || echo \"No pause images\""]' \
            --region "$AWS_REGION" \
            --output text \
            --query 'Command.CommandId' 2>/dev/null | \
        xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text"
    fi
else
    echo "没有 Karpenter 创建的节点"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}检查完成${NC}"
echo -e "${GREEN}========================================${NC}"
