#!/bin/bash

# 关闭 EKS API Server 公网访问脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "关闭 EKS API Server 公网访问"
echo "=========================================="
echo ""

# 加载环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

echo "集群: ${CLUSTER_NAME}"
echo "区域: ${AWS_REGION}"
echo ""

# 获取当前配置
CURRENT_PUBLIC=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
CURRENT_PRIVATE=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' --output text)

echo "当前配置:"
echo "  Public Access:  ${CURRENT_PUBLIC}"
echo "  Private Access: ${CURRENT_PRIVATE}"
echo ""

if [ "$CURRENT_PUBLIC" == "False" ]; then
    echo "公网访问已经关闭，无需操作"
    exit 0
fi

echo "警告:"
echo "  关闭公网访问后，只能从 VPC 内部访问集群"
echo "  确保你的操作环境在 VPC 内部，否则将失去访问权限"
echo ""

read -p "确认关闭公网访问? (y/n) " confirm

if [[ $confirm != "y" && $confirm != "Y" ]]; then
    echo "已取消"
    exit 0
fi

echo ""
echo "正在关闭公网访问..."

aws eks update-cluster-config \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --resources-vpc-config \
        endpointPublicAccess=false,endpointPrivateAccess=true

echo ""
echo "✓ 更新命令已提交"
echo ""
echo "等待更新完成（约 5-10 分钟）..."
echo ""

# 等待更新完成
while true; do
    STATUS=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
        --query 'cluster.status' --output text 2>/dev/null) || {
        echo "✗ 无法连接到 AWS API，可能已经失去访问权限"
        echo "  请从 VPC 内部重新运行此脚本检查状态"
        exit 1
    }

    if [ "$STATUS" == "ACTIVE" ]; then
        PUBLIC=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
            --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)

        if [ "$PUBLIC" == "False" ]; then
            echo "✓ 公网访问已关闭"
            break
        fi
    fi

    echo "  状态: $STATUS, 继续等待..."
    sleep 30
done

echo ""
echo "=== 配置已更新 ==="
echo ""
echo "新配置:"
echo "  Public Access:  False"
echo "  Private Access: True"
echo ""
echo "重要提示:"
echo "  1. 现在只能从 VPC 内部访问集群"
echo "  2. 确保你的操作环境在 VPC 内部"
echo "  3. Pod Identity 功能不受影响"
echo ""
