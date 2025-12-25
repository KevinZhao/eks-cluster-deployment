#!/bin/bash
#
# Karpenter LVM Fix Test - Run from bastion
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

# Set environment variables
export CLUSTER_NAME=${CLUSTER_NAME:-eks-frankfurt-test}
export AWS_REGION=${AWS_REGION:-eu-central-1}

echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo ""

# Ensure we're in the right directory
if [ ! -d "manifests/karpenter" ]; then
    echo "Manifests directory not found. Cloning repository..."
    cd ~
    if [ -d "eks-cluster-deployment" ]; then
        cd eks-cluster-deployment
        git pull origin master
    else
        git clone https://github.com/KevinZhao/eks-cluster-deployment.git
        cd eks-cluster-deployment
    fi
fi

# Now we should be in the project root
if [ ! -d "manifests/karpenter" ]; then
    echo -e "${RED}Error: Cannot find manifests directory${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found project directory${NC}"
echo ""

# Step 1: Apply updated EC2NodeClass configurations
echo -e "${YELLOW}Step 1: Applying updated EC2NodeClass configurations...${NC}"
echo ""

echo "Applying default EC2NodeClass..."
sed "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" manifests/karpenter/ec2nodeclass-default.yaml | kubectl apply -f -

echo "Applying graviton EC2NodeClass..."
sed "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" manifests/karpenter/ec2nodeclass-graviton.yaml | kubectl apply -f -

echo -e "${GREEN}✓ EC2NodeClass configurations applied${NC}"
echo ""

# Step 2: Check current NodeClaims
echo -e "${YELLOW}Step 2: Checking existing NodeClaims...${NC}"
echo ""

kubectl get nodeclaim -o wide 2>/dev/null || echo "No NodeClaims found"

echo ""
echo -e "${YELLOW}Current NodeClaim details:${NC}"
kubectl get nodeclaim -o yaml 2>/dev/null | grep -A 10 "status:" || echo "No status info"

echo ""
read -p "Delete existing NodeClaims to test the fix? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deleting NodeClaims..."
    kubectl delete nodeclaim --all --timeout=60s
    echo -e "${GREEN}✓ NodeClaims deleted${NC}"
    echo ""
    echo "Waiting 15 seconds for cleanup..."
    sleep 15
fi

# Step 3: Create test deployment
echo -e "${YELLOW}Step 3: Creating test deployment...${NC}"
echo ""

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-lvm-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: karpenter-lvm-test
  template:
    metadata:
      labels:
        app: karpenter-lvm-test
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

# Step 4: Monitor provisioning
echo -e "${YELLOW}Step 4: Monitoring provisioning (90 seconds)...${NC}"
echo ""

for i in {1..18}; do
    echo "--- Check $i/18 ---"
    kubectl get nodeclaim 2>/dev/null || echo "No NodeClaims yet"
    sleep 5
done

echo ""

# Step 5: Get NodeClaim details
echo -e "${YELLOW}Step 5: Analyzing NodeClaim...${NC}"
echo ""

NODECLAIM_COUNT=$(kubectl get nodeclaim --no-headers 2>/dev/null | wc -l)

if [ "$NODECLAIM_COUNT" -gt 0 ]; then
    NODECLAIM_NAME=$(kubectl get nodeclaim -o jsonpath='{.items[0].metadata.name}')
    echo "Found NodeClaim: $NODECLAIM_NAME"
    echo ""

    echo "NodeClaim status:"
    kubectl describe nodeclaim "$NODECLAIM_NAME" | grep -A 20 "Status:"
    echo ""

    # Get instance ID
    INSTANCE_ID=$(kubectl get nodeclaim "$NODECLAIM_NAME" -o jsonpath='{.status.providerID}' 2>/dev/null | cut -d'/' -f5 || echo "")

    if [ -n "$INSTANCE_ID" ]; then
        echo -e "${BLUE}Instance ID: $INSTANCE_ID${NC}"
        echo ""

        # Check user-data
        echo -e "${YELLOW}Checking user-data...${NC}"
        USER_DATA=$(aws ec2 describe-instance-attribute \
            --instance-id "$INSTANCE_ID" \
            --attribute userData \
            --region "$AWS_REGION" \
            --query 'UserData.Value' \
            --output text 2>/dev/null | base64 -d)

        if [ -n "$USER_DATA" ]; then
            echo "LVM script from user-data:"
            echo "$USER_DATA" | grep -A 20 "Auto-detect EBS data disk"
            echo ""

            # Verify the fix
            if echo "$USER_DATA" | grep -q 'if \[ -z "\$\$(lsblk'; then
                echo -e "${GREEN}✓ User-data looks correct!${NC}"
                echo "Using inline command substitution: \$\$(lsblk...)"
            else
                echo -e "${RED}✗ User-data may have issues${NC}"
                echo "Checking actual pattern:"
                echo "$USER_DATA" | grep "if \[ -z"
            fi
        fi
        echo ""

        # Check console output
        echo -e "${YELLOW}Checking console output...${NC}"
        CONSOLE=$(aws ec2 get-console-output \
            --instance-id "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --output text 2>/dev/null || echo "")

        if [ -n "$CONSOLE" ]; then
            echo "LVM-related logs:"
            echo "$CONSOLE" | grep -i "lvm\|pvcreate\|vgcreate\|lvcreate" | tail -15
            echo ""

            if echo "$CONSOLE" | grep -q "vg_data"; then
                echo -e "${GREEN}✓ LVM setup detected in logs${NC}"
            else
                echo -e "${YELLOW}⚠ No LVM logs yet (still booting?)${NC}"
            fi
        fi
        echo ""

        # Check node registration
        echo -e "${YELLOW}Checking node registration...${NC}"
        NODE_NAME=$(kubectl get nodes -o json 2>/dev/null | \
            jq -r ".items[] | select(.spec.providerID | contains(\"$INSTANCE_ID\")) | .metadata.name" 2>/dev/null || echo "")

        if [ -n "$NODE_NAME" ]; then
            echo -e "${GREEN}✓ Node registered: $NODE_NAME${NC}"
            echo ""
            kubectl get node "$NODE_NAME"
            echo ""

            # Check pods
            echo "Pods on this node:"
            kubectl get pods -A -o wide --field-selector spec.nodeName="$NODE_NAME"
        else
            echo -e "${YELLOW}⚠ Node not registered yet${NC}"
            echo "Wait and monitor: kubectl get nodes -w"
        fi
    else
        echo -e "${YELLOW}No instance ID in NodeClaim yet${NC}"
    fi
else
    echo -e "${RED}No NodeClaims created${NC}"
    echo ""
    echo "Check Karpenter logs:"
    kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=30
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Test Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}Next Steps:${NC}"
echo ""
echo "1. Monitor nodes:"
echo "   kubectl get nodes -w"
echo ""
echo "2. Check Karpenter logs:"
echo "   kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f"
echo ""
echo "3. Verify pod scheduling:"
echo "   kubectl get pods -o wide | grep karpenter-lvm-test"
echo ""
echo "4. If node joined, verify LVM via SSM:"
echo "   aws ssm start-session --target <instance-id> --region $AWS_REGION"
echo "   # Then run: vgs && lvs && df -h /var/lib/containerd"
echo ""
echo "5. Clean up:"
echo "   kubectl delete deployment karpenter-lvm-test"
echo ""
