# Building an Internal Developer Platform on EKS, Part 1: The Architecture, for About $0.40 an Hour

*Crossplane, Argo CD and Backstage on a cluster that's destroyed every night*

I wanted to understand internal developer platforms by building one, not by reading vendor diagrams. So I built one on Amazon EKS from an empty AWS account. It has a self-service API, a developer portal, databases on request, guardrails, dashboards and alerts. It runs only while I'm working on it, and Terraform destroys it every night.

Then I took it further, toward what a production platform needs:
- surviving a lost availability zone
- backups with tested restores
- central logs and network isolation between teams
- dev, staging and prod with promotion
- autoscaling and cost per service

That's still without running production infrastructure around the clock.

This series is the write-up. It's for platform, DevOps and cloud engineers who want to see how the pieces fit, what each choice cost, and what broke along the way. All the code is public: [github.com/kushan94/eks-internal-developer-platform](https://github.com/kushan94/eks-internal-developer-platform).

This first part covers what the platform does, how it's put together, and the constraints that shaped it. The other parts go deeper:

1. **The architecture, for about $0.40 an hour** (this part)
2. One API, two runtimes: Crossplane on Kubernetes and ECS Fargate
3. The golden path: Backstage templates, environments and promotion
4. Databases on demand: shared RDS, CloudNativePG, and restores you've actually tested
5. Guardrails: Pod Security, Kyverno, keyless signing and network isolation
6. Seeing your service: metrics, logs, alerts and cost
7. From study project to production: what it took, and what's still missing

> It started as a learning environment, and the later parts harden it. I'll say plainly what has been tested on EKS and what has only run on a local cluster so far.

## What a developer sees

The whole platform exists to make this file enough:

```yaml
apiVersion: platform.example.org/v1alpha1
kind: WebService
metadata:
  name: visits
spec:
  image: ghcr.io/kushan94/idp-visits:abfad8f
  port: 8080
  replicas: 2
  public: true
  metrics:
    path: /metrics
  database:
    class: managed
```

When it's merged, the developer gets:

- a Deployment and Service, with a security context and resource limits they didn't have to write
- a public HTTPS URL, `https://visits-demo.idp.skyforgelab.cloud`, with DNS and a certificate
- their own PostgreSQL database and login on a shared RDS server, passed in as `DATABASE_URL` and the usual `PG*` variables
- a Prometheus scrape of `/metrics`, a Grafana dashboard with its logs and what it costs per hour, and alerts in Slack when it goes down
- network isolation: only its own namespace, Prometheus and the load balancer can reach it, and it can only reach DNS, its namespace and its database, unless it lists more

Add `runtime: ecs`, and the service runs on ECS Fargate instead, with its database login delivered through Secrets Manager. Public URLs and metrics are Kubernetes-only for now. Change `class: managed` to `class: in-cluster`, and the database becomes a CloudNativePG cluster next to the service.

Services can also run in dev, staging and prod: the same file becomes a shared `base` plus a small override per environment. New builds go to dev automatically, and a Promote workflow opens a pull request that copies the exact image from one environment to the next.

Developers don't have to write any of this. A form in Backstage writes it and opens a pull request for them.

## The architecture

```
 Developer
    │  fills in a form
    ▼
 Backstage ───────────── opens a pull request ──────────────▶ GitHub repo
                                                                   │ merge
                                                                   ▼
 ┌──────────────────────────── EKS cluster ────────────────────────────────┐
 │                                                                         │
 │  Argo CD ── one app per workloads/ folder ──▶ WebService (namespaced XR)│
 │                                                    │                    │
 │                         Crossplane composition (Go templates)           │
 │            ┌───────────────┬───────────────┬──────┴──────┬───────────┐ │
 │            ▼               ▼               ▼             ▼           ▼ │
 │       Deployment      HTTPRoute       PodMonitor     Postgres     ECS  │
 │       + Service      (Gateway API)    (Prometheus)   login + DB  task  │
 │                            │                             │         │   │
 │   Kyverno + Pod Security   │   Prometheus, Grafana,      │         │   │
 │   NetworkPolicies          │   Alertmanager, Loki,       │         │   │
 │                            │   OpenCost                  │         │   │
 └────────────────────────────┼─────────────────────────────┼─────────┼───┘
                              ▼                             ▼         ▼
                  ALB + ACM + Route 53            RDS PostgreSQL   ECS Fargate
                  (via ExternalDNS)               (shared server)
```

The flow, end to end:

1. **Backstage** renders a template into a `WebService` file and opens a pull request as a GitHub App. Nothing calls a cloud API from the portal; Git is the only way in.
2. **Argo CD** watches the repo. An ApplicationSet creates one Argo CD application and one namespace for each folder under `workloads/`.
3. **Crossplane** owns the `WebService` API. A composition, written with Go templates, turns each `WebService` into the resources for its runtime and options.
4. **Controllers do the rest.** The AWS Load Balancer Controller turns HTTPRoutes into an ALB, ExternalDNS writes Route 53 records, and Crossplane's own providers manage RDS logins and ECS services.

### Why these tools

**Crossplane over Terraform modules or ACK + kro.** I wanted the developer API to be a Kubernetes resource, so Argo CD, Backstage and `kubectl` all treat it the same. Crossplane v2's namespaced composite resources fit that well: a `WebService` lives in the team's namespace next to its pods. ACK with kro, through EKS Capabilities, was the main alternative. I picked Crossplane because it isn't tied to AWS and because running it myself teaches more. The cost is that I run and upgrade Crossplane and its providers myself, and its providers use real memory.

**Self-hosted Backstage over a SaaS portal.** A SaaS portal is less work, but it hides most of what I wanted to learn. Backstage runs in the cluster with GitHub sign-in and RDS. Its templates only open pull requests, so the portal never needs cloud credentials.

**Argo CD with one root application.** I apply one Argo CD application by hand. It renders a Helm chart in `gitops/root`, which defines every other application. Dependency order is handled with retries and `SkipDryRunOnMissingResource`, not sync waves. Crossplane creates its CRDs after it starts, so resources using them fail a dry run at first, then succeed on a retry. It's less elegant than waves, but needs no ordering to maintain.

**Everything else is common CNCF tooling:**
- External Secrets for credentials
- Gateway API for routing
- CloudNativePG and provider-sql for databases
- Kyverno for policy
- kube-prometheus-stack for metrics
- Loki and Alloy for logs
- OpenCost for cost

Later parts explain each choice.

## The constraints that shaped it

Three constraints drove more of the design than any tool choice.

### 1. Idle spend is the main risk, so EKS is ephemeral

This is a personal project with $100 of AWS credits. The EKS control plane alone costs $0.10 an hour, so a cluster left running all month would use the whole budget. The design follows from that:

- **Terraform creates the cluster at the start of a session and destroys it at the end.** A full session, with two nodes, NAT, RDS, the load balancer and a CI runner, costs about $0.40 an hour. A typical 1.5-hour session to check a new feature cost me about $0.60.
- **A scheduled workflow destroys everything at 22:00 UTC** in case I forget.
- **Anything that must survive the nightly destroy lives outside the cluster.** That includes the Terraform state bucket, the ECR repository, the Route 53 parent zone, and the Secrets Manager secrets holding GitHub App keys and webhook URLs. A separate, small *bootstrap* Terraform stack creates them once from my laptop.

That last point matters more than it looks. You can't keep credentials only in the cluster, and Sealed Secrets gets awkward, because every new cluster would need the decryption key. External Secrets reading from Secrets Manager through EKS Pod Identity works on a cluster that's ten minutes old.

**Lesson: scheduled workflows are a safety net, not a timer.** GitHub ran my 22:00 destroy as late as 03:56. Once I started an EKS session at 21:55. The destroy queued behind my apply and would have torn the cluster down mid-test, five minutes after it came up.

### 2. The AWS Free plan says no to more than you'd expect

The account is on AWS's newer Free plan. Its service control policies deny:

- **Spot instances**, so the nodes are on-demand.
- **IAM OIDC providers**, so there's no IRSA. Pods get AWS credentials through **EKS Pod Identity** instead, which turned out to be simpler anyway. GitHub Actions can't use OIDC either, so it uses IAM users with access keys, split into a read-only plan user, an apply user behind an approval rule, and a push-only image user.
- **`ec2:CreateFleet`**, which rules out Karpenter and EKS Auto Mode.

It also only allows Free Tier-eligible instance types. That one isn't in the published policies. My first EKS apply created the cluster, the VPC and the NAT gateway, then failed on the node group with `The specified instance type is not eligible for Free Tier`. The half-built cluster cost money until I fixed it. `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true` lists the allowed types. In eu-north-1, the only one with 8 GiB is `m7i-flex.large`.

**Lesson: read the account's limits before writing the Terraform.** `terraform plan` can't see a service control policy. You only find it at apply, after the expensive parts already exist.

When I started hardening the platform, I upgraded the account to the Paid plan to lift those limits. The remaining credits carried over. **The limits didn't lift.** The account reported `PAID` and `ACTIVE`, but it stayed in the organization AWS uses for Free plan accounts, and that organization's policy still denied OIDC providers and `CreateFleet` hours later. I didn't find this by trying and failing: IAM's policy simulator shows the decision without creating anything:

```sh
aws iam simulate-principal-policy --policy-source-arn <your role ARN> \
  --action-names iam:CreateOpenIDConnectProvider ec2:CreateFleet \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

So GitHub OIDC is built and waiting in a pull request. Everything else in the hardening work avoided the denied actions.

### 3. Small nodes run out of pods before memory

Two `m7i-flex.large` nodes have 4 vCPUs and 16 GiB between them. That's enough for Crossplane, Argo CD, Backstage, Kyverno, Prometheus, Grafana and the demo services, though not with much to spare.

What ran out first wasn't CPU or memory. The VPC CNI gives each pod a real VPC IP from the node's network interfaces, and an `m7i-flex.large` gets 29 pod IPs. Once the monitoring stack was in, each node held 29 or 30 pods. CPU requests were at most two-thirds used, but new pods stayed Pending with `Too many pods`. Turning on **prefix delegation** in the `vpc-cni` add-on assigns /28 prefixes instead of single IPs, and raised the limit to 110 per node. Managed node groups pick up the new limit only when they're created, so the add-on must be configured before the nodes. The EKS Terraform module's `before_compute = true` handles that.

## From an empty account to a running platform

Getting from nothing to "Argo CD is syncing" takes four layers. Each one hands credentials to the next without a person copying a token.

```
laptop        make bootstrap       state bucket, IAM users, ECR, Route 53 parent zone,
                                   Secrets Manager secrets (values set with the CLI)
GitHub        Infrastructure       Terraform: VPC, EKS, RDS, IAM roles, a CI runner
Actions         workflow           inside the VPC
in the VPC    runner boots         reads a GitHub App key from Secrets Manager,
                                   registers itself with the repo
in the VPC    Cluster workflow     installs Argo CD and External Secrets with Helm,
                                   applies the root app, waits for all apps to be healthy
in-cluster    Argo CD              everything else from Git, including, from then on,
                                   Argo CD and External Secrets themselves
```

A few details worth copying:

- **The EKS API isn't open to GitHub.** Its public endpoint only allows my IP. Cluster setup runs on a self-hosted runner in a private subnet, which reaches the API through the private endpoint. At boot the runner signs a JWT with a GitHub App key from Secrets Manager, using nothing but `openssl`, and exchanges it for a registration token. No token passes through Terraform or user data.
- **Argo CD needs repo credentials before it can read Git**, so that part can't come from Git. The Cluster workflow installs Argo CD and External Secrets with Helm. External Secrets then turns a GitHub App key in Secrets Manager into an Argo CD credential template.
- **After that, Argo CD manages itself.** An `argocd` Application adopts the Helm release the bootstrap made, reading the same values file. Upgrading Argo CD is then a one-line pull request. That app never prunes and has no deletion finalizer, so a bad render can't make Argo CD delete itself.
- **The Cluster workflow only passes when every Argo CD application is Synced and Healthy.** That check has caught real bugs. For example, Argo CD showed a route as permanently OutOfSync because the API server added default fields the manifest left out.
- **Destroy needs as much care as create.** Controllers still running during `terraform destroy` recreated things I was deleting. The load balancer controller recreated an ALB, which blocked deleting the VPC. ExternalDNS rewrote DNS records a minute after cleanup removed them. The destroy now removes their IAM permissions first, then cleans up.

## Local first: most of it never touches AWS

Each feature was built on kind first. The same root application deploys the platform there, from a Git server in a container. On kind:

- CloudNativePG stands in for RDS.
- Grafana is behind a port-forward.
- The parts that need AWS, such as ECS, ALBs and Route 53, are simply switched off by one Helm value.

Much of the testing needs no cluster at all, and runs with `make test`:

- `crossplane render` and `crossplane resource validate` render the composition for each runtime and database class, and check the output against the providers' schemas.
- `kyverno test` runs the admission policies against sample pods.
- `promtool` unit-tests the alert and cost rules.
- `kubectl kustomize` builds every environment of every service, and the result is validated against the API.
- `make test-template` renders the Backstage template the way Backstage does, and validates what it writes.
- `terraform validate` checks the infrastructure code in a container.

Each one earned its place. I broke a field on purpose, flipped a policy expectation, and removed a filter from an alert rule, and each time the matching test failed.

For anything that depends on runtime behaviour, I used a **throwaway kind cluster** with its own kubeconfig, deleted afterwards. That covered whether a NetworkPolicy really blocks a call, whether the autoscaler scales, and whether Argo CD can adopt itself. That's where the most valuable bugs showed up. The cost rule passed its unit test first time. On a real cluster it returned nothing, because OpenCost publishes its own copy of `kube_pod_labels`, and with two copies Prometheus refuses every join on pod labels. That would also have silently broken the existing "service down" alerts the moment OpenCost was installed. A unit test feeds clean data; it can't find that.

**Offline checks have limits, though.** The ECS provider builds a service ID from `cluster`, which must be the cluster's *name*. I'd passed its ARN, which is just as valid a string to a schema. Only a real apply caught it. An apostrophe in a security group description passed every check and was rejected by EC2. That's why each feature ends with a session on EKS.

**Lesson: make sure a test fails for the reason you think.** Twice, a check I expected to fail did fail, but for the wrong reason. An Argo CD permission test returned 415, not 403, because I'd left out the JSON content type. A password comparison failed because the AWS CLI's text output adds a newline. A test that fails for the wrong reason looks exactly like a pass.

## Where it stands

To be clear about what this is:

- **Two shapes, one switch.** A `profile` input on the Infrastructure workflow picks between them:
  - `study`, what I run day to day: two AZs, one NAT gateway, two nodes and single-AZ databases, at about $0.40 an hour.
  - `production`: three AZs with a NAT gateway and a node in each, Multi-AZ RDS, more replicas of the platform's own components, and seven days of database backups that outlive the nightly destroy. It's roughly $0.60 an hour.
- **Still ephemeral.** Even the production shape is destroyed every night. Logs and backups live in S3 and RDS's retained backups for 7 days, so they survive that; the cluster doesn't.
- **CI still uses IAM users with access keys.** GitHub OIDC is built but waiting for AWS to lift the Free plan organization's policy.
- **No Karpenter, no Spot,** for the same reason. Pods autoscale on CPU, but the node group doesn't grow on its own.
- **One AWS account.** A real platform would separate accounts for production and the rest, under AWS Organizations.
- **Not all of it is verified on EKS yet.** Part 1's architecture, the databases, guardrails, metrics and alerts have run on EKS. The hardening work, covering availability, backups, logs, isolation, environments, autoscaling and cost, has passed its offline tests and its live tests on kind. Later parts say which is which.

What carries over is the shape: one small API, Git as the only way to change anything, controllers doing the work, and credentials that never sit in a repo or on a laptop.

## Next

[Part 2](02-one-api-two-runtimes.md) opens up the `WebService` API: how one Crossplane composition builds Kubernetes resources or an ECS Fargate service from the same file, and how to test a composition without a cluster.
