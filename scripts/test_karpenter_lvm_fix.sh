#!/bin/bash
#
# Test script for Karpenter LVM fix
# Run this from the bastion host
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Testing Karpenter LVM Fix${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Load environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/0_setup_env.sh"

export CLUSTER_NAME AWS_REGION

echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo ""

# Step 1: Apply updated EC2NodeClass configurations
echo -e "${YELLOW}Step 1: Applying updated EC2NodeClass configurations...${NC}"
echo ""

echo "Applying default EC2NodeClass..."
envsubst < "${SCRIPT_DIR}/../manifests/karpenter/ec2nodeclass-default.yaml" | kubectl apply -f -

echo "Applying graviton EC2NodeClass..."
envsubst < "${SCRIPT_DIR}/../manifests/karpenter/ec2nodeclass-graviton.yaml" | kubectl apply -f -

echo -e "${GREEN}✓ EC2NodeClass configurations applied${NC}"
echo ""

# Step 2: Check current NodeClaims
echo -e "${YELLOW}Step 2: Checking existing NodeClaims...${NC}"
echo ""

NODECLAIMS=$(kubectl get nodeclaim -o json)
echo "$NODECLAIMS" | jq -r '.items[] | "\(.metadata.name) - Status: \(.status.conditions[] | select(.type=="Launched") | .status) - Instance: \(.status.providerID // "N/A")"'

echo ""
read -p "Do you want to delete existing failed NodeClaims? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deleting NodeClaims..."
    kubectl delete nodeclaim --all
    echo -e "${GREEN}✓ NodeClaims deleted${NC}"
    echo ""
    echo "Waiting 10 seconds for cleanup..."
    sleep 10
fi

# Step 3: Create test deployment to trigger node provisioning
echo -e "${YELLOW}Step 3: Creating test deployment to trigger provisioning...${NC}"
echo ""

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: karpenter-test
  template:
    metadata:
      labels:
        app: karpenter-test
    spec:
      containers:
      - name: pause
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.2
        resources:
          requests:
            cpu: 1
            memory: 1Gi
      nodeSelector:
        karpenter.sh/capacity-type: on-demand
EOF

echo -e "${GREEN}✓ Test deployment created${NC}"
echo ""

# Step 4: Monitor node provisioning
echo -e "${YELLOW}Step 4: Monitoring node provisioning (60 seconds)...${NC}"
echo ""

echo "Watching NodeClaims..."
for i in {1..12}; do
    echo "--- Check $i/12 (every 5s) ---"
    kubectl get nodeclaim -o wide 2>/dev/null || echo "No NodeClaims yet"
    sleep 5
done

echo ""

# Step 5: Check if new nodes joined
echo -e "${YELLOW}Step 5: Checking if new nodes joined the cluster...${NC}"
echo ""

kubectl get nodes -l karpenter.sh/capacity-type=on-demand -o wide

echo ""

# Step 6: Get NodeClaim details
echo -e "${YELLOW}Step 6: Getting NodeClaim details...${NC}"
echo ""

NODECLAIM_NAME=$(kubectl get nodeclaim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$NODECLAIM_NAME" ]; then
    echo "NodeClaim: $NODECLAIM_NAME"
    echo ""

    kubectl get nodeclaim "$NODECLAIM_NAME" -o yaml | grep -A 20 "status:"

    # Get instance ID
    INSTANCE_ID=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.providerID}' | cut -d'/' -f5)

    if [ -n "$INSTANCE_ID" ]; then
        echo ""
        echo -e "${BLUE}Instance ID: $INSTANCE_ID${NC}"
        echo ""

        # Step 7: Check user-data on the instance
        echo -e "${YELLOW}Step 7: Checking user-data on instance...${NC}"
        echo ""

        echo "Fetching user-data attribute..."
        USER_DATA=$(aws ec2 describe-instance-attribute \
            --instance-id "$INSTANCE_ID" \
            --attribute userData \
            --region "$AWS_REGION" \
            --query 'UserData.Value' \
            --output text 2>/dev/null | base64 -d)

        if [ -n "$USER_DATA" ]; then
            echo "User-data LVM script section:"
            echo "$USER_DATA" | grep -A 15 "Auto-detect EBS data disk" || echo "LVM section not found in user-data"
            echo ""

            # Check for the critical line
            if echo "$USER_DATA" | grep -q 'if \[ -z "\$\$(lsblk'; then
                echo -e "${GREEN}✓ User-data looks correct (using inline command substitution)${NC}"
            else
                echo -e "${RED}✗ User-data may have issues${NC}"
            fi
        else
            echo -e "${YELLOW}Could not fetch user-data${NC}"
        fi

        echo ""

        # Step 8: Check console output
        echo -e "${YELLOW}Step 8: Checking console output for LVM setup...${NC}"
        echo ""

        echo "Fetching console output (this may take a moment)..."
        CONSOLE_OUTPUT=$(aws ec2 get-console-output \
            --instance-id "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --output text 2>/dev/null || echo "")

        if [ -n "$CONSOLE_OUTPUT" ]; then
            echo "Searching for LVM-related logs..."
            echo "$CONSOLE_OUTPUT" | grep -i "lvm\|pvcreate\|vgcreate\|lvcreate\|containerd" | tail -20
            echo ""

            if echo "$CONSOLE_OUTPUT" | grep -q "vg_data"; then
                echo -e "${GREEN}✓ LVM setup appears to have run${NC}"
            else
                echo -e "${YELLOW}⚠ No LVM logs found yet (may still be booting)${NC}"
            fi
        else
            echo -e "${YELLOW}Console output not available yet${NC}"
        fi

        echo ""

        # Step 9: Check if node registered
        echo -e "${YELLOW}Step 9: Checking if node registered with Kubernetes...${NC}"
        echo ""

        NODE_NAME=$(kubectl get nodes -o json | jq -r ".items[] | select(.spec.providerID | contains(\"$INSTANCE_ID\")) | .metadata.name" 2>/dev/null || echo "")

        if [ -n "$NODE_NAME" ]; then
            echo -e "${GREEN}✓ Node registered: $NODE_NAME${NC}"
            echo ""
            kubectl get node "$NODE_NAME" -o wide
            echo ""

            # Try to connect via SSM and check LVM
            echo -e "${YELLOW}Step 10: Checking LVM configuration on node via SSM...${NC}"
            echo ""

            read -p "Do you want to check LVM via SSM? (y/n) " -n 1 -r
            echo ""

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Running LVM checks..."
                echo ""

                echo "=== Checking volume groups ==="
                aws ssm send-command \
                    --instance-ids "$INSTANCE_ID" \
                    --document-name "AWS-RunShellScript" \
                    --parameters 'commands=["vgs"]' \
                    --region "$AWS_REGION" \
                    --output text \
                    --query 'Command.CommandId' | xargs -I {} aws ssm wait command-executed \
                    --command-id {} \
                    --instance-id "$INSTANCE_ID" \
                    --region "$AWS_REGION" && \
                aws ssm get-command-invocation \
                    --command-id $(aws ssm send-command \
                        --instance-ids "$INSTANCE_ID" \
                        --document-name "AWS-RunShellScript" \
                        --parameters 'commands=["vgs"]' \
                        --region "$AWS_REGION" \
                        --output text \
                        --query 'Command.CommandId') \
                    --instance-id "$INSTANCE_ID" \
                    --region "$AWS_REGION" \
                    --query 'StandardOutputContent' \
                    --output text

                echo ""
                echo "=== Checking /var/lib/containerd mount ==="
                aws ssm send-command \
                    --instance-ids "$INSTANCE_ID" \
                    --document-name "AWS-RunShellScript" \
                    --parameters 'commands=["df -h /var/lib/containerd"]' \
                    --region "$AWS_REGION" \
                    --output text \
                    --query 'Command.CommandId' | xargs -I {} aws ssm wait command-executed \
                    --command-id {} \
                    --instance-id "$INSTANCE_ID" \
                    --region "$AWS_REGION" && \
                aws ssm get-command-invocation \
                    --command-id $(aws ssm send-command \
                        --instance-ids "$INSTANCE_ID" \
                        --document-name "AWS-RunShellScript" \
                        --parameters 'commands=["df -h /var/lib/containerd"]' \
                        --region "$AWS_REGION" \
                        --output text \
                        --query 'Command.CommandId') \
                    --instance-id "$INSTANCE_ID" \
                    --region "$AWS_REGION" \
                    --query 'StandardOutputContent' \
                    --output text
            fi
        else
            echo -e "${YELLOW}⚠ Node not registered yet${NC}"
            echo "Instance may still be bootstrapping..."
        fi
    else
        echo -e "${YELLOW}No instance ID found in NodeClaim${NC}"
    fi
else
    echo -e "${YELLOW}No NodeClaims found${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Test Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}Summary:${NC}"
echo "1. EC2NodeClass configurations applied"
echo "2. Test deployment created to trigger provisioning"
echo "3. Check the output above to verify:"
echo "   - NodeClaim was created"
echo "   - Instance was launched"
echo "   - User-data contains correct LVM script"
echo "   - Node registered with Kubernetes"
echo "   - LVM is properly configured"
echo ""

echo -e "${YELLOW}To clean up test deployment:${NC}"
echo "  kubectl delete deployment karpenter-test"
echo ""

echo -e "${YELLOW}To watch Karpenter logs:${NC}"
echo "  kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f"
echo ""
