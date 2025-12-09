#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==========================================="
echo "Optional CSI Drivers Installation"
echo "==========================================="
echo ""

# 加载环境变量和 helper 函数
source "${SCRIPT_DIR}/0_setup_env.sh"
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

echo "This script installs optional CSI drivers for your EKS cluster."
echo ""
echo "Available drivers:"
echo "  1. EFS CSI Driver - Shared file system (multi-AZ, multi-Pod access)"
echo "  2. S3 CSI Driver - Object storage mounting via Mountpoint for S3 (v2.2.1)"
echo "  3. Both EFS and S3"
echo "  4. Exit"
echo ""

read -p "Select option (1-4): " choice

case $choice in
    1)
        echo ""
        echo "=========================================="
        echo "Installing EFS CSI Driver"
        echo "=========================================="
        echo ""

        # 设置 Pod Identity
        setup_efs_csi_pod_identity

        # 部署 EFS CSI Driver
        echo "Deploying EFS CSI Driver..."
        kubectl apply -f "${PROJECT_ROOT}/manifests/addons/efs-csi-driver.yaml"

        # 等待就绪
        echo "Waiting for EFS CSI Controller to be ready..."
        kubectl wait --for=condition=available --timeout=300s deployment/efs-csi-controller -n kube-system 2>/dev/null || true

        # 验证
        echo ""
        echo "Verifying EFS CSI Driver installation..."
        kubectl get pods -n kube-system | grep efs-csi

        echo ""
        echo "✓ EFS CSI Driver installed successfully!"
        echo ""
        echo "Next steps:"
        echo "  1. Create an EFS file system: aws efs create-file-system --region ${AWS_REGION}"
        echo "  2. Create mount targets in your VPC subnets"
        echo "  3. Create a StorageClass and PVC (see manifests/examples/efs-app.yaml)"
        echo ""
        ;;

    2)
        echo ""
        echo "=========================================="
        echo "Installing S3 CSI Driver"
        echo "=========================================="
        echo ""

        echo "S3 CSI Driver requires S3 bucket permissions."
        echo ""
        echo "IMPORTANT: You need to specify S3 bucket ARNs for access."
        echo "Format: arn:aws:s3:::bucket-name"
        echo ""
        echo "Examples:"
        echo "  - Single bucket: arn:aws:s3:::my-data-bucket"
        echo "  - Multiple buckets: arn:aws:s3:::bucket1,arn:aws:s3:::bucket2"
        echo ""

        read -p "Enter S3 bucket ARN(s) (comma-separated if multiple): " BUCKET_ARNS

        if [ -z "$BUCKET_ARNS" ]; then
            echo "Error: No bucket ARNs provided. Exiting."
            exit 1
        fi

        # 设置 Pod Identity
        setup_s3_csi_pod_identity "$BUCKET_ARNS"

        # 部署 S3 CSI Driver
        echo "Deploying S3 CSI Driver..."
        kubectl apply -f "${PROJECT_ROOT}/manifests/addons/s3-csi-driver.yaml"

        # 等待就绪
        echo "Waiting for S3 CSI Controller to be ready..."
        sleep 30  # S3 CSI driver may take longer to start

        # 验证
        echo ""
        echo "Verifying S3 CSI Driver installation..."
        kubectl get pods -n kube-system | grep s3-csi

        echo ""
        echo "✓ S3 CSI Driver installed successfully!"
        echo ""
        echo "Bucket ARNs configured:"
        IFS=',' read -ra ARNS <<< "$BUCKET_ARNS"
        for arn in "${ARNS[@]}"; do
            echo "  - ${arn}"
        done
        echo ""
        echo "Next steps:"
        echo "  1. Create a PersistentVolume pointing to your S3 bucket"
        echo "  2. Create a PVC and mount it in your Pod"
        echo "  3. See manifests/examples/s3-app.yaml for examples"
        echo ""
        ;;

    3)
        echo ""
        echo "=========================================="
        echo "Installing Both EFS and S3 CSI Drivers"
        echo "=========================================="
        echo ""

        # EFS
        echo "Step 1/2: Installing EFS CSI Driver..."
        setup_efs_csi_pod_identity
        kubectl apply -f "${PROJECT_ROOT}/manifests/addons/efs-csi-driver.yaml"
        echo "✓ EFS CSI Driver deployment submitted"

        # S3
        echo ""
        echo "Step 2/2: Installing S3 CSI Driver..."
        echo ""
        echo "Enter S3 bucket ARN(s) for the S3 CSI Driver:"
        read -p "Bucket ARN(s) (comma-separated): " BUCKET_ARNS

        if [ -z "$BUCKET_ARNS" ]; then
            echo "Warning: No bucket ARNs provided. Skipping S3 CSI Driver."
        else
            setup_s3_csi_pod_identity "$BUCKET_ARNS"
            kubectl apply -f "${PROJECT_ROOT}/manifests/addons/s3-csi-driver.yaml"
            echo "✓ S3 CSI Driver deployment submitted"
        fi

        # 等待
        echo ""
        echo "Waiting for controllers to be ready..."
        sleep 30

        # 验证
        echo ""
        echo "Verifying installations..."
        echo ""
        echo "EFS CSI Driver:"
        kubectl get pods -n kube-system | grep efs-csi || echo "  Not found (may still be starting)"
        echo ""
        echo "S3 CSI Driver:"
        kubectl get pods -n kube-system | grep s3-csi || echo "  Not found (may still be starting)"

        echo ""
        echo "✓ Both drivers installed!"
        echo ""
        echo "Next steps:"
        echo "  1. For EFS: Create EFS file system and mount targets"
        echo "  2. For S3: Use the configured bucket ARNs"
        echo "  3. See manifests/examples/ for usage examples"
        echo ""
        ;;

    4)
        echo "Exiting without installing any drivers."
        exit 0
        ;;

    *)
        echo "Invalid selection. Exiting."
        exit 1
        ;;
esac

echo "==========================================="
echo "Installation Complete"
echo "==========================================="
echo ""
echo "To verify Pod Identity Associations:"
echo "  aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME}"
echo ""
echo "To check CSI driver pods:"
echo "  kubectl get pods -n kube-system | grep csi"
echo ""
