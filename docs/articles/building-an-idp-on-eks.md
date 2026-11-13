# I Built an Internal Developer Platform on EKS for About $0.40 an Hour. Here's What It Took.

*Crossplane, Argo CD and Backstage on a cluster that's destroyed every night, then hardened toward production*

I wanted to understand internal developer platforms by building one, not by reading vendor diagrams. So I started from an empty AWS account and built one on Amazon EKS.

It has:
- a self-service API and a developer portal
- databases on request
- guardrails, network isolation between teams
- dev, staging and prod with promotion
- autoscaling, and dashboards with logs, alerts and cost per service

It runs only while I'm working on it, and Terraform destroys it every night.

This is the write-up, for platform, DevOps and cloud engineers who want to see how the pieces fit, what each choice cost, and what broke along the way. The code is public, with a decision record for every choice: [github.com/kushan94/eks-internal-developer-platform](https://github.com/kushan94/eks-internal-developer-platform).

> It started as a learning environment and grew toward production. I'll say plainly what has been tested on EKS and what has only run on a local cluster so far.

## 1. What a developer gets

The whole platform exists to make this file enough:

```yaml
apiVersion: platform.example.org/v1alpha1
kind: WebService
metadata:
  name: visits
spec:
  image: ghcr.io/kushan94/idp-visits:52c8920
  port: 8080
  replicas: 2
  public: true
  metrics:
    path: /metrics
  database:
    class: managed
```

When it's merged, the developer gets:

- **A Deployment and Service,** with a security context, resource limits, spread across zones and a PodDisruptionBudget, none of which they had to write.
- **A public HTTPS URL,** with DNS and a certificate.
- **Their own PostgreSQL database and login** on a shared RDS server, passed in as `DATABASE_URL` and the usual `PG*` variables.
- **A Grafana dashboard** with their metrics, logs and cost per hour, and **alerts in Slack** when the service goes down.
- **Network isolation.** Only their own namespace, Prometheus and the load balancer can reach the service. It can only reach DNS, its namespace and its database, unless it lists more.

Add `runtime: ecs` and the service runs on ECS Fargate instead. Change `class: managed` to `class: in-cluster`, and the database becomes a CloudNativePG cluster next to the service. Add an `autoscaling` block, and it scales on CPU.

Developers don't write the file themselves. A Backstage form writes it, in dev, staging and prod by default, and opens a pull request.

## 2. The architecture

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
2. **Argo CD** watches the repo. ApplicationSets create one Argo CD application and namespace for each team folder, or for each environment of a service.
3. **Crossplane** owns the `WebService` API. One composition, written with Go templates, turns each `WebService` into the resources for its runtime and options.
4. **Controllers do the rest.**
   - The AWS Load Balancer Controller turns HTTPRoutes into an ALB, and ExternalDNS writes the Route 53 records.
   - Crossplane's providers manage database logins and ECS services.

### Why these tools

**Crossplane over Terraform modules or ACK + kro.** I wanted the developer API to be a Kubernetes resource, so Argo CD, Backstage and `kubectl` all treat it the same. Crossplane v2's namespaced composite resources fit: a `WebService` lives in the team's namespace next to its pods. I picked it over ACK with kro because it isn't tied to AWS, and because running it myself teaches more. The cost is that I upgrade Crossplane and its providers myself, and the providers use real memory.

**Self-hosted Backstage over a SaaS portal.** A SaaS portal is less work, but it hides most of what I wanted to learn. Backstage runs in the cluster with GitHub sign-in and RDS. Its templates only open pull requests, so the portal never needs cloud credentials.

**Argo CD with one root application.** I apply one Argo CD application by hand. It renders a Helm chart that defines every other application. Dependency order is handled with retries and `SkipDryRunOnMissingResource`, not sync waves. Crossplane creates its CRDs after it starts, so resources using them fail a dry run at first, then succeed on a retry. It's less elegant than waves, but there's no ordering to maintain.

**The rest is common CNCF tooling:**
- External Secrets for credentials
- Gateway API for routing
- CloudNativePG and provider-sql for databases
- Kyverno for policy
- kube-prometheus-stack for metrics
- Loki and Alloy for logs
- OpenCost for cost

### One API, two runtimes

Kubernetes suits teams that want its ecosystem, and ECS Fargate is simpler to run for ordinary web services. `spec.runtime` lets a developer choose without learning two toolsets: the same composition builds either a Deployment and Service, or an ECS task definition and service. The `WebService` stays in Kubernetes either way, so Git, Argo CD and Backstage work the same.

The catch is that every feature has to exist twice, or say clearly that it doesn't. Public URLs, metrics, autoscaling and network policies are Kubernetes-only for now. An ECS `WebService` that asks for them fails with a message saying so, rather than half-working.

Two details only a real apply caught:
- **The service ID needs the cluster's name, not its ARN.** The ECS provider builds the service's ID from its `cluster` field. I'd passed the ARN, which is just as valid a string to a schema, so offline validation passed.
- **An apostrophe broke a security group.** It was in the group's description, passed every check, and EC2 rejected it.

## 3. Running it for $0.40 an hour

Three constraints drove more of the design than any tool choice.

### The cluster is ephemeral

This is a personal project on AWS credits. The EKS control plane alone costs $0.10 an hour, so a cluster left running would burn through them. So:

- **Terraform creates the cluster at the start of a session and destroys it at the end.** A full session costs about $0.40 an hour: two nodes, NAT, RDS, the load balancer and a CI runner.
- **A scheduled workflow destroys everything at 22:00 UTC,** in case I forget.
- **Anything that must survive lives outside the cluster:** the Terraform state, the ECR repository, the DNS zones and certificate, and the GitHub App keys in Secrets Manager. A small *bootstrap* Terraform stack creates them once.

That last point shapes everything. Credentials can't live only in the cluster. Sealed Secrets gets awkward too, because each new cluster would need the decryption key. External Secrets, reading Secrets Manager through EKS Pod Identity, works on a cluster that's ten minutes old.

**Lesson: scheduled workflows are a safety net, not a timer.** GitHub has run my 22:00 destroy as late as 03:56. Once I started a session at 21:55, and the destroy queued behind the apply. It would have torn the cluster down mid-test.

### The AWS Free plan says no to more than you'd expect

The account started on AWS's Free plan, whose service control policies deny:
- **Spot instances.**
- **IAM OIDC providers.** So no IRSA, and Pod Identity instead, which turned out simpler. It also meant no GitHub OIDC, so CI uses IAM users with access keys: a read-only plan user, an apply user behind an approval rule, and a push-only image user.
- **`ec2:CreateFleet`,** which rules out Karpenter and EKS Auto Mode.

It also only allows Free Tier instance types, which isn't in the published policies. My first EKS apply created the cluster, VPC and NAT gateway, then failed on the node group with `The specified instance type is not eligible for Free Tier`, and the half-built cluster cost money until I fixed it. `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true` lists what's allowed. In eu-north-1, the only type with 8 GiB is `m7i-flex.large`.

When I started hardening the platform, I upgraded the account to the Paid plan to lift those limits. **They didn't lift.** The account reported `PAID` and `ACTIVE`, but it stayed in the organization AWS uses for Free plan accounts, whose policy still denied OIDC and `CreateFleet` hours later. IAM's policy simulator shows this without creating anything:

```sh
aws iam simulate-principal-policy --policy-source-arn <your role ARN> \
  --action-names iam:CreateOpenIDConnectProvider ec2:CreateFleet \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

**Lesson: read the account's limits before writing Terraform.** `terraform plan` can't see a service control policy. You only find it at apply, after the expensive parts exist.

### Small nodes run out of pods before memory

Two `m7i-flex.large` nodes have 4 vCPUs and 16 GiB between them. What ran out first wasn't CPU or memory, though. The VPC CNI gives each pod a real VPC IP from the node's network interfaces, and this type gets 29. Once the monitoring stack was in, both nodes were full at 29 or 30 pods. CPU requests were at most two-thirds used, and new pods sat in `Pending` with `Too many pods`.

**Prefix delegation** in the `vpc-cni` add-on hands out /28 prefixes instead of single IPs, which raised the limit to 110. Managed node groups only read it when they're created, so the add-on has to be configured first; the EKS module's `before_compute = true` handles that.

### From an empty account to a running platform

Getting to "Argo CD is syncing" takes five steps. Each hands credentials to the next without a person copying a token:

```
laptop        make bootstrap       state bucket, IAM, ECR, DNS zones, certificate,
                                   Secrets Manager secrets (values set with the CLI)
GitHub        Infrastructure       Terraform: VPC, EKS, RDS, IAM roles, a CI runner
Actions         workflow           inside the VPC
in the VPC    runner boots         reads a GitHub App key from Secrets Manager,
                                   registers itself with the repo
in the VPC    Cluster workflow     installs Argo CD and External Secrets with Helm,
                                   applies the root app, waits for every app to be healthy
in-cluster    Argo CD              everything else from Git, including, from then on,
                                   Argo CD and External Secrets themselves
```

Details worth copying:
- **The EKS API isn't open to GitHub.** Its public endpoint only allows my IP. Cluster setup runs on a self-hosted runner in a private subnet. At boot, the runner signs a JWT with a GitHub App key using nothing but `openssl`, and exchanges it for a registration token.
- **Argo CD manages itself after bootstrap.** An `argocd` Application adopts the Helm release the bootstrap installed, reading the same values file, so upgrading Argo CD is a one-line pull request. It never prunes and has no deletion finalizer, so a bad render can't make Argo CD delete itself.
- **The Cluster workflow only passes when every Argo CD app is Synced and Healthy.** That check has caught real bugs. Several were fields that the API server or a controller fills in, which Argo CD then reported as drift forever. Server-side diff fixed most of them.
- **Destroy needs as much care as create.** Controllers still running during `terraform destroy` recreated what I was deleting: the load balancer controller rebuilt an ALB, and ExternalDNS rewrote records. The destroy now removes their IAM permissions first.

## 4. The golden path: Backstage, environments and promotion

Backstage is the front door. A Web Service template asks for a name, team, runtime, image, port, database, whether it's public and whether to autoscale. It then opens a pull request through a GitHub App, so no personal token is involved. The catalog models the platform itself: domains, systems, the clusters and the shared database as resources. Each service's page shows:
- its pods, from the Kubernetes plugin
- its Argo CD sync status, through a read-only Argo CD account
- links to its URL and dashboard

**Environments are namespaces.** A service with environments is a Kustomize layout, a shared `base` plus a small override per environment:

```
workloads/demo/visits/
  base/          the WebService, without an image
  envs/dev/      image + overrides  ->  namespace demo-dev
  envs/staging/  image + overrides  ->  namespace demo-staging
  envs/prod/     image + overrides  ->  namespace demo-prod
```

An ApplicationSet turns each `envs/*` folder into an Argo CD app, and labels the namespace with its environment. A Kyverno policy keys on that label: in prod, a service needs at least two replicas. If it autoscales, the policy checks the autoscaling minimum, so `replicas: 3` with `minReplicas: 1` is still refused.

I chose namespaces over a cluster per environment because separate clusters would multiply the cost of every session. The Git layout maps onto separate clusters later by changing each environment's destination.

**Promotion is a pull request.** CI writes each new image to dev only. A Promote workflow copies the exact image dev runs into staging, or staging's into prod, and opens a pull request showing the old and new image. Merging it deploys. So prod only ever runs what staging ran.

One environment-specific trap: each environment must get its own database. The managed database is named after the namespace and service, `demo-prod-visits`, never after the shared Backstage ID, so dev can never touch prod's data.

## 5. Databases, guardrails and isolation

### Databases

`spec.database.class` offers two classes:
- **`managed`:** a database and login on one shared RDS server. Crossplane's provider-sql creates the role, the database and a grant that revokes `CONNECT` from everyone else.
- **`in-cluster`:** a CloudNativePG cluster next to the service.

Either way, the app gets the standard `PG*` variables, so it works with either class unchanged.

Two things surprised me:
- **RDS's admin isn't a superuser.** Since Postgres 16 it can't create a database owned by another role unless it's a member of that role. The composition grants that membership, and Crossplane retries until it exists.
- **ECS can't read Kubernetes Secrets.** For ECS services, the composition copies the password to Secrets Manager, and holds back the task definition until the secret exists.

**Backups that outlive the nightly destroy.** In the production profile, RDS keeps 7 days of automated backups with point-in-time restore. It also keeps them after the instance is deleted, which is what makes them useful when the cluster disappears every night. In-cluster databases get EBS snapshots on a schedule. Both come with a restore drill that writes a marker row, restores to a new instance or cluster, checks the row is there, and times the whole thing. A backup you haven't restored isn't a backup.

### Guardrails

Team namespaces get guardrails through labels Argo CD sets when it creates them:
- **Pod Security Admission's `restricted` profile.**
- **Kyverno CEL policies:** no `:latest`, approved registries only, and resource requests required.
- **Keyless image signing.** CI signs images with cosign using its GitHub identity, and Kyverno only admits `ghcr.io/kushan94` images signed by this repo's workflows on `main`. There are no signing keys to store or rotate.

The composition sets secure defaults, so anything created through the golden path passes. When a policy refuses something, the reason shows up in the `WebService`'s `Synced` condition, not in a log nobody reads.

### Network isolation

Each `WebService` gets a NetworkPolicy:
- **Inbound:** its own namespace, Prometheus and, for public services, the load balancer's subnets.
- **Outbound:** DNS, its own namespace and its database.

Anything else is declared:

```yaml
spec:
  allowFrom:            # who may call it
    - team: shop
  allowTo:              # what it calls
    - team: billing
      service: invoices
  allowInternet: true   # public internet; private ranges, including 169.254.169.254, stay blocked
```

Two traps are worth knowing:

- **One entry with two selectors is AND; two entries are OR.** "Billing's invoices service" has to put the namespace and pod selectors in the same `from` entry. Split into two entries, any pod named `invoices` in any namespace would get in. My live test included exactly such a pod, and it was blocked.
- **Don't trust a label the team controls.** To share one Backstage ID across environments, the ID comes from a label on the `WebService`, so any team could claim another team's. Network rules use two labels instead. One is a team label that Argo CD puts on namespaces, which teams can't change, since the Argo CD project only lets them create `WebService`s. The other is the name label the composition puts on pods.

Also, the VPC CNI ignores NetworkPolicies unless enforcement is turned on in the add-on, without saying so.

## 6. Seeing your service: metrics, logs, alerts and cost

Everything about a service is found through one label, `backstage.io/kubernetes-id`, which the composition puts on every pod, including the database's:
- **Dashboard:** one Grafana dashboard serves every service, picked from a dropdown.
- **Alerts:** each alert carries the service and environment, and links to that dashboard.
- **Logs:** Alloy labels each log line with the service.
- **Cost:** OpenCost's figures are grouped by service.

Developers set none of it up.

- **Metrics:** kube-prometheus-stack, with an optional `metrics` field for a service's own metrics.
- **Alerts:** `WebServiceDown` and `WebServiceRestarting` per service, unit-tested with promtool. On EKS, a deliberately broken service fired in Slack after exactly 5 minutes, and the fix sent the resolved message within a minute. One subtlety: CloudNativePG pods carry the service's label too, so "down" only counts pods owned by a ReplicaSet. Otherwise a healthy database would hide a dead app.
- **Logs:** Loki stores 7 days, in S3 on EKS, so logs outlive the cluster. Alloy ships them from every node.
- **Cost:** OpenCost prices each container's allocation at its node's price. A recording rule sums that per service and environment.

The cost work produced my favourite bug. The recording rule passed its unit test the first time. On a real cluster it returned nothing, because OpenCost publishes its own copy of `kube_pod_labels`. With two copies, Prometheus refuses every join on pod labels as "many-to-many". That included the existing alerts, which would have silently stopped working the moment OpenCost was installed.

The fix had its own twist. With the duplicate turned off, OpenCost then had no prices at all. I first blamed the setting I'd just changed. The real cause was in its log all along: it stores price data in `/var/configs`, and its container's filesystem is read-only. After both fixes, a pod with 0.25 CPU and 256 MiB cost $0.008962 an hour, exactly the hand calculation.

## 7. How I tested it

Everything was built on kind first, from the same root application. CloudNativePG stands in for RDS, and the AWS-only parts are switched off by one Helm value.

`make test` needs no cluster:
- **Rendering:** it renders the composition for each runtime, database class, profile and environment, and validates the output against the providers' schemas.
- **Policies:** `kyverno test` runs the admission policies against sample resources.
- **Rules:** `promtool` unit-tests the alert and cost rules.
- **Environments and templates:** it builds every environment with Kustomize, and renders the Backstage template the way Backstage does.

Each test earned its place. I broke something on purpose, and checked the matching test failed.

For runtime behaviour, I used **throwaway kind clusters** with their own kubeconfig, deleted afterwards:
- Does a NetworkPolicy really block a call?
- Does the autoscaler scale? Under load it went from 2 to 5 replicas within a minute.
- Can Argo CD adopt its own Helm release?
- Do logs arrive under the right service?

That's where the most valuable problems showed up, ones every offline check had passed:
- OpenCost's two bugs.
- A log label that would have started a new stream on every container restart.
- An amd64-only Kustomize image that crashed now and then under emulation on my Mac.

**Lesson: make sure a test fails for the reason you think.** Several of mine passed or failed for the wrong reason:
- An Argo CD permission check returned 415, not 403, because I'd left out a content type.
- A password comparison failed because the AWS CLI's text output adds a newline.
- Four of my yq assertions passed by luck, because `select(...) | A and B` checks `B` against every document. A stray `false` in the output was the only sign.

A test that fails for the wrong reason looks exactly like a pass.

## 8. Where it stands

- **Two shapes, one switch.** A `profile` input picks between them.
  - `study`, what I run day to day: two AZs, one NAT gateway, two nodes and single-AZ databases, at about $0.40 an hour.
  - `production`: three AZs with a NAT gateway and node in each, Multi-AZ RDS, more replicas of the platform's components, and backups. It's roughly $0.60 an hour.
- **Still ephemeral.** Even the production shape is destroyed every night. Logs and backups survive for 7 days.
- **Waiting on AWS:** GitHub OIDC for CI (built, in a pull request), and Karpenter, both blocked by the Free plan organization's policy.
- **One AWS account.** A real platform would separate accounts for production under AWS Organizations.
- **Verification.** The architecture, both runtimes, databases, guardrails, metrics and alerts have run on EKS. The hardening work, from availability through cost, has passed its offline tests and live tests on kind, and its EKS session is next.

What carries over to any platform is the shape:
- one small API
- Git as the only way to change anything
- controllers doing the work
- credentials that never sit in a repo or on a laptop
- and tests that you've watched fail

---

*All code, two dozen decision records, and notes on everything that broke: [github.com/kushan94/eks-internal-developer-platform](https://github.com/kushan94/eks-internal-developer-platform).*
