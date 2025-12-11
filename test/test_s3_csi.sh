#!/bin/bash
#
# Test S3 CSI Driver functionality
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Testing S3 CSI Driver${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Prompt for S3 bucket name
if [ -z "${S3_BUCKET_NAME}" ]; then
    echo -e "${YELLOW}Please enter your S3 bucket name:${NC}"
    read -r S3_BUCKET_NAME
    
    if [ -z "${S3_BUCKET_NAME}" ]; then
        echo -e "${RED}Error: S3 bucket name is required${NC}"
        exit 1
    fi
fi

echo "Using S3 bucket: ${S3_BUCKET_NAME}"
echo ""

# Update the test YAML with bucket name
sed "s/REPLACE_WITH_YOUR_BUCKET_NAME/${S3_BUCKET_NAME}/g" test-s3-csi.yaml > test-s3-csi-configured.yaml

# Apply the test resources
echo -e "${YELLOW}Step 1: Creating test resources...${NC}"
kubectl apply -f test-s3-csi-configured.yaml

echo -e "${GREEN}✓ Test resources created${NC}"
echo ""

# Wait for PVC to be bound
echo -e "${YELLOW}Step 2: Waiting for PVC to be bound...${NC}"
kubectl wait --for=condition=Bound pvc/s3-pvc-test --timeout=60s

echo -e "${GREEN}✓ PVC is bound${NC}"
echo ""

# Wait for pod to be ready
echo -e "${YELLOW}Step 3: Waiting for test pod to be ready...${NC}"
kubectl wait --for=condition=Ready pod/s3-test-pod --timeout=120s

echo -e "${GREEN}✓ Test pod is ready${NC}"
echo ""

# Test file operations
echo -e "${YELLOW}Step 4: Testing file operations...${NC}"

# Create a test file
kubectl exec s3-test-pod -- sh -c 'echo "Hello from EKS S3 CSI Driver!" > /mnt/s3/test-file.txt'
echo "✓ Created test file"

# Read the test file
CONTENT=$(kubectl exec s3-test-pod -- cat /mnt/s3/test-file.txt)
echo "✓ Read test file: $CONTENT"

# List files
kubectl exec s3-test-pod -- ls -la /mnt/s3/
echo "✓ Listed files in S3 mount"

echo -e "${GREEN}✓ File operations successful${NC}"
echo ""

# Show resource status
echo -e "${YELLOW}Resource Status:${NC}"
echo "PVC:"
kubectl get pvc s3-pvc-test
echo ""
echo "Pod:"
kubectl get pod s3-test-pod
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}S3 CSI Driver Test Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}To clean up test resources:${NC}"
echo "kubectl delete -f test-s3-csi-configured.yaml"
echo ""
echo -e "${YELLOW}To check S3 bucket contents:${NC}"
echo "aws s3 ls s3://${S3_BUCKET_NAME}/"
