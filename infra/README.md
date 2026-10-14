# AWS infrastructure

This directory contains two independent Terraform roots plus repository-managed Helm configuration:

- [`dev/vpc`](./dev/vpc) owns the VPC, three subnet tiers, routing, NAT gateways, VPC endpoints, and VPC Flow Logs.
- [`dev/eks`](./dev/eks) owns the EKS control plane, managed node group, encryption key, access entries, and managed add-ons.
- [`dev/helm`](./dev/helm) contains version-pinned, repeatable Helm commands and values for in-cluster add-ons such as GitHub Actions Runner Controller. Helm, not Terraform, owns these releases.

The Terraform roots intentionally have separate state. This limits blast radius and lets networking and the cluster change on different lifecycles. The EKS stack reads only required VPC outputs. Helm releases have their own release history in the cluster and are not written into Terraform state.

## Deployment order

1. Create a secure S3 Terraform-state bucket. Enable versioning, block all public access, enforce TLS, and restrict access to the deployment principal. This development setup uses S3-managed encryption (SSE-S3); use SSE-KMS when customer-controlled keys are required. Terraform's S3 lockfile is used for state locking.
2. Deploy [`dev/vpc`](./dev/vpc/README.md).
3. Deploy [`dev/eks`](./dev/eks/README.md).
4. Install cluster add-ons from [`dev/helm`](./dev/helm/README.md).

Each Terraform stack contains `backend.hcl.example` and `terraform.tfvars.example`. Copy them to their non-committed names and replace all example values.

```bash
cp infra/dev/vpc/backend.hcl.example infra/dev/vpc/backend.hcl
cp infra/dev/vpc/terraform.tfvars.example infra/dev/vpc/terraform.tfvars

cp infra/dev/eks/backend.hcl.example infra/dev/eks/backend.hcl
cp infra/dev/eks/terraform.tfvars.example infra/dev/eks/terraform.tfvars
```

For this development account, each local `backend.hcl` selects the `privacera` profile for S3 state and each local `terraform.tfvars` selects the same profile for providers and remote-state readers. No repeated shell export is required:

```bash
aws sts get-caller-identity --profile privacera
```

The expected principal is `arn:aws:iam::102798328535:user/privacera-terraform-operator`. The profile name is not a secret; its access key remains only in the AWS shared credentials file. Do not put access keys in Terraform files. This fallback uses long-lived credentials; rotate them and migrate to an approved temporary-role mechanism when the organization permits it.

Do not use Terraform CLI workspaces to combine environments in one state namespace. Add a sibling directory such as `infra/stage` or `infra/prod` so code review, state access, and lifecycle remain explicit.

## Toolchain and module pins

- Terraform: `>= 1.10, < 2.0`
- AWS provider: `>= 6.59, < 7.0`
- Official AWS VPC module: `terraform-aws-modules/vpc/aws` `6.7.3`
- Official AWS EKS module: `terraform-aws-modules/eks/aws` `21.26.0`
- Official GitHub ARC controller and runner-scale-set charts: `0.15.0`

Module versions are exact pins for reproducible plans. Upgrade them deliberately, review release notes, and run a plan in development before promotion.
