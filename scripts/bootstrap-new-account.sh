#!/usr/bin/env bash
# Bootstraps the full aGorA dev environment in a fresh AWS account.
#
# Replaces the manual, multi-page runbook in agora-infra/PROJECT_STATE.md
# ("Platform Apply Order") with one script. Still NOT pure CI automation —
# you run this yourself, locally, with your own AWS credentials active —
# but it removes all the hand-typed -target flags and "did I get the order
# right?" guesswork that caused real failures during the original setup
# (CRD-not-installed-yet errors, EC2NodeClass validation errors, ArgoCD
# 262144-byte CRD annotation errors). Every workaround this script applies
# was discovered the hard way; don't strip them out without re-testing.
#
# Prerequisites (you must do these manually, before running this script —
# see the comments at each step for why they can't be automated):
#   1. AWS credentials for the target account active in your shell
#      (aws sts get-caller-identity should show the NEW account).
#   2. An S3 bucket + DynamoDB table for Terraform state already exists in
#      the new account (backend.tf's `backend "s3" {}` block cannot read a
#      variable — bucket/table names are baked into backend.tf and must be
#      edited by hand once per new account, OR pass -reconfigure with a
#      backend config file; this script does not attempt that for you).
#   3. A GitHub PAT with read access to the agora-helm repo
#      (ARGOCD_REPO_PAT below).
#   4. kubectl, aws CLI, and terraform (>=1.8.0) installed locally.
#
# Usage:
#   export AWS_REGION=us-east-1
#   export ALERT_EMAIL=you@example.com
#   export ARGOCD_REPO_PAT=ghp_xxx
#   export CLUSTER_NAME=agora-dev          # must match environments/dev/terraform.tfvars cluster_name
#   ./bootstrap-new-account.sh /path/to/agora-infra/environments/dev
#
# Optional:
#   export ENABLE_KARPENTER=true           # default: true
#   export KPS_CHART_VERSION=65.5.1        # must match dev-platform/main.tf's targetRevision
#   export DOMAIN_NAME=ustbiteshub.online  # default: empty (skips argocd./grafana. HTTPRoutes
#                                          # entirely — ArgoCD/Grafana stay reachable only via
#                                          # kubectl port-forward, same as before the single-NLB
#                                          # consolidation). Must match var.domain_name already
#                                          # set in environments/dev/terraform.tfvars, since that's
#                                          # what controls whether CloudFront/Route53 actually
#                                          # alias argocd./grafana. to anything.

set -euo pipefail

INFRA_DIR="${1:?Usage: $0 /path/to/agora-infra/environments/dev}"
# environments/dev-platform is a SIBLING of environments/dev (not nested) — both
# are independent Terraform root modules with their own state; the platform
# layer just happens to read the base layer's outputs via a data source.
PLATFORM_DIR="${INFRA_DIR}-platform"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME to match terraform.tfvars cluster_name}"
ALERT_EMAIL="${ALERT_EMAIL:?Set ALERT_EMAIL — required Terraform variable, no default}"
ARGOCD_REPO_PAT="${ARGOCD_REPO_PAT:?Set ARGOCD_REPO_PAT — GitHub PAT with read access to agora-helm}"
ENABLE_KARPENTER="${ENABLE_KARPENTER:-true}"
KPS_CHART_VERSION="${KPS_CHART_VERSION:-65.5.1}"
DOMAIN_NAME="${DOMAIN_NAME:-}"

log() { echo; echo "=== $* ==="; }

log "Confirming AWS identity"
aws sts get-caller-identity --region "$AWS_REGION"
read -p "Is this the correct TARGET account? Type 'yes' to continue: " confirm
[ "$confirm" = "yes" ] || { echo "Aborted."; exit 1; }

# ── Pass 0: base infra layer (VPC, EKS, RDS, SQS, ECR, IAM, Karpenter IAM) ──
log "Pass 0/4: terraform init + apply (base infra layer)"
( cd "$INFRA_DIR" && \
  terraform init -input=false && \
  terraform apply -input=false -auto-approve \
    -var="alert_email=${ALERT_EMAIL}" \
    -var="enable_karpenter=${ENABLE_KARPENTER}" )

# CloudWatch Container Insights creates these log groups itself the moment
# the amazon-cloudwatch-observability addon starts — if this is a TRUE fresh
# account they won't exist yet and the resource just creates cleanly. If
# you're re-running this against an account where the addon already ran
# once, import first (see agora-infra/PROJECT_STATE.md "CloudWatch Log Group
# Import"). This script does NOT attempt that — only run it blind on a
# genuinely fresh account.

log "Granting your IAM user cluster-admin access (always manual — the EKS"
log "module's bootstrap_cluster_creator_admin_permissions only works when"
log "Terraform runs AS a role, not an IAM user)"
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
if [[ "$CALLER_ARN" == *":user/"* ]]; then
  aws eks create-access-entry \
    --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$CALLER_ARN" \
    --region "$AWS_REGION" || echo "(access entry may already exist, continuing)"
  aws eks associate-access-policy \
    --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$CALLER_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster \
    --region "$AWS_REGION" || echo "(access policy may already be associated, continuing)"
else
  echo "Caller is a role, not a user — bootstrap_cluster_creator_admin_permissions should already cover this."
fi

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

log "Waiting for at least one node to be Ready before installing platform components"
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  echo "  waiting for nodes..."
  sleep 15
done
kubectl get nodes

# ── Pass 1: platform layer, Helm releases only (CRDs not yet referenced) ──
log "Pass 1/4: terraform init + apply -target (kgateway, external-secrets,"
log "argocd, karpenter Helm releases) — installs CRDs that pass 2 needs"
( cd "$PLATFORM_DIR" && \
  terraform init -input=false && \
  TF_VAR_argocd_repo_pat="$ARGOCD_REPO_PAT" \
  terraform apply -input=false -auto-approve \
    -var="enable_karpenter=${ENABLE_KARPENTER}" \
    -target=kubernetes_namespace.agora \
    -target=kubernetes_deployment.redis \
    -target=kubernetes_service.redis \
    -target=terraform_data.gateway_api_crds \
    -target=helm_release.kgateway_crds \
    -target=helm_release.kgateway \
    -target=helm_release.external_secrets \
    -target=helm_release.argocd \
    -target=helm_release.karpenter \
    -target=kubernetes_manifest.argocd_app_monitoring )

# ── kube-prometheus-stack CRDs: must be applied server-side, manually. ──
# ArgoCD's ServerSideApply=true syncOption does NOT avoid the 262144-byte
# last-applied-config annotation limit for these CRDs specifically — tested
# and confirmed during the original setup, not just a theoretical concern.
# skipCrds=true is already set in platform/main.tf's monitoring Application;
# this is the other half of that fix.
log "Pass 2/4: installing kube-prometheus-stack CRDs via real server-side apply"
TMP_KPS_DIR=$(mktemp -d)
curl -sL "https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-${KPS_CHART_VERSION}/kube-prometheus-stack-${KPS_CHART_VERSION}.tgz" \
  -o "${TMP_KPS_DIR}/kps.tgz"
tar -xzf "${TMP_KPS_DIR}/kps.tgz" -C "$TMP_KPS_DIR" kube-prometheus-stack/charts/crds/crds
kubectl apply --server-side -f "${TMP_KPS_DIR}/kube-prometheus-stack/charts/crds/crds/"
rm -rf "$TMP_KPS_DIR"

# ── Pass 3: everything else (Gateway, ReferenceGrant, ArgoCD per-service ──
# apps, Karpenter NodePool/EC2NodeClass, argocd./grafana. HTTPRoutes) —
# needs the CRDs from passes 1-2. domain_name is optional: leave DOMAIN_NAME
# unset to skip the HTTPRoutes (count = 0 on both resources) and keep
# ArgoCD/Grafana reachable only via kubectl port-forward, same as before the
# single-NLB consolidation that added them.
log "Pass 3/4: terraform apply (remaining platform resources)"
( cd "$PLATFORM_DIR" && \
  TF_VAR_argocd_repo_pat="$ARGOCD_REPO_PAT" \
  terraform apply -input=false -auto-approve \
    -var="enable_karpenter=${ENABLE_KARPENTER}" \
    -var="domain_name=${DOMAIN_NAME}" )

# ── Pass 4: force the prometheus-operator to pick up CRDs that existed ──
# AFTER it first started (its informer cache doesn't hot-reload new CRD
# registrations). Without this, the Prometheus custom resource never
# reconciles into an actual pod and ArgoCD reports Healthy=Missing forever.
log "Pass 4/4: restarting prometheus-operator to pick up newly-installed CRDs"
kubectl rollout restart deployment monitoring-kube-prometheus-operator -n monitoring 2>/dev/null \
  || echo "(operator not found yet — if monitoring didn't deploy, check ArgoCD app status manually)"
kubectl rollout status deployment monitoring-kube-prometheus-operator -n monitoring --timeout=120s 2>/dev/null || true

log "Done. Verify with:"
echo "  kubectl get applications -n argocd"
echo "  kubectl get pods -n agora"
echo "  kubectl get pods -n monitoring"
echo "  kubectl get nodepool,ec2nodeclass   # if ENABLE_KARPENTER=true"
echo
echo "Remaining MANUAL steps not covered by this script (see agora-infra/PROJECT_STATE.md):"
echo "  - GitHub OAuth App + agora/dev/api Secrets Manager fields (GITHUB_CLIENT_ID etc.)"
echo "  - Bedrock cross-account role ARN + agent IDs in agora/dev/worker secret"
echo "  - Route53 hosted zone + ACM cert + nlb_hostname/hosted_zone_id/acm_certificate_arn"
echo "    in terraform.tfvars, if you want CloudFront (re-run terraform apply in $INFRA_DIR after)"
echo "    -- DOMAIN_NAME above must match this terraform.tfvars value, or argocd./grafana."
echo "    won't have anything to alias to even though their HTTPRoutes got created"
echo "  - Register GitHub webhooks per org via the running app's Settings page"
