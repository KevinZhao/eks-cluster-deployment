#!/bin/bash

set -e

# 日志函数
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
warn() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }

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

# 4. 验证必需的环境变量 (支持3-4个AZ)
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

# 第4个 AZ 是可选的 (Oregon等区域有4个AZ)
OPTIONAL_4TH_AZ_VARS=(
    "PRIVATE_SUBNET_D"
    "PUBLIC_SUBNET_D"
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

# ============================================
# 组件版本配置（可通过 .env 覆盖）
# ============================================
# Cluster Autoscaler - 版本应与 K8S_VERSION 主版本匹配
export CLUSTER_AUTOSCALER_VERSION="${CLUSTER_AUTOSCALER_VERSION:-v1.34.2}"

# AWS Load Balancer Controller
export ALB_CONTROLLER_VERSION="${ALB_CONTROLLER_VERSION:-v2.13.0}"
export ALB_CONTROLLER_CHART_VERSION="${ALB_CONTROLLER_CHART_VERSION:-1.16.0}"

# Karpenter
export KARPENTER_VERSION="${KARPENTER_VERSION:-1.8.3}"

# CSI Drivers
export EFS_CSI_VERSION="${EFS_CSI_VERSION:-v2.2.0}"
export FSX_CSI_VERSION="${FSX_CSI_VERSION:-v1.7.0}"
export S3_CSI_VERSION="${S3_CSI_VERSION:-v2.2.2}"

# Metrics Server
export METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"

# 6. 自动推导 AZ（基于子网 ID 模式，支持3-4个AZ）
if [ -z "$AZ_A" ] || [ -z "$AZ_B" ] || [ -z "$AZ_C" ]; then
    log "Availability zones not set, deriving from region..."
    export AZ_A="${AWS_REGION}a"
    export AZ_B="${AWS_REGION}b"
    export AZ_C="${AWS_REGION}c"
fi

# 检测是否使用第4个AZ (如果定义了 PRIVATE_SUBNET_D 或 PUBLIC_SUBNET_D)
if [ -n "$PRIVATE_SUBNET_D" ] || [ -n "$PUBLIC_SUBNET_D" ]; then
    log "Detected 4th availability zone configuration"
    if [ -z "$AZ_D" ]; then
        export AZ_D="${AWS_REGION}d"
    fi
    export USE_4_AZS=true
else
    export USE_4_AZS=false
fi

# 7. 验证配置
log "Validating configuration..."

# 验证 AWS 凭证
aws sts get-caller-identity >/dev/null 2>&1 || \
    error "AWS credentials not configured. Please run 'aws configure' or set AWS credentials."

log "Configuration validation completed successfully!"

# 8. 系统节点组配置（高级选项）
# 注意: 默认使用 x86_64 架构实例，与 6_create_system_nodegroup.sh 中的 AMI 查询一致
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
if [[ ! "$SYSTEM_NODE_INSTANCE_TYPE" =~ ^[a-z][0-9]+[a-z]*\.[a-z0-9]+$ ]]; then
    echo "⚠ WARNING: Invalid SYSTEM_NODE_INSTANCE_TYPE format, using default: m7i.2xlarge"
    export SYSTEM_NODE_INSTANCE_TYPE="m7i.2xlarge"
fi

if [ "$SYSTEM_NODE_DATA_VOLUME_SIZE" -lt 50 ]; then
    echo "⚠ WARNING: SYSTEM_NODE_DATA_VOLUME_SIZE too small, using minimum: 50GB"
    export SYSTEM_NODE_DATA_VOLUME_SIZE=50
fi

# 9. 可选组件配置（默认值）
normalize_bool() {
    local val="${1,,}"  # 转换为小写
    case "$val" in
        true|1|yes|y) echo "true" ;;
        *) echo "false" ;;
    esac
}

# Storage (gp3/io2 always installed, only IOPS is configurable)
export IO2_IOPS="${IO2_IOPS:-10000}"

# Auto-scaling
export INSTALL_KARPENTER=$(normalize_bool "${INSTALL_KARPENTER:-false}")
export KARPENTER_VERSION="${KARPENTER_VERSION:-1.8.3}"

# File Systems (Optional)
export INSTALL_EFS_CSI=$(normalize_bool "${INSTALL_EFS_CSI:-false}")
export INSTALL_FSX_CSI=$(normalize_bool "${INSTALL_FSX_CSI:-false}")

# 验证 IO2 IOPS 范围
if [ "$IO2_IOPS" -lt 100 ] || [ "$IO2_IOPS" -gt 64000 ]; then
    echo "⚠ WARNING: IO2_IOPS out of range (100-64000), using default: 10000"
    export IO2_IOPS=10000
fi

# 10. 显示配置摘要
log "=== Configuration Summary ==="
echo "ACCOUNT_ID: $ACCOUNT_ID"
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "K8S_VERSION: $K8S_VERSION"
echo "VPC_ID: $VPC_ID"

if [ "$USE_4_AZS" = "true" ]; then
    echo "AZ: $AZ_A, $AZ_B, $AZ_C, $AZ_D (4 Availability Zones)"
    echo "PRIVATE_SUBNETS: $PRIVATE_SUBNET_A, $PRIVATE_SUBNET_B, $PRIVATE_SUBNET_C, $PRIVATE_SUBNET_D"
    echo "PUBLIC_SUBNETS: $PUBLIC_SUBNET_A, $PUBLIC_SUBNET_B, $PUBLIC_SUBNET_C, $PUBLIC_SUBNET_D"
else
    echo "AZ: $AZ_A, $AZ_B, $AZ_C (3 Availability Zones)"
    echo "PRIVATE_SUBNETS: $PRIVATE_SUBNET_A, $PRIVATE_SUBNET_B, $PRIVATE_SUBNET_C"
    echo "PUBLIC_SUBNETS: $PUBLIC_SUBNET_A, $PUBLIC_SUBNET_B, $PUBLIC_SUBNET_C"
fi
echo "SYSTEM_NODE_INSTANCE_TYPE: $SYSTEM_NODE_INSTANCE_TYPE"
echo "SYSTEM_NODE_DATA_VOLUME_SIZE: ${SYSTEM_NODE_DATA_VOLUME_SIZE}GB"
echo "SYSTEM_NODE_LABEL: ${SYSTEM_NODE_LABEL_KEY}=${SYSTEM_NODE_LABEL_VALUE}"
echo ""
echo "Storage Configuration:"
echo "  - gp3 StorageClass: Always installed (default)"
echo "  - io2 StorageClass: Always installed (${IO2_IOPS} IOPS)"
echo ""
echo "Optional Components:"
echo "  - Karpenter: $INSTALL_KARPENTER $([ "$INSTALL_KARPENTER" = "true" ] && echo "(v${KARPENTER_VERSION})" || echo "")"
echo "  - EFS CSI: $INSTALL_EFS_CSI"
echo "  - FSx CSI: $INSTALL_FSX_CSI"
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

# ============================================
# Resource Validation Functions
# ============================================

# Validate VPC exists
validate_vpc_exists() {
    local vpc_id="${1}"
    local region="${2:-${AWS_REGION}}"

    if [ -z "${vpc_id}" ]; then
        error "VPC ID is required"
    fi

    log "Validating VPC ${vpc_id}..."
    if ! aws ec2 describe-vpcs \
        --vpc-ids "${vpc_id}" \
        --region "${region}" \
        --query 'Vpcs[0].VpcId' \
        --output text &>/dev/null; then
        error "VPC '${vpc_id}' not found in region '${region}'"
    fi
    log "✓ VPC ${vpc_id} validated"
}

# Validate subnet exists and belongs to VPC
validate_subnet_exists() {
    local subnet_id="${1}"
    local expected_vpc_id="${2:-}"
    local region="${3:-${AWS_REGION}}"

    if [ -z "${subnet_id}" ]; then
        error "Subnet ID is required"
    fi

    log "Validating subnet ${subnet_id}..."
    local subnet_info
    subnet_info=$(aws ec2 describe-subnets \
        --subnet-ids "${subnet_id}" \
        --region "${region}" \
        --query 'Subnets[0].[SubnetId,VpcId,AvailabilityZone]' \
        --output text 2>/dev/null)

    if [ -z "${subnet_info}" ]; then
        error "Subnet '${subnet_id}' not found in region '${region}'"
    fi

    local actual_vpc_id=$(echo "${subnet_info}" | awk '{print $2}')
    local az=$(echo "${subnet_info}" | awk '{print $3}')

    if [ -n "${expected_vpc_id}" ] && [ "${actual_vpc_id}" != "${expected_vpc_id}" ]; then
        error "Subnet '${subnet_id}' belongs to VPC '${actual_vpc_id}', expected '${expected_vpc_id}'"
    fi

    log "✓ Subnet ${subnet_id} validated (VPC: ${actual_vpc_id}, AZ: ${az})"
}

# Validate multiple subnets
validate_subnets() {
    local subnet_list="${1}"
    local vpc_id="${2:-}"
    local region="${3:-${AWS_REGION}}"

    if [ -z "${subnet_list}" ]; then
        error "Subnet list is required"
    fi

    IFS=',' read -ra SUBNETS <<< "${subnet_list}"
    for subnet_id in "${SUBNETS[@]}"; do
        subnet_id=$(echo "${subnet_id}" | xargs)  # Trim whitespace
        validate_subnet_exists "${subnet_id}" "${vpc_id}" "${region}"
    done
}

# Validate AMI exists
validate_ami_exists() {
    local ami_id="${1}"
    local region="${2:-${AWS_REGION}}"

    if [ -z "${ami_id}" ]; then
        error "AMI ID is required"
    fi

    log "Validating AMI ${ami_id}..."
    local ami_info
    ami_info=$(aws ec2 describe-images \
        --image-ids "${ami_id}" \
        --region "${region}" \
        --query 'Images[0].[ImageId,State,Name]' \
        --output text 2>/dev/null)

    if [ -z "${ami_info}" ]; then
        error "AMI '${ami_id}' not found in region '${region}'"
    fi

    local ami_state=$(echo "${ami_info}" | awk '{print $2}')
    local ami_name=$(echo "${ami_info}" | awk '{$1=$2=""; print $0}' | xargs)

    if [ "${ami_state}" != "available" ]; then
        error "AMI '${ami_id}' is not available (state: ${ami_state})"
    fi

    log "✓ AMI ${ami_id} validated (${ami_name})"
}

# Validate security group exists
validate_security_group_exists() {
    local sg_id="${1}"
    local expected_vpc_id="${2:-}"
    local region="${3:-${AWS_REGION}}"

    if [ -z "${sg_id}" ]; then
        error "Security Group ID is required"
    fi

    log "Validating security group ${sg_id}..."
    local sg_info
    sg_info=$(aws ec2 describe-security-groups \
        --group-ids "${sg_id}" \
        --region "${region}" \
        --query 'SecurityGroups[0].[GroupId,VpcId,GroupName]' \
        --output text 2>/dev/null)

    if [ -z "${sg_info}" ]; then
        error "Security Group '${sg_id}' not found in region '${region}'"
    fi

    local actual_vpc_id=$(echo "${sg_info}" | awk '{print $2}')
    local sg_name=$(echo "${sg_info}" | awk '{print $3}')

    if [ -n "${expected_vpc_id}" ] && [ "${actual_vpc_id}" != "${expected_vpc_id}" ]; then
        error "Security Group '${sg_id}' belongs to VPC '${actual_vpc_id}', expected '${expected_vpc_id}'"
    fi

    log "✓ Security Group ${sg_id} validated (${sg_name}, VPC: ${actual_vpc_id})"
}

# Validate IAM role exists
validate_iam_role_exists() {
    local role_name="${1}"

    if [ -z "${role_name}" ]; then
        error "IAM role name is required"
    fi

    log "Validating IAM role ${role_name}..."
    if ! aws iam get-role \
        --role-name "${role_name}" \
        --query 'Role.RoleName' \
        --output text &>/dev/null; then
        error "IAM role '${role_name}' not found"
    fi

    log "✓ IAM role ${role_name} validated"
}

# Validate IAM instance profile exists
validate_instance_profile_exists() {
    local profile_name="${1}"

    if [ -z "${profile_name}" ]; then
        error "Instance profile name is required"
    fi

    log "Validating instance profile ${profile_name}..."
    if ! aws iam get-instance-profile \
        --instance-profile-name "${profile_name}" \
        --query 'InstanceProfile.InstanceProfileName' \
        --output text &>/dev/null; then
        error "Instance profile '${profile_name}' not found"
    fi

    log "✓ Instance profile ${profile_name} validated"
}

# Validate EKS cluster exists
validate_eks_cluster_exists() {
    local cluster_name="${1}"
    local region="${2:-${AWS_REGION}}"

    if [ -z "${cluster_name}" ]; then
        error "Cluster name is required"
    fi

    log "Validating EKS cluster ${cluster_name}..."
    local cluster_status
    cluster_status=$(aws eks describe-cluster \
        --name "${cluster_name}" \
        --region "${region}" \
        --query 'cluster.status' \
        --output text 2>/dev/null)

    if [ -z "${cluster_status}" ]; then
        error "EKS cluster '${cluster_name}' not found in region '${region}'"
    fi

    if [ "${cluster_status}" != "ACTIVE" ]; then
        warn "EKS cluster '${cluster_name}' is not ACTIVE (status: ${cluster_status})"
    fi

    log "✓ EKS cluster ${cluster_name} validated (status: ${cluster_status})"
}
