output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes minor version."
  value       = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "Security group ID created for the EKS control plane."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Shared security group ID for EKS managed nodes."
  value       = module.eks.node_security_group_id
}

output "managed_node_group_autoscaling_group_names" {
  description = "Auto Scaling group names behind the EKS managed node group."
  value       = module.eks.eks_managed_node_groups_autoscaling_group_names
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN retained for workloads that still require IRSA."
  value       = module.eks.oidc_provider_arn
}

output "eks_kms_key_arn" {
  description = "KMS key used for Kubernetes secrets and EKS control-plane logs."
  value       = aws_kms_key.eks.arn
}

output "kubectl_update_command" {
  description = "Command to merge this cluster into kubeconfig. It must run from a network path that can reach the private API endpoint."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
