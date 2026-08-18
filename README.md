# opentelemetry-aws-infra

Terraform for the AWS infrastructure behind the [OpenTelemetry demo GitOps project](https://github.com/AmirWeiser/opentelemetry-demo-gitops) — a VPC and an EKS cluster, provisioned the same way every time.

This is one of three repositories that make up the full project:

| Repo | Role |
|---|---|
| **opentelemetry-aws-infra** (this repo) | The infrastructure the app runs on |
| [opentelemetry-demo-gitops](https://github.com/AmirWeiser/opentelemetry-demo-gitops) | The Helm chart ArgoCD deploys |
| [opentelemetry-demo-src](https://github.com/AmirWeiser/opentelemetry-demo-src) | Application source + CI pipeline |

## What it provisions

```
eks/
├── main.tf              # wires the vpc and eks modules together
├── variables.tf         # region, CIDRs, cluster version, node group sizing
├── outputs.tf           # cluster_endpoint, cluster_name, vpc_id
├── backend/              # bootstraps the S3 + DynamoDB remote state backend
└── modules/
    ├── vpc/              # VPC, public/private subnets across 2 AZs
    └── eks/               # EKS control plane + managed node group
```

- **VPC**: a `/16` with public and private subnets split across two availability zones. Node groups run in the private subnets.
- **EKS**: a managed cluster (Kubernetes 1.35 by default) with a configurable managed node group — instance types, capacity type (on-demand/spot), and min/max/desired scaling are all Terraform variables, not hardcoded.
- **Remote state**: state lives in S3 (`amir-demo-terraform-eks-state-bucket`) with DynamoDB-backed locking, not on a laptop. The `eks/backend/` directory is a one-time bootstrap for that bucket and lock table — apply it once, before the main `eks/` config, since the main config's own backend depends on it existing.

## Usage

```bash
# one-time: create the S3 bucket + DynamoDB table the main config's backend needs
cd eks/backend
terraform init && terraform apply

# provision the VPC + EKS cluster
cd ../
terraform init
terraform plan
terraform apply

# point kubectl at the new cluster
aws eks update-kubeconfig --name <cluster_name> --region us-east-1
```

## Bootstrapping ArgoCD onto a fresh cluster

`scripts/bootstrap-eks.sh` picks up where `terraform apply` leaves off: installs ArgoCD, the AWS Load Balancer Controller (with its IAM/IRSA role), the GHCR pull secret, and the app's ArgoCD `Application` - the whole post-infra setup in one command instead of a dozen manual `eksctl`/`helm`/`kubectl` steps. It's idempotent, so re-running it after a partial failure (or just to double-check nothing drifted) is always safe.

```bash
echo -n "<your GHCR PAT>" > ~/.ghcr-pat   # once - never committed, never logged
cd scripts
./bootstrap-eks.sh
```

This is deliberately separate from `terraform apply`/`terraform destroy`: infra provisioning takes several minutes and is its own lifecycle, while this script is the fast, repeatable "make the app come alive" step you'd run right before a demo.

## Where this fits in the bigger picture

Once the cluster exists, [ArgoCD](https://github.com/AmirWeiser/opentelemetry-demo-gitops) is installed on it and points at the `opentelemetry-demo-gitops` repo's Helm chart. From there, deployments are entirely GitOps-driven — nothing gets `kubectl apply`'d by hand. This repo's only job is making sure the cluster itself exists and is sized sensibly; it has no opinion on what runs inside it.

Currently exercised on [minikube](https://minikube.sigs.k8s.io/) for local iteration (faster feedback loop, zero cloud cost); this Terraform is what stands up the real target environment.
