# =====================================================================
# Required: cluster + network identity
# =====================================================================

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. Must be unique in the AWS account."
}

variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC ID. This stack does not create a VPC."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (one per AZ; min 2, max 4). EKS control plane ENIs and worker nodes are placed here."
  validation {
    condition     = length(var.private_subnet_ids) >= 2 && length(var.private_subnet_ids) <= 4
    error_message = "private_subnet_ids must contain 2 to 4 subnet IDs."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs (used for internet-facing LBs only). Optional for fully-private clusters."
  default     = []
}

# =====================================================================
# Cluster control-plane behavior
# =====================================================================

variable "cluster_mode" {
  type        = string
  description = "API endpoint exposure: 'private' (recommended) or 'public'."
  default     = "private"
  validation {
    condition     = contains(["private", "public"], var.cluster_mode)
    error_message = "cluster_mode must be 'private' or 'public'."
  }
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDR ranges allowed to reach the public API endpoint. Only used when cluster_mode=public."
  default     = ["0.0.0.0/0"]
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes minor version (e.g. '1.35'). EKS picks the latest patch."
  default     = "1.35"
}

variable "service_ipv4_cidr" {
  type        = string
  description = "Kubernetes Service CIDR. Must not overlap the VPC CIDR."
  default     = "172.20.0.0/16"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for envelope-encrypting Kubernetes secrets at rest. Empty disables encryption (not recommended)."
  default     = ""
}

variable "enable_deletion_protection" {
  type        = bool
  description = "Block accidental cluster deletion via terraform destroy."
  default     = true
}

# =====================================================================
# VPC Endpoints
# =====================================================================

variable "vpc_endpoints_mode" {
  type        = string
  description = "'full' for all 13 Interface Endpoints + S3 Gateway (private cluster); 'minimal' for the 4 endpoints required for node bootstrap + S3 Gateway."
  default     = "full"
  validation {
    condition     = contains(["full", "minimal"], var.vpc_endpoints_mode)
    error_message = "vpc_endpoints_mode must be 'full' or 'minimal'."
  }
}

# =====================================================================
# System nodegroup
# =====================================================================

variable "system_node_instance_type" {
  type        = string
  description = "System nodegroup instance type. Architecture (arm64/x86_64) is auto-detected from the EC2 API."
  default     = "m8g.xlarge"
}

variable "system_node_root_volume_size" {
  type        = number
  description = "System nodegroup root EBS volume size in GiB."
  default     = 50
}

variable "system_node_data_volume_size" {
  type        = number
  description = "System nodegroup data (containerd LVM) EBS volume size in GiB."
  default     = 100
}

variable "system_node_desired_capacity" {
  type        = number
  default     = 3
  description = "System nodegroup desired node count."
}

variable "system_node_min_size" {
  type        = number
  default     = 3
  description = "System nodegroup min size."
}

variable "system_node_max_size" {
  type        = number
  default     = 6
  description = "System nodegroup max size."
}

variable "system_node_label_key" {
  type    = string
  default = "app"
}

variable "system_node_label_value" {
  type    = string
  default = "eks-utils"
}

variable "ec2_key_name" {
  type        = string
  description = "Optional EC2 key pair name for SSH access. Empty = SSM-only."
  default     = ""
}

# =====================================================================
# Component versions
# =====================================================================

variable "cluster_autoscaler_version" {
  type        = string
  description = "Cluster Autoscaler image tag. Major.minor must match k8s_version."
  default     = "v1.35.0"
}

variable "cluster_autoscaler_chart_version" {
  type        = string
  description = "kubernetes/autoscaler helm chart version (independent of image tag). Bump together with cluster_autoscaler_version when upgrading. 9.48+ ships v1.35.0 as the default image tag, matching our cluster version."
  default     = "9.48.0"
}

variable "alb_controller_chart_version" {
  type        = string
  description = "AWS Load Balancer Controller helm chart version. Must be paired with alb_controller_app_version (chart 1.14.x ↔ app v2.13.x; chart 1.16.x ↔ app v2.14.x)."
  default     = "1.16.0"
}

variable "alb_controller_app_version" {
  type        = string
  description = "AWS Load Balancer Controller image tag. Sourced from upstream release. The IAM policy fetched at apply time follows this tag exactly."
  default     = "v2.14.1"
}

variable "alb_controller_iam_policy_source" {
  type        = string
  description = "Where to source the AWS Load Balancer Controller IAM policy: 'http' fetches from the upstream release tag (matches alb_controller_app_version), 'file' uses the bundled manifests/iam/alb-controller-iam-policy.json. Use 'file' for air-gapped environments or when GitHub.com is blocked."
  default     = "http"
  validation {
    condition     = contains(["http", "file"], var.alb_controller_iam_policy_source)
    error_message = "alb_controller_iam_policy_source must be 'http' or 'file'."
  }
}

variable "karpenter_version" {
  type        = string
  default     = "1.10.0"
  description = "Karpenter helm chart version (matches app version)."
}

# =====================================================================
# CSI drivers
# =====================================================================

variable "install_efs_csi" {
  type    = bool
  default = false
}

variable "install_fsx_csi" {
  type    = bool
  default = false
}

variable "install_s3_csi" {
  type    = bool
  default = false
}

variable "s3_csi_bucket_arns" {
  type        = list(string)
  description = "S3 bucket ARNs the S3 CSI Driver may access. Supports both standard S3 and S3 Express One Zone ARNs."
  default     = []
}

# =====================================================================
# Optional: Karpenter
# =====================================================================

variable "install_karpenter" {
  type    = bool
  default = false
}

variable "karpenter_ssh_public_key" {
  type        = string
  description = "Optional SSH public key injected into Karpenter-provisioned nodes via userData."
  default     = ""
}

variable "helm_replace_existing" {
  type        = bool
  description = "Set helm_release.replace=true on every managed helm release (cluster-autoscaler, ALB controller, karpenter, karpenter-pools, nvidia-device-plugin). Only enable in dev/test — when true, an interrupted apply that left a stale release behind is auto-recovered, but in production this would silently take over a manually-managed release and is a footgun."
  default     = false
}

# =====================================================================
# GPU nodegroups
# =====================================================================

variable "install_gpu_nodegroups" {
  type    = bool
  default = false
}

variable "gpu_ami_release_version" {
  type        = string
  description = "EKS NVIDIA AL2023 AMI release tag, e.g. 'v20260512'. Empty = follow SSM 'recommended' (rolls forward). Pin a specific release to keep the GPU runtime stack reproducible. See docs/AMI_VERSIONS.md for verified combinations."
  default     = ""
}

variable "gpu_nodegroups" {
  type = list(object({
    gpu_type                = string                   # e.g. p5.48xlarge
    purchase_option         = string                   # od | spot | odcr | cb
    suffix                  = optional(string, "")     # disambiguates multiple NGs of same (type, purchase)
    subnet_ids              = optional(list(string))   # default: all private subnets
    capacity_reservation_id = optional(string)         # required for odcr / cb
    placement_group         = optional(string, "none") # none | cluster
    desired_capacity        = optional(number, 0)
    min_size                = optional(number, 0)
    max_size                = optional(number, 8)
  }))
  description = "Explicit list of GPU nodegroups to create. Replaces the bash DEPLOY_GPU_OD/SPOT/ODCR/CB toggles with declarative entries."
  default     = []
}

variable "gpu_node_root_volume_size" {
  type    = number
  default = 50
}

variable "gpu_node_data_volume_size" {
  type    = number
  default = 100
}

variable "gpu_install_efa_userspace" {
  type        = bool
  description = "Install full EFA userspace (libfabric-aws + openmpi5-aws) on GPU nodes via userdata. The EKS GPU AMI ships only kernel-side EFA."
  default     = true
}

variable "gpu_enable_local_lvm" {
  type        = bool
  description = "Stripe Instance Store NVMe disks into a local LVM volume mounted at gpu_local_lvm_mount."
  default     = true
}

variable "gpu_local_lvm_mount" {
  type    = string
  default = "/data"
}

variable "gpu_local_lvm_fs" {
  type    = string
  default = "xfs"
}

# NVIDIA + EFA device plugin
variable "nvidia_device_plugin_version" {
  type    = string
  default = "v0.19.1"
}

variable "nvidia_device_plugin_repo" {
  type        = string
  default     = "nvcr.io/nvidia/k8s-device-plugin"
  description = "Override for regions where nvcr.io is unreachable (cn-*)."
}

variable "efa_device_plugin_version" {
  type    = string
  default = "v0.5.18"
}

variable "efa_device_plugin_image" {
  type        = string
  description = "Full image override for the AWS EFA k8s device plugin (e.g. private mirror in cn-* regions). Empty falls back to the public ECR image map."
  default     = ""
}

# =====================================================================
# Tagging
# =====================================================================

variable "default_tags" {
  type    = map(string)
  default = {}
}
