#!/bin/bash
#
# 修复 Karpenter 节点认证问题
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}修复 Karpenter 节点认证问题${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

export CLUSTER_NAME=${CLUSTER_NAME:-eks-frankfurt-test}
export AWS_REGION=${AWS_REGION:-eu-central-1}
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "集群: ${CLUSTER_NAME}"
echo "区域: ${AWS_REGION}"
echo "账号: ${AWS_ACCOUNT_ID}"
echo ""

# 1. 检查并修复 Karpenter Node Role 的访问权限
echo -e "${YELLOW}=== 1. 配置 Karpenter Node Role 的集群访问 ===${NC}"
KARPENTER_NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
KARPENTER_NODE_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE}"

echo "节点角色: ${KARPENTER_NODE_ROLE}"
echo "节点角色 ARN: ${KARPENTER_NODE_ROLE_ARN}"
echo ""

# 创建 EKS access entry
echo "创建 EKS access entry..."
aws eks create-access-entry \
    --cluster-name "${CLUSTER_NAME}" \
    --principal-arn "${KARPENTER_NODE_ROLE_ARN}" \
    --type EC2_LINUX \
    --region "${AWS_REGION}" 2>/dev/null && \
    echo "  ✓ Access entry 创建成功" || \
    echo "  ℹ Access entry 已存在"

echo ""

# 2. 检查子网标签
echo -e "${YELLOW}=== 2. 检查并修复子网标签 ===${NC}"

# 获取私有子网列表
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.vpcId' --output text)" \
    --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' \
    --region "${AWS_REGION}" \
    --output text)

echo "发现私有子网: $PRIVATE_SUBNETS"
echo ""

for SUBNET in $PRIVATE_SUBNETS; do
    echo "标记子网: $SUBNET"
    aws ec2 create-tags \
        --resources "$SUBNET" \
        --tags Key=karpenter.sh/discovery,Value="${CLUSTER_NAME}" \
        --region "${AWS_REGION}" 2>/dev/null && \
        echo "  ✓ 子网 $SUBNET 标记成功" || \
        echo "  ℹ 子网 $SUBNET 标签已存在"
done

echo ""

# 3. 检查安全组标签
echo -e "${YELLOW}=== 3. 检查并修复安全组标签 ===${NC}"

CLUSTER_SG=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text)

echo "集群安全组: $CLUSTER_SG"

aws ec2 create-tags \
    --resources "$CLUSTER_SG" \
    --tags Key=karpenter.sh/discovery,Value="${CLUSTER_NAME}" \
    --region "${AWS_REGION}" 2>/dev/null && \
    echo "  ✓ 安全组标记成功" || \
    echo "  ℹ 安全组标签已存在"

echo ""

# 4. 删除现有的失败 NodeClaim
echo -e "${YELLOW}=== 4. 删除失败的 NodeClaim ===${NC}"

FAILED_NODECLAIMS=$(kubectl get nodeclaim -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="Unknown")) | .metadata.name' 2>/dev/null || echo "")

if [ -n "$FAILED_NODECLAIMS" ]; then
    echo "发现失败的 NodeClaims:"
    echo "$FAILED_NODECLAIMS"
    echo ""

    read -p "是否删除这些失败的 NodeClaims? (y/n) " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for NC in $FAILED_NODECLAIMS; do
            echo "删除 NodeClaim: $NC"
            kubectl delete nodeclaim "$NC" --timeout=60s
        done
        echo -e "${GREEN}✓ 失败的 NodeClaims 已删除${NC}"
    fi
else
    echo "没有发现失败的 NodeClaims"
fi

echo ""

# 5. 重启 Karpenter pods 以重新加载配置
echo -e "${YELLOW}=== 5. 重启 Karpenter pods ===${NC}"

read -p "是否重启 Karpenter pods? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    kubectl rollout restart deployment -n kube-system -l app.kubernetes.io/name=karpenter
    echo "等待 Karpenter pods 就绪..."
    kubectl rollout status deployment -n kube-system -l app.kubernetes.io/name=karpenter --timeout=120s
    echo -e "${GREEN}✓ Karpenter pods 重启完成${NC}"
fi

echo ""

# 6. 验证配置
echo -e "${YELLOW}=== 6. 验证配置 ===${NC}"

echo "检查 EKS access entries:"
aws eks list-access-entries \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'accessEntries' \
    --output table

echo ""
echo "检查 EC2NodeClass 状态:"
kubectl get ec2nodeclass -o wide

echo ""
echo "检查 NodePool 状态:"
kubectl get nodepool -o wide

echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}修复完成${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}后续步骤:${NC}"
echo ""
echo "1. 等待几分钟让 Karpenter 重新同步配置"
echo ""
echo "2. 检查 Karpenter 日志确认错误消失:"
echo "   kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f"
echo ""
echo "3. 创建测试 deployment 触发节点创建:"
echo "   kubectl scale deployment karpenter-test --replicas=2"
echo ""
echo "4. 监控新节点加入:"
echo "   watch -n 5 'kubectl get nodeclaim -o wide && echo && kubectl get nodes -o wide'"
echo ""
echo "5. 如果节点成功加入，验证 LVM 配置:"
echo "   # 获取新节点的实例 ID"
echo "   INSTANCE_ID=\$(kubectl get nodeclaim -o jsonpath='{.items[0].status.providerID}' | cut -d'/' -f5)"
echo "   # 通过 SSM 连接"
echo "   aws ssm start-session --target \$INSTANCE_ID --region ${AWS_REGION}"
echo "   # 在节点上检查: vgs && lvs && df -h /var/lib/containerd"
echo ""
