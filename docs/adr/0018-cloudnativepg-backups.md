# ADR 0018: Back up in-cluster databases as EBS snapshots

**Status:** Accepted (2026-11-13)

## Context
[ADR 0017](0017-rds-backups.md) covered the RDS instances. In-cluster databases, the CloudNativePG clusters a `WebService` gets with `database.class: in-cluster`, still had no backups. CloudNativePG can back up to object storage with the Barman Cloud plugin, or as Kubernetes volume snapshots.

## Decision
- **Volume snapshots on EBS, in the production profile.** The EKS `snapshot-controller` add-on provides the VolumeSnapshot API. An `ebs-snapshots` VolumeSnapshotClass uses the EBS CSI driver, which already has the permissions it needs.
- **The composition adds a backup to each in-cluster database:**
  - `backup.volumeSnapshot` on the CloudNativePG `Cluster`.
  - A `ScheduledBackup` that takes one when the database is created, then every 6 hours.
  - Backups are owned by their database, and snapshots by their backup. So deleting a `WebService` deletes its backups and their EBS snapshots, as it already deletes its data.
- **Snapshots outlive the nightly destroy for 7 days,** like RDS's retained backups. Destroying the cluster doesn't delete them, because the Kubernetes objects disappear with it. The VolumeSnapshotClass tags them `idp/backup=cloudnative-pg`, and the destroy job deletes tagged snapshots older than 7 days.
- **`make cnpg-restore-drill` proves it works.**
  1. It creates a service with an in-cluster database, and writes a marker row.
  2. It takes a backup, and times it.
  3. It restores the snapshot into a new CloudNativePG cluster, and times it.
  4. It checks the marker row is there.
  5. It deletes everything.

## Alternatives considered
- **Barman Cloud to S3:** adds continuous WAL archiving, so point-in-time restore to any second, and copies that are easy to move to another region or account. It needs the Barman Cloud plugin, cert-manager, an S3 bucket, and an IAM role for each database's service account. That's the choice for real production data, and the next step if in-cluster databases hold anything important.
- **AWS Backup or Data Lifecycle Manager for the volumes:** they don't know about Postgres, so the copies wouldn't be consistent unless the database is paused first. CloudNativePG takes the snapshot with Postgres's backup mode on.

## Consequences
- **Restore points are every 6 hours,** not any second. For in-cluster databases with data that matters, use Barman Cloud or the managed class.
- **Snapshots are in the same region and account.** They survive losing a node, an AZ or the cluster, but not the account or the region.
- **The study profile and kind take no backups.** kind has no snapshot support.
- **EBS snapshot storage is billed** for up to 7 days per backup, which is small at this size.
