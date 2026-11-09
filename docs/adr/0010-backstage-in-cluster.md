# ADR 0010: Run Backstage in the cluster

**Status:** Accepted (2026-11-09)

## Context
Backstage ran only on a laptop, with guest sign-in, an allow-all policy and a personal GitHub token. It needs to run in the cluster with real sign-in, a real database and no personal credentials.

## Decision
- **Image:**
  - A multi-stage Dockerfile builds the whole app inside Docker.
  - The Backstage image workflow builds it on every change to `backstage/` on `main` and pushes it to the `idp/backstage` ECR repository, tagged with the commit. The repository keeps immutable tags and scans images on push.
  - The workflow then commits the tag to `gitops/root/values.yaml`, and Argo CD deploys it.
- **CI credentials:** a push-only IAM user, `github-image-push`, in a dedicated `aws-build` environment.
- **Database:** RDS PostgreSQL 18 on `db.t4g.micro`, created with each EKS session and destroyed with it. Backstage rebuilds its catalog from Git, so the data is disposable. The connection uses TLS, verified against the RDS CA bundle baked into the image.
- **GitHub access:** a GitHub App, `<owner>-idp-backstage`, handles both sign-in through OAuth and pull requests (Contents and Pull requests: write). It's installed only on the platform repo. No personal token is involved.
- **Sign-in:** only GitHub users with a matching `User` entity in the catalog can sign in. The guest provider stays configured for local development but refuses sign-ins in production.
- **Secrets:** the app's credentials and the database connection live in Secrets Manager, and External Secrets delivers them through the chart's `extraDeploy`.
- **Account ID:** the ECR address includes the account ID, so `make gitops` passes it to the root app at deploy time rather than committing it.
- **Delivery:** the official Backstage Helm chart, served at `https://backstage.<domain>` by the chart's HTTPRoute on the shared Gateway.

## Consequences
- **Session cost:** sessions take about 5–10 minutes longer, while RDS starts and stops, and cost about $0.02 an hour more.
- **Bot commits:** CI commits to `main`. With branch protection, the workflow would need to open a pull request instead.
- **Permissions:** the allow-all permission policy remains, so every signed-in user can do everything. That's acceptable while only the catalog's users can sign in.
- **Double escaping:** `extraDeploy` goes through Helm's `tpl`, so the ExternalSecret placeholders need escaping twice.

## Update (2026-11-09): catalog model and Kubernetes plugin
- **Catalog model:** the catalog models the platform itself.
  - A `platform` Domain, with an `idp-platform` System for Backstage, Argo CD and Crossplane, and an `idp-services` System for team services.
  - `Resource`s for the EKS and ECS clusters, the database, the shared gateway and DNS.
  - Services name their system and owner, and depend on the cluster their runtime uses. The Web Service template sets this from the runtime.
- **Kubernetes plugin:** shows each service's pods, Deployment, Service, `WebService` and HTTPRoute on its page.
  - The composition labels everything it creates with `backstage.io/kubernetes-id`.
  - Backstage reads the cluster as its own service account, with read-only access that excludes Secrets and ConfigMaps.
  - Metrics lookups are skipped until the cluster has a metrics-server.
- **Argo CD plugin:** Roadie's plugin shows each service's sync status, health and deploy history, using the `argocd/app-name` annotation services already have.
  - It reaches Argo CD through Backstage's proxy, which only signed-in users can call.
  - It uses a read-only Argo CD account, `backstage`, defined in `platform/bootstrap/argocd-values.yaml`.
  - The Cluster workflow creates that account's token for each cluster through Argo CD's API, and stores it only as a Kubernetes secret.
  - The proxy skips TLS verification, because Argo CD's own certificate is self-signed and the traffic stays inside the cluster.

