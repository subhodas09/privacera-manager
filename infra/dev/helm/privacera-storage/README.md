# Privacera EBS CSI storage

Privacera 7.0.0 generates StorageClasses with the removed in-tree
`kubernetes.io/aws-ebs` provisioner and `Immediate` volume binding. In a
multi-AZ EKS node group, `Immediate` binding can create every EBS volume in
one Availability Zone before the Kubernetes scheduler chooses nodes. Pods
using those volumes then cannot move to otherwise available nodes in another
AZ.

The GitHub installation workflow runs
`scripts/patch_privacera_storage_classes.py` against the generated vendor
charts before Helm deployment. The patch changes only StorageClass templates:

- Provisioner: `ebs.csi.aws.com`
- Volume type: encrypted `gp3`
- Binding mode: `WaitForFirstConsumer`

`storageclasses.yml` contains the equivalent live definitions for the dev
environment. `pvcs.yml` contains the four claims managed directly by Helm;
the Audit Server, Solr, and ZooKeeper claims are recreated by their
StatefulSet volume claim templates.

Changing a StorageClass does not migrate existing volumes. Existing claims
must be deleted and recreated, which permanently deletes their data when the
PV reclaim policy is `Delete`. Only perform that migration for disposable
development data or after completing an appropriate backup and restore plan.
