# Privacera Manager on AWS EKS: complete development walkthrough

This repository is the reproducible record of the development environment we
built for Privacera Manager. It covers AWS access, Terraform remote state, a
three-tier VPC, EKS, GitHub Actions Runner Controller (ARC), Snowflake
PolicySync, GitHub secrets, the Privacera deployment workflow, validation, and
the problems encountered along the way.

Follow this guide from top to bottom for a new environment. Use the operations
and troubleshooting sections when maintaining the existing environment.

> **Development warning:** the current environment favors a quick working
> deployment. It uses temporary IAM-user access keys, a restricted public EKS
> endpoint, and small Free Plan-eligible nodes. The production replacements are
> called out throughout this document.

> **Secret warning:** never commit an AWS key, GitHub PAT, Snowflake password,
> Privacera Hub password, rendered secret manifest, `terraform.tfvars`, or
> `backend.hcl`. If a credential has appeared in a screenshot, saved worksheet,
> terminal recording, or Git history, rotate it immediately even if the file was
> never committed.

## 1. What was built

### Current development values

| Item | Value |
| --- | --- |
| AWS account | `102798328535` |
| AWS Region | `ap-southeast-2` (Sydney) |
| Local AWS profile | `privacera` |
| Terraform state bucket | `privacera-tfstate-102798328535-ap-southeast-2-an` |
| VPC CIDR | `10.20.0.0/16` |
| Availability Zones | `ap-southeast-2a`, `ap-southeast-2b`, `ap-southeast-2c` |
| EKS cluster | `privacera-cluster` |
| Kubernetes version | `1.32` |
| Privacera version | `9.0.29.1` |
| Managed node group | min `0`, desired `3`, max `3` |
| Current node type | `m7i-flex.large` (development validation only) |
| Privacera target node type | `r5.2xlarge` or a Privacera-approved equivalent |
| Node root disk | encrypted `gp3`, 100 GiB per node |
| Privacera namespace | `candidate-test` |
| ARC controller namespace | `arc-systems` |
| ARC runner namespace | `arc-runners` |
| ARC runner scale-set label | `privacera-dev` |
| Snowflake service user | `PRIVACERA_POLICYSYNC_USER` |
| Snowflake service role | `PRIVACERA_POLICYSYNC_ROLE` |
| Snowflake warehouse | `PRIVACERA_POLICYSYNC_WH` |
| Snowflake database | `PRIVACERA_DB` |

### Mental model: who owns what

```text
Local administrator
  └─ AWS profile "privacera"
      ├─ Terraform root: infra/dev/vpc
      │   └─ VPC, subnets, routes, NAT, endpoints, flow logs
      └─ Terraform root: infra/dev/eks
          └─ EKS, node group, add-ons, IAM, KMS, EKS access entry

GitHub
  └─ Actions Runner Controller in EKS
      └─ ephemeral runner pod using Docker-in-Docker
          └─ .github/workflows/install.yml
              └─ Privacera Helm releases in namespace candidate-test

Snowflake
  └─ PolicySync user + role + warehouse + database

S3 remote-state bucket
  ├─ privacera/dev/vpc/terraform.tfstate
  └─ privacera/dev/eks/terraform.tfstate
```

There are three ownership boundaries:

1. Terraform owns AWS infrastructure. Do not manually edit Terraform-managed
   AWS resources unless a documented recovery procedure requires it.
2. Helm and Kubernetes manifests own in-cluster add-ons and applications.
   Terraform intentionally does not install ARC or Privacera.
3. GitHub and Snowflake credentials live in their secret stores. They do not
   belong in Terraform state or tracked YAML.

## 2. Repository layout

```text
.
├── .github/workflows/install.yml       # Privacera deployment workflow
├── variables.env                       # tracked, non-secret release settings
├── custom-vars/                        # Privacera configuration
│   └── connectors/snowflake/test/      # Snowflake SQL and connector vars
├── infra/
│   └── dev/
│       ├── vpc/                        # independent Terraform root and state
│       ├── eks/                        # independent Terraform root and state
│       └── helm/                       # ARC and Kubernetes add-on files
│           ├── actions-runner-controller/
│           └── privacera-storage/
└── scripts/
    ├── render_snowflake_secrets.py     # runtime-only secret injection
    ├── patch_privacera_storage_classes.py
    └── wget                            # curl-backed compatibility wrapper
```

The old root-level `github-self-hosted-runner.yaml` and
`github_actions_values.yml` describe the legacy Summerwind controller. Do not
use them for this environment. The active ARC source of truth is
`infra/dev/helm/actions-runner-controller/`.

## 3. Prerequisites on the Mac

Install and verify the local tools:

```bash
brew update
brew install awscli terraform kubectl helm git gh

aws --version
terraform version
kubectl version --client
helm version
git --version
gh --version
```

## 4. AWS identity and authentication

### Why both an IAM user and a role were considered

The intended model was:

```text
IAM user or SSO identity ──sts:AssumeRole──> deployment role ──> AWS resources
```

The user is the login identity; the role is the temporary permission set used
for deployment. A role normally gives short-lived credentials, a clean trust
boundary, and an easier path to least privilege. Attaching
`AdministratorAccess` to the role was intended only as a fast development
bootstrap, not as the final policy.

The setup uses these identities:

- IAM user: `privacera-terraform-operator`
- IAM role: `privacera-terraform-admin`
- Temporary development permission: AWS managed `AdministratorAccess`

The current development path uses the IAM user directly through the
`privacera` profile. The reason the role path could not be used and its
long-term correction are documented in the dedicated known-issues section.

### Configure the current development profile

Create one access key for the temporary IAM user in **IAM → Users →
privacera-terraform-operator → Security credentials → Create access key**.
Do not create a console password unless interactive console access is needed.

```bash
aws configure --profile privacera
```

Enter:

```text
AWS Access Key ID: <paste the access-key ID>
AWS Secret Access Key: <paste the secret once>
Default region name: ap-southeast-2
Default output format: json
```

AWS CLI stores these values in `~/.aws/credentials`, outside this repository.
Verify the exact account before creating anything:

```bash
aws sts get-caller-identity --profile privacera
```

Expected account: `102798328535`.

Never place the access key in `backend.tf`, `backend.hcl`,
`terraform.tfvars`, or any tracked file. Rotate and delete it after this
exercise. For production, use IAM Identity Center or GitHub OIDC plus a
least-privilege deployment role.

## 5. Create and secure the Terraform state bucket

Terraform state contains resource IDs, topology, and sometimes sensitive
values. It must not be public or silently editable.

```bash
export AWS_PROFILE=privacera
export AWS_REGION=ap-southeast-2
export TF_STATE_BUCKET=privacera-tfstate-102798328535-ap-southeast-2-an
```

Create the bucket once. Skip this command if it already exists:

```bash
aws s3api create-bucket \
  --bucket "$TF_STATE_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION" \
  --profile "$AWS_PROFILE"
```

Block public access, enable versioning, and enable server-side encryption:

```bash
aws s3api put-public-access-block \
  --bucket "$TF_STATE_BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' \
  --profile "$AWS_PROFILE"

aws s3api put-bucket-versioning \
  --bucket "$TF_STATE_BUCKET" \
  --versioning-configuration Status=Enabled \
  --profile "$AWS_PROFILE"

aws s3api put-bucket-encryption \
  --bucket "$TF_STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' \
  --profile "$AWS_PROFILE"
```

Add a bucket policy that denies non-TLS requests. Save this as a temporary
local file outside the repository:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::privacera-tfstate-102798328535-ap-southeast-2-an",
        "arn:aws:s3:::privacera-tfstate-102798328535-ap-southeast-2-an/*"
      ],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    }
  ]
}
```

```bash
aws s3api put-bucket-policy \
  --bucket "$TF_STATE_BUCKET" \
  --policy file://state-bucket-policy.json \
  --profile "$AWS_PROFILE"
```

Why these controls exist:

- SSE-S3 (`AES256`) encrypts state **at rest** in S3.
- HTTPS/TLS encrypts state **in transit** between Terraform and S3.
- The bucket policy rejects accidental plain-HTTP access; it is enforcement,
  not a second form of at-rest encryption.
- Public-access blocking prevents unintended internet exposure.
- Versioning provides recovery from overwrites or accidental deletion.

### What “separate workspaces” means here

We did **not** use Terraform CLI workspaces. VPC and EKS are separate root
modules with separate state objects:

```text
infra/dev/vpc  -> privacera/dev/vpc/terraform.tfstate
infra/dev/eks  -> privacera/dev/eks/terraform.tfstate
```

This gives a clearer dependency boundary and safer plans. For another
environment, create a sibling such as `infra/stage/`; do not hide environments
behind CLI workspace names.

## 6. Deploy the three-tier VPC

The VPC uses the official `terraform-aws-modules/vpc/aws` module pinned to
`6.7.3`.

| Tier | CIDRs | Default route | Purpose |
| --- | --- | --- | --- |
| Public/edge | `10.20.0.0/24`, `10.20.1.0/24`, `10.20.2.0/24` | Internet gateway | NAT gateways and future public load balancers |
| Private/application | `10.20.16.0/20`, `10.20.32.0/20`, `10.20.48.0/20` | same-AZ NAT gateway | EKS control plane ENIs, nodes, pods, internal services |
| Database/data | `10.20.64.0/24`, `10.20.65.0/24`, `10.20.66.0/24` | none | isolated stateful services such as RDS |

The application subnets are larger because the AWS VPC CNI assigns VPC IPs to
pods. Database subnets have no internet or NAT default route.

Security and reliability controls include:

- three AZs and one NAT gateway per AZ;
- disabled automatic public IP assignment;
- empty default security group and unused main route table;
- one-minute VPC Flow Logs, KMS encryption, and 90-day retention;
- KMS rotation and a 30-day deletion window;
- S3 gateway and private interface endpoints for AWS APIs;
- HTTPS-only endpoint security-group ingress from application subnets;
- Kubernetes subnet-discovery tags that exclude the database tier;
- IP utilization metrics, account-ID guardrails, and ownership/cost tags.

The current design is resilient but costly: three NAT gateways and multiple
interface endpoints are significant development costs. A disposable lab can
use one NAT or fewer endpoints only after accepting the tradeoff.

### Configure and apply

```bash
cd infra/dev/vpc
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
# Edit the ignored files with the account, bucket, Region, CIDRs, and profile.

terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=vpc.tfplan
terraform apply vpc.tfplan
```

The original apply created 67 resources. Validate:

```bash
terraform output
terraform state list
aws ec2 describe-vpcs \
  --filters Name=tag:Name,Values=privacera-dev \
  --profile privacera \
  --region ap-southeast-2
```

See [`infra/dev/vpc/README.md`](infra/dev/vpc/README.md) for component-level
rationale.

## 7. Deploy EKS

The EKS root uses official `terraform-aws-modules/eks/aws` version `21.26.0`.
It reads the VPC outputs from VPC state but cannot modify that state.

### Selected Kubernetes version

`variables.env` pins Privacera `9.0.29.1`. Its compatibility matrix supports
EKS only through Kubernetes `1.32`, so Terraform pins `1.32` instead of the
newest EKS version. Version lifecycle and upgrade limitations are collected in
the dedicated known-issues section.

### Security and platform controls

- Private EKS endpoint always enabled.
- Public endpoint enabled for quick development only and restricted to the
  administrator's current public IP `/32`; `0.0.0.0/0` is rejected.
- Nodes/pods in private subnets with NAT HTTPS access to Privacera Hub/GitHub.
- Explicit EKS Access Entry for the configured administrator.
- On-demand AL2023 managed node group across three AZs.
- Encrypted 100 GiB `gp3` node disks, IMDSv2, no SSH, node repair, controlled
  rolling updates, and detailed monitoring.
- CoreDNS, kube-proxy, VPC CNI, EKS Pod Identity Agent, and EBS CSI add-ons.
- Dedicated Pod Identity roles for CNI and EBS CSI; IRSA is disabled.
- KMS envelope encryption for Kubernetes secrets and all EKS control-plane
  logs; 90-day log retention and deletion protection.
- EBS only; no EFS or AWS Load Balancer Controller for this exercise.

### Restrict the public endpoint to the current IP

```bash
curl -fsS https://checkip.amazonaws.com
```

Set ignored `infra/dev/eks/terraform.tfvars`:

```hcl
endpoint_public_access       = true
endpoint_public_access_cidrs = ["YOUR.PUBLIC.IP.ADDRESS/32"]
```

Never replace it with `0.0.0.0/0`. If the ISP changes the address, update and
apply Terraform before `kubectl` will connect again.

### Configure and apply

```bash
cd infra/dev/eks
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Set the important local values:

```hcl
aws_region          = "ap-southeast-2"
aws_profile         = "privacera"
allowed_account_ids = ["102798328535"]
cluster_name        = "privacera-cluster"
kubernetes_version  = "1.32"

cluster_admin_principal_arns = [
  "arn:aws:iam::102798328535:user/privacera-terraform-operator",
]

endpoint_public_access       = true
endpoint_public_access_cidrs = ["YOUR.PUBLIC.IP.ADDRESS/32"]

node_instance_types = ["m7i-flex.large"]
node_min_size       = 0
node_desired_size   = 3
node_max_size       = 3
node_disk_size_gib  = 100
```

```bash
terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=eks.tfplan
terraform apply eks.tfplan
```

Connect and validate:

```bash
aws eks update-kubeconfig \
  --region ap-southeast-2 \
  --name privacera-cluster \
  --profile privacera

kubectl config current-context
kubectl get nodes -o wide
kubectl get pods -A
kubectl get storageclass
```

See [`infra/dev/eks/README.md`](infra/dev/eks/README.md) for component-level
rationale.

## 8. Install GitHub Actions Runner Controller

ARC watches GitHub for jobs targeted to its scale set and creates short-lived
runner pods. It scales runner pods, not EC2 nodes.

This repository uses GitHub's official scale-set charts pinned to `0.15.0`:

- `gha-runner-scale-set-controller`
- `gha-runner-scale-set`

This is a tested pin, not an unbounded “latest” chart. Upgrade both charts
together after release review. The runner image still uses an upstream
`latest` tag; pin a tested digest for production.

### Why two namespaces

- `arc-systems` contains the long-lived controller/listener control plane.
- `arc-runners` contains ephemeral job runners.

The Privacera job needs Docker-in-Docker and a privileged DinD sidecar.
Separation prevents that privilege level from applying to the controller and
permits independent policy, quota, and cleanup.

### GitHub setup and PAT

In **Repository → Settings → Actions → General**, allow the workflows needed
by this repository and grant only the repository permissions the workflow
uses. Do not enable PR approval permissions unless a workflow needs them.

Create one of:

- preferred fine-grained PAT: target this repository and grant repository
  **Administration: read and write**;
- classic PAT fallback: `repo` for a private repository runner;
- `admin:org` only for an organization-level runner.

Set an expiry. Prefer a GitHub App for a durable shared environment. Do not
manually base64 the PAT: base64 is not encryption. The Secret template uses
`stringData`; the API encodes it, and EKS KMS protects it at rest.

### Install from the repository

```bash
aws eks update-kubeconfig \
  --region ap-southeast-2 \
  --name privacera-cluster \
  --profile privacera

cd infra/dev/helm
make context

cp actions-runner-controller/github_actions_secret.yml.example \
  actions-runner-controller/github_actions_secret.yml
# Edit the ignored local copy and replace the PAT placeholder.

git check-ignore -v actions-runner-controller/github_actions_secret.yml
make render
make arc
make verify
```

Diagnostics:

```bash
make logs
make events
make watch-runners
```

The scale set is `privacera-dev`, with `minRunners: 0` and `maxRunners: 1`.
No idle runner pod is expected. A pod appears when a job is queued with:

```yaml
runs-on: privacera-dev
```

Validate at **GitHub → Repository Settings → Actions → Runners** and with:

```bash
kubectl get autoscalinglisteners -n arc-systems
kubectl get autoscalingrunnersets,ephemeralrunnersets,ephemeralrunners,pods \
  -n arc-runners -o wide
```

See [`infra/dev/helm/README.md`](infra/dev/helm/README.md) for full details.

## 9. Configure Snowflake PolicySync

Sign in to Snowsight with access to `ACCOUNTADMIN`, open a worksheet, and run
[`snowflake-prerequisites.sql`](custom-vars/connectors/snowflake/test/snowflake-prerequisites.sql).

The idempotent script creates/reconciles:

- role `PRIVACERA_POLICYSYNC_ROLE`;
- XSMALL warehouse `PRIVACERA_POLICYSYNC_WH`, auto-suspend after 600 seconds,
  auto-resume, one cluster, initially suspended;
- imported privileges on `SNOWFLAKE` for audit reads;
- database `PRIVACERA_DB` and schema/function privileges;
- user `PRIVACERA_POLICYSYNC_USER`; and
- the role assignment to that user.

The role can create roles/users, manage grants, and apply masking policies
because these are PolicySync functions. It is a privileged automation identity.
The warehouse intentionally omits `SCALING_POLICY = 'ECONOMY'`.

Run the final row-access grant separately. If it returns error `391811`, use
the resolution in the dedicated known-issues section.

### Set the password privately

Open
[`snowflake-user-password.sql.example`](custom-vars/connectors/snowflake/test/snowflake-user-password.sql.example),
copy its statement into a private worksheet, replace the placeholder with a
generated password, and run it. Do not save rendered SQL in Git. If the
password appeared in a screenshot or shared worksheet, rotate it now.

Keep placeholders in tracked connector YAML:

```yaml
CONNECTOR_SNOWFLAKE_JDBC_PASSWORD: "<PLEASE_CHANGE>"
CONNECTOR_SNOWFLAKE_DEFAULT_USER_PASSWORD: "<PLEASE_CHANGE>"
```

The workflow calls `scripts/render_snowflake_secrets.py` to inject real values
only into its temporary runner checkout.

Run
[`snowflake-validate.sql`](custom-vars/connectors/snowflake/test/snowflake-validate.sql),
then connect as the service user and run:

```sql
SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE();
SELECT 1;
```

Expected values are `PRIVACERA_POLICYSYNC_USER`,
`PRIVACERA_POLICYSYNC_ROLE`, and `PRIVACERA_POLICYSYNC_WH`. See the
[`Snowflake connector README`](custom-vars/connectors/snowflake/test/README.md)
for permission details.

## 10. Add GitHub Actions secrets

Go to **Repository → Settings → Secrets and variables → Actions → New
repository secret** and add:

| Secret | Value/purpose |
| --- | --- |
| `PRIVACERA_HUB_USER` | Username provisioned by Privacera for `hub2.privacera.com`; not the AWS/GitHub username |
| `PRIVACERA_HUB_PASSWORD` | Matching Privacera Hub password |
| `ANSIBLE_VAULT_PASSWORD` | Unique strong password, at least 12 characters |
| `GLOBAL_DEFAULT_SECRETS_KEYSTORE_PASSWORD` | Different unique strong keystore password |
| `EKS_CLUSTER_NAME` | `privacera-cluster` |
| `SNOWFLAKE_JDBC_PASSWORD` | Password assigned to the PolicySync user |
| `SNOWFLAKE_DEFAULT_USER_PASSWORD` | Separate password PolicySync uses for managed users |
| `AWS_ACCESS_KEY_ID` | Temporary quick-development IAM-user key ID |
| `AWS_SECRET_ACCESS_KEY` | Matching temporary secret key |

GitHub masks secrets in normal logs, but masking does not make unsafe shell
construction safe. The workflow avoids deliberately printing them.

## 11. Run the Privacera workflow

Start [`.github/workflows/install.yml`](.github/workflows/install.yml) from
**GitHub → Actions → Privacera Manager Install → Run workflow** with:

```text
deployment_env_type: AWS
aws_region: ap-southeast-2
skip_helm_validation: false
debug_mode: false
```

The workflow:

1. checks out on an ephemeral `privacera-dev` ARC runner;
2. loads non-secret release settings from `variables.env`;
3. installs a Kubernetes 1.32-compatible kubectl, Helm, AWS CLI, and helpers;
4. validates secrets and logs in to `hub2.privacera.com`;
5. configures temporary AWS credentials and EKS kubeconfig;
6. downloads/repairs upstream scripts for the non-root runner;
7. copies tracked custom vars and injects Snowflake secrets at runtime;
8. generates Privacera Helm charts;
9. patches deprecated Kubernetes APIs;
10. patches legacy EBS classes to CSI, encrypted gp3, and
    `WaitForFirstConsumer`;
11. runs `pm_with_helm.sh upgrade` and post-install;
12. uploads service URLs and prints pod status.

Monitor with:

```bash
gh run list --workflow "Privacera Manager Install"
gh run watch <run-id> --exit-status
gh run view <run-id> --log-failed
```

## 12. End-to-end validation

### AWS, Terraform, and EKS

```bash
aws sts get-caller-identity --profile privacera

cd infra/dev/vpc
terraform output
terraform state list

cd ../eks
terraform output
terraform state list
aws eks describe-cluster \
  --name privacera-cluster \
  --region ap-southeast-2 \
  --profile privacera \
  --query 'cluster.{status:status,version:version,endpointPublicAccess:resourcesVpcConfig.endpointPublicAccess,publicCidrs:resourcesVpcConfig.publicAccessCidrs}'

aws eks update-kubeconfig \
  --region ap-southeast-2 \
  --name privacera-cluster \
  --profile privacera
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp
```

### ARC

```bash
cd infra/dev/helm
make verify
make logs
make events
```

Also confirm the runner in **GitHub → Settings → Actions → Runners**. No idle
runner pod is normal because `minRunners` is zero.

### Privacera

```bash
kubectl get all -n candidate-test
kubectl get pods -n candidate-test -o wide
kubectl get pvc -n candidate-test
helm list -n candidate-test

kubectl get pods -n candidate-test \
  --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get events -n candidate-test --sort-by=.lastTimestamp
```

For a failure:

```bash
kubectl describe pod <pod-name> -n candidate-test
kubectl logs <pod-name> -n candidate-test --all-containers --tail=200
kubectl logs <pod-name> -n candidate-test --all-containers --previous --tail=200
```

### Snowflake

Run `snowflake-validate.sql`, then test a fresh connection as the PolicySync
service user. Validation only as `ACCOUNTADMIN` does not prove the service user
can log in or use its defaults.

## 13. Day-two Terraform commands

Run inside the root you intend to manage:

```bash
# Reconfigure or migrate backend settings
terraform init -reconfigure -backend-config=backend.hcl

# Normal plan refreshes remote objects first
terraform plan

# Review and apply state-only refresh
terraform plan -refresh-only -out=refresh.tfplan
terraform apply refresh.tfplan

terraform state list
terraform output
terraform fmt -check
terraform validate
```

Avoid legacy `terraform refresh`, which writes state without a reviewable plan.

## 14. Known errors, issues, and limitations

This is the single troubleshooting and limitations section. The deployment
steps above describe only the intended path; all failures, workarounds,
temporary compromises, and unresolved constraints are collected here.

### 14.1 IAM role assumption blocked by an organization SCP

The `privacera-terraform` role profile failed with an explicit deny similar to:

```text
User arn:aws:iam::102798328535:user/privacera-terraform-operator is not
authorized to perform sts:AssumeRole ... with an explicit deny in service
control policy p-ai0r8shd
```

An AWS Organizations Service Control Policy is an upper permission boundary.
Changing the role trust policy, user policy, or attaching
`AdministratorAccess` cannot override an explicit SCP deny.

**Development resolution:** use the IAM user directly through the
`privacera` profile and the two temporary AWS GitHub secrets.

**Long-term resolution:** have the organization administrator permit an
approved federated/deployment-role path. Then change the workflow to GitHub
OIDC with `role-to-assume`, remove `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`, delete the IAM-user key, and replace
`AdministratorAccess` with least privilege.

### 14.2 Kubernetes and Privacera version constraint

Privacera `9.0.29.1` supports EKS only through Kubernetes `1.32`, which is why
the cluster is pinned to `1.32`. That Kubernetes version is in EKS extended
support, so it has a higher support charge and is not a permanent target.

**Resolution:** upgrade Privacera to a supported release that supports a
current EKS Kubernetes version. Validate the compatibility matrix first, then
upgrade the control plane, managed add-ons, and node group one minor version at
a time.

### 14.3 Free Plan instance restriction and insufficient capacity

The requested node type was `r5.2xlarge` (8 vCPU and 64 GiB RAM), but the
account's Free Plan permitted only selected instance types. We used three
`m7i-flex.large` nodes for development validation. Each node has only 2 vCPU
and 8 GiB RAM, so three of them are not equivalent to the requested Privacera
capacity and leave very little scheduling headroom.

Check the account plan when reevaluating capacity:

```bash
aws freetier get-account-plan-state \
  --profile privacera \
  --region us-east-1
```

The plan is credit-based. EKS support, NAT gateways, EC2, EBS, VPC endpoints,
CloudWatch, and data transfer all consume credits.

**Development resolution:** desired capacity was raised to three
`m7i-flex.large` nodes so the core services could run.

**Long-term resolution:** use `r5.2xlarge` or another Privacera-approved,
properly sized instance type and maintain meaningful CPU/memory headroom.

### 14.4 EKS API unreachable after the public IP changed

The development cluster exposes its public API only to one administrator
`/32`. When the ISP changes that IP, `kubectl` cannot reach the API.

Get the new IP, update `endpoint_public_access_cidrs` in the ignored EKS
`terraform.tfvars`, and apply:

```bash
curl -fsS https://checkip.amazonaws.com
cd infra/dev/eks
terraform plan -out=eks-endpoint.tfplan
terraform apply eks-endpoint.tfplan
aws eks update-kubeconfig \
  --region ap-southeast-2 \
  --name privacera-cluster \
  --profile privacera
kubectl get nodes
```

Never use `0.0.0.0/0` as the shortcut. The production resolution is a
private-only endpoint accessed through VPN, Direct Connect, or a controlled
management host.

### 14.5 Desired node count did not change through Terraform

The EKS module deliberately ignores later managed node-group `desired_size`
drift so Terraform does not fight Cluster Autoscaler or another live capacity
controller. Changing only `node_desired_size` after creation can therefore
show `No changes`.

The live node group was scaled with the EKS API:

```bash
aws eks list-nodegroups \
  --cluster-name privacera-cluster \
  --profile privacera \
  --region ap-southeast-2

aws eks update-nodegroup-config \
  --cluster-name privacera-cluster \
  --nodegroup-name <name-returned-above> \
  --scaling-config minSize=0,maxSize=3,desiredSize=3 \
  --profile privacera \
  --region ap-southeast-2
```

Cluster Autoscaler and Karpenter are not installed. They are not required while
desired capacity remains fixed at three. Install one only when pod demand
should change the EC2 node count. Scale-to-zero also needs an always-on
bootstrap design because ARC and system workloads cannot request new capacity
if nothing remains running.

### 14.6 IRSA/OIDC provider creation denied

The organization SCP denied `iam:CreateOpenIDConnectProvider`, so the EKS
stack could not use IRSA.

**Resolution:** IRSA is disabled and EKS Pod Identity supplies dedicated roles
to VPC CNI and EBS CSI. Any future workload that supports only IRSA needs an
organization-policy exception or must be migrated to Pod Identity.

### 14.7 Legacy ARC resources and missing Docker support

The earlier Summerwind instructions used `RunnerDeployment`, which does not
match GitHub's current scale-set controller. In addition, the Privacera
installer invokes Docker, while an ordinary ARC runner had no usable Docker
daemon.

**Resolution:** use GitHub's official `gha-runner-scale-set-controller` and
`gha-runner-scale-set` charts, plus official `containerMode: dind`. Privileged
runner workloads are isolated in `arc-runners`, the non-privileged controller
stays in `arc-systems`, and concurrency is capped at one.

The minimal non-root runner also did not satisfy assumptions in the downloaded
Privacera scripts. The workflow now:

- installs tools below `RUNNER_TEMP`;
- supplies a curl-backed `wget` wrapper;
- removes the duplicate `docker login` command that exposed the password in
  process arguments; and
- removes an unnecessary `sudo chown` that cannot run in the non-root runner.

### 14.8 Snowflake trial error `391811`

The final prerequisite grant can fail on a Snowflake trial account:

```sql
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT
  TO ROLE "PRIVACERA_POLICYSYNC_ROLE";
```

**Resolution:** run this statement separately so the expected failure cannot
stop the earlier object creation and grants. Role, user, warehouse, audit, and
masking-policy setup remains usable, but Privacera-managed row access policies
remain unavailable until the Snowflake account edition supports them.

### 14.9 A successful workflow did not guarantee healthy pods

Helm can successfully create releases while Kubernetes pods remain Pending,
and a post-install Job can fail after the main releases are present.

**Resolution:** treat the commands in the end-to-end validation section as a
required completion gate. Check pods, events, PVCs, Helm releases, and logs;
do not use the GitHub job color as the only success signal.

### 14.10 Stateful pods and volumes were stuck in one AZ

The generated Privacera 7.0.0 charts used the removed in-tree provisioner
`kubernetes.io/aws-ebs`, `gp2`, and `Immediate` binding. All seven volumes were
created in one AZ before pod scheduling. Pods could not move to otherwise free
nodes in another AZ because EBS volumes have AZ affinity.

The permanent workflow fix runs
[`scripts/patch_privacera_storage_classes.py`](scripts/patch_privacera_storage_classes.py)
and changes generated classes to:

```yaml
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
```

This makes Kubernetes select the consumer node/AZ before EBS CSI provisions
the volume. Equivalent development manifests and additional explanation are
in [`infra/dev/helm/privacera-storage/`](infra/dev/helm/privacera-storage/).

Existing StorageClasses do not migrate existing PVs. Because this was a
disposable no-data environment, we scaled stateful workloads down, deleted the
seven old PVC/PVs and classes, applied the corrected resources, and scaled the
workloads up. The recreated 35 GiB of encrypted gp3 storage spread across the
three AZs.

> **Destructive limitation:** a PV with reclaim policy `Delete` is permanently
> deleted with its claim. Never repeat this migration on valuable data without
> a tested snapshot or backup-and-restore plan.

Validate storage after every deployment:

```bash
kubectl get storageclass
kubectl get pvc -n candidate-test
kubectl get pv \
  -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,AZ:.metadata.labels.topology\\.kubernetes\\.io/zone,STATUS:.status.phase
```

Every claim should be `Bound`, and every PV should be in the AZ of its
consuming pod.

### 14.11 Solr exporter Pending and CrashLoopBackOff

**Symptoms:** the optional `solr-exporter` initially remained `Pending`. Its
pod events reported `Insufficient cpu` on all three nodes and insufficient
memory on two nodes. After lowering its CPU allocation, it scheduled but then
entered `CrashLoopBackOff` with exit code 1.

**Root causes:** this was a combination of three independent conditions:

1. The generated exporter Deployment requested 1 full CPU and 1 GiB memory.
   None of the three `m7i-flex.large` development nodes had 1 CPU of
   unreserved capacity.
2. The generated exporter command connected to
   `https://solr-service...`, while the installed in-cluster Solr service was
   listening over HTTP. An in-cluster test returned HTTP 200 for the HTTP URL
   and a TLS `wrong version number` error for HTTPS.
3. The exporter JVM options referenced
   `/etc/default/global-truststore.p12`. That truststore was not generated or
   mounted for this non-TLS deployment, so Java rejected it as an invalid
   keystore.

**Resolution:** [`custom-vars/vars.sizing.yml`](custom-vars/vars.sizing.yml)
sets the exporter CPU request to `0.25` and limit to `0.5`. Its 1 GiB memory
request and limit remain unchanged to avoid creating a Java out-of-memory
risk. This is sufficient for the pod to fit on the existing third node, so no
fourth node or cluster autoscaler is required for this development setup.

The workflow also runs
[`scripts/patch_privacera_solr_exporter.py`](scripts/patch_privacera_solr_exporter.py)
against both generated chart copies. For this non-TLS deployment, the patch:

- changes the exporter Solr URL from HTTPS to HTTP; and
- removes only the JVM truststore options that reference the missing file.

The patch is applied before `pm_with_helm.sh upgrade`, so future workflow runs
do not restore the broken generated configuration. The final exporter pod was
`1/1 Running` with zero restarts, and its Prometheus endpoint returned HTTP 200
with the expected Prometheus text content type.

Validate the fix with:

```bash
kubectl get deployment,pod -n candidate-test -l app=solr-exporter-app
kubectl get deployment solr-exporter -n candidate-test \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'
kubectl port-forward -n candidate-test deployment/solr-exporter 9854:9854
curl -sS --max-time 60 -o /dev/null \
  -w 'HTTP %{http_code}, %{content_type}\n' http://127.0.0.1:9854/
```

Old `FailedScheduling` and `BackOff` warning events can remain visible until
Kubernetes expires them; confirm the current pod name, readiness and restart
count rather than treating historical events as a current failure.

> **Production limitation:** these settings are specifically for the small,
> non-TLS development environment. Re-evaluate exporter sizing and remove the
> HTTP/non-TLS compatibility patch when using production-sized nodes or when
> Solr TLS is enabled.

### 14.12 Observability post-install limitation

The Privacera deployment installed its built-in monitoring/Grafana components.

The generated `post-install-job` and daily `post-install-cronjob` tried to clone
Privacera's private monitoring-dashboard repository from GitLab over SSH. The
container could reach GitLab, but GitLab rejected the clone because this
environment has no SSH key authorized for that private repository. This was a
dashboard-import failure, not a Grafana service failure; the Grafana pod remained
healthy and available.

**Resolution used here:**

```yaml
# custom-vars/vars.monitoring.yml
MONITORING_ENABLE: "true"
GRAFANA_UPLOAD_COMMON_DASHBOARDS: "false"
POST_INSTALL_JOB_ENABLED: "false"
```

`MONITORING_ENABLE` keeps Grafana and the metrics stack installed. The other two
settings prevent Privacera Manager from cloning the private dashboard repository
and stop it from generating the failing dashboard Job/CronJob. This also avoids
placing the Grafana administrator password directly in that CronJob's environment.
Re-run the installation workflow after changing these values so regenerated
manifests use the new configuration. Existing failed Jobs are only historical
records and can be removed after confirming Grafana is healthy.

If the common Privacera dashboards are required, follow Privacera's
[Grafana post-install recovery guide](https://docs.privacera.com/get-started/base-installation/self-managed/grafana-post-install-failure.html)
and use its public S3 dashboard archive. Do that as a controlled, one-time
operation using a freshly rotated Grafana credential. Do not place the password
in Git, command output, or workflow logs. Review the supplied uploader before
automation because it creates a Grafana service-account token and replaces
matching dashboard folders.

### 14.13 Credential exposure risk

A Snowflake password was visible during the interactive setup. Any credential
shown in a screenshot, saved worksheet, terminal recording, or committed file
must be treated as exposed.

**Resolution:** rotate the Snowflake service-user password, update
`SNOWFLAKE_JDBC_PASSWORD` in GitHub, remove the old value from worksheets and
local files, and verify the tracked connector YAML still contains only
`<PLEASE_CHANGE>`. Apply the same process to any exposed PAT, AWS key, or
Grafana administrator password. The generated Grafana post-install CronJob was
removed because its pod specification stored that password as a plain
environment value; the repository configuration now prevents its recreation.

## 15. Security decisions and production follow-up

Implemented:

- private application/data placement and isolated database routing;
- restricted EKS public endpoint plus private endpoint;
- account guardrails, KMS encryption, audit/flow logs;
- encrypted node/application EBS volumes;
- TLS-only, encrypted, versioned, non-public Terraform state;
- EKS Access Entries and Pod Identity;
- IMDSv2, no node SSH, AL2023, and node repair;
- ignored local secrets and runtime Snowflake secret injection;
- pinned Terraform modules and ARC chart versions.

Before production:

1. Replace IAM-user keys with Identity Center and GitHub OIDC; use least
   privilege instead of `AdministratorAccess`.
2. Rotate credentials exposed in screenshots/worksheets.
3. Upgrade Privacera and EKS out of extended support.
4. Use Privacera-sized nodes and create capacity/HA plans.
5. Choose fixed nodes, Cluster Autoscaler, or Karpenter; add disruption budgets.
6. Make EKS private-only and use VPN/Direct Connect/controlled management host.
7. Add default-deny NetworkPolicies with explicit required egress.
8. Pin images by digest and add image/security scanning.
9. Back up stateful workloads and test restores.
10. Define alerting, budgets, backup, RTO/RPO, and rotation procedures.

## 16. Cost and cleanup

The main costs are EKS extended support, three NAT gateways, EC2 nodes, 300 GiB
of node EBS, Privacera PVCs, VPC endpoints, CloudWatch, and data transfer. Free
Plan credits do not make these free.

For full cleanup:

1. Export/back up required configuration and data.
2. Remove Privacera and ARC Helm releases/PVCs.
3. Set EKS deletion protection false and apply that change.
4. Run `terraform destroy` in `infra/dev/eks`.
5. Run `terraform destroy` in `infra/dev/vpc`.
6. Review retained Flow Log groups, KMS keys pending deletion, EBS
   volumes/snapshots, and S3 versions.
7. Keep the state bucket until recovery is no longer needed.
8. Rotate/delete temporary IAM and GitHub credentials.

Destroy EKS before VPC because EKS depends on the network. EKS deletion
protection intentionally prevents an accidental first destroy.

## 17. Source documentation

- [Privacera compatibility and versions](https://docs.privacera.com/resources/infrastructure/compatibility-and-versions/compatibility-and-versions.html)
- [Privacera Snowflake prerequisites](https://docs.privacera.com/connectors/snowflake/access/prerequisites.html)
- [AWS EKS version lifecycle](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
- [AWS EKS pricing](https://aws.amazon.com/eks/pricing/)
- [GitHub ARC](https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/about-actions-runner-controller)
- [Terraform AWS VPC module](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest)
- [Terraform AWS EKS module](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)

Repository-specific details:

- [`infra/README.md`](infra/README.md)
- [`infra/dev/vpc/README.md`](infra/dev/vpc/README.md)
- [`infra/dev/eks/README.md`](infra/dev/eks/README.md)
- [`infra/dev/helm/README.md`](infra/dev/helm/README.md)
- [`custom-vars/connectors/snowflake/test/README.md`](custom-vars/connectors/snowflake/test/README.md)
