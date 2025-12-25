#!/bin/bash
#
# Install S3 CSI Driver using EKS Add-on with Pod Identity
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/0_setup_env.sh"

# 设置 KUBECONFIG 环境变量
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installing S3 CSI Driver with Pod Identity${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 验证集群存在并更新 kubeconfig
echo -e "${YELLOW}Verifying EKS cluster exists and updating kubeconfig...${NC}"
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo -e "${RED}❌ ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'${NC}"
    exit 1
fi

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
echo -e "${GREEN}✓ Cluster found and kubeconfig updated${NC}"
echo ""

# Validate required variables
required_vars=("CLUSTER_NAME" "AWS_REGION")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: ${var} is not set${NC}"
        exit 1
    fi
done

# Prompt for S3 bucket ARN
if [ -z "${S3_BUCKET_ARN}" ]; then
    echo -e "${YELLOW}Please enter the S3 bucket ARN (e.g., arn:aws:s3:::my-bucket):${NC}"
    read -r S3_BUCKET_ARN
    
    if [ -z "${S3_BUCKET_ARN}" ]; then
        echo -e "${RED}Error: S3 bucket ARN is required${NC}"
        exit 1
    fi
fi

# Extract bucket name from ARN
S3_BUCKET_NAME=$(echo "${S3_BUCKET_ARN}" | sed 's/arn:aws:s3::://')

echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo "S3 Bucket ARN: ${S3_BUCKET_ARN}"
echo "S3 Bucket Name: ${S3_BUCKET_NAME}"
echo ""

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: ${ACCOUNT_ID}"
echo ""

# Step 1: Clean up existing resources
echo -e "${YELLOW}Step 1: Cleaning up existing S3 CSI resources...${NC}"
kubectl delete daemonset s3-csi-node -n kube-system --ignore-not-found=true
kubectl delete deployment s3-csi-controller -n kube-system --ignore-not-found=true
kubectl delete serviceaccount s3-csi-controller-sa -n kube-system --ignore-not-found=true
kubectl delete serviceaccount s3-csi-node-sa -n kube-system --ignore-not-found=true
kubectl delete clusterrole s3-csi-external-provisioner-role --ignore-not-found=true
kubectl delete clusterrolebinding s3-csi-provisioner-binding --ignore-not-found=true
kubectl delete csidriver s3.csi.aws.com --ignore-not-found=true

# Delete existing add-on if it exists
aws eks delete-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name aws-mountpoint-s3-csi-driver \
    --region "${AWS_REGION}" \
    --no-cli-pager 2>/dev/null || echo "No existing add-on to delete"

echo -e "${GREEN}✓ Cleanup completed${NC}"
echo ""

# Step 2: Wait for cleanup
echo -e "${YELLOW}Step 2: Waiting for cleanup to complete...${NC}"
sleep 10

# Step 3: Create IAM role for Pod Identity
echo -e "${YELLOW}Step 3: Creating IAM role and policy for Pod Identity...${NC}"

# Create trust policy
cat > /tmp/s3-csi-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

# Create fine-grained S3 policy
cat > /tmp/s3-csi-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": "${S3_BUCKET_ARN}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion"
            ],
            "Resource": "${S3_BUCKET_ARN}/*"
        }
    ]
}
EOF

# Create IAM role
ROLE_NAME="AmazonEKS_S3_CSI_DriverRole_${CLUSTER_NAME}"
aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document file:///tmp/s3-csi-trust-policy.json \
    --no-cli-pager 2>/dev/null || echo "Role already exists"

# Create custom policy
POLICY_NAME="AmazonEKS_S3_CSI_Policy_${CLUSTER_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --policy-document file:///tmp/s3-csi-policy.json \
    --no-cli-pager 2>/dev/null || echo "Policy already exists"

# Attach custom policy
aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "${POLICY_ARN}" \
    --no-cli-pager 2>/dev/null || echo "Policy already attached"

echo -e "${GREEN}✓ IAM role and policy created${NC}"
echo ""

# Step 4: Install S3 CSI Driver add-on
echo -e "${YELLOW}Step 4: Installing S3 CSI Driver add-on...${NC}"
aws eks create-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name aws-mountpoint-s3-csi-driver \
    --addon-version v2.2.0-eksbuild.1 \
    --resolve-conflicts OVERWRITE \
    --region "${AWS_REGION}" \
    --no-cli-pager

echo -e "${GREEN}✓ Add-on installation initiated${NC}"
echo ""

# Step 5: Wait for add-on to be active
echo -e "${YELLOW}Step 5: Waiting for add-on to become active...${NC}"
while true; do
    STATUS=$(aws eks describe-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --addon-name aws-mountpoint-s3-csi-driver \
        --region "${AWS_REGION}" \
        --query 'addon.status' \
        --output text 2>/dev/null)
    
    if [ "$STATUS" = "ACTIVE" ]; then
        echo -e "${GREEN}✓ Add-on is active${NC}"
        break
    elif [ "$STATUS" = "CREATE_FAILED" ]; then
        echo -e "${RED}✗ Add-on creation failed${NC}"
        aws eks describe-addon \
            --cluster-name "${CLUSTER_NAME}" \
            --addon-name aws-mountpoint-s3-csi-driver \
            --region "${AWS_REGION}" \
            --query 'addon.health.issues'
        exit 1
    else
        echo "Status: $STATUS, waiting..."
        sleep 10
    fi
done

# Step 6: Create Pod Identity association
echo -e "${YELLOW}Step 6: Creating Pod Identity association...${NC}"
aws eks create-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace kube-system \
    --service-account s3-csi-controller-sa \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
    --region "${AWS_REGION}" \
    --no-cli-pager 2>/dev/null || echo "Association may already exist"

echo -e "${GREEN}✓ Pod Identity association created${NC}"
echo ""

# Step 7: Verify installation
echo -e "${YELLOW}Step 7: Verifying installation...${NC}"
echo "Controller pods:"
kubectl get pods -n kube-system -l app=s3-csi-controller
echo ""
echo "Node pods:"
kubectl get pods -n kube-system -l app=s3-csi-node
echo ""

# Clean up temp files
rm -f /tmp/s3-csi-trust-policy.json /tmp/s3-csi-policy.json

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}S3 CSI Driver Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "• Cluster: ${CLUSTER_NAME}"
echo "• S3 Bucket: ${S3_BUCKET_NAME}"
echo "• IAM Role: ${ROLE_NAME}"
echo "• Policy: ${POLICY_NAME}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Verify all pods are running: kubectl get pods -n kube-system | grep s3-csi"
echo "2. Create a test PVC to verify functionality"
echo "3. Check logs if any issues: kubectl logs -n kube-system -l app=s3-csi-controller"
echo ""
echo -e "${YELLOW}Example PVC for testing:${NC}"
echo "apiVersion: v1"
echo "kind: PersistentVolumeClaim"
echo "metadata:"
echo "  name: s3-pvc"
echo "spec:"
echo "  accessModes:"
echo "    - ReadWriteMany"
echo "  storageClassName: s3-csi"
echo "  resources:"
echo "    requests:"
echo "      storage: 1Gi"
echo "  csi:"
echo "    driver: s3.csi.aws.com"
echo "    volumeAttributes:"
echo "      bucketName: ${S3_BUCKET_NAME}"
