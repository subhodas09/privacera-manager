# Development VPC workspace

This Terraform root module creates a production-shaped development VPC using the official [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest) module. The module is pinned to `6.7.3` so a new upstream release cannot silently change a plan.

## Architecture

The default `/16` is split across three availability zones:

| Tier | Default CIDRs | Internet route | Intended use |
| --- | --- | --- | --- |
| Public/edge | Three `/24` subnets (`.0`, `.1`, `.2`) | Internet gateway | Internet-facing load balancers and one NAT gateway per AZ |
| Private/application | Three `/20` subnets (`.16`, `.32`, `.48`) | Same-AZ NAT gateway | EKS control-plane ENIs, EKS nodes, pods, and internal load balancers |
| Database/data | Three `/24` subnets (`.64`, `.65`, `.66`) | None | RDS and other stateful services that must not initiate internet traffic |

The application tier receives larger CIDRs because the AWS VPC CNI allocates VPC addresses to pods. The data tier has separate route tables and no `0.0.0.0/0` route to either an internet gateway or NAT gateway. The module also creates a multi-AZ RDS subnet group.

## Security and resilience controls

- **Three-AZ fault isolation:** each tier spans three AZs. The default creates a NAT gateway per AZ and maps each private route table to its local NAT gateway, avoiding cross-AZ egress dependency and cross-AZ data charges.
- **No automatic public addresses:** `map_public_ip_on_launch` is disabled even in the public subnets. Only resources explicitly designed for the edge should receive public reachability.
- **Isolated data routing:** database subnets have dedicated route tables and no internet or NAT default route. Access must be granted by workload-specific security groups; this workspace intentionally does not create permissive database security groups.
- **Default security group disabled:** the VPC default security group is managed with no ingress or egress rules. Workloads must use purpose-built security groups.
- **Unused main route table kept empty:** the default route table is managed without routes, preventing an accidentally associated subnet from inheriting internet access.
- **VPC Flow Logs:** accepted and rejected traffic are captured at one-minute aggregation intervals. Logs are encrypted with a customer-managed KMS key, retained for 90 days by default, and protected from Terraform destroy by default. This supports incident response, traffic baselining, and rejected-connection troubleshooting.
- **KMS rotation:** the Flow Log KMS key has automatic rotation and a 30-day deletion window.
- **Private AWS API paths:** a gateway endpoint for S3 and interface endpoints for ECR, EC2, EKS, EKS Pod Identity, STS, KMS, CloudWatch, Systems Manager, Elastic Load Balancing, and Auto Scaling reduce NAT exposure. The endpoint security group accepts HTTPS only from the application subnets.
- **EKS subnet discovery tags:** public and private subnets carry the external/internal load-balancer role tags and a shared `privacera-cluster` tag. This prevents Kubernetes integrations from selecting the database tier. No AWS Load Balancer Controller is installed by these Terraform stacks.
- **Address utilization metrics:** VPC network-address-usage metrics are enabled so IP exhaustion can be alerted before it affects pod scheduling.
- **Account guardrail:** set `allowed_account_ids` so an otherwise valid plan cannot be applied to the wrong AWS account.
- **Consistent ownership tags:** environment, project, repository, and Terraform ownership tags are applied through provider default tags.

Network ACLs remain stateless coarse-grained controls with the AWS default allow behavior. Security groups, isolated route tables, Kubernetes network policies, and workload identity are used for least privilege; attempting to duplicate dynamic Kubernetes flows in NACLs commonly creates brittle outages. Add organization-specific NACL denies only when there is a documented threat-control requirement.

## Cost decisions

The secure/resilient defaults create three NAT gateways and multiple interface endpoints. For a disposable development environment, set `single_nat_gateway = true` or `enable_vpc_endpoints = false` after accepting the reduced AZ resilience or increased NAT traversal. Database isolation and private EKS placement do not change.

## Deploy

For local development, `backend.hcl` supplies the `privacera` profile to the S3 backend and `terraform.tfvars` supplies it to the AWS provider. Therefore the commands below do not require `AWS_PROFILE=privacera`. Set `aws_profile = null` and remove `profile` from `backend.hcl` when running with environment, workload, or assumed-role credentials in automation.

```bash
cd infra/dev/vpc
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
# Replace the bucket, account ID, Region, and AZ example values. SSE-S3 is the
# development default; configure the optional KMS key only when required.

terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=vpc.tfplan
terraform apply vpc.tfplan
```

Use short-lived AWS credentials or an assumed deployment role. Never place credentials in `backend.hcl`, `terraform.tfvars`, or Terraform state.

## Teardown caveat

With `protect_flow_logs = true`, Terraform removes the Flow Log group from state instead of deleting the retained audit data. Inventory and delete or import that log group separately when retention requirements permit. KMS key deletion has a mandatory 30-day waiting period.
