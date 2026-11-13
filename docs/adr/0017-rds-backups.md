# ADR 0017: RDS backups that survive the nightly destroy, and a restore drill

**Status:** Accepted (2026-11-13)

## Context
Both RDS instances, Backstage's and the shared server for managed `WebService` databases, kept no backups, so every destroy lost their data. That was fine for throwaway study sessions, but production needs to answer "can we get yesterday's data back, and how long does it take?" The nightly destroy deletes the instances themselves, so backups that are deleted with their instance don't help.

## Decision
- **In the production profile ([ADR 0016](0016-availability-profile.md)), both instances keep 7 days of automated backups.** That also enables point-in-time restore to any second in the window.
- **`delete_automated_backups = false`:** RDS keeps those backups after the instance is deleted, until they expire. So the morning after a destroy, last night's data can still be restored.
- **No final snapshots.** Manual snapshots never expire, so one per nightly destroy would pile up. The retained automated backups cover the same need.
- **Deletion protection stays off.** The nightly destroy must be able to delete the instances, and the retained backups are the safety net instead.
- **`make rds-restore-drill` proves the backups work.**
  1. It writes a marker row to the shared server.
  2. It waits until RDS can restore to a point after the marker.
  3. It restores to a new instance, and times it.
  4. From a pod in the cluster, it checks the copy has the marker and the same databases.
  5. It deletes the copy and the marker, even when a check fails.
- **The study profile is unchanged:** no backups, quick to create and delete.

## Alternatives considered
- **AWS Backup:** central policies and cross-account copies, which a multi-account setup would want. More setup than one account needs.
- **Deletion protection with a destroy step that turns it off first:** protects against accidental deletes, but the nightly destroy is a planned delete, so it would only add a step.
- **Restoring automatically at apply time:** the next session could restore last night's data with `snapshot_identifier`. For services' databases that would leave provider-sql's logins out of step with Kubernetes, so it's left as a manual step.

## Consequences
- **Retained backups cost a little.** Each session's backups stay for 7 days, billed as backup storage. They're small at this size.
- **Instance creation takes a few minutes longer** in production, while RDS takes the first backup.
- **Recovery time is measured, not assumed.** The drill prints how long the restore took.
- **In-cluster databases are covered separately,** in [ADR 0018](0018-cloudnativepg-backups.md).
