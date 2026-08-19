# opentelemetry-aws-infra

Terraform for the AWS infrastructure behind the [OpenTelemetry demo GitOps project](https://github.com/AmirWeiser/opentelemetry-demo-gitops). A single `terraform apply` provisions the VPC, the EKS cluster, ArgoCD, the AWS Load Balancer Controller, the GHCR pull secret, and the app's ArgoCD `Application` — the app is live and reachable over a real ALB by the time `apply` finishes, no manual steps after.

This is one of three repositories that make up the full project:

| Repo | Role |
|---|---|
| **opentelemetry-aws-infra** (this repo) | The infrastructure the app runs on |
| [opentelemetry-demo-gitops](https://github.com/AmirWeiser/opentelemetry-demo-gitops) | The Helm chart ArgoCD deploys |
| [opentelemetry-demo-src](https://github.com/AmirWeiser/opentelemetry-demo-src) | Application source + CI pipeline |

## What it provisions

```
eks/
├── main.tf              # vpc + eks modules, kubernetes/helm/kubectl providers, readiness gate
├── addons.tf            # ArgoCD, AWS Load Balancer Controller, GHCR secret, ArgoCD Application, destroy-safety
├── variables.tf         # region, CIDRs, cluster version, node group sizing, ghcr_pat (sensitive)
├── outputs.tf           # cluster_endpoint, cluster_name, vpc_id, lb_controller_role_arn, ...
├── backend/              # bootstraps the S3 + DynamoDB remote state backend
└── modules/
    ├── vpc/              # VPC, public/private subnets across 2 AZs
    └── eks/               # EKS control plane, managed node group, OIDC provider + LB Controller IRSA role
```

- **VPC**: a `/16` with public and private subnets split across two availability zones. Node groups run in the private subnets.
- **EKS**: a managed cluster (Kubernetes 1.35 by default) with a configurable managed node group — instance types, capacity type (on-demand/spot), and min/max/desired scaling are all Terraform variables, not hardcoded.
- **ArgoCD + AWS Load Balancer Controller**: installed via `helm_release` in the same apply as the cluster. The controller's IAM role is IRSA, tied to an `aws_iam_openid_connect_provider` that Terraform creates and owns in the same state as the cluster — see the gotcha below on why that matters.
- **The app itself**: a `kubectl_manifest` applies the ArgoCD `Application` pointing at [opentelemetry-demo-gitops](https://github.com/AmirWeiser/opentelemetry-demo-gitops). From there ArgoCD's own auto-sync takes over — nothing app-related is ever `kubectl apply`'d by hand.
- **Remote state**: state lives in S3 (`amir-demo-terraform-eks-state-bucket`) with DynamoDB-backed locking, not on a laptop. The `eks/backend/` directory is a one-time bootstrap for that bucket and lock table — apply it once, before the main `eks/` config, since the main config's own backend depends on it existing.

## Usage

```bash
# one-time: create the S3 bucket + DynamoDB table the main config's backend needs
cd eks/backend
terraform init && terraform apply

# provision everything - VPC, EKS, ArgoCD, LB Controller, GHCR secret, the app itself
cd ../eks
export TF_VAR_ghcr_pat="<your GHCR PAT, read:packages or write:packages scope>"   # never committed; no default, so apply fails loudly if unset
terraform init
terraform plan
terraform apply
```

That's it - no separate bootstrap script, no manual `kubectl`/`helm`/`eksctl` steps. Takes roughly 15-20 minutes, dominated by EKS control plane + node group provisioning. By the time `apply` finishes, all app pods are `Running`, ArgoCD shows `Synced`/`Healthy`, and the frontend is reachable over a real ALB.

Terraform's own providers authenticate to the cluster directly and never touch your local `~/.kube/config` - to inspect the cluster yourself afterward (not required for the app to work):

```bash
aws eks update-kubeconfig --name <cluster_name> --region us-east-1
kubectl get ingress -n opentelemetry-demo   # ALB hostname is here - browse it over http://, no TLS listener is configured
```

`scripts/bootstrap-eks.sh` is kept in the repo as a manual fallback/reference (e.g. for debugging one addon in isolation without a full `terraform apply`), but is redundant for a normal EKS deploy now.

## EKS gotchas found running this for real

None of these are theoretical — each one broke a real deploy on this exact cluster before being fixed here:

- **IMDS hop limit.** EKS-managed node groups default to an Instance Metadata Service hop limit of `1`, which only the host itself can reach - not a pod, which sits one virtual-network hop further away. The AWS Load Balancer Controller uses IMDS to auto-discover its VPC ID and crash-loops without it. Fixed via a custom `aws_launch_template` (`eks/modules/eks/main.tf`) setting `http_put_response_hop_limit = 2`, attached to the node group - not a one-off patch, since the default launch template would silently reset any new node back to `1`.
- **Pod-density ceiling, not a compute limit.** `t3.medium` cannot schedule more than ~17 pods regardless of idle CPU/memory - EKS's VPC CNI gives every pod a real VPC IP, and each instance type has a hard cap on how many it can hand out (`N_ENIs × (IPs_per_ENI − 1) + 2`). Two nodes (34 pod slots) wasn't enough headroom for ArgoCD + the LB controller + all 23 app pods; bumped to four nodes.
- **A cluster-wide admission webhook outage silently blocks unrelated resources.** The LB controller registers a mutating webhook for *every* `Service` object in the cluster, not just ones it manages. While that webhook's pods were down, ArgoCD's sync reported a generic failure and **zero Services were created anywhere in the namespace** - pods came up fine, nothing could reach anything by DNS. Fixed itself once the controller was healthy and a sync was re-triggered; worth knowing this failure mode exists before debugging "why can't my pods talk to each other" from the app side.
- **`kubectl apply` has a 256KB annotation ceiling.** ArgoCD's own `ApplicationSet` CRD is large enough to exceed the `last-applied-configuration` annotation limit under plain client-side apply, so it fails silently while every other resource in the same manifest succeeds. `bootstrap-eks.sh` uses `kubectl apply --server-side --force-conflicts` for the ArgoCD install specifically to avoid this.
- **`eksctl create iamserviceaccount` doesn't survive the disposable-cluster cycle - fixed for good by moving IRSA into Terraform itself.** eksctl tracks whether it has work to do via a CloudFormation stack name (`eksctl-<cluster>-addon-iamserviceaccount-<ns>-<name>`), not the live cluster state. Since `terraform destroy` never touches that stack, the next `terraform apply` gets a brand-new cluster with a brand-new OIDC provider, but eksctl finds the old stack "already exists" and skips real work - leaving an IAM trust policy pinned to a now-deleted OIDC provider ID and, the first time this happened, no Kubernetes ServiceAccount at all. Symptom chain: LB controller pods stuck at `0/2` (`serviceaccount not found`), then after a manual SA fix, `AssumeRoleWithWebIdentity` 403s and the ALB never gets created. `bootstrap-eks.sh` used to work around this by comparing the stack's trust policy against the cluster's current OIDC issuer before calling eksctl - superseded now: `eks/modules/eks/irsa.tf` creates the OIDC provider (`aws_iam_openid_connect_provider`) and the LB Controller's IAM role in the *same Terraform state* as the cluster, so destroy always removes both together and the next apply always recreates both together, always matched. The staleness bug class simply can't happen when there's no separate, longer-lived resource left behind to go stale.
- **`kubernetes_manifest` needs its target CRD's schema at *plan* time, not apply time.** The ArgoCD `Application` CRD only exists after `helm_release.argocd` runs, in this same apply - so on a genuinely fresh cluster, `terraform plan` would fail trying to validate the `Application` resource against a CRD schema that doesn't exist yet. Fixed by using `kubectl_manifest` (the `gavinbunney/kubectl` provider) instead, which applies at apply-time like `kubectl apply` - no plan-time schema lookup, so CRD-then-CR in one apply works.
- **The AWS Load Balancer Controller's ALB lives outside Terraform's knowledge entirely.** It's created directly against the AWS API by the controller pod, not by any Terraform resource. The first time this project moved the controller into the same Terraform state as the cluster, `terraform destroy` killed the cluster before that ALB was gone - orphaning it and leaving its ENIs stuck in the subnets, blocking IGW/subnet deletion with `DependencyViolation`. Fixed with a `null_resource` (`cleanup_alb_before_vpc_destroy` in `addons.tf`) whose `depends_on` chain guarantees it runs, on destroy, after the app/Ingress but before the VPC module - it tries a graceful `kubectl delete ingress` first, then falls back to deleting any leftover ALB directly via the AWS API.
- **A `terraform destroy` that gets interrupted (or fails on one resource) can leave the state file itself locked, or holding a stale entry for a resource that's actually already gone from AWS.** Hit both this session: a leftover DynamoDB lock from an earlier interrupted run blocked a later `plan` with `ConditionalCheckFailedException` (fixed with `terraform force-unlock <lock-id>`), and the VPC stayed in state as if it existed after a destroy that had, in reality, fully succeeded in AWS (fixed with `terraform state rm`). Worth checking `terraform state list` against reality (e.g. `aws ec2 describe-vpcs`) if a plan's resource count looks off after a rough destroy.

## Where this fits in the bigger picture

`terraform apply` provisions the cluster *and* installs ArgoCD on it, pointed at the `opentelemetry-demo-gitops` repo's Helm chart. From there, deployments are entirely GitOps-driven — nothing app-related is ever `kubectl apply`'d by hand, and pushing a new image tag to the gitops repo (done automatically by CI, see [opentelemetry-demo-src](https://github.com/AmirWeiser/opentelemetry-demo-src)) is all it takes to roll out a change.

Confirmed working end-to-end on a real EKS cluster, from a single `terraform apply` with nothing run afterward: ArgoCD `Synced`/`Healthy`, all 23 pods `Running`, and the frontend reachable over a real internet-facing ALB provisioned by the AWS Load Balancer Controller. The cluster is treated as disposable on purpose - `terraform apply` before a demo, `terraform destroy` after, since the control plane bills hourly regardless of usage. [minikube](https://minikube.sigs.k8s.io/) remains the day-to-day iteration environment (faster feedback loop, zero cloud cost); this Terraform is what stands up the real target environment when it's actually needed.
