# Launch Template Outputs
output "launch_template_id" {
  description = "Launch template ID"
  value       = aws_launch_template.app_nodegroup.id
}

output "launch_template_arn" {
  description = "Launch template ARN"
  value       = aws_launch_template.app_nodegroup.arn
}

output "launch_template_latest_version" {
  description = "Latest version of the launch template"
  value       = aws_launch_template.app_nodegroup.latest_version
}

output "launch_template_name" {
  description = "Launch template name"
  value       = aws_launch_template.app_nodegroup.name
}

# IAM Outputs
output "node_role_arn" {
  description = "IAM role ARN for app nodegroup"
  value       = aws_iam_role.app_nodegroup.arn
}

output "node_role_name" {
  description = "IAM role name for app nodegroup"
  value       = aws_iam_role.app_nodegroup.name
}

output "instance_profile_arn" {
  description = "Instance profile ARN"
  value       = aws_iam_instance_profile.app_nodegroup.arn
}

# Security Group Outputs
output "security_group_id" {
  description = "Security group ID for app nodegroup"
  value       = aws_security_group.app_nodegroup.id
}

# AMI Outputs
output "ami_id" {
  description = "EKS optimized AMI ID used for nodes"
  value       = data.aws_ssm_parameter.eks_ami_arm64.value
}

# Summary for eksctl nodegroup config
output "eksctl_config_summary" {
  description = "Summary for eksctl nodegroup configuration"
  value = <<-EOT
    Launch Template ID: ${aws_launch_template.app_nodegroup.id}
    Launch Template Name: ${aws_launch_template.app_nodegroup.name}
    Launch Template Version: ${aws_launch_template.app_nodegroup.latest_version}
    IAM Role ARN: ${aws_iam_role.app_nodegroup.arn}
    Security Group ID: ${aws_security_group.app_nodegroup.id}

    Use this in your eksctl nodegroup config:
    launchTemplate:
      id: ${aws_launch_template.app_nodegroup.id}
      version: "${aws_launch_template.app_nodegroup.latest_version}"
  EOT
}
