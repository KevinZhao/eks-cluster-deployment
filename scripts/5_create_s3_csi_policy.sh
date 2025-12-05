#!/bin/bash
#
# Create S3 CSI Driver IAM Policy
# This script creates a least-privilege IAM policy for Mountpoint for S3 CSI Driver
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Symbols
CHECK_MARK="✓"
CROSS_MARK="✗"
INFO="ℹ"
WARNING="⚠"

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/0_setup_env.sh"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Create S3 CSI Driver IAM Policy                   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo "AWS Account: ${ACCOUNT_ID}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo ""

# Validate required variables
if [ -z "${ACCOUNT_ID}" ]; then
    echo -e "${RED}${CROSS_MARK} Error: ACCOUNT_ID is not set${NC}"
    exit 1
fi

if [ -z "${CLUSTER_NAME}" ]; then
    echo -e "${RED}${CROSS_MARK} Error: CLUSTER_NAME is not set${NC}"
    exit 1
fi

# Policy name
POLICY_NAME="${CLUSTER_NAME}-S3CSIDriverPolicy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

echo -e "${BLUE}${INFO} Policy Name: ${POLICY_NAME}${NC}"
echo -e "${BLUE}${INFO} Policy ARN: ${POLICY_ARN}${NC}"
echo ""

# Check if policy already exists
echo -e "${YELLOW}Checking if policy already exists...${NC}"
EXISTING_POLICY=$(aws iam get-policy --policy-arn "${POLICY_ARN}" --query 'Policy.Arn' --output text 2>/dev/null || echo "")

if [ -n "${EXISTING_POLICY}" ]; then
    echo -e "${GREEN}${CHECK_MARK} Policy already exists: ${POLICY_ARN}${NC}"
    echo ""
    echo -e "${YELLOW}${WARNING} To update the policy, you need to:${NC}"
    echo "  1. Create a new policy version, or"
    echo "  2. Delete the existing policy and run this script again"
    echo ""
    echo -e "${BLUE}${INFO} View existing policy:${NC}"
    echo "  aws iam get-policy --policy-arn ${POLICY_ARN}"
    echo ""
    exit 0
fi

# Get S3 bucket configuration from user
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}S3 Bucket Configuration${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "${YELLOW}${WARNING} This policy will grant S3 access to the buckets you specify.${NC}"
echo -e "${YELLOW}${WARNING} For security, limit access to only the buckets needed by your applications.${NC}"
echo ""

# Option 1: Specific buckets (recommended)
# Option 2: All buckets with prefix
# Option 3: Single bucket

echo "Select policy scope:"
echo "  1) Specific bucket(s) (Recommended - Most Secure)"
echo "  2) All buckets with prefix (e.g., my-app-*)"
echo "  3) All buckets in account (Not Recommended - Use for testing only)"
echo ""
read -p "Enter choice [1-3] (default: 1): " SCOPE_CHOICE
SCOPE_CHOICE=${SCOPE_CHOICE:-1}

case ${SCOPE_CHOICE} in
    1)
        echo ""
        echo "Enter S3 bucket names (comma-separated):"
        echo "Example: my-app-data,my-app-logs,my-app-backups"
        read -p "Bucket names: " BUCKET_NAMES

        if [ -z "${BUCKET_NAMES}" ]; then
            echo -e "${RED}${CROSS_MARK} No bucket names provided${NC}"
            exit 1
        fi

        # Convert comma-separated list to JSON array
        IFS=',' read -ra BUCKETS <<< "${BUCKET_NAMES}"
        BUCKET_RESOURCES=""
        OBJECT_RESOURCES=""

        for bucket in "${BUCKETS[@]}"; do
            bucket=$(echo "$bucket" | xargs) # trim whitespace
            BUCKET_RESOURCES="${BUCKET_RESOURCES}\"arn:aws:s3:::${bucket}\","
            OBJECT_RESOURCES="${OBJECT_RESOURCES}\"arn:aws:s3:::${bucket}/*\","
        done

        # Remove trailing commas
        BUCKET_RESOURCES=${BUCKET_RESOURCES%,}
        OBJECT_RESOURCES=${OBJECT_RESOURCES%,}

        RESOURCE_BUCKETS="[${BUCKET_RESOURCES}]"
        RESOURCE_OBJECTS="[${OBJECT_RESOURCES}]"
        ;;

    2)
        echo ""
        echo "Enter bucket prefix (e.g., my-app):"
        read -p "Prefix: " BUCKET_PREFIX

        if [ -z "${BUCKET_PREFIX}" ]; then
            echo -e "${RED}${CROSS_MARK} No prefix provided${NC}"
            exit 1
        fi

        RESOURCE_BUCKETS="\"arn:aws:s3:::${BUCKET_PREFIX}*\""
        RESOURCE_OBJECTS="\"arn:aws:s3:::${BUCKET_PREFIX}*/*\""

        echo -e "${YELLOW}${WARNING} This will grant access to all buckets starting with: ${BUCKET_PREFIX}${NC}"
        ;;

    3)
        echo ""
        echo -e "${RED}${WARNING} WARNING: This grants access to ALL S3 buckets in your account!${NC}"
        echo -e "${RED}${WARNING} This is NOT recommended for production use.${NC}"
        read -p "Are you sure? Type 'yes' to continue: " CONFIRM

        if [ "${CONFIRM}" != "yes" ]; then
            echo "Cancelled."
            exit 1
        fi

        RESOURCE_BUCKETS="\"arn:aws:s3:::*\""
        RESOURCE_OBJECTS="\"arn:aws:s3:::*/*\""
        ;;

    *)
        echo -e "${RED}${CROSS_MARK} Invalid choice${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${YELLOW}Creating IAM policy...${NC}"

# Create policy document
POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "MountpointListBuckets",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": ${RESOURCE_BUCKETS}
        },
        {
            "Sid": "MountpointObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:AbortMultipartUpload"
            ],
            "Resource": ${RESOURCE_OBJECTS}
        },
        {
            "Sid": "DenyDangerousOperations",
            "Effect": "Deny",
            "Action": [
                "s3:DeleteBucket",
                "s3:DeleteBucketPolicy",
                "s3:PutBucketPolicy",
                "s3:PutBucketAcl",
                "s3:PutBucketPublicAccessBlock",
                "s3:PutLifecycleConfiguration",
                "s3:PutReplicationConfiguration",
                "s3:PutEncryptionConfiguration"
            ],
            "Resource": "*"
        }
    ]
}
EOF
)

# Save policy to temporary file
POLICY_FILE="/tmp/${POLICY_NAME}.json"
echo "${POLICY_DOCUMENT}" > "${POLICY_FILE}"

echo -e "${BLUE}${INFO} Policy document saved to: ${POLICY_FILE}${NC}"
echo ""
echo -e "${CYAN}Policy Preview:${NC}"
echo "${POLICY_DOCUMENT}" | jq '.' 2>/dev/null || echo "${POLICY_DOCUMENT}"
echo ""

# Create IAM policy
echo -e "${YELLOW}Creating IAM policy: ${POLICY_NAME}...${NC}"
CREATE_OUTPUT=$(aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --policy-document file://"${POLICY_FILE}" \
    --description "Mountpoint for S3 CSI Driver policy for ${CLUSTER_NAME}" \
    --tags "Key=Cluster,Value=${CLUSTER_NAME}" "Key=ManagedBy,Value=eks-cluster-deployment" \
    --query 'Policy.Arn' \
    --output text 2>&1)

if [ $? -eq 0 ]; then
    echo -e "${GREEN}${CHECK_MARK} IAM policy created successfully${NC}"
    echo -e "${GREEN}${CHECK_MARK} Policy ARN: ${CREATE_OUTPUT}${NC}"
else
    echo -e "${RED}${CROSS_MARK} Failed to create IAM policy${NC}"
    echo "${CREATE_OUTPUT}"
    rm -f "${POLICY_FILE}"
    exit 1
fi

# Clean up temporary file
rm -f "${POLICY_FILE}"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  S3 CSI Driver Policy Creation: SUCCESS           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}Next Steps:${NC}"
echo ""
echo "1. Update eksctl_cluster_template.yaml to use this policy:"
echo ""
echo "   Uncomment and update the S3 CSI driver configuration:"
echo "   attachPolicyARNs:"
echo "     - arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
echo ""
echo "2. Deploy or update your EKS cluster:"
echo "   ./scripts/4_install_eks_cluster.sh"
echo ""
echo "3. Verify the policy is attached to the ServiceAccount:"
echo "   kubectl describe sa s3-csi-driver-sa -n kube-system"
echo ""

echo -e "${BLUE}${INFO} Policy Details:${NC}"
echo "  Policy Name: ${POLICY_NAME}"
echo "  Policy ARN:  arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
echo "  Cluster:     ${CLUSTER_NAME}"
echo ""

echo -e "${YELLOW}${INFO} To view the policy:${NC}"
echo "  aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
echo ""

echo -e "${YELLOW}${INFO} To delete the policy (if needed):${NC}"
echo "  aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
echo ""
