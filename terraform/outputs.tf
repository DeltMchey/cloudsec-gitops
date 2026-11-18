output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint (known only after the explicitly authorized W9 apply)."
  value       = module.eks.cluster_endpoint
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs across the two supplied AZs."
  value       = module.network.public_subnet_ids
}

output "node_group_name" {
  description = "Minimal managed node-group name."
  value       = module.eks.node_group_name
}
