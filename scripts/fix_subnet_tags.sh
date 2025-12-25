#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/0_setup_env.sh"

echo "=== Fix Private Subnet Tags for EKS ==="
echo ""
echo "This script will add required Kubernetes tags to private subnets:"
echo "  1. kubernetes.io/cluster/${CLUSTER_NAME} = shared"
echo "  2. kubernetes.io/role/internal-elb = 1"
echo ""
echo "Subnets to update:"
echo "  - ${PRIVATE_SUBNET_A}"
echo "  - ${PRIVATE_SUBNET_B}"
echo "  - ${PRIVATE_SUBNET_C}"
echo ""
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

echo ""
echo "Step 1: Adding tags to private subnets..."

for SUBNET in ${PRIVATE_SUBNET_A} ${PRIVATE_SUBNET_B} ${PRIVATE_SUBNET_C}; do
  echo ""
  echo "Processing subnet: ${SUBNET}"

  # 添加集群所有权标签
  aws ec2 create-tags \
    --resources ${SUBNET} \
    --tags "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared" \
    --region ${AWS_REGION}

  # 添加内部 ELB 角色标签
  aws ec2 create-tags \
    --resources ${SUBNET} \
    --tags "Key=kubernetes.io/role/internal-elb,Value=1" \
    --region ${AWS_REGION}

  echo "✓ Tags added to ${SUBNET}"
done

echo ""
echo "Step 2: Verifying tags..."
aws ec2 describe-subnets \
  --subnet-ids ${PRIVATE_SUBNET_A} ${PRIVATE_SUBNET_B} ${PRIVATE_SUBNET_C} \
  --region ${AWS_REGION} \
  --query "Subnets[*].{ID:SubnetId, K8sCluster:Tags[?Key=='kubernetes.io/cluster/${CLUSTER_NAME}']|[0].Value, InternalELB:Tags[?Key=='kubernetes.io/role/internal-elb']|[0].Value}" \
  --output table

echo ""
echo "Step 3: Checking for failed CloudFormation stacks..."
FAILED_STACKS=$(aws cloudformation list-stacks \
  --region ${AWS_REGION} \
  --stack-status-filter ROLLBACK_COMPLETE \
  --query "StackSummaries[?contains(StackName, 'eksctl-${CLUSTER_NAME}-nodegroup-eks-utils-x86')].StackName" \
  --output text)

if [ -n "${FAILED_STACKS}" ]; then
  echo "Found failed stack(s) to delete: ${FAILED_STACKS}"
  echo ""
  for STACK in ${FAILED_STACKS}; do
    echo "Deleting stack: ${STACK}"
    aws cloudformation delete-stack \
      --stack-name ${STACK} \
      --region ${AWS_REGION}

    echo "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
      --stack-name ${STACK} \
      --region ${AWS_REGION} || echo "Warning: Stack may still be deleting"

    echo "✓ Stack ${STACK} deleted"
  done
else
  echo "No failed stacks found, skipping cleanup"
fi

echo ""
echo "=== Fix Complete ==="
echo ""
echo "Next steps:"
echo "  1. Run: bash scripts/9_replace_system_nodegroup.sh"
echo "  2. Monitor the eksctl output for any errors"
echo ""
