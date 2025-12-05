#!/bin/bash

# 设置环境变量
export ACCOUNT_ID=724772074726
export VPC_ID=vpc-0ba681f6f1a99f288
export AWS_REGION=us-east-2
export CLUSTER_NAME="eks-demo-2"
export K8S_VERSION="1.33"
export AWS_PARTITION="aws"
export AWS_DEFAULT_REGION="us-east-2"

# AZ环境变量
export AZ_2A=us-east-2a
export AZ_2B=us-east-2b
export AZ_2C=us-east-2c

# 子网环境变量
export PRIVATE_SUBNET_2A=subnet-0ac69f1e945b6390b
export PRIVATE_SUBNET_2B=subnet-09aacf835a895cb38
export PRIVATE_SUBNET_2C=subnet-0b6de0c1343e64bf9
export PUBLIC_SUBNET_2A=subnet-0d6943f15c74bc517
export PUBLIC_SUBNET_2B=subnet-0ad04d7ecf505b0d9
export PUBLIC_SUBNET_2C=subnet-05675ed3f1657c4d5

# 检查环境变量
echo "Environment variables:"
echo "ACCOUNT_ID: $ACCOUNT_ID"
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "K8S_VERSION: $K8S_VERSION"
echo "AWS_PARTITION: $AWS_PARTITION"
echo "AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
echo "VPC_ID: $VPC_ID"
