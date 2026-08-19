output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate, for configuring the kubernetes/helm providers"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "EKS cluster OIDC issuer URL"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC identity provider associated with this cluster"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "lb_controller_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller's IRSA service account"
  value       = aws_iam_role.lb_controller.arn
}