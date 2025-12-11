#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== EKS Cluster Installation with Cluster Autoscaler and EBS CSI Driver ==="

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 1.1 设置 KUBECONFIG 环境变量 (确保 kubectl 能找到配置文件)
export KUBECONFIG="${HOME}/.kube/config"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 1.5. 导入 Pod Identity helper 函数
source "${SCRIPT_DIR}/pod_identity_helpers.sh"

# 1.6. 检查必需的依赖工具
echo "Checking required dependencies..."
MISSING_DEPS=()

command -v kubectl >/dev/null 2>&1 || MISSING_DEPS+=("kubectl")
command -v eksctl >/dev/null 2>&1 || MISSING_DEPS+=("eksctl")
command -v helm >/dev/null 2>&1 || MISSING_DEPS+=("helm")
command -v envsubst >/dev/null 2>&1 || MISSING_DEPS+=("envsubst (from gettext package)")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")
command -v aws >/dev/null 2>&1 || MISSING_DEPS+=("aws cli")

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "❌ ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    echo ""
    echo "Please install the missing dependencies and try again."
    exit 1
fi
echo "✓ All required dependencies are installed"
echo ""

# 2. 创建EKS集群
echo "Creating EKS cluster..."
envsubst < "${PROJECT_ROOT}/manifests/cluster/eksctl_cluster_template.yaml" > "${PROJECT_ROOT}/eksctl_cluster_final.yaml"
eksctl create cluster -f "${PROJECT_ROOT}/eksctl_cluster_final.yaml"
