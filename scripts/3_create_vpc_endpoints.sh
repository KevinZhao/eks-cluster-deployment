#!/bin/bash
#
# Create VPC Endpoints for Private EKS Cluster
# This script creates all necessary VPC endpoints using AWS CLI
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/0_setup_env.sh"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Creating VPC Endpoints for Private EKS${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Validate required variables
required_vars=(
    "VPC_ID"
    "PRIVATE_SUBNET_A"
    "PRIVATE_SUBNET_B"
    "PRIVATE_SUBNET_C"
    "AWS_REGION"
    "CLUSTER_NAME"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: ${var} is not set${NC}"
        exit 1
    fi
done

# Get VPC CIDR
VPC_CIDR=$(aws ec2 describe-vpcs \
    --vpc-ids "${VPC_ID}" \
    --query 'Vpcs[0].CidrBlock' \
    --output text)

echo "VPC ID: ${VPC_ID}"
echo "VPC CIDR: ${VPC_CIDR}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo ""

# Create security group for VPC endpoints
echo -e "${YELLOW}Creating security group for VPC endpoints...${NC}"
SG_ID=$(aws ec2 create-security-group \
    --group-name "${CLUSTER_NAME}-vpc-endpoints-sg" \
    --description "Security group for VPC endpoints" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${CLUSTER_NAME}-vpc-endpoints-sg" "Name=vpc-id,Values=${VPC_ID}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

echo "Security Group ID: ${SG_ID}"

# Add ingress rule for HTTPS from VPC
aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp \
    --port 443 \
    --cidr "${VPC_CIDR}" \
    --no-cli-pager 2>/dev/null || echo "Ingress rule already exists"

# Tag security group
aws ec2 create-tags \
    --resources "${SG_ID}" \
    --tags "Key=Name,Value=${CLUSTER_NAME}-vpc-endpoints-sg" \
           "Key=Cluster,Value=${CLUSTER_NAME}" \
    --no-cli-pager 2>/dev/null || true

echo -e "${GREEN}✓ Security group created${NC}"
echo ""

# Define subnet IDs
SUBNET_IDS="${PRIVATE_SUBNET_A} ${PRIVATE_SUBNET_B} ${PRIVATE_SUBNET_C}"

# Define interface endpoints
declare -a INTERFACE_ENDPOINTS=(
    "eks:EKS API"
    "eks-auth:EKS Auth (Pod Identity)"
    "sts:STS (Pod Identity)"
    "ecr.api:ECR API"
    "ecr.dkr:ECR Docker"
    "logs:CloudWatch Logs"
    "ec2:EC2 + EBS CSI"
    "autoscaling:Cluster Autoscaler"
    "elasticloadbalancing:AWS LB Controller"
    "elasticfilesystem:EFS CSI Driver"
    "ssm:Systems Manager Session Manager"
    "ssmmessages:Session Manager Messages"
    "ec2messages:EC2 Messages for SSM"
)

# Create interface endpoints
echo -e "${YELLOW}Creating interface endpoints...${NC}"
for endpoint_info in "${INTERFACE_ENDPOINTS[@]}"; do
    IFS=':' read -r service description <<< "${endpoint_info}"
    service_name="com.amazonaws.${AWS_REGION}.${service}"

    echo -n "Creating ${description} endpoint (${service})... "

    # Check if endpoint already exists
    EXISTING_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" \
        --query 'VpcEndpoints[0].VpcEndpointId' \
        --output text 2>/dev/null)

    if [ "${EXISTING_ENDPOINT}" != "None" ] && [ -n "${EXISTING_ENDPOINT}" ]; then
        echo -e "${YELLOW}already exists (${EXISTING_ENDPOINT})${NC}"
        continue
    fi

    # Create endpoint
    ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
        --vpc-id "${VPC_ID}" \
        --service-name "${service_name}" \
        --vpc-endpoint-type Interface \
        --subnet-ids ${SUBNET_IDS} \
        --security-group-ids "${SG_ID}" \
        --private-dns-enabled \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${CLUSTER_NAME}-${service}-endpoint},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text 2>/dev/null)

    if [ -n "${ENDPOINT_ID}" ]; then
        echo -e "${GREEN}✓ created (${ENDPOINT_ID})${NC}"
    else
        echo -e "${RED}✗ failed${NC}"
    fi
done

echo ""

# Get private route table IDs
echo -e "${YELLOW}Getting private route table IDs...${NC}"
ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=association.subnet-id,Values=${PRIVATE_SUBNET_A},${PRIVATE_SUBNET_B},${PRIVATE_SUBNET_C}" \
    --query 'RouteTables[*].RouteTableId' \
    --output text)

echo "Route Table IDs: ${ROUTE_TABLE_IDS}"
echo ""

# Create S3 gateway endpoint
echo -n "Creating S3 Gateway Endpoint... "
service_name="com.amazonaws.${AWS_REGION}.s3"

# Check if S3 endpoint already exists
EXISTING_S3_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" \
    --query 'VpcEndpoints[0].VpcEndpointId' \
    --output text 2>/dev/null)

if [ "${EXISTING_S3_ENDPOINT}" != "None" ] && [ -n "${EXISTING_S3_ENDPOINT}" ]; then
    echo -e "${YELLOW}already exists (${EXISTING_S3_ENDPOINT})${NC}"
else
    S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
        --vpc-id "${VPC_ID}" \
        --service-name "${service_name}" \
        --vpc-endpoint-type Gateway \
        --route-table-ids ${ROUTE_TABLE_IDS} \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${CLUSTER_NAME}-s3-gateway-endpoint},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text 2>/dev/null)

    if [ -n "${S3_ENDPOINT_ID}" ]; then
        echo -e "${GREEN}✓ created (${S3_ENDPOINT_ID})${NC}"
    else
        echo -e "${RED}✗ failed${NC}"
    fi
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}VPC Endpoints Creation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# List all endpoints
echo "Created VPC Endpoints:"
aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
    --query 'VpcEndpoints[*].[VpcEndpointType,ServiceName,State,VpcEndpointId]' \
    --output table

echo ""
echo -e "${YELLOW}Note: It may take a few minutes for endpoints to become available.${NC}"
echo -e "${YELLOW}Monthly cost estimate: ~\$93-97 for 13 interface endpoints (includes SSM endpoints for Session Manager)${NC}"
