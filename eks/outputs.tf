output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "lb_controller_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller's IRSA service account"
  value       = module.eks.lb_controller_role_arn
}

output "argocd_admin_password_command" {
  description = "Command to fetch the ArgoCD initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}