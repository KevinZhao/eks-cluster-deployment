# VPC Endpoints for Private EKS Cluster
# This configuration creates all necessary VPC endpoints for a fully private EKS cluster

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Variables
variable "vpc_id" {
  description = "VPC ID where endpoints will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for interface endpoints"
  type        = list(string)
}

variable "private_route_table_ids" {
  description = "List of private route table IDs for gateway endpoints"
  type        = list(string)
}

variable "cluster_name" {
  description = "EKS cluster name (for tagging)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

# Security Group for VPC Endpoints
resource "aws_security_group" "vpc_endpoints" {
  name_description = "${var.cluster_name}-vpc-endpoints-sg"
  description = "Security group for VPC endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-vpc-endpoints-sg"
    Cluster = var.cluster_name
  }
}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

# Interface VPC Endpoints
locals {
  interface_endpoints = {
    # Core EKS
    eks = {
      service_name        = "com.amazonaws.${var.region}.eks"
      private_dns_enabled = true
    }
    eks-auth = {
      service_name        = "com.amazonaws.${var.region}.eks-auth"
      private_dns_enabled = true
    }

    # IAM
    sts = {
      service_name        = "com.amazonaws.${var.region}.sts"
      private_dns_enabled = true
    }

    # ECR
    ecr-api = {
      service_name        = "com.amazonaws.${var.region}.ecr.api"
      private_dns_enabled = true
    }
    ecr-dkr = {
      service_name        = "com.amazonaws.${var.region}.ecr.dkr"
      private_dns_enabled = true
    }

    # CloudWatch
    logs = {
      service_name        = "com.amazonaws.${var.region}.logs"
      private_dns_enabled = true
    }

    # EC2 (for EBS CSI and node management)
    ec2 = {
      service_name        = "com.amazonaws.${var.region}.ec2"
      private_dns_enabled = true
    }

    # Auto Scaling (for Cluster Autoscaler)
    autoscaling = {
      service_name        = "com.amazonaws.${var.region}.autoscaling"
      private_dns_enabled = true
    }

    # ELB (for AWS Load Balancer Controller)
    elasticloadbalancing = {
      service_name        = "com.amazonaws.${var.region}.elasticloadbalancing"
      private_dns_enabled = true
    }

    # EFS (for EFS CSI Driver)
    elasticfilesystem = {
      service_name        = "com.amazonaws.${var.region}.elasticfilesystem"
      private_dns_enabled = true
    }

    # SSM (optional but recommended)
    ssm = {
      service_name        = "com.amazonaws.${var.region}.ssm"
      private_dns_enabled = true
    }
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = var.vpc_id
  service_name        = each.value.service_name
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = each.value.private_dns_enabled

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name    = "${var.cluster_name}-${each.key}-endpoint"
    Cluster = var.cluster_name
  }
}

# S3 Gateway Endpoint (required for ECR and S3 CSI)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = {
    Name    = "${var.cluster_name}-s3-gateway-endpoint"
    Cluster = var.cluster_name
  }
}

# Outputs
output "interface_endpoint_ids" {
  description = "Map of interface endpoint names to IDs"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint ID"
  value       = aws_vpc_endpoint.s3.id
}

output "vpc_endpoints_security_group_id" {
  description = "Security group ID for VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}
