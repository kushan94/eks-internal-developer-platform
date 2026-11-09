# ADR 0011: Databases for WebServices, managed or in-cluster

**Status:** Accepted (2026-11-09)

## Context
Most services need a database. Developers should get one by asking for it in their `WebService`, without filing a ticket or learning RDS. The platform runs on a $50-a-month budget, and EKS is recreated every session, so a database per service on RDS would cost about $15 a month each and take 10 minutes to create.

## Decision
`spec.database.class` on a `WebService` offers two classes, the same way `runtime` offers two runtimes:

- **managed:** a database and login on one shared Postgres server.
  - On EKS the server is an RDS PostgreSQL 18 `db.t4g.micro`, created by Terraform with the cluster. On kind a CloudNativePG cluster stands in for it, so the class works and can be tested without AWS.
  - Crossplane's provider-sql creates a `Role` (with a generated password), a `Database` owned by it, and a `Grant` that revokes `CONNECT` from everyone else. Each is named `<namespace>-<name>`.
  - RDS's admin isn't a superuser, so a second `Grant` makes it a member of each service's role, which Postgres requires before it can create a database owned by that role.
  - Works on both runtimes. ECS can only read secrets from AWS, so Crossplane copies the password to Secrets Manager (`idp/workloads/<namespace>/<name>/database`), and the task definition waits until it is there.
- **in-cluster:** a CloudNativePG `Cluster` next to the service, with one instance and a 1 GiB volume. Kubernetes runtime only, since ECS tasks can't reach pods. EKS gets the EBS CSI driver and a default `gp3` StorageClass for the volume.

Either way, the container gets the standard libpq variables (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` and `PGSSLMODE=require`), and on Kubernetes also `DATABASE_URL`, so an app works with either class unchanged. `status.database` names the host, database and Secret.

## Alternatives considered
- **RDS per service:** strongest isolation and closest to production, but too slow and expensive for ephemeral sessions on this budget.
- **CloudNativePG only:** cheapest, but ECS services couldn't use it.
- **A separate `Database` API:** cleaner reuse, but developers would have to connect two resources. A field on `WebService` keeps the golden path to one file. It can be split out later.

## Consequences
- **Isolation:** managed databases share one server's CPU, memory and connection limit. One busy service can slow the others. Logins can't connect to each other's databases.
- **Data is disposable:** deleting a `WebService` drops its database, and the nightly destroy deletes everything. Neither class has backups yet.
- **TLS:** provider-sql and services use `sslmode=require`, which encrypts but doesn't verify the server certificate, because RDS's CA isn't in their trust stores.
- **Name length:** Postgres names are limited to 63 characters, so `<namespace>-<name>` must fit. The composition fails with a clear message if it doesn't.
- **Cleanup:** Crossplane can't delete the Secrets Manager copies once the cluster is gone, so the destroy job removes Crossplane's AWS permissions and then deletes them.
