# Development Helm releases

This directory is the source of truth for Helm releases installed into `privacera-cluster`. Terraform continues to own only the VPC and EKS infrastructure; Helm owns these in-cluster releases.

The checked-in Makefile turns the installation into a repeatable repository operation. It uses `helm upgrade --install`, so the same target handles both initial installation and later value/chart upgrades. There is no `helm repo add` step because current GitHub-supported Actions Runner Controller (ARC) charts are distributed as OCI artifacts in GHCR.

## Layout

```text
infra/dev/helm/
├── Makefile
├── namespaces.yml
└── actions-runner-controller/
    ├── github_actions_controller_values.yml
    ├── github_actions_values.yml
    └── github_actions_secret.yml.example
```

- `namespaces.yml` defines separate controller and runner namespaces with Pod Security Admission labels.
- `github_actions_controller_values.yml` configures the ARC controller.
- `github_actions_values.yml` configures the runner scale set and is the file to edit for the GitHub repository/organization URL.
- `github_actions_secret.yml.example` is a safe template. Its real copy is ignored and must never be committed.
- `Makefile` pins the chart version and contains the full Helm commands.

## Current official charts

The older command using `actions-runner-controller/actions-runner-controller` is for the legacy community chart. This configuration uses GitHub's current scale-set charts:

- `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`
- `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set`

Both are pinned to `0.15.0`. Upgrade them together only after reviewing the [official ARC releases](https://github.com/actions/actions-runner-controller/releases).

## Prerequisites

- EKS `privacera-cluster` is running and has at least one ready node.
- Your public IP is still included in the cluster endpoint `/32` allow-list.
- `aws`, `kubectl`, and `helm` are installed.
- Your kubeconfig points to the development cluster.
- You have a GitHub PAT or GitHub App credential with the required runner-management permissions.

For a fine-grained PAT, GitHub requires repository **Administration: read and write** for a repository runner. For an organization runner, it requires organization **Administration: read** and **Self-hosted runners: read and write**. For a classic PAT, the documented scopes are `repo` for repository runners or `admin:org` for organization runners. Use the narrowest target, set an expiry, and prefer a GitHub App for a durable shared environment.

## Configure once

Update kubeconfig and confirm the active target:

```bash
aws eks update-kubeconfig \
  --region ap-southeast-2 \
  --name privacera-cluster \
  --profile privacera

cd infra/dev/helm
make context
```

The checked-in runner values currently target this repository:

```yaml
githubConfigUrl: https://github.com/subhodas09/privacera-manager
```

Change it only if the runners should belong to a different repository or the whole organization/account:

```yaml
# Repository runner
githubConfigUrl: https://github.com/YOUR_ORG/YOUR_REPOSITORY

# Organization runner
githubConfigUrl: https://github.com/YOUR_ORG
```

Create the local Secret manifest and edit only the local copy:

```bash
cp actions-runner-controller/github_actions_secret.yml.example \
  actions-runner-controller/github_actions_secret.yml
```

Replace `REPLACE_WITH_GITHUB_PAT` in that local file. The repository `.gitignore` excludes `*secret*.yml`, so the populated file is not committed. Kubernetes Secrets are base64-encoded API objects, not plaintext files in Git; the EKS control plane's KMS envelope encryption protects this Secret at rest and TLS protects it in transit.

## Install or upgrade

From `infra/dev/helm`, run:

```bash
make arc
```

That single target performs the following in a fixed order:

1. Applies `arc-systems` and `arc-runners` namespaces.
2. Applies the local PAT Secret to `arc-runners`.
3. Runs the pinned controller `helm upgrade --install` command.
4. Runs the pinned runner-scale-set `helm upgrade --install` command.

It uses atomic Helm operations, cleanup on failure, a ten-minute timeout, a five-revision history, and waits for resources to become ready. To inspect manifests before changing the cluster:

```bash
make render
```

Rendered output is written to `.rendered/`, which is ignored by Git.

## Verify

```bash
make verify
```

This validates Helm release status, controller/listener pods, GitHub scale-set registration, ephemeral runner resources, and Secret metadata without printing the PAT. For diagnostics:

```bash
make logs
make events
```

The controller and listener should remain running in `arc-systems`. Runner custom resources and temporary runner pods belong to `arc-runners`. Because `minRunners` is zero, a runner pod appears only when a matching job is queued. A workflow selects this scale set by its scale-set name—not the legacy `[self-hosted, k8s, linux]` label combination:

```yaml
jobs:
  test:
    runs-on: privacera-dev
    steps:
      - uses: actions/checkout@v4
      - run: uname -a
```

While that workflow is queued or running, watch the ephemeral runner lifecycle:

```bash
make watch-runners
```

## Security and capacity choices

- Controller and runner resources are separated into different namespaces.
- Pod Security Admission enforces `baseline` and reports `restricted` violations.
- Containers drop Linux capabilities and cannot gain privileges.
- Ordinary runner pods do not receive a Kubernetes service-account token.
- Resource requests/limits protect the small development node.
- `minRunners: 0` removes idle runner cost; `maxRunners: 1` matches the current `m7i-flex.large` development capacity. Reassess this after switching to `r5.2xlarge` or an approved equivalent.
- No Docker-in-Docker mode is enabled. Docker builds and container jobs require a separately reviewed design because DinD normally introduces privileged containers.
- Private nodes use NAT for outbound HTTPS to GitHub and GHCR; no inbound load balancer is required.
- Self-hosted runners should not execute untrusted fork pull requests with sensitive credentials. Restrict allowed repositories/workflows, protect deployment environments, and pin third-party actions to commit SHAs.

## Adding another Helm release

Create a sibling directory under `infra/dev/helm`, keep non-secret values there, pin the chart version in the Makefile, and add an idempotent `helm upgrade --install` target plus a verification target. Keep credentials in an ignored Secret manifest or, preferably, an approved external secret manager.

Do not run a differently named release or use unreviewed values from another directory; doing so creates duplicate resources and makes later upgrades difficult to reproduce.
