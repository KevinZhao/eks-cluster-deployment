#!/bin/bash
#
# Create EC2 Bastion Instance in Private Subnet for EKS Deployment
# This script creates a temporary EC2 instance in a private subnet with SSM access
#

set -e
set -o pipefail
export AWS_PAGER=""

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

# Validate VPC and subnet exist
echo -e "${YELLOW}Validating AWS resources...${NC}"
validate_vpc_exists "${VPC_ID}" "${AWS_REGION}"
validate_subnet_exists "${PRIVATE_SUBNET_A}" "${VPC_ID}" "${AWS_REGION}"
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

# Validate security group exists and belongs to correct VPC
validate_security_group_exists "${VPC_ENDPOINT_SG}" "${VPC_ID}" "${AWS_REGION}"

echo "VPC Endpoint Security Group: ${VPC_ENDPOINT_SG}"
echo ""

# Get latest Amazon Linux 2023 ARM64 AMI (for t4g instances)
echo -e "${YELLOW}Getting latest Amazon Linux 2023 ARM64 AMI...${NC}"
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-arm64" \
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

    # Create trust policy（使用 mktemp 避免临时文件冲突）
    BASTION_TRUST_POLICY_FILE=$(mktemp /tmp/trust-policy.XXXXXX.json)

    cat > "${BASTION_TRUST_POLICY_FILE}" <<'EOF'
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
        --assume-role-policy-document "file://${BASTION_TRUST_POLICY_FILE}" \
        --description "Role for EKS deployment bastion instance" \
        --no-cli-pager

    rm -f "${BASTION_TRUST_POLICY_FILE}"

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
        # 使用 mktemp 避免临时文件冲突
        BASTION_IAM_POLICY_FILE=$(mktemp /tmp/eks-bastion-policy.XXXXXX.json)

        cat > "${BASTION_IAM_POLICY_FILE}" <<'POLICYEOF'
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
            --policy-document "file://${BASTION_IAM_POLICY_FILE}" \
            --description "Least-privilege policy for EKS deployment from bastion" \
            --query 'Policy.Arn' \
            --output text)

        rm -f "${BASTION_IAM_POLICY_FILE}"
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

    # 支持非交互模式: REUSE_BASTION=yes|no
    if [ -n "${REUSE_BASTION}" ]; then
        if [[ "${REUSE_BASTION}" =~ ^[Yy] ]]; then
            INSTANCE_ID="${EXISTING_INSTANCE}"
            echo -e "${GREEN}Using existing instance: ${INSTANCE_ID}${NC}"
        else
            echo "Creating new instance..."
            INSTANCE_ID=""
        fi
    else
        echo -e "${YELLOW}Do you want to use this instance? (y/n)${NC}"
        echo "For non-interactive mode, set REUSE_BASTION=yes or REUSE_BASTION=no"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            INSTANCE_ID="${EXISTING_INSTANCE}"
            echo -e "${GREEN}Using existing instance: ${INSTANCE_ID}${NC}"
        else
            echo "Creating new instance..."
            INSTANCE_ID=""
        fi
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
        --instance-type t4g.micro \
        --subnet-id ${PRIVATE_SUBNET_A} \
        --security-group-ids ${VPC_ENDPOINT_SG} \
        --iam-instance-profile Name=EKS-Deploy-Profile \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=EKS-Deploy-Bastion-${CLUSTER_NAME}},{Key=Purpose,Value=EKS-Deployment},{Key=Cluster,Value=${CLUSTER_NAME}},{Key=business,Value=middleware},{Key=resource,Value=eks}]" \
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

    # Install deployment tools on bastion
    echo -e "${YELLOW}Installing deployment tools on bastion...${NC}"
    echo "  This may take 1-2 minutes..."

    # Resolve the latest kubectl patch release that matches K8S_VERSION
    # (e.g. K8S_VERSION=1.35 -> v1.35.x). kubectl officially supports ±1
    # minor skew against the cluster, so following the cluster minor keeps
    # the bastion safe for cluster upgrades. Fall back to v1.35.0 if the
    # resolver request fails (e.g. bastion builds without internet during
    # a dev run).
    KUBECTL_VERSION=$(curl -fsSL --max-time 10 \
        "https://dl.k8s.io/release/stable-${K8S_VERSION}.txt" 2>/dev/null \
        || echo "v${K8S_VERSION}.0")
    echo "  Installing kubectl ${KUBECTL_VERSION} (matches cluster minor ${K8S_VERSION})"

    # Close the outer single quotes around --parameters for the URL
    # segments so ${KUBECTL_VERSION} expands on the control host, then
    # reopen single quotes so "$(cat kubectl.sha256)" continues to run
    # on the bastion (SSM remote) rather than locally.
    INSTALL_COMMAND_ID=$(aws ssm send-command \
        --instance-ids ${INSTANCE_ID} \
        --region ${AWS_REGION} \
        --document-name "AWS-RunShellScript" \
        --timeout-seconds 600 \
        --parameters 'commands=[
            "echo Installing kubectl '"${KUBECTL_VERSION}"' for ARM64...",
            "curl -fLO --retry 3 --retry-delay 5 https://dl.k8s.io/release/'"${KUBECTL_VERSION}"'/bin/linux/arm64/kubectl",
            "curl -fLO --retry 3 --retry-delay 5 https://dl.k8s.io/release/'"${KUBECTL_VERSION}"'/bin/linux/arm64/kubectl.sha256",
            "echo \"$(cat kubectl.sha256)  kubectl\" | sha256sum --check || { echo ERROR: kubectl checksum verification failed; exit 1; }",
            "sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl",
            "rm -f kubectl kubectl.sha256",
            "echo Installing eksctl for ARM64...",
            "curl -fsLO --retry 3 --retry-delay 5 https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_arm64.tar.gz",
            "tar -xzf eksctl_Linux_arm64.tar.gz",
            "sudo mv eksctl /usr/local/bin/",
            "rm eksctl_Linux_arm64.tar.gz",
            "echo Installing helm...",
            "curl -fsSL --retry 3 --retry-delay 5 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash",
            "echo Installing additional tools...",
            "sudo yum install -y git jq gettext",
            "echo --- Tool Versions ---",
            "kubectl version --client --short 2>/dev/null || kubectl version --client",
            "eksctl version",
            "helm version --short",
            "jq --version",
            "echo --- Tools installed successfully ---"
        ]' \
        --query 'Command.CommandId' \
        --output text)

    if [ -n "${INSTALL_COMMAND_ID}" ]; then
        echo "  Waiting for tools installation to complete..."
        sleep 5

        for i in {1..24}; do
            INSTALL_STATUS=$(aws ssm get-command-invocation \
                --command-id ${INSTALL_COMMAND_ID} \
                --instance-id ${INSTANCE_ID} \
                --region ${AWS_REGION} \
                --query 'Status' \
                --output text 2>/dev/null)

            if [ "${INSTALL_STATUS}" = "Success" ]; then
                echo -e "${GREEN}  ✓ Tools installed successfully${NC}"
                break
            elif [ "${INSTALL_STATUS}" = "Failed" ]; then
                echo -e "${RED}  ✗ Tools installation failed${NC}"
                break
            fi

            echo "  Installing... ($i/24)"
            sleep 5
        done
    else
        echo -e "${YELLOW}  ⚠ Could not initiate tools installation${NC}"
        echo "  You can install tools manually after connecting"
    fi
    echo ""

    echo -e "${BLUE}To connect to the instance:${NC}"
    echo "  aws ssm start-session --target ${INSTANCE_ID} --region ${AWS_REGION}"
    echo ""

    echo -e "${BLUE}Or use the AWS Console:${NC}"
    echo "  EC2 → Instances → Select instance → Connect → Session Manager"
    echo ""

    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Connect to the instance using the command above"
    echo "  2. Upload your project code or clone from git"
    echo "  3. Run deployment scripts from /home/ssm-user/"
    echo ""

    echo -e "${YELLOW}To delete the bastion instance later:${NC}"
    echo "  ./scripts/delete_bastion.sh"
    echo "  Or manually: aws ec2 terminate-instances --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
    echo ""
fi

# Save instance ID to file for later reference
echo "${INSTANCE_ID}" > /tmp/eks-bastion-instance-id.txt
echo -e "${GREEN}Instance ID saved to: /tmp/eks-bastion-instance-id.txt${NC}"

# Configure EKS cluster access for bastion
echo ""
echo -e "${YELLOW}Configuring EKS cluster access...${NC}"

# Check if cluster exists
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "EKS cluster found: ${CLUSTER_NAME}"

    # Get cluster security group
    CLUSTER_SG=$(aws eks describe-cluster \
        --name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
        --output text)

    # Get bastion security group
    BASTION_SG=$(aws ec2 describe-instances \
        --instance-ids ${INSTANCE_ID} \
        --region ${AWS_REGION} \
        --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
        --output text)

    echo "  Cluster Security Group: ${CLUSTER_SG}"
    echo "  Bastion Security Group: ${BASTION_SG}"

    # Add security group rule to allow bastion access to EKS API
    echo "  Configuring security group access..."
    sg_result=""
    if sg_result=$(aws ec2 authorize-security-group-ingress \
        --group-id ${CLUSTER_SG} \
        --protocol tcp \
        --port 443 \
        --source-group ${BASTION_SG} \
        --region ${AWS_REGION} 2>&1); then
        echo "  ✓ Security group rule added"
    elif echo "${sg_result}" | grep -q "already exists"; then
        echo "  ✓ Security group rule already exists"
    else
        echo "  ERROR: Failed to add security group rule: ${sg_result}"
        exit 1
    fi

    # Configure EKS access entry for bastion IAM role
    echo "  Configuring EKS access entry..."
    BASTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/EKS-Deploy-Role"

    # Create access entry
    ae_result=""
    if ae_result=$(aws eks create-access-entry \
        --cluster-name "${CLUSTER_NAME}" \
        --principal-arn "${BASTION_ROLE_ARN}" \
        --type STANDARD \
        --region "${AWS_REGION}" 2>&1); then
        echo "  ✓ Access entry created"
    elif echo "${ae_result}" | grep -q "already exists"; then
        echo "  ✓ Access entry already exists"
    else
        echo "  ERROR: Failed to create access entry: ${ae_result}"
        exit 1
    fi

    # Associate cluster admin policy
    ap_result=""
    if ap_result=$(aws eks associate-access-policy \
        --cluster-name "${CLUSTER_NAME}" \
        --principal-arn "${BASTION_ROLE_ARN}" \
        --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
        --access-scope type=cluster \
        --region "${AWS_REGION}" 2>&1); then
        echo "  ✓ Admin policy associated"
    elif echo "${ap_result}" | grep -q "already exists"; then
        echo "  ✓ Admin policy already associated"
    else
        echo "  ERROR: Failed to associate admin policy: ${ap_result}"
        exit 1
    fi

    echo -e "${GREEN}✓ EKS cluster access configured${NC}"
else
    echo -e "${YELLOW}ℹ EKS cluster not found yet. Access will need to be configured after cluster creation.${NC}"
    echo "  Run this script again after creating the cluster, or manually configure access using:"
    echo "  aws eks create-access-entry --cluster-name ${CLUSTER_NAME} --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/EKS-Deploy-Role --type STANDARD"
    echo "  aws eks associate-access-policy --cluster-name ${CLUSTER_NAME} --principal-arn arn:aws:iam::${ACCOUNT_ID}:role/EKS-Deploy-Role --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster"
fi
echo ""
