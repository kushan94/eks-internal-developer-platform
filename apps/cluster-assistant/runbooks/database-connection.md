---
name: database-connection
description: A service with spec.database can't connect, gets authentication errors, a missing database, TLS errors, too many connections, or its database never becomes ready
tools: get_resource, list_pods, get_pod_logs, get_events
---
# Database connections

**First, which class?** `get_resource` the `WebService` (kind `webservices`): `spec.database.class` is `managed` or `in-cluster`, and `status.database` names the host, database and Secret. The app receives `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE=require`, and on Kubernetes `DATABASE_URL`. The database is named `<namespace>-<service>`, so each environment has its own, and it can't be longer than 63 characters.

**Read the error in the log** (`get_pod_logs`, with `previous: true` if it crashed):
- **Timeout** (no answer): almost always the network policy, since a blocked connection hangs. The service may only reach its own database on its port. See `blocked-traffic`. A host or port other than the one in `status.database` is blocked.
- **Connection refused:** the server isn't listening yet. For `in-cluster`, the database pod isn't ready.
- **`password authentication failed`:** the login or password doesn't match. They come from a Secret the platform creates (`<service>-db-app` for in-cluster, `<service>-db` for managed). Don't paste credentials into the service.
- **`database "…" does not exist`:** Crossplane hasn't created it yet (managed), or the app asks for a different name than `PGDATABASE`.
- **SSL errors:** the platform sets `sslmode=require`, which encrypts but doesn't verify the server's certificate, because the RDS CA isn't in the images' trust stores. An app that uses `verify-ca` or `verify-full` fails. It needs `require`.
- **`too many connections`:** managed databases share one server's connection limit, so a busy service can starve others. Use a smaller connection pool.

**in-cluster:** one CloudNativePG instance and a 1 GiB volume, next to the service. `get_resource` kind `clusters` for `<service>-db`: `status.phase` should be a healthy state and `readyInstances` 1. A stuck volume claim keeps it from starting (load `pending-or-unschedulable`). Its policy (`<service>-db`) allows its namespace, the operator in `cnpg-system` and Prometheus.

**managed:** a database and login on the shared Postgres server (RDS on EKS, a CloudNativePG stand-in on kind), created by Crossplane. If the server is unreachable or the name is too long, the `WebService` stays not Ready. Read its conditions (load `webservice-not-ready`).

**Data is disposable:** deleting the `WebService` drops its database.

**Fix:** in the `WebService` in Git. For anything on the shared server, tell the platform team.
