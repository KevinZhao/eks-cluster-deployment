#!/bin/bash
#
# Quick test script - Copy and paste this into your bastion host
#

set -e

echo "=== Quick Karpenter LVM Fix Test ==="
echo ""

# Navigate to project directory
cd ~/eks-cluster-deployment || cd /home/ssm-user/eks-cluster-deployment || {
    echo "Project directory not found. Cloning..."
    cd ~
    git clone https://github.com/KevinZhao/eks-cluster-deployment.git
    cd eks-cluster-deployment
}

# Pull latest changes
echo "Pulling latest code..."
git pull origin master

# Set environment variables
export CLUSTER_NAME=eks-frankfurt-test
export AWS_REGION=eu-central-1

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo ""

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

# Verify kubectl access
echo "Verifying kubectl access..."
if kubectl get nodes &>/dev/null; then
    echo "✓ kubectl access confirmed"
    echo ""
    kubectl get nodes
else
    echo "✗ Cannot access cluster"
    exit 1
fi

echo ""
echo "Ready to run test script!"
echo ""

# Run the test script
./scripts/test_karpenter_lvm_fix.sh
