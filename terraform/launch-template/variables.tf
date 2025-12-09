# AWS Region
variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "ap-southeast-1"
}

# Cluster Configuration
variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "vpc_id" {
  description = "VPC ID where the cluster is deployed"
  type        = string
}

# Instance Configuration
variable "instance_type" {
  description = "EC2 instance type for app nodes"
  type        = string
  default     = "c8g.large"
}

variable "key_name" {
  description = "EC2 SSH key pair name for accessing nodes"
  type        = string
  default     = ""
}

# Root Volume Configuration
variable "root_volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root volume type (gp3, gp2, io1, io2)"
  type        = string
  default     = "gp3"
}

variable "root_volume_iops" {
  description = "Root volume IOPS (only for gp3, io1, io2)"
  type        = number
  default     = 3000
}

variable "root_volume_throughput" {
  description = "Root volume throughput in MB/s (only for gp3)"
  type        = number
  default     = 125
}

# Data Volume Configuration
variable "data_volume_size" {
  description = "Data volume size in GB (set to 0 to disable)"
  type        = number
  default     = 100
}

variable "data_volume_type" {
  description = "Data volume type (gp3, gp2, io1, io2)"
  type        = string
  default     = "gp3"
}

variable "data_volume_iops" {
  description = "Data volume IOPS (only for gp3, io1, io2)"
  type        = number
  default     = 3000
}

variable "data_volume_throughput" {
  description = "Data volume throughput in MB/s (only for gp3)"
  type        = number
  default     = 125
}

# Monitoring
variable "enable_monitoring" {
  description = "Enable detailed CloudWatch monitoring"
  type        = bool
  default     = false
}

# Custom User Data
variable "custom_userdata" {
  description = "Custom user data script to run on node startup"
  type        = string
  default     = ""
}

# Common Tags
variable "common_tags" {
  description = "Common tags to be applied to all resources"
  type        = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
    Project     = "eks-cluster"
  }
}
