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

# 设置 KUBECONFIG 环境变量
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 验证集群存在并更新 kubeconfig
echo "Verifying EKS cluster exists and updating kubeconfig..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "❌ ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    exit 1
fi

# 验证 kubectl context（使用统一函数）
verify_kubectl_context
echo ""

# 支持非交互模式: INSTALL_DRIVERS=efs|fsx|s3|all S3_BUCKET_ARNS=arn:aws:s3:::bucket1,arn:aws:s3:::bucket2
INSTALL_DRIVERS="${INSTALL_DRIVERS:-}"
S3_BUCKET_ARNS="${S3_BUCKET_ARNS:-}"

if [ -z "$INSTALL_DRIVERS" ]; then
    echo "This script installs optional CSI drivers for your EKS cluster."
    echo ""
    echo "For non-interactive mode, set environment variables:"
    echo "  INSTALL_DRIVERS=efs|fsx|s3|all"
    echo "  S3_BUCKET_ARNS='arn:aws:s3:::bucket1,arn:aws:s3:::bucket2' (for S3 driver)"
    echo ""
    echo "Available drivers:"
    echo "  1. EFS CSI Driver - Shared file system (multi-AZ, multi-Pod access) [${EFS_CSI_VERSION}]"
    echo "  2. FSx CSI Driver - High-performance Lustre/ONTAP for HPC/ML workloads [${FSX_CSI_VERSION}]"
    echo "  3. S3 CSI Driver - Object storage mounting via Mountpoint for S3 [${S3_CSI_VERSION}]"
    echo "  4. Install All (EFS + FSx + S3)"
    echo "  5. Exit"
    echo ""

    read -p "Select option (1-5): " choice
else
    case "$INSTALL_DRIVERS" in
        efs) choice=1 ;;
        fsx) choice=2 ;;
        s3) choice=3 ;;
        all) choice=4 ;;
        *)
            echo "❌ ERROR: Invalid INSTALL_DRIVERS value: $INSTALL_DRIVERS"
            echo "Valid values: efs, fsx, s3, all"
            exit 1
            ;;
    esac
    echo "Running in non-interactive mode: INSTALL_DRIVERS=$INSTALL_DRIVERS"
fi

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
        sed -e "s/\${SYSTEM_NODE_LABEL_KEY}/${SYSTEM_NODE_LABEL_KEY}/g" \
            -e "s/\${SYSTEM_NODE_LABEL_VALUE}/${SYSTEM_NODE_LABEL_VALUE}/g" \
            "${PROJECT_ROOT}/manifests/addons/efs-csi-driver.yaml" | kubectl apply -f -

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
        echo "  3. Create a StorageClass and PVC (see examples/efs-app.yaml)"
        echo ""
        ;;

    2)
        echo ""
        echo "=========================================="
        echo "Installing FSx CSI Driver"
        echo "=========================================="
        echo ""

        # 设置 Pod Identity
        setup_fsx_csi_pod_identity

        # 部署 FSx CSI Driver
        echo "Deploying FSx CSI Driver..."
        sed -e "s/\${SYSTEM_NODE_LABEL_KEY}/${SYSTEM_NODE_LABEL_KEY}/g" \
            -e "s/\${SYSTEM_NODE_LABEL_VALUE}/${SYSTEM_NODE_LABEL_VALUE}/g" \
            -e "s/\${AWS_REGION}/${AWS_REGION}/g" \
            "${PROJECT_ROOT}/manifests/addons/fsx-csi-driver.yaml" | kubectl apply -f -

        # 等待就绪
        echo "Waiting for FSx CSI Controller to be ready..."
        kubectl wait --for=condition=available --timeout=300s deployment/fsx-csi-controller -n kube-system 2>/dev/null || true

        # 验证
        echo ""
        echo "Verifying FSx CSI Driver installation..."
        kubectl get pods -n kube-system | grep fsx-csi

        echo ""
        echo "✓ FSx CSI Driver installed successfully!"
        echo ""
        echo "Next steps:"
        echo "  1. Create FSx for Lustre or ONTAP file system"
        echo "  2. Create a StorageClass with FSx parameters"
        echo "  3. Create PVC and mount in your workloads"
        echo ""
        echo "Supported FSx types:"
        echo "  - FSx for Lustre: High-performance for HPC/ML (GB/s throughput)"
        echo "  - FSx for NetApp ONTAP: Enterprise features (snapshots, replication)"
        echo ""
        ;;

    3)
        echo ""
        echo "=========================================="
        echo "Installing S3 CSI Driver"
        echo "=========================================="
        echo ""

        if [ -z "$S3_BUCKET_ARNS" ]; then
            echo "S3 CSI Driver requires S3 bucket permissions."
            echo ""
            echo "IMPORTANT: You need to specify S3 bucket ARNs for access."
            echo ""
            echo "Supported bucket types:"
            echo "  1. Standard S3: arn:aws:s3:::bucket-name"
            echo "  2. S3 Express One Zone: arn:aws:s3express:region:account:bucket/bucket-name--zone-id--x-s3"
            echo ""
            echo "Examples:"
            echo "  - Standard: arn:aws:s3:::my-data-bucket"
            echo "  - S3 Express: arn:aws:s3express:us-east-1:123456789012:bucket/my-bucket--use1-az1--x-s3"
            echo "  - Mixed: arn:aws:s3:::bucket1,arn:aws:s3express:us-east-1:123456789012:bucket/express-bucket--use1-az1--x-s3"
            echo ""

            read -p "Enter S3 bucket ARN(s) (comma-separated if multiple): " BUCKET_ARNS
        else
            BUCKET_ARNS="$S3_BUCKET_ARNS"
            echo "Using S3 bucket ARNs from environment: $BUCKET_ARNS"
        fi

        if [ -z "$BUCKET_ARNS" ]; then
            echo "❌ ERROR: No bucket ARNs provided. Exiting."
            exit 1
        fi

        # 部署 S3 CSI Driver (使用官方 kustomize)
        echo "Deploying S3 CSI Driver ${S3_CSI_VERSION} using official manifests..."
        kubectl apply -k "github.com/awslabs/mountpoint-s3-csi-driver/deploy/kubernetes/overlays/stable/?ref=${S3_CSI_VERSION}"

        # 扩展 controller 到 2 副本（官方默认 1，参考 EBS CSI 最佳实践设为 2）
        echo "Scaling S3 CSI controller to 2 replicas for HA..."
        kubectl scale deployment s3-csi-controller -n kube-system --replicas=2

        # 等待 CRD 和基础资源就绪
        echo "Waiting for resources to be created..."
        sleep 10

        # 设置 Pod Identity（在 ServiceAccount 创建之后）
        setup_s3_csi_pod_identity "$BUCKET_ARNS"

        # 配置 ServiceAccount 注解
        echo "Configuring ServiceAccount for Pod Identity..."
        kubectl annotate serviceaccount s3-csi-driver-sa -n kube-system \
            eks.amazonaws.com/sts-regional-endpoints="true" --overwrite

        # 等待就绪
        echo "Waiting for S3 CSI Driver pods to be ready..."
        sleep 30

        # 验证
        echo ""
        echo "Verifying S3 CSI Driver installation..."
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver
        echo ""
        kubectl get pods -n mount-s3 2>/dev/null || echo "No Mountpoint pods yet (will be created on first volume mount)"

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
        echo "  3. See examples/s3-app.yaml for examples"
        echo ""
        ;;

    4)
        echo ""
        echo "=========================================="
        echo "Installing All CSI Drivers (EFS + FSx + S3)"
        echo "=========================================="
        echo ""

        # EFS
        echo "Step 1/3: Installing EFS CSI Driver..."
        setup_efs_csi_pod_identity
        sed -e "s/\${SYSTEM_NODE_LABEL_KEY}/${SYSTEM_NODE_LABEL_KEY}/g" \
            -e "s/\${SYSTEM_NODE_LABEL_VALUE}/${SYSTEM_NODE_LABEL_VALUE}/g" \
            "${PROJECT_ROOT}/manifests/addons/efs-csi-driver.yaml" | kubectl apply -f -
        echo "✓ EFS CSI Driver deployment submitted"
        echo ""

        # FSx
        echo "Step 2/3: Installing FSx CSI Driver..."
        setup_fsx_csi_pod_identity
        sed -e "s/\${SYSTEM_NODE_LABEL_KEY}/${SYSTEM_NODE_LABEL_KEY}/g" \
            -e "s/\${SYSTEM_NODE_LABEL_VALUE}/${SYSTEM_NODE_LABEL_VALUE}/g" \
            -e "s/\${AWS_REGION}/${AWS_REGION}/g" \
            "${PROJECT_ROOT}/manifests/addons/fsx-csi-driver.yaml" | kubectl apply -f -
        echo "✓ FSx CSI Driver deployment submitted"
        echo ""

        # S3
        echo "Step 3/3: Installing S3 CSI Driver..."
        echo ""

        if [ -z "$S3_BUCKET_ARNS" ]; then
            echo "Enter S3 bucket ARN(s) for the S3 CSI Driver:"
            echo "  - Standard S3: arn:aws:s3:::bucket-name"
            echo "  - S3 Express: arn:aws:s3express:region:account:bucket/bucket-name--zone-id--x-s3"
            read -p "Bucket ARN(s) (comma-separated): " BUCKET_ARNS
        else
            BUCKET_ARNS="$S3_BUCKET_ARNS"
            echo "Using S3 bucket ARNs from environment: $BUCKET_ARNS"
        fi

        if [ -z "$BUCKET_ARNS" ]; then
            echo "Warning: No bucket ARNs provided. Skipping S3 CSI Driver."
        else
            # 部署 S3 CSI Driver (使用官方 kustomize)
            echo "Deploying S3 CSI Driver ${S3_CSI_VERSION} using official manifests..."
            kubectl apply -k "github.com/awslabs/mountpoint-s3-csi-driver/deploy/kubernetes/overlays/stable/?ref=${S3_CSI_VERSION}"

            # 扩展 controller 到 2 副本（官方默认 1，参考 EBS CSI 最佳实践设为 2）
            echo "Scaling S3 CSI controller to 2 replicas for HA..."
            kubectl scale deployment s3-csi-controller -n kube-system --replicas=2

            # 等待资源创建
            echo "Waiting for resources to be created..."
            sleep 10

            # 设置 Pod Identity
            setup_s3_csi_pod_identity "$BUCKET_ARNS"

            # 配置 ServiceAccount 注解
            echo "Configuring ServiceAccount for Pod Identity..."
            kubectl annotate serviceaccount s3-csi-driver-sa -n kube-system \
                eks.amazonaws.com/sts-regional-endpoints="true" --overwrite

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
        echo "FSx CSI Driver:"
        kubectl get pods -n kube-system | grep fsx-csi || echo "  Not found (may still be starting)"
        echo ""
        echo "S3 CSI Driver:"
        kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver || echo "  Not found (may still be starting)"
        echo ""
        kubectl get pods -n mount-s3 2>/dev/null || echo "No Mountpoint pods yet (will be created on first volume mount)"

        echo ""
        echo "✓ All drivers installed!"
        echo ""
        echo "Next steps:"
        echo "  1. For EFS: Create EFS file system and mount targets"
        echo "  2. For FSx: Create FSx for Lustre or ONTAP file system"
        echo "  3. For S3: Use the configured bucket ARNs"
        echo "  4. See examples/ for usage examples"
        echo ""
        ;;

    5)
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
