#!/usr/bin/env bash
# Bootstraps ArgoCD + AWS Load Balancer Controller + the GHCR pull secret +
# the app's ArgoCD Application onto an EKS cluster that Terraform has
# already provisioned (see ../eks). Safe to re-run any number of times -
# every step checks before it creates, nothing errors on "already exists."
#
# Prereqs: aws, kubectl, eksctl, helm on PATH; AWS credentials configured
# with permission to create IAM policies/roles.
#
# GHCR PAT: put ONLY the token in a local file, never in git, never in this
# script:
#   echo -n "ghp_xxx" > ~/.ghcr-pat
#
# Usage:
#   CLUSTER_NAME=my-eks-cluster AWS_REGION=us-east-1 ./bootstrap-eks.sh

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-my-eks-cluster}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GHCR_USERNAME="${GHCR_USERNAME:-amirweiser}"
GHCR_PAT_FILE="${GHCR_PAT_FILE:-$HOME/.ghcr-pat}"
NAMESPACE="opentelemetry-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_APP_MANIFEST="${GITOPS_APP_MANIFEST:-$SCRIPT_DIR/../../opentelemetry-demo-gitops/argocd-application-eks.yaml}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

echo "==> Cluster: $CLUSTER_NAME   Region: $AWS_REGION   Account: $ACCOUNT_ID"

echo "==> [1/7] Pointing kubectl at the cluster"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

echo "==> [2/7] Installing ArgoCD"
# --server-side is required, not optional: the ApplicationSet CRD is large
# enough that plain client-side "kubectl apply" hits Kubernetes' 256KB
# last-applied-configuration annotation limit and silently fails for just
# that one resource, leaving the applicationset-controller pod
# crash-looping forever with "no matches for kind ApplicationSet."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "    waiting for ArgoCD to be ready..."
kubectl -n argocd wait --for=condition=available --timeout=300s deployment --all

echo "==> [3/7] Associating IAM OIDC provider (no-op if already associated)"
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve

echo "==> [4/7] IAM policy for AWS Load Balancer Controller"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "    already exists, skipping"
else
  # Downloaded to the current directory, not /tmp: Git Bash's /tmp is an
  # MSYS-internal path the native Windows aws.exe can't resolve.
  curl -sL -o ./lbc-iam-policy.json \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://lbc-iam-policy.json
  rm -f ./lbc-iam-policy.json
fi

echo "==> [5/7] IAM service account (IRSA) for the controller"
# eksctl tracks this via a CloudFormation stack name, not the live cluster.
# On a disposable cluster (terraform destroy/apply each cycle), the stack
# from a PREVIOUS cluster generation survives - terraform destroy doesn't
# touch it - so eksctl finds it "already exists" and skips real work,
# leaving a trust policy that still points at the old, now-deleted OIDC
# provider. That breaks both the K8s ServiceAccount creation (eksctl thinks
# there's nothing to do) and, more importantly, every AssumeRoleWithWebIdentity
# call the controller makes at runtime (403 AccessDenied), which in turn
# blocks the ALB from ever being created. Detect and clear that staleness
# before letting eksctl run.
LBC_IRSA_STACK="eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
CURRENT_OIDC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's#.*/id/##')"

if aws cloudformation describe-stacks --stack-name "$LBC_IRSA_STACK" >/dev/null 2>&1; then
  ROLE_ARN="$(aws cloudformation describe-stacks --stack-name "$LBC_IRSA_STACK" \
    --query 'Stacks[0].Outputs[?OutputKey==`Role1`].OutputValue' --output text)"
  ROLE_NAME="${ROLE_ARN##*/}"
  TRUST_OIDC_ID="$(aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Federated' --output text | sed 's#.*/id/##')"
  if [ "$TRUST_OIDC_ID" != "$CURRENT_OIDC_ID" ]; then
    echo "    stale IRSA stack found (trust policy points at old OIDC provider $TRUST_OIDC_ID, this cluster is $CURRENT_OIDC_ID) - deleting so it can be recreated correctly"
    aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name "$LBC_IRSA_STACK" >/dev/null
    aws cloudformation delete-stack --stack-name "$LBC_IRSA_STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$LBC_IRSA_STACK"
  fi
fi

eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" --region="$AWS_REGION" \
  --namespace=kube-system --name=aws-load-balancer-controller \
  --attach-policy-arn="$POLICY_ARN" \
  --override-existing-serviceaccounts --approve

# The controller pod may already be running with the stale/missing
# credentials from a prior partial run - force it to pick up the
# (possibly just-recreated) role and serviceaccount.
kubectl -n kube-system rollout restart deployment aws-load-balancer-controller 2>/dev/null || true

echo "==> [6/7] Installing AWS Load Balancer Controller"
# Note: IMDS hop-limit (pods need hop-limit 2 to reach instance metadata,
# which the controller uses to auto-discover the VPC ID) is handled by the
# node group's launch template in Terraform now - nothing to patch here.
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
echo "    waiting for the controller to be ready..."
kubectl -n kube-system wait --for=condition=available --timeout=180s deployment/aws-load-balancer-controller

echo "==> [7/7] GHCR pull secret + app deployment"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
if [ -f "$GHCR_PAT_FILE" ]; then
  kubectl create secret docker-registry ghcr-pull-secret \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$(cat "$GHCR_PAT_FILE")" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    pull secret created/updated from $GHCR_PAT_FILE"
else
  echo "    !! $GHCR_PAT_FILE not found - skipping pull secret."
  echo "       Create it (a file containing ONLY your GHCR PAT) and re-run"
  echo "       this script if private images fail to pull."
fi

if [ -f "$GITOPS_APP_MANIFEST" ]; then
  kubectl apply -f "$GITOPS_APP_MANIFEST"
else
  echo "    !! ArgoCD Application manifest not found at $GITOPS_APP_MANIFEST"
  echo "       Set GITOPS_APP_MANIFEST to its path and re-run, or apply it manually."
fi

echo ""
echo "==> Done. Check status with:"
echo "    kubectl get application opentelemetry-demo -n argocd"
echo "    kubectl get pods -n $NAMESPACE"
echo ""
echo "ArgoCD UI:      kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
