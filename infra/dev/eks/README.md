# Development EKS workspace

This Terraform root module creates the required `privacera-cluster` EKS cluster using the official [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest) module. The module is pinned to `21.26.0`. Its state is separate from the VPC state and consumes only documented VPC outputs through read-only S3 remote state.

## Infrastructure included

- One regional EKS control plane placed into the three private application subnets.
- One EKS managed node group spread across those subnets, using `r5.2xlarge` x86_64 nodes as the workload target. The instance-type input can accept a compatible alternative when Privacera approves it. Accounts restricted to Free Tier instance types can use `m7i-flex.large` only for infrastructure validation; its 2 vCPU and 8 GiB memory are not equivalent to `r5.2xlarge` and are not sized for a real Privacera workload.
- A development autoscaling range of zero to three nodes, with one desired node. Scale-to-zero reduces idle cost but means the application is unavailable until a node starts and is not an HA configuration.
- Amazon Linux 2023 EKS-optimized images, encrypted gp3 root volumes, detailed EC2 monitoring, EKS node auto-repair, and controlled rolling updates.
- Managed CoreDNS, kube-proxy, VPC CNI, EKS Pod Identity Agent, and EBS CSI add-ons, using the most recent add-on build compatible with the selected Kubernetes version. EBS is the only persistent-storage integration created; no EFS resources or EFS CSI driver are included.
- Dedicated Pod Identity roles for VPC CNI and EBS CSI instead of placing those permissions on every node.
- A customer-managed KMS key for Kubernetes secret-envelope encryption and EKS control-plane logs.
- IAM access entries for explicitly named administrator roles or users.

The repository sets `PRIVACERA_VERSION=9.0.29.1`. The [Privacera compatibility matrix](https://docs.privacera.com/resources/infrastructure/compatibility-and-versions/compatibility-and-versions.html) classifies `9.0.x` as supporting EKS only up to Kubernetes `1.32`, so this stack pins `1.32` and rejects an unreviewed version change. The [AWS EKS version lifecycle](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) places 1.32 in extended support through March 23, 2027, so AWS charges extended-support pricing. Privacera's release index also lists 9.0.29.1 as out of support after July 2026. Upgrade Privacera to a supported release that supports a current Kubernetes version, then update this guardrail. Module and add-on updates should be reviewed independently from Kubernetes minor-version upgrades.

## Security and reliability controls

- **Restricted Kubernetes API:** private endpoint access is always enabled. Public endpoint access is optional for quick development and, when enabled, requires one or more explicitly trusted office, VPN, or administrator `/32` CIDRs. `0.0.0.0/0` is rejected. A `/32` must be updated and the stack reapplied whenever the administrator's public IP changes.
- **Explicit administrators:** the Terraform caller is not silently made cluster-admin. Only IAM role or user ARNs in `cluster_admin_principal_arns` receive `AmazonEKSClusterAdminPolicy`. A named IAM user is supported when federation is unavailable, but short-lived role credentials remain the preferred long-term model.
- **EKS API authentication:** authentication uses EKS Access Entries (`API` mode), providing auditable AWS API objects and avoiding hand-edited `aws-auth` mappings.
- **Encrypted Kubernetes secrets:** EKS envelope encryption uses a dedicated customer-managed KMS key with rotation and a 30-day deletion window.
- **Complete control-plane audit trail:** API server, audit, authenticator, controller-manager, and scheduler logs are enabled. The log group is encrypted with the same customer-managed key and retained for 90 days by default.
- **Deletion protection:** EKS deletion protection is enabled. It must be deliberately disabled before destroying the cluster.
- **Private nodes:** nodes receive only private addresses in the application subnets. No SSH key or remote-access security group is configured; use SSM-based operational patterns where node access is unavoidable.
- **Hardened node metadata:** IMDSv2 tokens are mandatory, the response hop limit is one, and metadata tags are disabled. Pods should use EKS Pod Identity instead of node credentials.
- **Least-privilege add-ons:** VPC CNI and EBS CSI receive separate IAM roles through Pod Identity. The node role does not receive the CNI policy.
- **Encrypted ephemeral storage:** node root disks are encrypted gp3 volumes and are deleted with the node. Use encrypted EBS storage classes and service-specific KMS keys for persistent application data.
- **Current node OS:** managed nodes use AL2023 and track the latest EKS AMI release for the chosen Kubernetes minor version, improving security patch uptake.
- **Managed disruption:** EKS node repair is enabled, updates allow no more than 33% of nodes unavailable, and on-demand capacity avoids Spot interruption for the core Privacera workload.
- **Multi-AZ placement:** the node group can place nodes in all three application subnets and EKS zonal shift is enabled. The required development range of zero to three nodes does not guarantee HA; use at least two nodes plus replicated workloads and disruption budgets when availability matters.
- **Network policy engine:** VPC CNI network-policy support and IPv4 prefix delegation are enabled. Network policy enforcement still requires namespace/workload `NetworkPolicy` objects; default-deny policies should be installed with the application platform.
- **No long-lived static AWS keys:** Pod Identity is installed for workloads and used by VPC CNI and EBS CSI. IRSA is disabled because this organization denies `iam:CreateOpenIDConnectProvider` through an SCP; add-ons or workloads that require IRSA need an organization-policy exception or must be migrated to Pod Identity.
- **Compatibility-preserving support policy:** the cluster temporarily uses EKS `EXTENDED` support because Privacera 9.0.29.1 supports only Kubernetes 1.32. This prevents an incompatible forced upgrade but incurs additional AWS charges and is not a substitute for upgrading Privacera.
- **Account guardrail and tags:** `allowed_account_ids` prevents wrong-account applies, and ownership/cost tags are applied consistently.

The official module's recommended node security-group rules include unrestricted node egress because Kubernetes nodes and controllers need dynamic destinations and ports. Risk is reduced through private subnets, VPC endpoints, NAT-only internet egress, pod network policies, and workload identity. If your organization requires domain-aware egress filtering, add AWS Network Firewall or an approved proxy rather than brittle IP-only security-group rules.

## Required external access and storage

- **Privacera registry:** private nodes and pods have outbound HTTPS internet access through the application-tier NAT gateways, allowing image pulls from `hub2.privacera.com`. Registry credentials must be stored as a Kubernetes image-pull Secret or in an approved external secret manager; they are not placed in Terraform state.
- **GitHub:** the same NAT path permits outbound HTTPS to GitHub for repository operations. SSH-based Git access is not opened explicitly; prefer HTTPS or tightly controlled SSH egress if it is later required.
- **DNS:** VPC DNS support and hostnames are enabled so registry and GitHub names resolve from nodes and pods.
- **Security groups:** managed nodes receive no public address or inbound SSH rule. The official module creates the control-plane/node rules required for EKS communication, while outbound access is NAT-only.
- **EBS only:** the Amazon EBS CSI managed add-on and its dedicated Pod Identity role are included. No EFS file system, EFS CSI driver, or AWS Load Balancer Controller is created for this exercise.
- **Network policies:** if default-deny pod egress policies are added, explicitly allow DNS plus TCP/443 to the approved registry and GitHub/proxy path; otherwise image pulls and repository operations will fail.

## State boundary and permissions

The EKS deployment role needs read access to the VPC state object but must not need write access to it. Grant write access only to the EKS state prefix. Because remote state readers can technically read the complete state snapshot, do not store secrets in Terraform state and use separate KMS/S3 policies for state prefixes where organizational policy requires it.

## Deploy

For local development, `backend.hcl` supplies the `privacera` profile to the EKS S3 backend and `terraform.tfvars` supplies it to both the AWS provider and VPC remote-state reader. Therefore the commands below do not require `AWS_PROFILE=privacera`. Set `aws_profile = null` and remove `profile` from `backend.hcl` when running with environment, workload, or assumed-role credentials in automation.

Deploy the VPC workspace first, then:

```bash
cd infra/dev/eks
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
# Replace the bucket, account ID, Region, and IAM principal example values.
# SSE-S3 is the development default; configure the optional KMS key only when required.

terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=eks.tfplan
terraform apply eks.tfplan
```

After apply, connect either from a network that can route to the private endpoint or, when restricted public access is enabled, from one of the configured public CIDRs:

```bash
aws eks update-kubeconfig --region ap-southeast-2 --name privacera-cluster
kubectl get nodes
kubectl get pods -A
```

Before installing Privacera, add namespace-level Pod Security Admission labels, default-deny ingress/egress network policies, resource requests/limits, PodDisruptionBudgets, encrypted storage classes, and application-specific IAM Pod Identity associations. Those controls depend on the Privacera chart/release and therefore belong in the Kubernetes/application workspace, not this AWS infrastructure state.

## Upgrade and destroy

Upgrade one Kubernetes minor version at a time: control plane, add-ons, then node group. Validate Privacera compatibility and deprecated APIs before each step. To destroy, first drain/migrate workloads and load balancers, set `deletion_protection = false` in `main.tf`, apply that change, and only then run `terraform destroy`. The KMS key remains pending deletion for 30 days by design.
