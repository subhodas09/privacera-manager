# Privacera customer deployment: one-page retrospective

## Outcome

I built a reproducible Privacera development environment on AWS: a three-tier,
three-AZ VPC, EKS, encrypted EBS storage, GitHub Actions Runner Controller,
Privacera, and Snowflake PolicySync. All 13 Helm releases deployed, core services
became healthy, the portal was reachable, and Privacera users/groups synchronized
to Snowflake. Git contains placeholders; secrets are injected at runtime.

This is a development setup. Free Plan restrictions required three
`m7i-flex.large` nodes instead of `r5.2xlarge`; an organization SCP forced
temporary IAM-user keys instead of OIDC/roles; and the public EKS endpoint is
restricted to one administrator `/32` rather than private-only.

## What went well

- Clear ownership: Terraform for AWS, Helm/Kubernetes for cluster software, and
  dedicated stores for credentials.
- Strong baseline: private application/data placement, encryption, IMDSv2, no
  node SSH, control-plane/flow logs, EKS access entries, and Pod Identity.
- Evidence-led diagnosis: events exposed scheduling/storage failures; logs
  exposed Solr errors; connector logs and Snowflake queries proved sync.
- Permanent fixes: chart transforms, runtime secret rendering, and release
  validation are now repeatable code rather than live-cluster commands.

## What cost the most time

Generated charts assumed a larger, older environment. Legacy `gp2`/in-tree
StorageClasses caused AZ/PVC failures; immutable fields and Helm history slowed
migration. Solr exporter had both capacity and protocol/truststore failures. A
private GitLab dependency broke optional dashboard import. The Snowflake
connector used an obsolete endpoint and needed explicit entity settings plus a
redeploy. The lesson: green tooling is not the outcome—ready workloads, bound
storage, connector convergence, and a successful user transaction are.

## Top three improvements

| Improvement | Impact | Evidence it worked |
| --- | --- | --- |
| **Three-minute preflight gate** for identity/SCPs, quotas, versions, capacity, CSI, secrets, connectivity, JDBC identity, and grants. | One actionable report before installation. | Under 3 minutes; catches every known prerequisite failure; no secret output; fewer failed first runs. |
| **Idempotent deployment and health gates** for generated manifests, Helm releases, workloads, PVCs, portal, and connector. | Makes pipeline green mean customer-usable. | No failed releases/Pending workloads; synthetic checks pass; second run needs no manual action. |
| **Default support dashboard and runbook-linked alerts** for infrastructure, Kubernetes, Helm, portal, and connector. | Finds the failing layer without tribal knowledge. | Detection under 2 minutes; game-day recovery under 15; over 90% actionable alerts; measured portal SLO. |

## How I handle an incident

I state customer impact and what still works, rank hypotheses, collect events,
logs, release/configuration state and audits, then change one variable at a
time. I use the smallest reversible mitigation and verify platform health plus
a synthetic user operation. Updates include time, impact, facts, hypothesis,
action/owner, workaround, and next-update time.

The blameless review records impact, timeline, detection, technical and
contributing conditions, mitigation, proof of recovery, and owned/measurable
actions. The EBS incident, for example, came from generated legacy classes,
multi-AZ scheduling, and immutable fields—not an individual.

## Demo evidence to bring

- Clean tested commit, README, this page, and successful/failed-run evidence.
- Healthy nodes, pods, PVCs, releases, portal, connector, and Snowflake objects.
- RBAC hierarchy/edit/access/audits and tag-driven access-change evidence.
- Dashboard, alert route, safe fault, diagnosis, recovery, and cleared alert.
- Sanitized screenshots/recording as the network and audit-latency fallback.
