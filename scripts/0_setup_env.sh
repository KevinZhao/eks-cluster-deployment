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

# 4. 设置 AWS Partition（默认为 aws，除非在 GovCloud 或 China）
if [ -z "$AWS_PARTITION" ]; then
    log "AWS_PARTITION not set, using default: aws"
    export AWS_PARTITION="aws"
else
    export AWS_PARTITION
fi

# 5. 环境变量兼容性映射（支持 _A 和 _2A 两种命名方式）
# 如果使用 _2A 格式，自动映射到 _A 格式
if [ -n "$PRIVATE_SUBNET_2A" ]; then
    export PRIVATE_SUBNET_A="${PRIVATE_SUBNET_A:-$PRIVATE_SUBNET_2A}"
    export PRIVATE_SUBNET_B="${PRIVATE_SUBNET_B:-$PRIVATE_SUBNET_2B}"
    export PRIVATE_SUBNET_C="${PRIVATE_SUBNET_C:-$PRIVATE_SUBNET_2C}"
fi

if [ -n "$PUBLIC_SUBNET_2A" ]; then
    export PUBLIC_SUBNET_A="${PUBLIC_SUBNET_A:-$PUBLIC_SUBNET_2A}"
    export PUBLIC_SUBNET_B="${PUBLIC_SUBNET_B:-$PUBLIC_SUBNET_2B}"
    export PUBLIC_SUBNET_C="${PUBLIC_SUBNET_C:-$PUBLIC_SUBNET_2C}"
fi

if [ -n "$AZ_2A" ]; then
    export AZ_A="${AZ_A:-$AZ_2A}"
    export AZ_B="${AZ_B:-$AZ_2B}"
    export AZ_C="${AZ_C:-$AZ_2C}"
fi

# 6. 验证必需的环境变量
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

# 7. 设置默认值
export K8S_VERSION="${K8S_VERSION:-1.34}"
export SERVICE_IPV4_CIDR="${SERVICE_IPV4_CIDR:-172.20.0.0/16}"

# 8. 自动推导 AZ（基于子网 ID 模式）
if [ -z "$AZ_A" ] || [ -z "$AZ_B" ] || [ -z "$AZ_C" ]; then
    log "Availability zones not set, deriving from region..."
    export AZ_A="${AWS_REGION}a"
    export AZ_B="${AWS_REGION}b"
    export AZ_C="${AWS_REGION}c"
fi

# 9. 验证配置
log "Validating configuration..."

# 验证 AWS 凭证
aws sts get-caller-identity >/dev/null 2>&1 || \
    error "AWS credentials not configured. Please run 'aws configure' or set AWS credentials."

log "Configuration validation completed successfully!"

# 10. 显示配置摘要
log "=== Configuration Summary ==="
echo "ACCOUNT_ID: $ACCOUNT_ID"
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "K8S_VERSION: $K8S_VERSION"
echo "AWS_PARTITION: $AWS_PARTITION"
echo "VPC_ID: $VPC_ID"
echo "AZ: $AZ_A, $AZ_B, $AZ_C"
echo "PRIVATE_SUBNETS: $PRIVATE_SUBNET_A, $PRIVATE_SUBNET_B, $PRIVATE_SUBNET_C"
echo "PUBLIC_SUBNETS: $PUBLIC_SUBNET_A, $PUBLIC_SUBNET_B, $PUBLIC_SUBNET_C"
log "============================"
