#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== eksctl CloudFormation Creation Failure Diagnosis ==="
echo ""

# 加载环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo ""

# 1. 检查 eksctl 日志
echo "=========================================="
echo "1. Checking eksctl logs"
echo "=========================================="
if [ -f /tmp/eksctl_create_nodegroup.log ]; then
    echo "Last 50 lines of eksctl log:"
    tail -50 /tmp/eksctl_create_nodegroup.log
    echo ""
    echo "Searching for errors in log:"
    grep -i "error\|fail\|denied\|invalid" /tmp/eksctl_create_nodegroup.log || echo "No obvious errors found in log"
else
    echo "⚠️  eksctl log not found at /tmp/eksctl_create_nodegroup.log"
fi
echo ""

# 2. 检查 CloudFormation 栈状态
echo "=========================================="
echo "2. Checking CloudFormation stacks"
echo "=========================================="
echo "Looking for stacks related to ${CLUSTER_NAME}..."
STACKS=$(aws cloudformation list-stacks \
    --region "${AWS_REGION}" \
    --stack-status-filter CREATE_IN_PROGRESS CREATE_FAILED CREATE_COMPLETE ROLLBACK_IN_PROGRESS ROLLBACK_COMPLETE \
    --query "StackSummaries[?contains(StackName, '${CLUSTER_NAME}')].{Name:StackName,Status:StackStatus,Time:CreationTime}" \
    --output table)

echo "$STACKS"
echo ""

# 获取最新的失败栈
FAILED_STACK=$(aws cloudformation list-stacks \
    --region "${AWS_REGION}" \
    --stack-status-filter CREATE_FAILED ROLLBACK_COMPLETE ROLLBACK_IN_PROGRESS \
    --query "StackSummaries[?contains(StackName, '${CLUSTER_NAME}') && contains(StackName, 'nodegroup')] | [0].StackName" \
    --output text)

if [ -n "$FAILED_STACK" ] && [ "$FAILED_STACK" != "None" ]; then
    echo "Found failed stack: $FAILED_STACK"
    echo ""
    echo "Stack events (last 20):"
    aws cloudformation describe-stack-events \
        --region "${AWS_REGION}" \
        --stack-name "$FAILED_STACK" \
        --max-items 20 \
        --query 'StackEvents[].[Timestamp,ResourceType,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
        --output table
    echo ""

    echo "Looking for failure reasons:"
    aws cloudformation describe-stack-events \
        --region "${AWS_REGION}" \
        --stack-name "$FAILED_STACK" \
        --query "StackEvents[?contains(ResourceStatus, 'FAILED')].{Time:Timestamp,Resource:LogicalResourceId,Status:ResourceStatus,Reason:ResourceStatusReason}" \
        --output table
else
    echo "No failed stacks found (this might mean stack creation never started)"
fi
echo ""

# 3. 检查 IAM Role 和权限
echo "=========================================="
echo "3. Checking IAM Role and Permissions"
echo "=========================================="
NODE_ROLE_NAME="EKSNodeRole-eks-frankfurt"

# 检查 Role 是否存在
if aws iam get-role --role-name "${NODE_ROLE_NAME}" &>/dev/null; then
    echo "✓ IAM Role exists: ${NODE_ROLE_NAME}"

    # 检查附加的策略
    echo ""
    echo "Attached policies:"
    aws iam list-attached-role-policies --role-name "${NODE_ROLE_NAME}" --output table

    # 检查 Role 的 tags
    echo ""
    echo "Role tags:"
    aws iam list-role-tags --role-name "${NODE_ROLE_NAME}" --output table
else
    echo "❌ IAM Role NOT found: ${NODE_ROLE_NAME}"
fi
echo ""

# 检查 Instance Profile
if aws iam get-instance-profile --instance-profile-name "${NODE_ROLE_NAME}" &>/dev/null; then
    echo "✓ Instance Profile exists: ${NODE_ROLE_NAME}"

    # 检查 Instance Profile 是否关联了 Role
    PROFILE_ROLE=$(aws iam get-instance-profile \
        --instance-profile-name "${NODE_ROLE_NAME}" \
        --query 'InstanceProfile.Roles[0].RoleName' \
        --output text)

    if [ "$PROFILE_ROLE" == "${NODE_ROLE_NAME}" ]; then
        echo "✓ Instance Profile correctly linked to Role"
    else
        echo "❌ Instance Profile NOT linked to Role (found: $PROFILE_ROLE)"
    fi
else
    echo "❌ Instance Profile NOT found: ${NODE_ROLE_NAME}"
fi
echo ""

# 4. 检查 Launch Template
echo "=========================================="
echo "4. Checking Launch Template"
echo "=========================================="
LT_NAME="${CLUSTER_NAME}-eks-utils-x86-lt"

if aws ec2 describe-launch-templates \
    --launch-template-names "${LT_NAME}" \
    --region "${AWS_REGION}" &>/dev/null; then

    echo "✓ Launch Template exists: ${LT_NAME}"

    LT_INFO=$(aws ec2 describe-launch-templates \
        --launch-template-names "${LT_NAME}" \
        --region "${AWS_REGION}" \
        --output json)

    LT_ID=$(echo "$LT_INFO" | jq -r '.LaunchTemplates[0].LaunchTemplateId')
    LT_VERSION=$(echo "$LT_INFO" | jq -r '.LaunchTemplates[0].LatestVersionNumber')

    echo "  ID: ${LT_ID}"
    echo "  Latest Version: ${LT_VERSION}"
    echo ""

    # 获取最新版本的详细信息
    echo "Latest version details:"
    aws ec2 describe-launch-template-versions \
        --launch-template-id "${LT_ID}" \
        --versions '$Latest' \
        --region "${AWS_REGION}" \
        --query 'LaunchTemplateVersions[0].LaunchTemplateData.{InstanceType:InstanceType,ImageId:ImageId,IamInstanceProfile:IamInstanceProfile}' \
        --output table

    # 检查 Launch Template 中是否包含 IAM Instance Profile
    HAS_PROFILE=$(aws ec2 describe-launch-template-versions \
        --launch-template-id "${LT_ID}" \
        --versions '$Latest' \
        --region "${AWS_REGION}" \
        --query 'LaunchTemplateVersions[0].LaunchTemplateData.IamInstanceProfile' \
        --output text)

    if [ -n "$HAS_PROFILE" ] && [ "$HAS_PROFILE" != "None" ]; then
        echo "⚠️  WARNING: Launch Template contains IAM Instance Profile: $HAS_PROFILE"
        echo "   This may conflict with eksctl's IAM management"
    else
        echo "✓ Launch Template does not specify IAM Instance Profile (correct)"
    fi
else
    echo "❌ Launch Template NOT found: ${LT_NAME}"
fi
echo ""

# 5. 检查 VPC 和子网
echo "=========================================="
echo "5. Checking VPC and Subnets"
echo "=========================================="
echo "VPC ID: ${VPC_ID}"

# 检查 VPC 是否存在
if aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --region "${AWS_REGION}" &>/dev/null; then
    echo "✓ VPC exists"
else
    echo "❌ VPC NOT found"
fi
echo ""

# 检查子网
echo "Checking subnets:"
for SUBNET_VAR in PRIVATE_SUBNET_A PRIVATE_SUBNET_B PRIVATE_SUBNET_C; do
    SUBNET_ID="${!SUBNET_VAR}"
    echo -n "  ${SUBNET_VAR} (${SUBNET_ID}): "

    if aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" --region "${AWS_REGION}" &>/dev/null; then
        # 检查子网的 AZ 和可用 IP
        SUBNET_INFO=$(aws ec2 describe-subnets \
            --subnet-ids "${SUBNET_ID}" \
            --region "${AWS_REGION}" \
            --query 'Subnets[0].{AZ:AvailabilityZone,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}' \
            --output json)

        AZ=$(echo "$SUBNET_INFO" | jq -r '.AZ')
        AVAILABLE_IPS=$(echo "$SUBNET_INFO" | jq -r '.AvailableIPs')

        echo "✓ (AZ: $AZ, Available IPs: $AVAILABLE_IPS)"

        if [ "$AVAILABLE_IPS" -lt 10 ]; then
            echo "    ⚠️  WARNING: Low available IPs in subnet"
        fi
    else
        echo "❌ NOT found"
    fi
done
echo ""

# 6. 检查 EKS 集群状态
echo "=========================================="
echo "6. Checking EKS Cluster Status"
echo "=========================================="
CLUSTER_STATUS=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.status' \
    --output text 2>/dev/null || echo "NOT_FOUND")

echo "Cluster status: ${CLUSTER_STATUS}"

if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
    echo "⚠️  WARNING: Cluster is not in ACTIVE state"
fi
echo ""

# 检查现有节点组
echo "Existing nodegroups:"
aws eks list-nodegroups \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'nodegroups' \
    --output table 2>/dev/null || echo "Failed to list nodegroups"
echo ""

# 7. 检查 Service Quotas
echo "=========================================="
echo "7. Checking AWS Service Quotas"
echo "=========================================="
echo "EC2 Quotas:"

# 检查 EC2 实例配额（m7i.large）
INSTANCE_QUOTA=$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-43DA4232 \
    --region "${AWS_REGION}" \
    --query 'Quota.{Name:QuotaName,Value:Value}' \
    --output table 2>/dev/null || echo "Failed to get quota info")
echo "$INSTANCE_QUOTA"
echo ""

# 检查当前运行的实例数
echo "Current EC2 instances:"
aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,Type:InstanceType,State:State.Name,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table
echo ""

# 8. 检查当前用户权限
echo "=========================================="
echo "8. Checking Current User/Role"
echo "=========================================="
CALLER_IDENTITY=$(aws sts get-caller-identity --output json)
echo "Current identity:"
echo "$CALLER_IDENTITY" | jq .
echo ""

# 9. 检查 eksctl 版本
echo "=========================================="
echo "9. Checking eksctl version"
echo "=========================================="
eksctl version
echo ""

# 10. 检查是否有 SCP 限制
echo "=========================================="
echo "10. Testing for SCP restrictions"
echo "=========================================="
echo "Attempting to create a small test CloudFormation stack..."

TEST_STACK_NAME="${CLUSTER_NAME}-test-stack-$$"
cat > /tmp/test-cfn.yaml <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Description: Test stack to verify CFN permissions
Resources:
  DummyWaitHandle:
    Type: AWS::CloudFormation::WaitConditionHandle
EOF

aws cloudformation create-stack \
    --stack-name "${TEST_STACK_NAME}" \
    --template-body file:///tmp/test-cfn.yaml \
    --region "${AWS_REGION}" \
    --tags Key=business,Value=middleware Key=resource,Value=eks \
    2>&1 | tee /tmp/test-cfn-result.txt

if grep -q "CREATE_COMPLETE\|CREATE_IN_PROGRESS" /tmp/test-cfn-result.txt || aws cloudformation describe-stacks --stack-name "${TEST_STACK_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "✓ CloudFormation creation permission OK"

    # 清理测试栈
    echo "Cleaning up test stack..."
    aws cloudformation delete-stack --stack-name "${TEST_STACK_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
else
    echo "❌ CloudFormation creation FAILED - possible SCP restriction"
    echo "Error details:"
    cat /tmp/test-cfn-result.txt
fi

rm -f /tmp/test-cfn.yaml /tmp/test-cfn-result.txt
echo ""

# 11. 总结
echo "=========================================="
echo "Summary and Recommendations"
echo "=========================================="
echo ""
echo "Common issues to check:"
echo ""
echo "1. If CloudFormation stack creation never started:"
echo "   - Check IAM permissions for CloudFormation"
echo "   - Check SCP (Service Control Policies) restrictions"
echo "   - Verify eksctl has permission to create stacks"
echo ""
echo "2. If CloudFormation stack creation failed:"
echo "   - Review stack events above for specific error"
echo "   - Common causes:"
echo "     * IAM role/instance profile conflicts"
echo "     * Subnet has insufficient IP addresses"
echo "     * Service quota limits reached"
echo "     * Launch template configuration issues"
echo "     * Missing required tags (business, resource)"
echo ""
echo "3. If 'InsufficientCapacity' or quota errors:"
echo "   - Try different instance type"
echo "   - Try different AZs"
echo "   - Request quota increase"
echo ""
echo "4. If IAM/permission errors:"
echo "   - Ensure current user has cloudformation:* permissions"
echo "   - Ensure current user has ec2:RunInstances permission"
echo "   - Check if SCP blocks certain actions"
echo ""
echo "Next steps:"
echo "1. Review the output above for any ❌ or ⚠️  warnings"
echo "2. Check CloudFormation stack events for failure details"
echo "3. Review eksctl log at /tmp/eksctl_create_nodegroup.log"
echo "4. If needed, add --verbose=5 to eksctl for more details"
echo ""
