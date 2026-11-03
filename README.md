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

## How changes are deployed
Argo CD reads **commits**, not your working tree, so uncommitted changes have no effect. It checks for new commits about every 3 minutes.

| To do this | Change this |
|---|---|
| Add a team or service | Add a file under `workloads/<namespace>/` |
| Change a platform API | Edit `platform/crossplane/webservice/` |
| Add a platform component | Add an application to `gitops/root/templates/` |

Locally, Argo CD reads this repo from a Git server on the kind network and follows the branch you have checked out. To use a hosted repo instead, run `make gitops REPO_URL=https://github.com/<you>/eks-idp.git`.

Deleting a folder under `workloads/` removes its application and resources, but not its namespace.

## Troubleshooting
**`kube-proxy` crash-loops with `too many open files`:** several kind nodes have exhausted the Docker VM's inotify limit. On Colima, this raises it until the next restart:

```sh
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=512
```

## Roadmap
- [x] **1. Local core:** Crossplane, Argo CD and the `WebService` API on kind
- [x] **2. GitOps:** Argo CD deploys the platform and workloads from this repo
- [ ] **3. Backstage:** catalog, plus a template that opens a pull request
- [ ] **4. EKS:** the same platform on a Terraform-built cluster
- [ ] **5. AWS resources:** add a database to `WebService` with the Crossplane AWS provider and Pod Identity
- [ ] **6. Traffic:** Gateway API with the AWS Load Balancer Controller
- [ ] **7. Guardrails:** Kyverno CEL policies, External Secrets Operator and image signing
- [ ] **8. Observability and cost:** OpenTelemetry, Prometheus, Grafana and OpenCost
- [ ] **9. Scaling:** Karpenter and KEDA
- [ ] **10. Article:** publish the write-up

## EKS sessions
`make tf-validate` runs Terraform in Docker and does not touch AWS. Creating real resources needs the AWS CLI, Terraform and AWS credentials, and it costs money.

Before a session, set a budget alert and copy `infra/terraform/terraform.tfvars.example` to `terraform.tfvars`. At the end of every session, run `terraform destroy` and confirm in the AWS console that nothing is left running.

## Pinned versions
Latest releases checked on 2026-11-03. Only the first five rows are used so far, and the Terraform has only been validated, not applied. The rest are for later milestones.

| Tool | Version |
|---|---|
| Crossplane chart | 2.4.3 |
| Argo CD chart | 10.11.6 (Argo CD 3.5.6) |
| function-go-templating | 0.13.2 |
| EKS Kubernetes | 1.36 |
| terraform-aws-eks / terraform-aws-vpc | 21.29 / 6.7 |
| Backstage | 1.56.3 |
| provider-upjet-aws | 2.9.0 |
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
