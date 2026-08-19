# Everything scripts/bootstrap-eks.sh used to do by hand after `terraform
# apply`, now folded into the same apply. bootstrap-eks.sh is left in place as
# a manual fallback/reference but is redundant for the EKS path from here on.

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "8.0.9"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600

  depends_on = [time_sleep.wait_for_cluster]
}

# Same chart/repo bootstrap-eks.sh already used - zero behavior change, just
# installed by Terraform instead of the `helm` CLI. serviceAccount.create=true
# with the IRSA role annotation means Helm owns the ServiceAccount's full
# lifecycle - no eksctl pre-create step, so the stale-CFN-stack class of bug
# that broke this in production this session can't happen here: the role and
# the chart that references it live in the same Terraform state as the
# cluster and are destroyed/recreated together, always matched.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"
  namespace  = "kube-system"
  timeout    = 300

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.lb_controller_role_arn
  }

  depends_on = [time_sleep.wait_for_cluster]
}

resource "kubernetes_namespace" "opentelemetry_demo" {
  metadata {
    name = "opentelemetry-demo"
  }

  depends_on = [time_sleep.wait_for_cluster]
}

# Unlike bootstrap-eks.sh (where the PAT never touches anything Terraform
# reads/writes), this secret's value lives in the Terraform state file - in
# the private, encrypted S3 backend bucket already used for this project's
# state. Accepted trade-off for a portfolio project; var.ghcr_pat has no
# default, so apply fails loudly rather than silently deploying without a
# working pull secret if TF_VAR_ghcr_pat isn't set.
resource "kubernetes_secret" "ghcr_pull" {
  metadata {
    name      = "ghcr-pull-secret"
    namespace = kubernetes_namespace.opentelemetry_demo.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = var.ghcr_username
          password = var.ghcr_pat
          auth     = base64encode("${var.ghcr_username}:${var.ghcr_pat}")
        }
      }
    })
  }
}

# Mirrors opentelemetry-demo-gitops/argocd-application-eks.yaml. Uses
# kubectl_manifest (not kubernetes_manifest) specifically because the
# Application CRD comes from helm_release.argocd in this SAME apply -
# kubernetes_manifest would need that CRD's schema at plan time, which
# doesn't exist yet on a fresh cluster; kubectl_manifest applies at apply
# time like `kubectl apply`, so CRD-then-CR in one apply works.
resource "kubectl_manifest" "argocd_application" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "opentelemetry-demo"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "main"
        path           = "helm/opentelemetry-demo"
        helm = {
          valueFiles = ["values.yaml", "values-eks.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "opentelemetry-demo"
      }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  })

  depends_on = [helm_release.argocd, kubernetes_secret.ghcr_pull]
}

# Fixes the orphaned-ALB `terraform destroy` failure hit this session: the
# AWS Load Balancer Controller creates a real ALB directly against AWS,
# outside Terraform's knowledge. Without this, destroying the cluster before
# that ALB is gone leaves its ENIs stuck in the subnets, blocking IGW/subnet
# deletion (exactly what happened: had to manually `aws elbv2
# delete-load-balancer` to unblock it). depends_on ensures this runs (on
# destroy) after the app/Ingress but transitively before module.vpc - see the
# note in main.tf next to module.vpc. Every step is best-effort (`|| true`):
# a flaky cleanup step must never block the rest of destroy.
resource "null_resource" "cleanup_alb_before_vpc_destroy" {
  depends_on = [kubectl_manifest.argocd_application, module.eks]

  triggers = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} || true
      kubectl delete ingress --all -A --wait --timeout=90s || true
      for i in $(seq 1 12); do
        ALB=$(aws elbv2 describe-load-balancers --region ${self.triggers.region} \
          --query "LoadBalancers[?contains(DNSName, 'k8s-')].LoadBalancerArn" --output text)
        [ -z "$ALB" ] && break
        for arn in $ALB; do
          aws elbv2 delete-load-balancer --region ${self.triggers.region} --load-balancer-arn "$arn" || true
        done
        sleep 10
      done
    EOT
  }
}
