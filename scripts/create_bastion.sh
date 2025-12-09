#!/bin/bash
#
# Create EC2 Bastion Instance in Private Subnet for EKS Deployment
# This script creates a temporary EC2 instance in a private subnet with SSM access
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
echo -e "${GREEN}Creating EC2 Bastion Instance${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Validate required variables
required_vars=(
    "VPC_ID"
    "PRIVATE_SUBNET_A"
    "AWS_REGION"
    "CLUSTER_NAME"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: ${var} is not set${NC}"
        exit 1
    fi
done

echo "VPC ID: ${VPC_ID}"
echo "Private Subnet: ${PRIVATE_SUBNET_A}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo ""

# Get VPC endpoint security group ID
echo -e "${YELLOW}Looking for VPC endpoint security group...${NC}"
VPC_ENDPOINT_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${CLUSTER_NAME}-vpc-endpoints-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region ${AWS_REGION})

if [ -z "${VPC_ENDPOINT_SG}" ] || [ "${VPC_ENDPOINT_SG}" = "None" ]; then
    echo -e "${RED}Error: VPC endpoint security group not found!${NC}"
    echo -e "${YELLOW}Please run ./scripts/3_create_vpc_endpoints.sh first${NC}"
    exit 1
fi

echo "VPC Endpoint Security Group: ${VPC_ENDPOINT_SG}"
echo ""

# Get latest Amazon Linux 2023 AMI
echo -e "${YELLOW}Getting latest Amazon Linux 2023 AMI...${NC}"
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text \
    --region ${AWS_REGION})

echo "AMI ID: ${AMI_ID}"
echo ""

# Create IAM role if it doesn't exist
echo -e "${YELLOW}Checking IAM role...${NC}"
if aws iam get-role --role-name EKS-Deploy-Role >/dev/null 2>&1; then
    echo -e "${GREEN}✓ IAM role exists${NC}"
else
    echo "Creating IAM role..."

    # Create trust policy
    cat > /tmp/trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # Create role
    aws iam create-role \
        --role-name EKS-Deploy-Role \
        --assume-role-policy-document file:///tmp/trust-policy.json \
        --description "Role for EKS deployment bastion instance" \
        --no-cli-pager

    # Attach policies
    echo "Attaching policies..."
    aws iam attach-role-policy \
        --role-name EKS-Deploy-Role \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
        --no-cli-pager

    # Create least-privilege policy for EKS deployment
    echo "Creating custom EKS deployment policy..."
    POLICY_NAME="EKS-Bastion-Deploy-Policy"

    # Check if policy already exists
    POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text)

    if [ -z "${POLICY_ARN}" ]; then
        cat > /tmp/eks-bastion-policy.json <<'POLICYEOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSClusterManagement",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters",
        "eks:DescribeNodegroup",
        "eks:ListNodegroups",
        "eks:DescribeAddon",
        "eks:ListAddons",
        "eks:UpdateClusterConfig",
        "eks:UpdateNodegroupConfig",
        "eks:TagResource",
        "eks:ListPodIdentityAssociations",
        "eks:DescribePodIdentityAssociation",
        "eks:CreatePodIdentityAssociation",
        "eks:UpdatePodIdentityAssociation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2ReadOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMPodIdentity",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:CreateRole",
        "iam:AttachRolePolicy",
        "iam:PutRolePolicy",
        "iam:TagRole",
        "iam:GetPolicy",
        "iam:CreatePolicy",
        "iam:ListPolicies",
        "iam:ListAttachedRolePolicies"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoScaling",
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "STSAssumeRole",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
POLICYEOF

        POLICY_ARN=$(aws iam create-policy \
            --policy-name ${POLICY_NAME} \
            --policy-document file:///tmp/eks-bastion-policy.json \
            --description "Least-privilege policy for EKS deployment from bastion" \
            --query 'Policy.Arn' \
            --output text)

        rm -f /tmp/eks-bastion-policy.json
        echo "✓ Custom policy created: ${POLICY_ARN}"
    else
        echo "✓ Using existing policy: ${POLICY_ARN}"
    fi

    aws iam attach-role-policy \
        --role-name EKS-Deploy-Role \
        --policy-arn ${POLICY_ARN} \
        --no-cli-pager

    # Create instance profile
    echo "Creating instance profile..."
    aws iam create-instance-profile \
        --instance-profile-name EKS-Deploy-Profile \
        --no-cli-pager

    aws iam add-role-to-instance-profile \
        --instance-profile-name EKS-Deploy-Profile \
        --role-name EKS-Deploy-Role \
        --no-cli-pager

    echo "Waiting for IAM role to propagate (60 seconds for AWS global consistency)..."
    sleep 60

    echo -e "${GREEN}✓ IAM role created${NC}"
fi
echo ""

# Check if instance already exists
echo -e "${YELLOW}Checking for existing bastion instance...${NC}"
EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=EKS-Deploy-Bastion-${CLUSTER_NAME}" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text \
    --region ${AWS_REGION} 2>/dev/null)

if [ -n "${EXISTING_INSTANCE}" ] && [ "${EXISTING_INSTANCE}" != "None" ]; then
    echo -e "${YELLOW}Found existing instance: ${EXISTING_INSTANCE}${NC}"
    echo -e "${YELLOW}Do you want to use this instance? (y/n)${NC}"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        INSTANCE_ID="${EXISTING_INSTANCE}"
        echo -e "${GREEN}Using existing instance: ${INSTANCE_ID}${NC}"
    else
        echo "Creating new instance..."
        INSTANCE_ID=""
    fi
else
    echo "No existing instance found"
    INSTANCE_ID=""
fi

# Create new instance if needed
if [ -z "${INSTANCE_ID}" ]; then
    echo -e "${YELLOW}Creating EC2 instance in private subnet...${NC}"

    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id ${AMI_ID} \
        --instance-type t3.micro \
        --subnet-id ${PRIVATE_SUBNET_A} \
        --security-group-ids ${VPC_ENDPOINT_SG} \
        --iam-instance-profile Name=EKS-Deploy-Profile \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=EKS-Deploy-Bastion-${CLUSTER_NAME}},{Key=Purpose,Value=EKS-Deployment},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
        --region ${AWS_REGION} \
        --query 'Instances[0].InstanceId' \
        --output text)

    if [ -z "${INSTANCE_ID}" ]; then
        echo -e "${RED}Failed to create instance${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Instance created: ${INSTANCE_ID}${NC}"
    echo ""

    echo "Waiting for instance to be running..."
    aws ec2 wait instance-running \
        --instance-ids ${INSTANCE_ID} \
        --region ${AWS_REGION}

    echo -e "${GREEN}✓ Instance is running${NC}"
fi

echo ""
echo -e "${YELLOW}Waiting for SSM Agent to be ready (up to 5 minutes)...${NC}"
echo ""

for i in {1..30}; do
    STATUS=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text \
        --region ${AWS_REGION} 2>/dev/null)

    if [ "${STATUS}" = "Online" ]; then
        echo -e "${GREEN}✓ SSM Agent is ready!${NC}"
        break
    fi

    echo "Waiting... ($i/30) - Current status: ${STATUS:-Initializing}"
    sleep 10
done

if [ "${STATUS}" != "Online" ]; then
    echo -e "${RED}✗ SSM Agent failed to become ready${NC}"
    echo "You can check the instance status later with:"
    echo "  aws ssm describe-instance-information --filters \"Key=InstanceIds,Values=${INSTANCE_ID}\""
else
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Bastion Instance Ready!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    # Get instance details
    INSTANCE_INFO=$(aws ec2 describe-instances \
        --instance-ids ${INSTANCE_ID} \
        --query 'Reservations[0].Instances[0]' \
        --region ${AWS_REGION})

    PRIVATE_IP=$(echo ${INSTANCE_INFO} | jq -r '.PrivateIpAddress')
    INSTANCE_TYPE=$(echo ${INSTANCE_INFO} | jq -r '.InstanceType')
    SUBNET_ID=$(echo ${INSTANCE_INFO} | jq -r '.SubnetId')

    echo ""
    echo "Instance Details:"
    echo "  Instance ID:   ${INSTANCE_ID}"
    echo "  Instance Type: ${INSTANCE_TYPE}"
    echo "  Private IP:    ${PRIVATE_IP}"
    echo "  Subnet:        ${SUBNET_ID}"
    echo ""

    echo -e "${BLUE}To connect to the instance:${NC}"
    echo "  aws ssm start-session --target ${INSTANCE_ID} --region ${AWS_REGION}"
    echo ""

    echo -e "${BLUE}Or use the AWS Console:${NC}"
    echo "  EC2 → Instances → Select instance → Connect → Session Manager"
    echo ""

    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Connect to the instance using the command above"
    echo "  2. Install deployment tools (kubectl, eksctl, helm):"
    echo "     Run: curl -O https://raw.githubusercontent.com/your-repo/main/scripts/install_tools.sh && bash install_tools.sh"
    echo "  3. Clone this project and run deployment scripts"
    echo ""

    echo -e "${YELLOW}To delete the bastion instance later:${NC}"
    echo "  ./scripts/delete_bastion.sh"
    echo "  Or manually: aws ec2 terminate-instances --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
    echo ""
fi

# Save instance ID to file for later reference
echo "${INSTANCE_ID}" > /tmp/eks-bastion-instance-id.txt
echo -e "${GREEN}Instance ID saved to: /tmp/eks-bastion-instance-id.txt${NC}"
