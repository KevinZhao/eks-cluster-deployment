output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_issuer_url" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "cluster_role_arn" {
  value = aws_iam_role.cluster.arn
}

output "service_ipv4_cidr" {
  value = aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
}

output "k8s_version" {
  value = aws_eks_cluster.this.version
}
