# EKS Internal Developer Platform

A study project that builds an internal developer platform on Amazon EKS with Crossplane, Argo CD and self-hosted Backstage.

> This is a learning environment, not a production design. See [ADR 0003](docs/adr/0003-local-first-ephemeral-eks.md).

## Quick start
Requires Docker, kind, kubectl and Helm. This runs locally and does not use AWS.

```sh
make local-up    # Create the cluster, then let Argo CD install the platform from Git
make demo        # Wait for the example WebService in workloads/demo
make status      # Show the Argo CD applications
make local-down  # Delete the cluster and local Git server
```

`make local-up` switches your active `kubectl` context to `kind-idp-local` and leaves it there. The Makefile always targets that cluster, but check your context before running your own commands.

A developer only has to write this to get a Deployment and a Service:

```yaml
apiVersion: platform.example.org/v1alpha1
kind: WebService
metadata:
  name: hello
spec:
  image: nginxinc/nginx-unprivileged:1.29-alpine
  port: 8080
  replicas: 2
```

## Choosing a runtime
`WebService` runs on Kubernetes by default. Set `runtime: ecs` to run the same service on ECS Fargate instead:

```yaml
spec:
  runtime: ecs   # or kubernetes
  image: nginxinc/nginx-unprivileged:1.29-alpine
  port: 8080
  replicas: 2
```

| | Kubernetes | ECS Fargate |
|---|---|---|
| **Crossplane creates** | Deployment and Service | ECS service, task definition, security group and log group |
| **Reachable from** | Inside the cluster, at `<name>.<namespace>.svc` | Inside the VPC only, with no DNS name yet |
| **Needs** | Nothing extra | EKS, where Crossplane gets AWS credentials from Pod Identity, plus the `aws-platform` EnvironmentConfig |

The `aws-platform` EnvironmentConfig holds account-specific values, such as subnet IDs, so it is generated and applied directly rather than committed. See [environment.example.yaml](platform/crossplane/aws/environment.example.yaml) for its shape. Without it, an ECS `WebService` reports `Synced=False` with a message naming the missing value.

Run `make test` to render the composition for both runtimes and validate the output against the AWS provider schemas. It needs Docker and the [Crossplane CLI](https://docs.crossplane.io/latest/cli/), but not AWS.

## Databases
Add `database` to a WebService to get a PostgreSQL database. Pick a class, much like a runtime:

```yaml
spec:
  image: ghcr.io/example/orders:1.0.0
  database:
    class: managed   # or in-cluster
```

| | managed | in-cluster |
|---|---|---|
| **What you get** | A database and login on the shared Postgres server (RDS on EKS) | Your own CloudNativePG Postgres cluster in your namespace |
| **Runtimes** | Kubernetes and ECS | Kubernetes only |
| **Created by** | Crossplane's provider-sql | The CloudNativePG operator |

The container gets `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` and `PGSSLMODE`, and on Kubernetes also `DATABASE_URL`, so the app doesn't need to know which class it has.

**Try it:**
- **[visits](apps/visits/main.go)** is a small demo app with a managed database, in dev, staging and prod. Each page view adds a row and shows the count, the database and the login. On EKS it's at `https://visits-demo-<env>.idp.example.com`.
- **`make test-db`** runs an end-to-end check against the current cluster, kind or EKS (`make test-db KUBE_CONTEXT=idp`). It creates services with both classes, logs in with each one's environment, checks that one service can't open another's database, deletes them, and confirms the shared server has nothing left. `kubectl get webservice` shows the class, and `status.database` names the host, database and Secret. Deleting the WebService deletes its database. See [ADR 0011](docs/adr/0011-databases.md).

**Backups:** with the production profile, both RDS instances keep 7 days of automated backups, including point-in-time restore, and keep them after the nightly destroy. **`make rds-restore-drill KUBE_CONTEXT=idp-eks`** restores the shared server to a new instance and checks the data is there. See [ADR 0017](docs/adr/0017-rds-backups.md). In-cluster databases are backed up as EBS snapshots when they're created and every 6 hours, and **`make cnpg-restore-drill`** restores one into a new cluster. See [ADR 0018](docs/adr/0018-cloudnativepg-backups.md).

## Autoscaling
Instead of a fixed `replicas`, a Kubernetes service can scale on CPU:

```yaml
spec:
  autoscaling:
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilization: 70   # optional, % of the CPU request
```

The composition adds a HorizontalPodAutoscaler and leaves the replica count to it. In prod, `minReplicas` must be at least 2. See [ADR 0022](docs/adr/0022-autoscaling.md).

## Environments
A service can run in dev, staging and prod, each in its own namespace (`<team>-dev`, `<team>-staging`, `<team>-prod`) with its own database:

```
workloads/demo/visits/
  base/            the WebService, without an image
  envs/dev/        image and overrides  ->  demo-dev
  envs/staging/    image and overrides  ->  demo-staging
  envs/prod/       image and overrides  ->  demo-prod (at least 2 replicas)
```

New builds of visits go to dev automatically. To move a tested image on, run the **Promote** workflow (Actions → Promote, or `gh workflow run promote.yml -f service=demo/visits -f to=staging`). It opens a pull request that copies the exact image from dev to staging, or staging to prod. Merging it deploys. If the repo doesn't let Actions open pull requests, the run's summary has a one-click link instead.

Backstage's Web Service template creates services with environments by default (**Run in dev, staging and prod**). `make test-template` renders it both ways and validates the result. One Backstage component, dashboard and set of alerts covers every environment, with an environment label to tell them apart. Services written as a single file in `workloads/<team>/` keep working as before. See [ADR 0021](docs/adr/0021-environments.md).

## Public URLs
On EKS, add `public: true` to a Kubernetes-runtime WebService to serve it at `https://<name>-<namespace>.idp.example.com`. Its URL appears in `kubectl get webservice` and in `status.url`. One shared ALB, created from a Gateway API Gateway, serves every public service, and ExternalDNS publishes the hostnames. See [ADR 0009](docs/adr/0009-public-urls.md).

One-time DNS setup:
1. **Create the zones:** run `make bootstrap`. It creates Route 53 zones for `example.com` and `idp.example.com`, the delegation between them, and the wildcard certificate.
2. **Get the nameservers:** run `terraform -chdir=infra/bootstrap output parent_domain_nameservers`.
3. **Point the domain at Route 53:** at the registrar, set the domain's nameservers to those four. ACM validates the certificate once they resolve.

ECS services stay reachable only inside the VPC for now.

## Guardrails
Team namespaces, which Argo CD creates from `workloads/` and `apps/`, enforce:

| Rule | Enforced by |
|---|---|
| Restricted Pod Security: no root, no privilege escalation, capabilities dropped | Kubernetes Pod Security Admission |
| Images have a version tag or digest, never `:latest` | Kyverno `disallow-latest-tag` |
| Images come from `ghcr.io/kushan94`, `ghcr.io/stefanprodan`, `ghcr.io/cloudnative-pg` or `docker.io/nginxinc` | Kyverno `allowed-registries` |
| Containers set CPU and memory requests and a memory limit | Kyverno `require-resources` |
| `ghcr.io/kushan94` images are signed by this repo's workflows on main (cosign keyless) | Kyverno `verify-platform-images` |

WebServices meet these by default. If an image names its user (such as `USER app`) instead of numbering it, set `runAsUser`. When a rule rejects a service, `kubectl get webservice` shows `SYNCED=False` and the condition says which rule and why. `make test` checks the policies against sample pods. See [ADR 0012](docs/adr/0012-guardrails.md).

**Network isolation:** every service only accepts traffic from its own namespace, Prometheus, and the load balancer if it's public. Its in-cluster database also only accepts traffic from its namespace, the CloudNativePG operator and Prometheus. On EKS the VPC CNI enforces this. To let another team's services call yours, list them:

```yaml
spec:
  allowFrom:
    - team: shop            # every service of team shop
    - team: billing
      service: invoices     # only billing's invoices
```

Callers must be in the same environment, so dev can't call prod. See [ADR 0020](docs/adr/0020-network-policies.md).

Outbound traffic is limited too: a service can reach DNS, its own namespace and its database. For anything else, say so:

```yaml
spec:
  allowTo:                  # other teams' services it calls; they list it in allowFrom
    - team: billing
      service: invoices
  allowInternet: true       # public internet, such as external APIs
```

See [ADR 0024](docs/adr/0024-egress-policies.md).

## Metrics, logs, dashboards and alerts
Every cluster runs metrics-server, Prometheus, Grafana and Alertmanager, and Loki and Alloy for logs. If a service serves Prometheus metrics, say where:

```yaml
spec:
  metrics:
    path: /metrics   # and port, if it isn't the service's port
```

The `WebService` dashboard shows any service's pods, CPU, memory, restarts, scrape health and logs, including its in-cluster database. Logs are kept for 7 days, in S3 on EKS, so they outlive the nightly destroy; see [ADR 0019](docs/adr/0019-logs.md). It also shows what the service costs per hour and per month, from OpenCost; see [ADR 0025](docs/adr/0025-cost-per-service.md). Each service's Backstage page links to it. On EKS, Grafana is at `https://grafana.idp.example.com` with GitHub login, for the users listed in `grafanaAdmins` in [values.yaml](gitops/root/values.yaml). On kind, run `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`, and get the admin password from the `kube-prometheus-stack-grafana` secret. See [ADR 0013](docs/adr/0013-observability.md).

One-time Grafana login setup for EKS:
1. **Create a GitHub OAuth app:** GitHub → Settings → Developer settings → OAuth Apps → New. Use homepage `https://grafana.idp.example.com` and callback `https://grafana.idp.example.com/login/github`, then generate a client secret.
2. **Create the secret:** run `make bootstrap` to create the empty Secrets Manager secret.
3. **Store the credentials:** run `aws secretsmanager put-secret-value --secret-id idp/grafana/github-oauth --secret-string '{"clientId":"...","clientSecret":"..."}'`.

Every service gets two alerts: `WebServiceDown` when none of its pods are ready for 5 minutes, and `WebServiceRestarting` when it restarts more than twice in 15 minutes. Each links to the service's dashboard. On EKS, warning and critical alerts go to a Slack or Discord channel; on kind, they show in Grafana only. See [ADR 0014](docs/adr/0014-alerting.md).

One-time alert setup for EKS:
1. **Create an incoming webhook** in Slack, or in Discord under the channel's Integrations → Webhooks. For Discord, add `/slack` to the end of the URL.
2. **Create the secret:** run `make bootstrap` to create the empty Secrets Manager secret.
3. **Store the URL:** run `aws secretsmanager put-secret-value --secret-id idp/alerting/webhook --secret-string '{"url":"..."}'`.

## Developer portal
In the cluster, Backstage runs at `https://backstage.idp.example.com` with GitHub sign-in. See [ADR 0010](docs/adr/0010-backstage-in-cluster.md).

One-time setup for the cluster:
1. **Create the app:** run `scripts/github-app.py create backstage`, then install it **only on this repo**.
2. **Prepare the secret:** run `scripts/github-app.py secret backstage`.
3. **Store it:** run `make bootstrap`, then store the JSON:
   ```sh
   aws secretsmanager put-secret-value --secret-id idp/backstage/github-app \
     --secret-string file://$HOME/.config/eks-idp/github-backstage-app-secret.json
   ```
4. **Set up CI:** run `make github-setup` to give the image workflow its ECR push key.
5. **Build the first image:** run **Actions → Backstage image**. It commits the image tag, and Argo CD deploys Backstage on EKS from then on.

To run it on your laptop instead:

Backstage also needs Node.js 24 and Corepack (`corepack enable`), and a GitHub CLI login. Install its dependencies once, then start it:

```sh
cd backstage && yarn install && cd ..
make backstage  # http://localhost:3000
```

Choose **Create > Web Service**, pick a runtime and fill in the form. Backstage opens a pull request that adds a `WebService` and a catalog entry, and Argo CD deploys it after you merge. Backstage shows the new entry in its catalog after the merge too.

`make backstage` passes your GitHub CLI token to Backstage, and that token can reach all of your repositories. Guest sign-in and the allow-all permission policy are also on, so keep it on your own machine until milestone 3b.

## How changes are deployed
Argo CD reads **commits**, not your working tree, so uncommitted changes have no effect. It checks for new commits about every 3 minutes.

| To do this | Change this |
|---|---|
| Add a team or service | Use the Backstage template, or add a file under `workloads/<namespace>/` |
| Change a platform API | Edit `platform/crossplane/webservice/` |
| Add a platform component | Add an application to `gitops/root/templates/` |
| Upgrade Argo CD or External Secrets | Change `argocd.chartVersion` or `externalSecrets.chartVersion` in `gitops/root/values.yaml`; Argo CD upgrades itself |
| Promote a service | Run the Promote workflow, then merge its pull request |

Locally, Argo CD reads this repo from a Git server on the kind network and follows the branch you have checked out. To use a hosted repo instead, run `make gitops REPO_URL=https://github.com/kushan94/eks-internal-developer-platform.git`.

Deleting a folder under `workloads/` removes its application and resources, but not its namespace.

## Troubleshooting
**`kube-proxy` crash-loops with `too many open files`:** several kind nodes have exhausted the Docker VM's inotify limit. On Colima, this raises it until the next restart:

```sh
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=512
```

## Roadmap
- [x] **1. Local core:** Crossplane, Argo CD and the `WebService` API on kind
- [x] **2. GitOps:** Argo CD deploys the platform and workloads from this repo
- [x] **3. Backstage:** catalog, plus a template that opens a pull request, running locally
- [ ] **3b. Backstage in the cluster:** container image, Postgres, GitHub sign-in *(built and tested locally)*
- [x] **4. AWS foundations:** account access, budget alerts, VPC and ECS cluster in Terraform, plus infrastructure and cluster pipelines
- [x] **5. EKS:** the same platform on a Terraform-built cluster, with Crossplane using Pod Identity, and Argo CD reading private repos through a GitHub App
- [x] **6. ECS runtime:** run `runtime: ecs` services on Fargate, managed from EKS
- [x] **7. Databases:** managed (shared RDS) or in-cluster (CloudNativePG) PostgreSQL on `WebService`, for both runtimes
- [x] **8. Traffic:** public HTTPS URLs with Gateway API on EKS, for the Kubernetes runtime
- [ ] **8b. Traffic for ECS:** public URLs for the ECS runtime
- [x] **9. Guardrails:** Pod Security Admission, Kyverno CEL policies and keyless image signing
- [x] **10. Metrics:** metrics-server, Prometheus, Grafana with GitHub login, a dashboard per service linked from Backstage, and alerts to chat
- [ ] **10b. Tracing, cost and scaling:** OpenCost cost per service and CPU autoscaling are built, and Karpenter node autoscaling is built and verified, on-demand only ([ADR 0029](docs/adr/0029-karpenter-on-demand.md)); OpenTelemetry and KEDA remain
- [ ] **12. Production hardening:** availability profile, backups and restore drills, logs, network isolation, environments and promotion, self-managed Argo CD *(built and tested offline and on kind; EKS verification pending)*
- [ ] **11. Article:** publish the write-up

## Repo access and other repos
Argo CD reads private repos through a GitHub App. The app's credentials live in AWS Secrets Manager, and External Secrets Operator turns them into an Argo CD credential template for every repo under `https://github.com/kushan94`. See [ADR 0007](docs/adr/0007-argocd-repo-access.md).

One-time setup:
1. **Create the app:** run `scripts/github-app.py create`. It opens GitHub's app manifest flow, where you check the app and click **Create**. The app gets read-only *Contents* and *Metadata* access and no webhook. Its ID and private key are saved to `~/.config/eks-idp/`, readable only by you.
2. **Install it:** follow the link the script prints, and install the app on all repos or only the ones Argo CD may read.
3. **Prepare the secret:** run `scripts/github-app.py secret`. It finds the installation ID and writes the secret's JSON to `~/.config/eks-idp/github-app-secret.json`.
4. **Store it:** create the secret with `make bootstrap`, then store the JSON:
   ```sh
   aws secretsmanager put-secret-value --secret-id idp/argocd/github-app \
     --secret-string file://$HOME/.config/eks-idp/github-app-secret.json
   ```

To deploy a service from another repo, add a file to [`apps/`](apps/README.md).

Teams are limited by the `workloads` Argo CD project. They can only create `WebService` resources, only outside the platform's own namespaces, and only from repos under the GitHub account.

## Cluster pipeline
[`.github/workflows/cluster.yml`](.github/workflows/cluster.yml) sets up a new EKS cluster after each successful Infrastructure run, and can also be run by hand:
1. Installs Argo CD and External Secrets, which provides Argo CD's GitHub App credentials
2. Applies the root app, with the AWS providers turned on
3. Applies the `aws-platform` settings from Terraform outputs
4. Waits until every Argo CD application is Synced and Healthy

It runs on a self-hosted runner inside the VPC, created by Terraform with EKS. The runner reaches the private API endpoint with its instance role, so no AWS keys are needed. See [ADR 0008](docs/adr/0008-vpc-runner.md).

One-time setup for the runner's GitHub App:
1. **Create the app:** run `scripts/github-app.py create runner`, then install it **only on this repo**, because it can administer any repo it's installed on.
2. **Prepare the secret:** run `scripts/github-app.py secret runner`.
3. **Store it:** create the secret with `make bootstrap`, then store the JSON:
   ```sh
   aws secretsmanager put-secret-value --secret-id idp/github/runner-app \
     --secret-string file://$HOME/.config/eks-idp/github-runner-app-secret.json
   ```

## Infrastructure pipeline
[`.github/workflows/infra.yml`](.github/workflows/infra.yml) runs Terraform for `infra/terraform`:

| Trigger | What runs |
|---|---|
| Pull request that changes `infra/terraform` | `validate`, then a read-only `plan` (not for pull requests from forks) |
| **Run workflow** with `plan` | `plan` |
| **Run workflow** with `apply` | `plan`, then `apply` after you approve it |
| **Run workflow** with `destroy` | `destroy` after you approve it |
| Every night at 22:00 UTC | `destroy`, without approval. GitHub often starts scheduled runs late, by up to about 3 hours, so destroy manually when you finish. |

Tick **enable_eks** when running the workflow to include the EKS cluster. Before Terraform runs, every destroy deletes the load balancers and DNS records that Kubernetes created, and first removes the load balancer controller's permissions so it can't recreate them. Logs show only resource addresses and actions, because this repo's logs are public. See [ADR 0006](docs/adr/0006-infrastructure-pipeline.md).

One-time setup, from your laptop after `aws login`:

```sh
make bootstrap     # S3 state bucket and the github-plan and github-apply IAM users
make github-setup  # GitHub environments and secrets, from the bootstrap outputs
make tf-init       # Point your local Terraform at the same state
```

The bootstrap stack's state stays in `infra/bootstrap/terraform.tfstate`. It holds the access keys, so it is gitignored. Keep it safe.

## EKS sessions
`make tf-validate` runs Terraform in Docker and does not touch AWS. Creating real resources needs the AWS CLI, Terraform and AWS credentials, and it costs money.

The account is in eu-north-1, and a member of an organization whose policy denies creating OIDC providers and launching Spot instances (a real Spot launch was refused on 2026-11-19), and refuses other regions, so this setup uses on-demand nodes and Pod Identity. It no longer restricts on-demand instance types to the Free Tier's. Karpenter first looked blocked, but that was a false result; it runs on-demand ([ADR 0029](docs/adr/0029-karpenter-on-demand.md)), and EKS Auto Mode hasn't been tried. See [ADR 0003](docs/adr/0003-local-first-ephemeral-eks.md).

Terraform always creates the VPC, a NAT gateway and the ECS cluster, which cost about $0.05 an hour. Setting `enable_eks=true` adds the EKS cluster, two on-demand nodes and the Pod Identity role for Crossplane, for about $0.38 an hour in total, including the VPC runner. A `$50` monthly budget alert, named `idp-monthly`, excludes credits.

The Infrastructure workflow's `profile` input picks the shape. `study`, the default, is the setup above. `production` uses three AZs, with a NAT gateway and a node in each, Multi-AZ RDS, and more replicas of Kyverno, Crossplane, Backstage and in-cluster databases, for roughly $0.60 an hour. In both profiles, every service's pods spread across zones and nodes, with a PodDisruptionBudget when there's more than one. See [ADR 0016](docs/adr/0016-availability-profile.md).

Before a session, sign in with `aws login` and copy `infra/terraform/terraform.tfvars.example` to `terraform.tfvars`. A full EKS session then looks like this:

```sh
terraform -chdir=infra/terraform apply -var enable_eks=true   # or run the Infrastructure workflow
aws eks update-kubeconfig --region eu-north-1 --name idp
make platform-bootstrap gitops KUBE_CONTEXT=<EKS context> REPO_URL=https://github.com/kushan94/eks-internal-developer-platform.git AWS_ENABLED=true
make aws-environment KUBE_CONTEXT=<EKS context>
# ...work...
terraform -chdir=infra/terraform destroy -var enable_eks=true
``` At the end of every session, run `terraform destroy` and confirm in the AWS console that nothing is left running.

## Pinned versions
Latest releases checked on 2026-11-03. Only the first six rows are used so far, and the Terraform has only been validated, not applied. The rest are for later milestones.

| Tool | Version |
|---|---|
| Crossplane chart | 2.4.3 |
| Argo CD chart | 10.11.6 (Argo CD 3.5.6) |
| function-go-templating | 0.13.2 |
| EKS Kubernetes | 1.36 |
| terraform-aws-eks / terraform-aws-vpc | 21.29 / 6.7 |
| Backstage | 1.56.0 (1.56.3 is available) |
| provider-upjet-aws (ECS, EC2, CloudWatch Logs, Secrets Manager) | 2.9.0 |
| function-environment-configs / function-auto-ready | 0.9.2 / 0.7.3 |
| Crossplane CLI | 2.5.0 |
| AWS Load Balancer Controller | 3.6.2 |
| Gateway API | 1.7.0 |
| Kyverno | 1.19.2 (chart 3.9.2) |
| cosign | 3.1.4 |
| External Secrets Operator chart | 2.14.0 |
| provider-sql | 0.16.2 |
| CloudNativePG chart | 0.29.1 (operator 1.30.1) |
| kube-prometheus-stack chart | 92.14.1 (Prometheus Operator 0.94.2) |
| Loki chart / Alloy chart | 7.5.0 (Loki 3.6.16) / 1.15.0 (Alloy 1.21.3) |
| OpenCost chart | 2.5.33 (OpenCost 1.121.3) |
| metrics-server chart | 3.14.0 (metrics-server 0.9.0) |
| Karpenter | 1.15.1 |

## Decisions
- [ADR 0001: Use Crossplane](docs/adr/0001-use-crossplane.md)
- [ADR 0002: Self-host Backstage](docs/adr/0002-self-host-backstage.md)
- [ADR 0003: Build locally first and keep EKS ephemeral](docs/adr/0003-local-first-ephemeral-eks.md)
- [ADR 0004: Structure GitOps with a root application](docs/adr/0004-gitops-structure.md)
- [ADR 0005: Offer Kubernetes and ECS Fargate behind one API](docs/adr/0005-kubernetes-and-ecs-runtimes.md)
- [ADR 0006: Run Terraform from GitHub Actions with access keys](docs/adr/0006-infrastructure-pipeline.md)
- [ADR 0007: Give Argo CD repo access through a GitHub App](docs/adr/0007-argocd-repo-access.md)
- [ADR 0008: Set up clusters from a GitHub runner inside the VPC](docs/adr/0008-vpc-runner.md)
- [ADR 0009: Public URLs through Gateway API and a Route 53 subdomain](docs/adr/0009-public-urls.md)
- [ADR 0010: Run Backstage in the cluster](docs/adr/0010-backstage-in-cluster.md)
- [ADR 0011: Databases for WebServices, managed or in-cluster](docs/adr/0011-databases.md)
- [ADR 0012: Guardrails with Pod Security Admission, Kyverno and signed images](docs/adr/0012-guardrails.md)
- [ADR 0013: Metrics with Prometheus, Grafana and one dashboard per service](docs/adr/0013-observability.md)
- [ADR 0014: Alerts per service, sent to a chat webhook](docs/adr/0014-alerting.md)
- [ADR 0016: A production profile for availability, and spread for every service](docs/adr/0016-availability-profile.md)
- [ADR 0017: RDS backups that survive the nightly destroy, and a restore drill](docs/adr/0017-rds-backups.md)
- [ADR 0018: Back up in-cluster databases as EBS snapshots](docs/adr/0018-cloudnativepg-backups.md)
- [ADR 0019: Logs for every service with Loki and Alloy](docs/adr/0019-logs.md)
- [ADR 0020: Isolate every service's inbound traffic with NetworkPolicies](docs/adr/0020-network-policies.md)
- [ADR 0021: Environments as namespaces, promoted through Git](docs/adr/0021-environments.md)
- [ADR 0022: Autoscale services on CPU with a HorizontalPodAutoscaler](docs/adr/0022-autoscaling.md)
- [ADR 0023: Argo CD manages itself and External Secrets after bootstrap](docs/adr/0023-self-managed-argocd.md)
- [ADR 0024: Limit where services can connect](docs/adr/0024-egress-policies.md)
- [ADR 0025: Cost per service with OpenCost](docs/adr/0025-cost-per-service.md)
- [ADR 0029: Karpenter for node autoscaling, on-demand only](docs/adr/0029-karpenter-on-demand.md)

## License
[MIT](LICENSE)
