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
