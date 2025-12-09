#!/bin/bash
#
# Delete EC2 Bastion Instance
# This script terminates the temporary bastion instance
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/0_setup_env.sh"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deleting EC2 Bastion Instance${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Try to get instance ID from saved file
INSTANCE_ID=""
if [ -f "/tmp/eks-bastion-instance-id.txt" ]; then
    INSTANCE_ID=$(cat /tmp/eks-bastion-instance-id.txt)
    echo "Found saved instance ID: ${INSTANCE_ID}"
fi

# If not found, search by tag
if [ -z "${INSTANCE_ID}" ]; then
    echo "Searching for bastion instance by tag..."
    INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=EKS-Deploy-Bastion-${CLUSTER_NAME}" \
                  "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text \
        --region ${AWS_REGION} 2>/dev/null)
fi

if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" = "None" ]; then
    echo -e "${YELLOW}No bastion instance found${NC}"
    echo ""
    echo "If you know the instance ID, you can manually delete it with:"
    echo "  aws ec2 terminate-instances --instance-ids <instance-id> --region ${AWS_REGION}"
    exit 0
fi

# Get instance details
echo ""
echo "Instance Details:"
INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids ${INSTANCE_ID} \
    --query 'Reservations[0].Instances[0]' \
    --region ${AWS_REGION})

STATE=$(echo ${INSTANCE_INFO} | jq -r '.State.Name')
PRIVATE_IP=$(echo ${INSTANCE_INFO} | jq -r '.PrivateIpAddress')
INSTANCE_TYPE=$(echo ${INSTANCE_INFO} | jq -r '.InstanceType')

echo "  Instance ID:   ${INSTANCE_ID}"
echo "  State:         ${STATE}"
echo "  Instance Type: ${INSTANCE_TYPE}"
echo "  Private IP:    ${PRIVATE_IP}"
echo ""

# Confirm deletion
echo -e "${YELLOW}⚠️  Are you sure you want to terminate this instance? (y/n)${NC}"
read -r response

if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 0
fi

# Terminate instance
echo ""
echo "Terminating instance ${INSTANCE_ID}..."
aws ec2 terminate-instances \
    --instance-ids ${INSTANCE_ID} \
    --region ${AWS_REGION} \
    --no-cli-pager

echo -e "${GREEN}✓ Termination initiated${NC}"
echo ""

echo "Waiting for instance to terminate..."
aws ec2 wait instance-terminated \
    --instance-ids ${INSTANCE_ID} \
    --region ${AWS_REGION}

echo -e "${GREEN}✓ Instance terminated${NC}"
echo ""

# Clean up saved instance ID
if [ -f "/tmp/eks-bastion-instance-id.txt" ]; then
    rm /tmp/eks-bastion-instance-id.txt
    echo "Cleaned up saved instance ID"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Bastion Instance Deleted${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}Note:${NC} The IAM role and instance profile (EKS-Deploy-Role/EKS-Deploy-Profile)"
echo "      have NOT been deleted. If you don't need them, delete manually:"
echo ""
echo "  aws iam remove-role-from-instance-profile \\"
echo "    --instance-profile-name EKS-Deploy-Profile \\"
echo "    --role-name EKS-Deploy-Role"
echo ""
echo "  aws iam delete-instance-profile \\"
echo "    --instance-profile-name EKS-Deploy-Profile"
echo ""
echo "  aws iam detach-role-policy \\"
echo "    --role-name EKS-Deploy-Role \\"
echo "    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
echo ""
echo "  aws iam detach-role-policy \\"
echo "    --role-name EKS-Deploy-Role \\"
echo "    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess"
echo ""
echo "  aws iam delete-role --role-name EKS-Deploy-Role"
echo ""
