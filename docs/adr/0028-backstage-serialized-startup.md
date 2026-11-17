# ADR 0028: Start Backstage's replicas one at a time

**Status:** Accepted (2026-11-17). Tested against a real Postgres and through both Helm charts. It has not run on EKS yet.

## Context
The first EKS session on the `production` profile left Backstage never ready. That profile runs two replicas, and the database is created fresh every session. Both replicas started at once and ran the same migrations against it. The race inserted knex's migration lock row twice in one plugin's database. With two rows, knex can never take its lock (`Migration table is already locked`), so that plugin failed to start for good. Backstage's liveness endpoint kept answering 200, so nothing restarted the pods, and restarting them would not have helped anyway, because the second row stayed. It was repaired by hand, by deleting the duplicate row. Earlier sessions ran the `study` profile, with one replica, so it never showed.

## Decision
Each replica takes a **Postgres advisory lock** before it starts the backend, and holds it until the backend is ready, which means its migrations are done. The next replica starts then, and finds nothing left to migrate. A small Node launcher does this (`gitops/root/files/backstage-start.js`). The Backstage Application mounts it from a ConfigMap and the container runs `node /launcher/start.js node packages/backend`.
- **While a replica waits, the launcher answers the probes itself:** liveness is ok, everything else is not ready. Without that, the chart's startup probe (30 seconds against the liveness URL) would kill a replica that is only waiting, in a loop.
- **A backend that isn't ready within five minutes** (`LAUNCHER_STARTUP_TIMEOUT_MS`) is stopped and the launcher exits with an error, so the pod restarts instead of hanging, and the next replica gets its turn.
- **If the database can't be reached to take the lock,** it starts the backend anyway, after about two minutes of trying. That is no worse than before.
- **The lock is released when the process ends,** however it ends, because it lives on a database connection. A replica that is killed mid-start doesn't block the others.
- **The launcher connects the way Backstage does:** the same `POSTGRES_*` variables, and the RDS CA bundle baked into the image. It uses the `postgres` database for the lock, so every replica takes the same one.
- **It applies to every profile.** With one replica the lock is never contended.
- **Testing:**
  - Nine tests run the real launcher against a real Postgres in Docker, with a fake backend that becomes ready after a delay (`make test-backstage`). They check that replicas start strictly in turn (two and three), that a waiting replica answers its probes, that a backend that never becomes ready is stopped and the next replica goes ahead, that a killed replica releases its turn, that an unreachable database is survived, that SIGTERM reaches the backend, and that the file contains no double braces.
  - Another test renders the Application through the root chart and then the Backstage chart, for both profiles, and checks the command, the mount, the ConfigMap holding the exact file, and that the probes, secrets and replica counts are unchanged.
  - I broke the launcher five ways and the wiring four ways, and a test failed each time.

## Alternatives considered
- **An Argo CD hook that migrates first (PreSync):** it runs before the other resources, so it runs before the External Secrets that provide the database password exist, and would deadlock on every first sync. Sync waves and a Sync hook avoid that, but the chart's own Deployment would have to be annotated into a later wave.
- **Start with one replica and scale up afterwards:** needs something to do the scaling after the first is ready, and Argo CD's self-heal fights a changed replica count.
- **A startup probe on readiness, so a stuck pod restarts:** doesn't help here. Restarting doesn't remove the duplicate lock row.
- **An init container:** can't hold a lock across to the main container, because the lock lives on a connection.
- **A StatefulSet:** starts pods in order, but the chart deploys a Deployment, and rollouts behave differently.
- **Baking the launcher into the image:** cleaner, but every change needs an image build and a new tag. A ConfigMap changes with the Git commit.

## Consequences
- **The second replica starts after the first is ready,** about a minute later, and rollouts serialize too. Backstage's availability at start is unchanged: the first replica serves while the second starts.
- **New code sits in Backstage's startup path.** The fail-open rule, the timeout and the tests are what keep that safe.
- **A migration that takes more than five minutes would be stopped.** Raise `LAUNCHER_STARTUP_TIMEOUT_MS` if that ever happens.
- **It prevents the corruption, and doesn't repair it.** If a lock table ever has two rows, delete the extra one: `DELETE FROM <table> WHERE index > (SELECT MIN(index) FROM <table>)`, in the plugin database that is failing.
- **Not tested on EKS yet.** On the next production-profile session, the second replica's log should say `waiting for the startup lock`, and it should become ready about a minute after the first. A clean "empty account to healthy platform" time can be measured then.
