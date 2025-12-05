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
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"

# 4. 设置 AWS Partition（默认为 aws，除非在 GovCloud 或 China）
export AWS_PARTITION="${AWS_PARTITION:-aws}"

# 5. 验证必需的环境变量
REQUIRED_VARS=(
    "CLUSTER_NAME"
    "VPC_ID"
    "PRIVATE_SUBNET_2A"
    "PRIVATE_SUBNET_2B"
    "PRIVATE_SUBNET_2C"
    "PUBLIC_SUBNET_2A"
    "PUBLIC_SUBNET_2B"
    "PUBLIC_SUBNET_2C"
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

# 6. 设置默认值
export K8S_VERSION="${K8S_VERSION:-1.30}"

# 7. 自动推导 AZ（基于子网 ID 模式）
if [ -z "$AZ_2A" ] || [ -z "$AZ_2B" ] || [ -z "$AZ_2C" ]; then
    log "Availability zones not set, deriving from region..."
    export AZ_2A="${AWS_REGION}a"
    export AZ_2B="${AWS_REGION}b"
    export AZ_2C="${AWS_REGION}c"
fi

# 8. 验证配置
log "Validating configuration..."

# 验证 AWS 凭证
aws sts get-caller-identity >/dev/null 2>&1 || \
    error "AWS credentials not configured. Please run 'aws configure' or set AWS credentials."

# 验证 VPC 存在
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" >/dev/null 2>&1 || \
    error "VPC $VPC_ID not found in region $AWS_REGION"

# 验证子网存在（仅验证一个作为示例）
aws ec2 describe-subnets --subnet-ids "$PRIVATE_SUBNET_2A" --region "$AWS_REGION" >/dev/null 2>&1 || \
    error "Subnet $PRIVATE_SUBNET_2A not found in region $AWS_REGION"

log "Configuration validation completed successfully!"

# 9. 显示配置摘要
log "=== Configuration Summary ==="
echo "ACCOUNT_ID: $ACCOUNT_ID"
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "K8S_VERSION: $K8S_VERSION"
echo "AWS_PARTITION: $AWS_PARTITION"
echo "VPC_ID: $VPC_ID"
echo "AZ: $AZ_2A, $AZ_2B, $AZ_2C"
echo "PRIVATE_SUBNETS: $PRIVATE_SUBNET_2A, $PRIVATE_SUBNET_2B, $PRIVATE_SUBNET_2C"
echo "PUBLIC_SUBNETS: $PUBLIC_SUBNET_2A, $PUBLIC_SUBNET_2B, $PUBLIC_SUBNET_2C"
log "============================"
