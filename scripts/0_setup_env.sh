#!/bin/bash

set -e

# 日志函数
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

log "Loading environment configuration..."

# 1. 尝试从 .env 文件加载配置（如果存在）
if [ -f .env ]; then
    log "Loading configuration from .env file..."
    set -a
    source .env
    set +a
fi

# 2. 动态获取 AWS Account ID（如果未设置）
if [ -z "$ACCOUNT_ID" ]; then
    log "ACCOUNT_ID not set, fetching from AWS STS..."
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || \
        error "Failed to get AWS Account ID. Please set ACCOUNT_ID environment variable or configure AWS CLI."
    export ACCOUNT_ID
fi

# 3. 设置 AWS Region（优先级：环境变量 > .env > AWS CLI 配置 > 默认值）
if [ -z "$AWS_REGION" ]; then
    AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
    log "AWS_REGION not set, using: $AWS_REGION"
fi
export AWS_REGION

# 自动设置 AWS_DEFAULT_REGION（如果 .env 中没有设置）
if [ -z "$AWS_DEFAULT_REGION" ]; then
    log "AWS_DEFAULT_REGION not set, auto-setting to: $AWS_REGION"
    export AWS_DEFAULT_REGION="$AWS_REGION"
else
    export AWS_DEFAULT_REGION
fi

# 4. 验证必需的环境变量
REQUIRED_VARS=(
    "CLUSTER_NAME"
    "VPC_ID"
    "PRIVATE_SUBNET_A"
    "PRIVATE_SUBNET_B"
    "PRIVATE_SUBNET_C"
    "PUBLIC_SUBNET_A"
    "PUBLIC_SUBNET_B"
    "PUBLIC_SUBNET_C"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    error "Missing required environment variables: ${MISSING_VARS[*]}\nPlease create a .env file or set these variables. See .env.example for reference."
fi

# 5. 设置默认值
export K8S_VERSION="${K8S_VERSION:-1.34}"
export SERVICE_IPV4_CIDR="${SERVICE_IPV4_CIDR:-172.20.0.0/16}"

# 6. 自动推导 AZ（基于子网 ID 模式）
if [ -z "$AZ_A" ] || [ -z "$AZ_B" ] || [ -z "$AZ_C" ]; then
    log "Availability zones not set, deriving from region..."
    export AZ_A="${AWS_REGION}a"
    export AZ_B="${AWS_REGION}b"
    export AZ_C="${AWS_REGION}c"
fi

# 7. 验证配置
log "Validating configuration..."

# 验证 AWS 凭证
aws sts get-caller-identity >/dev/null 2>&1 || \
    error "AWS credentials not configured. Please run 'aws configure' or set AWS credentials."

log "Configuration validation completed successfully!"

# 8. 系统节点组配置（高级选项）
export SYSTEM_NODE_INSTANCE_TYPE="${SYSTEM_NODE_INSTANCE_TYPE:-m7i.2xlarge}"
export SYSTEM_NODE_ROOT_VOLUME_SIZE="${SYSTEM_NODE_ROOT_VOLUME_SIZE:-50}"
export SYSTEM_NODE_DATA_VOLUME_SIZE="${SYSTEM_NODE_DATA_VOLUME_SIZE:-100}"
export SYSTEM_NODE_DESIRED_CAPACITY="${SYSTEM_NODE_DESIRED_CAPACITY:-3}"
export SYSTEM_NODE_MIN_SIZE="${SYSTEM_NODE_MIN_SIZE:-3}"
export SYSTEM_NODE_MAX_SIZE="${SYSTEM_NODE_MAX_SIZE:-6}"

# 系统节点标签配置（用于调度系统组件）
export SYSTEM_NODE_LABEL_KEY="${SYSTEM_NODE_LABEL_KEY:-app}"
export SYSTEM_NODE_LABEL_VALUE="${SYSTEM_NODE_LABEL_VALUE:-eks-utils}"

# 配置验证
if [[ ! "$SYSTEM_NODE_INSTANCE_TYPE" =~ ^[a-z][0-9][a-z]?\.[a-z0-9]+$ ]]; then
    echo "⚠ WARNING: Invalid SYSTEM_NODE_INSTANCE_TYPE format, using default: m7i.2xlarge"
    export SYSTEM_NODE_INSTANCE_TYPE="m7i.2xlarge"
fi

if [ "$SYSTEM_NODE_DATA_VOLUME_SIZE" -lt 50 ]; then
    echo "⚠ WARNING: SYSTEM_NODE_DATA_VOLUME_SIZE too small, using minimum: 50GB"
    export SYSTEM_NODE_DATA_VOLUME_SIZE=50
fi

# 9. 显示配置摘要
log "=== Configuration Summary ==="
echo "ACCOUNT_ID: $ACCOUNT_ID"
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "K8S_VERSION: $K8S_VERSION"
echo "VPC_ID: $VPC_ID"
echo "AZ: $AZ_A, $AZ_B, $AZ_C"
echo "PRIVATE_SUBNETS: $PRIVATE_SUBNET_A, $PRIVATE_SUBNET_B, $PRIVATE_SUBNET_C"
echo "PUBLIC_SUBNETS: $PUBLIC_SUBNET_A, $PUBLIC_SUBNET_B, $PUBLIC_SUBNET_C"
echo "SYSTEM_NODE_INSTANCE_TYPE: $SYSTEM_NODE_INSTANCE_TYPE"
echo "SYSTEM_NODE_DATA_VOLUME_SIZE: ${SYSTEM_NODE_DATA_VOLUME_SIZE}GB"
echo "SYSTEM_NODE_LABEL: ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE}"
log "============================"

# ============================================================
# Kubectl Context Verification Function
# ============================================================
# 验证 kubectl 是否连接到正确的集群
# 用法: verify_kubectl_context
verify_kubectl_context() {
    local cluster_name="${CLUSTER_NAME}"
    local region="${AWS_REGION}"

    if [ -z "${cluster_name}" ]; then
        error "CLUSTER_NAME not set, cannot verify kubectl context"
    fi

    log "Verifying kubectl is connected to cluster '${cluster_name}'..."

    # 首先更新 kubeconfig 确保连接到正确的集群
    if ! aws eks update-kubeconfig --name "${cluster_name}" --region "${region}" &>/dev/null; then
        error "Failed to update kubeconfig for cluster '${cluster_name}'"
    fi

    # 检查当前 context 是否包含集群名
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "")

    if [[ "${current_context}" != *"${cluster_name}"* ]]; then
        log "WARNING: kubectl context '${current_context}' doesn't match cluster '${cluster_name}'"
        log "Forcing context update with alias..."
        aws eks update-kubeconfig --region "${region}" --name "${cluster_name}" --alias "${cluster_name}"
        current_context=$(kubectl config current-context 2>/dev/null || echo "")
    fi

    # 验证 API endpoint 匹配
    local expected_endpoint
    local current_endpoint

    expected_endpoint=$(aws eks describe-cluster --name "${cluster_name}" --region "${region}" --query 'cluster.endpoint' --output text 2>/dev/null)
    current_endpoint=$(kubectl config view --minify --output jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")

    if [ -z "${expected_endpoint}" ]; then
        error "Failed to get cluster endpoint for '${cluster_name}'"
    fi

    if [ "${current_endpoint}" != "${expected_endpoint}" ]; then
        error "kubectl is pointing to WRONG cluster endpoint!
  Expected: ${expected_endpoint}
  Current:  ${current_endpoint}
  Kubeconfig: ${KUBECONFIG:-default}

Please ensure you are operating on the correct cluster."
    fi

    log "✓ kubectl verified - connected to cluster '${cluster_name}'"
    log "  Context: ${current_context}"
    log "  Endpoint: ${current_endpoint}"
}
