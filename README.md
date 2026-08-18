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

## EKS gotchas found running this for real

None of these are theoretical — each one broke a real deploy on this exact cluster before being fixed here:

- **IMDS hop limit.** EKS-managed node groups default to an Instance Metadata Service hop limit of `1`, which only the host itself can reach - not a pod, which sits one virtual-network hop further away. The AWS Load Balancer Controller uses IMDS to auto-discover its VPC ID and crash-loops without it. Fixed via a custom `aws_launch_template` (`eks/modules/eks/main.tf`) setting `http_put_response_hop_limit = 2`, attached to the node group - not a one-off patch, since the default launch template would silently reset any new node back to `1`.
- **Pod-density ceiling, not a compute limit.** `t3.medium` cannot schedule more than ~17 pods regardless of idle CPU/memory - EKS's VPC CNI gives every pod a real VPC IP, and each instance type has a hard cap on how many it can hand out (`N_ENIs × (IPs_per_ENI − 1) + 2`). Two nodes (34 pod slots) wasn't enough headroom for ArgoCD + the LB controller + all 23 app pods; bumped to four nodes.
- **A cluster-wide admission webhook outage silently blocks unrelated resources.** The LB controller registers a mutating webhook for *every* `Service` object in the cluster, not just ones it manages. While that webhook's pods were down, ArgoCD's sync reported a generic failure and **zero Services were created anywhere in the namespace** - pods came up fine, nothing could reach anything by DNS. Fixed itself once the controller was healthy and a sync was re-triggered; worth knowing this failure mode exists before debugging "why can't my pods talk to each other" from the app side.
- **`kubectl apply` has a 256KB annotation ceiling.** ArgoCD's own `ApplicationSet` CRD is large enough to exceed the `last-applied-configuration` annotation limit under plain client-side apply, so it fails silently while every other resource in the same manifest succeeds. `bootstrap-eks.sh` uses `kubectl apply --server-side --force-conflicts` for the ArgoCD install specifically to avoid this.

## Where this fits in the bigger picture

Once the cluster exists, [ArgoCD](https://github.com/AmirWeiser/opentelemetry-demo-gitops) is installed on it and points at the `opentelemetry-demo-gitops` repo's Helm chart. From there, deployments are entirely GitOps-driven — nothing gets `kubectl apply`'d by hand. This repo's only job is making sure the cluster itself exists and is sized sensibly; it has no opinion on what runs inside it.

Confirmed working end-to-end on a real EKS cluster: ArgoCD `Synced`/`Healthy`, all pods running, and the frontend reachable over a real internet-facing ALB provisioned by the AWS Load Balancer Controller. The cluster is treated as disposable on purpose - `terraform apply` before a demo, `terraform destroy` after, since the control plane bills hourly regardless of usage. [minikube](https://minikube.sigs.k8s.io/) remains the day-to-day iteration environment (faster feedback loop, zero cloud cost); this Terraform is what stands up the real target environment when it's actually needed.
