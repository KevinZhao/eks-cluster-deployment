# Provider Configuration
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data: Get EKS cluster info
data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

# Data: Get the latest EKS optimized AMI for ARM64 (Graviton) - AL2023
data "aws_ssm_parameter" "eks_ami_arm64" {
  name = "/aws/service/eks/optimized-ami/${var.k8s_version}/amazon-linux-2023/arm64/standard/recommended/image_id"
}

# Security Group for app nodegroup
resource "aws_security_group" "app_nodegroup" {
  name_prefix = "${var.cluster_name}-app-nodegroup-"
  description = "Security group for app nodegroup with custom rules"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.common_tags,
    {
      Name                                        = "${var.cluster_name}-app-nodegroup-sg"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  )
}

# Security group rule: Allow cluster control plane to communicate with nodes
resource "aws_security_group_rule" "app_ingress_cluster" {
  description              = "Allow cluster control plane to communicate with nodes"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = data.aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
  security_group_id        = aws_security_group.app_nodegroup.id
}

# Security group rule: Allow nodes to communicate with each other
resource "aws_security_group_rule" "app_ingress_self" {
  description       = "Allow nodes to communicate with each other"
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.app_nodegroup.id
}

# IAM Role for app nodegroup
resource "aws_iam_role" "app_nodegroup" {
  name_prefix = "${var.cluster_name}-app-nodegroup-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.common_tags,
    {
      Name = "${var.cluster_name}-app-nodegroup-role"
    }
  )
}

# Attach required policies to IAM role
resource "aws_iam_role_policy_attachment" "app_nodegroup_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.app_nodegroup.name
}

resource "aws_iam_role_policy_attachment" "app_nodegroup_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.app_nodegroup.name
}

resource "aws_iam_role_policy_attachment" "app_nodegroup_registry" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.app_nodegroup.name
}

resource "aws_iam_role_policy_attachment" "app_nodegroup_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.app_nodegroup.name
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "app_nodegroup" {
  name_prefix = "${var.cluster_name}-app-nodegroup-"
  role        = aws_iam_role.app_nodegroup.name

  tags = merge(
    var.common_tags,
    {
      Name = "${var.cluster_name}-app-nodegroup-profile"
    }
  )
}

# User data script for EKS nodes
locals {
  userdata = <<-EOT
    #!/bin/bash
    set -o xtrace

    # Bootstrap the node
    /etc/eks/bootstrap.sh '${var.cluster_name}' \
      --b64-cluster-ca '${data.aws_eks_cluster.cluster.certificate_authority[0].data}' \
      --apiserver-endpoint '${data.aws_eks_cluster.cluster.endpoint}' \
      --kubelet-extra-args '--node-labels=app=application,arch=arm64,workload=user-apps --register-with-taints=workload=user-apps:NoSchedule'

    # Run custom user data if provided
    ${var.custom_userdata}
  EOT
}

# Launch Template with data disk
resource "aws_launch_template" "app_nodegroup" {
  name_prefix = "${var.cluster_name}-app-nodegroup-"
  description = "Launch template for app nodegroup with custom configuration"

  image_id      = data.aws_ssm_parameter.eks_ami_arm64.value
  instance_type = var.instance_type
  key_name      = var.key_name

  iam_instance_profile {
    arn = aws_iam_instance_profile.app_nodegroup.arn
  }

  vpc_security_group_ids = [
    aws_security_group.app_nodegroup.id,
    data.aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
  ]

  # Root volume (system disk)
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = var.root_volume_type
      iops                  = var.root_volume_type == "gp3" ? var.root_volume_iops : null
      throughput            = var.root_volume_type == "gp3" ? var.root_volume_throughput : null
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Additional data disk (optional)
  dynamic "block_device_mappings" {
    for_each = var.data_volume_size > 0 ? [1] : []
    content {
      device_name = "/dev/xvdb"

      ebs {
        volume_size           = var.data_volume_size
        volume_type           = var.data_volume_type
        iops                  = var.data_volume_type == "gp3" ? var.data_volume_iops : null
        throughput            = var.data_volume_type == "gp3" ? var.data_volume_throughput : null
        encrypted             = true
        delete_on_termination = true
      }
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = var.enable_monitoring
  }

  user_data = base64encode(local.userdata)

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      var.common_tags,
      {
        Name                                        = "${var.cluster_name}-app-node"
        "kubernetes.io/cluster/${var.cluster_name}" = "owned"
        "k8s.io/cluster-autoscaler/enabled"         = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(
      var.common_tags,
      {
        Name = "${var.cluster_name}-app-node-volume"
      }
    )
  }

  tags = merge(
    var.common_tags,
    {
      Name = "${var.cluster_name}-app-nodegroup-lt"
    }
  )
}
