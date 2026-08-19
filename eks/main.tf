terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    kubectl = {
      # Not hashicorp/kubernetes's own kubernetes_manifest: that resource
      # needs to fetch the target CRD's schema from the live cluster at PLAN
      # time, which fails on a truly fresh cluster where ArgoCD's Application
      # CRD doesn't exist yet when Terraform plans. kubectl_manifest applies
      # like `kubectl apply` (apply-time, not plan-time), so CRD + CR in the
      # same apply works.
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
  }

  backend "s3" {
    bucket         = "amir-demo-terraform-eks-state-bucket"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-eks-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}

# `name` alone (module.eks.cluster_name) is just a plain string known at plan
# time, so without depends_on Terraform would try to read this data source
# during plan/refresh - before the cluster exists on a first apply. depends_on
# forces it to defer to apply-time, after module.eks (cluster + node group)
# has actually finished.
data "aws_eks_cluster_auth" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
  apply_retry_count      = 5
}

# module.eks only finishes once aws_eks_node_group.main is ACTIVE (nodes
# registered and healthy per AWS's own checks), so this is a real readiness
# gate, not cosmetic - the extra 30s is a defensive buffer for CoreDNS/
# kube-proxy to settle before anything tries to schedule pods via Helm.
resource "time_sleep" "wait_for_cluster" {
  depends_on      = [module.eks]
  create_duration = "30s"
}

module "vpc" {
  source = "./modules/vpc"

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  cluster_name         = var.cluster_name
}

# NOTE on destroy ordering (no explicit depends_on needed here): the ALB
# cleanup null_resource in addons.tf depends on module.eks, which already
# depends on module.vpc via vpc_id/subnet_ids above. That transitive chain
# alone guarantees Terraform destroys in the order: null_resource (runs the
# ALB cleanup) -> module.eks -> module.vpc, last. Adding an explicit
# depends_on from module.vpc to the null_resource would create a cycle
# (vpc -> null_resource -> eks -> vpc), since the null_resource already
# depends on module.eks which depends on module.vpc. See
# null_resource.cleanup_alb_before_vpc_destroy in addons.tf.

module "eks" {
  source = "./modules/eks"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids
  node_groups     = var.node_groups
}