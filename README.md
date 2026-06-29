# stagecraft-workflows

Reusable GitHub Actions workflows for all [Stagecraft-Ops](https://github.com/Stagecraft-Ops) repositories.

## Usage

Reference any workflow from a service repo:
```yaml
uses: Stagecraft-Ops/stagecraft-workflows/.github/workflows/<workflow>.yml@main
```

## Available Workflows

| Workflow | Purpose | Called by |
|----------|---------|-----------|
| `gitleaks.yml` | Secret scanning (full history) | All service repos |
| `python-ci.yml` | ruff lint + mypy + pytest | stagecraft-api, stagecraft-webhook, stagecraft-worker |
| `node-ci.yml` | npm lint + tsc + next build | stagecraft-frontend |
| `build-and-scan.yml` | Docker build + Trivy CRITICAL/HIGH scan | All service repos |
| `push-to-ecr.yml` | Push to ECR (immutable tag) + Cosign sign | All service repos |
| `helm-update.yml` | Bump image tag in stagecraft-helm | All service repos |
| `terraform-plan.yml` | tf fmt + init + validate + plan, post to PR | stagecraft-infra |
| `terraform-apply.yml` | tf apply (requires env approval for prod) | stagecraft-infra |
| `notify.yml` | SendGrid failure email | All repos, on failure |

## Required Org Secrets

Set these in the `Stagecraft-Ops` organisation settings:

| Secret | Used by |
|--------|---------|
| `AWS_ACCOUNT_ID` | build-and-scan, push-to-ecr |
| `ECR_ROLE_ARN` | build-and-scan, push-to-ecr |
| `AWS_PLAN_ROLE_ARN` | terraform-plan |
| `AWS_APPLY_ROLE_ARN` | terraform-apply |
| `HELM_CHARTS_TOKEN` | helm-update (PAT with write access to stagecraft-helm) |
| `SENDGRID_API_KEY` | notify |
| `NOTIFY_EMAIL` | notify |

## Tag Strategy

- **`main` branch** → semantic version tag (`v1.2.3` — patch auto-incremented)
- **Other branches** → `{branch-slug}-{sha8}` (e.g. `feature-auth-a3b1c2d4`)

Images use immutable ECR tags — `:latest` is never pushed.
