variable "cluster_name" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type    = list(string)
  default = []
}

variable "cluster_mode" {
  type        = string
  description = "'private' or 'public'."
}

variable "public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "service_ipv4_cidr" {
  type = string
}

variable "kms_key_arn" {
  type    = string
  default = ""
}

variable "enable_deletion_protection" {
  type    = bool
  default = true
}

variable "enabled_cluster_log_types" {
  type    = list(string)
  default = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "enable_irsa" {
  type        = bool
  description = "Create the legacy IAM OIDC provider for IRSA. Default false: this stack uses Pod Identity for every managed component (Karpenter, Cluster Autoscaler, ALB Controller, every CSI driver), which is the AWS-recommended path since 2023-11. Mirrors the bash flow's `withOIDC: false`. Enable only if external workloads need to verify JWTs against the cluster's OIDC issuer (e.g. GitHub Actions OIDC federation, cross-account IRSA). NOTE: in private clusters with the eks VPC interface endpoint, the endpoint's private hosted zone shadows oidc.eks.<region>.amazonaws.com and breaks the issuer fetch — operators that opt in must arrange DNS for that subdomain themselves (per-host /etc/hosts pin or systemd-resolved per-domain forward to public DNS)."
  default     = false
}
