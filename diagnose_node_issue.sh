#!/bin/bash
#
# 诊断 Karpenter 节点无法加入集群的问题
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}诊断 Karpenter 节点问题${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

export CLUSTER_NAME=${CLUSTER_NAME:-eks-frankfurt-test}
export AWS_REGION=${AWS_REGION:-eu-central-1}

echo "集群: ${CLUSTER_NAME}"
echo "区域: ${AWS_REGION}"
echo ""

# 1. 检查节点状态
echo -e "${YELLOW}=== 1. 检查所有节点状态 ===${NC}"
kubectl get nodes -o wide
echo ""

# 2. 检查 Unknown 状态的节点详情
echo -e "${YELLOW}=== 2. 检查 Unknown 状态节点的详细信息 ===${NC}"
UNKNOWN_NODES=$(kubectl get nodes --no-headers | grep Unknown | awk '{print $1}')

if [ -z "$UNKNOWN_NODES" ]; then
    echo "没有发现 Unknown 状态的节点"
else
    for NODE in $UNKNOWN_NODES; do
        echo -e "${BLUE}节点: $NODE${NC}"
        echo ""

        echo "节点状态条件:"
        kubectl describe node "$NODE" | grep -A 20 "Conditions:"
        echo ""

        echo "节点事件:"
        kubectl get events --field-selector involvedObject.name="$NODE" --sort-by='.lastTimestamp' | tail -20
        echo ""
    done
fi

# 3. 检查 NodeClaim 状态
echo -e "${YELLOW}=== 3. 检查 NodeClaim 状态 ===${NC}"
kubectl get nodeclaim -o wide
echo ""

# 4. 获取 NodeClaim 对应的实例 ID
echo -e "${YELLOW}=== 4. 获取实例详情 ===${NC}"
NODECLAIM_NAME=$(kubectl get nodeclaim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$NODECLAIM_NAME" ]; then
    echo "NodeClaim: $NODECLAIM_NAME"

    INSTANCE_ID=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.providerID}' 2>/dev/null | cut -d'/' -f5)

    if [ -n "$INSTANCE_ID" ]; then
        echo "实例 ID: $INSTANCE_ID"
        echo ""

        # 5. 检查实例状态
        echo -e "${YELLOW}=== 5. 检查 EC2 实例状态 ===${NC}"
        aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PrivateIpAddress,InstanceType]' \
            --output table
        echo ""

        # 6. 检查实例网络连接
        echo -e "${YELLOW}=== 6. 检查实例网络配置 ===${NC}"
        aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].NetworkInterfaces[0].[PrivateIpAddress,SubnetId,VpcId,Groups[].GroupId]' \
            --output table
        echo ""

        # 7. 检查 console output 中的错误
        echo -e "${YELLOW}=== 7. 检查控制台输出中的错误 ===${NC}"
        CONSOLE_OUTPUT=$(aws ec2 get-console-output \
            --instance-id "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --output text 2>/dev/null || echo "")

        if [ -n "$CONSOLE_OUTPUT" ]; then
            echo "检查 cloud-init 错误:"
            echo "$CONSOLE_OUTPUT" | grep -i "error\|fail\|fatal" | tail -20
            echo ""

            echo "检查 LVM 相关日志:"
            echo "$CONSOLE_OUTPUT" | grep -i "lvm\|pvcreate\|vgcreate\|containerd" | tail -20
            echo ""

            echo "检查 kubelet 状态:"
            echo "$CONSOLE_OUTPUT" | grep -i "kubelet" | tail -20
            echo ""
        else
            echo "控制台输出暂不可用"
        fi

        # 8. 尝试通过 SSM 连接并检查
        echo -e "${YELLOW}=== 8. 通过 SSM 检查节点内部状态 ===${NC}"
        echo ""
        echo "检查 containerd 状态:"
        aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["systemctl status containerd --no-pager"]' \
            --region "$AWS_REGION" \
            --output text \
            --query 'Command.CommandId' 2>/dev/null | \
        xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text" || \
        echo "无法通过 SSM 连接"
        echo ""

        echo "检查 kubelet 状态:"
        aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["systemctl status kubelet --no-pager"]' \
            --region "$AWS_REGION" \
            --output text \
            --query 'Command.CommandId' 2>/dev/null | \
        xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text" || \
        echo "无法获取 kubelet 状态"
        echo ""

        echo "检查 kubelet 日志:"
        aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["journalctl -u kubelet --no-pager -n 50"]' \
            --region "$AWS_REGION" \
            --output text \
            --query 'Command.CommandId' 2>/dev/null | \
        xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text" || \
        echo "无法获取 kubelet 日志"
        echo ""

        echo "检查 LVM 配置:"
        aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["vgs && lvs && df -h /var/lib/containerd"]' \
            --region "$AWS_REGION" \
            --output text \
            --query 'Command.CommandId' 2>/dev/null | \
        xargs -I {} sh -c "sleep 3 && aws ssm get-command-invocation --command-id {} --instance-id $INSTANCE_ID --region $AWS_REGION --query 'StandardOutputContent' --output text" || \
        echo "无法获取 LVM 配置"
        echo ""
    fi
fi

# 9. 检查 Karpenter 日志
echo -e "${YELLOW}=== 9. 检查 Karpenter 控制器日志 ===${NC}"
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 | grep -i "error\|fail\|warn" || echo "没有发现明显错误"
echo ""

# 10. 检查集群的网络配置
echo -e "${YELLOW}=== 10. 检查集群网络配置 ===${NC}"
echo "集群安全组:"
CLUSTER_SG=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text)
echo "  $CLUSTER_SG"

echo ""
echo "集群安全组入站规则:"
aws ec2 describe-security-groups \
    --group-ids "$CLUSTER_SG" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,UserIdGroupPairs[0].GroupId,CidrIp]' \
    --output table
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}诊断完成${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}常见问题排查:${NC}"
echo ""
echo "1. 节点状态为 Unknown 通常意味着:"
echo "   - kubelet 无法与 API server 通信"
echo "   - containerd 未正常启动"
echo "   - 网络连接问题"
echo ""
echo "2. 如果 LVM 配置失败:"
echo "   - 检查 console output 中的 boothook 执行日志"
echo "   - 确认 user-data 中的 \$\$ 变量是否正确展开"
echo "   - 通过 SSM 手动登录节点检查: aws ssm start-session --target $INSTANCE_ID"
echo ""
echo "3. 如果 kubelet 未启动:"
echo "   - 检查 containerd 是否正常运行"
echo "   - 检查 /var/lib/containerd 是否挂载成功"
echo "   - 查看 kubelet 日志: journalctl -u kubelet"
echo ""
echo "4. 如果网络问题:"
echo "   - 确认节点安全组允许访问集群 API (port 443)"
echo "   - 确认子网路由表配置正确"
echo "   - 检查 VPC DNS 设置"
echo ""
