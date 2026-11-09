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

## Public URLs
On EKS, add `public: true` to a Kubernetes-runtime WebService to serve it at `https://<name>-<namespace>.idp.skyforgelab.cloud`. Its URL appears in `kubectl get webservice` and in `status.url`. One shared ALB, created from a Gateway API Gateway, serves every public service, and ExternalDNS publishes the hostnames. See [ADR 0009](docs/adr/0009-public-urls.md).

One-time DNS setup:
1. **Create the zones:** run `make bootstrap`. It creates Route 53 zones for `skyforgelab.cloud` and `idp.skyforgelab.cloud`, the delegation between them, and the wildcard certificate.
2. **Get the nameservers:** run `terraform -chdir=infra/bootstrap output parent_domain_nameservers`.
3. **Point the domain at Route 53:** at the registrar, set the domain's nameservers to those four. ACM validates the certificate once they resolve.

ECS services stay reachable only inside the VPC for now.

## Developer portal
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
- [ ] **3b. Backstage in the cluster:** container image, Postgres, GitHub token and sign-in
- [x] **4. AWS foundations:** account access, budget alerts, VPC and ECS cluster in Terraform, plus infrastructure and cluster pipelines
- [x] **5. EKS:** the same platform on a Terraform-built cluster, with Crossplane using Pod Identity, and Argo CD reading private repos through a GitHub App
- [x] **6. ECS runtime:** run `runtime: ecs` services on Fargate, managed from EKS
- [ ] **7. AWS resources:** add a database to `WebService` for both runtimes
- [x] **8. Traffic:** public HTTPS URLs with Gateway API on EKS, for the Kubernetes runtime
- [ ] **8b. Traffic for ECS:** public URLs for the ECS runtime
- [ ] **9. Guardrails:** Kyverno CEL policies, External Secrets Operator and image signing
- [ ] **10. Observability, cost and scaling:** OpenTelemetry, Prometheus, Grafana, OpenCost, Karpenter and KEDA
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

The account is on the AWS Free plan in eu-north-1. The Free plan denies Spot instances, OIDC providers and `ec2:CreateFleet`, and only allows Free Tier-eligible instance types, so this setup uses on-demand `m7i-flex.large` nodes and Pod Identity, and can't use Karpenter or EKS Auto Mode. See [ADR 0003](docs/adr/0003-local-first-ephemeral-eks.md).

Terraform always creates the VPC, a NAT gateway and the ECS cluster, which cost about $0.05 an hour. Setting `enable_eks=true` adds the EKS cluster, two on-demand nodes and the Pod Identity role for Crossplane, for about $0.38 an hour in total, including the VPC runner. A `$50` monthly budget alert, named `idp-monthly`, excludes credits.

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
| provider-upjet-aws (ECS, EC2, CloudWatch Logs) | 2.9.0 |
| function-environment-configs / function-auto-ready | 0.9.2 / 0.7.3 |
| Crossplane CLI | 2.5.0 |
| AWS Load Balancer Controller | 3.6.2 |
| Gateway API | 1.7.0 |
| Kyverno | 1.19.2 |
| External Secrets Operator chart | 2.14.0 |
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

## License
[MIT](LICENSE)
