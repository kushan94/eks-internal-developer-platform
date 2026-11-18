# I Destroy My Kubernetes Platform Every Night. Here's What That Taught Me.

*An internal developer platform on EKS for about $0.40 an hour, and the bugs only a real cluster showed me*

Every night at 22:00 UTC, a scheduled workflow destroys my Kubernetes platform: the EKS cluster, the databases, the load balancer, the DNS records. The next session starts from nothing, and everything comes back from Git, Terraform and a few secrets in Secrets Manager.

I did it because the platform runs on AWS credits, and the EKS control plane alone costs $0.10 an hour. It turned out to be the best design constraint I've had. A platform you can destroy and recreate every day can't hide anything: no state that lives only in the cluster, no credential someone pasted once, no test that was never run for real.

The platform lets a developer write one small file and get a service with a database, a public URL, dashboards, alerts and network isolation. I built it from an empty AWS account with Crossplane, Argo CD and a self-hosted Backstage, to learn how an internal developer platform fits together. This is the write-up, for platform, DevOps and cloud engineers, including what broke. The code, with a decision record for every choice, is at [github.com/kushan94/eks-internal-developer-platform](https://github.com/kushan94/eks-internal-developer-platform).

> The hardening work ran on kind first, and then on EKS in one session on the production shape. I'll say what that found, and what still hasn't been tried.

## What a developer gets

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
  database:
    class: managed
```

Merge it, and the developer gets:

- **A Deployment and Service** with a security context, resource limits, zone spread and a disruption budget, none of which they wrote.
- **A public HTTPS URL,** with DNS and a certificate.
- **Their own PostgreSQL database and login,** passed in as `DATABASE_URL`.
- **A Grafana dashboard** with metrics, logs and cost per hour, and a Slack alert when the service goes down.
- **Network isolation.** Only its own namespace, Prometheus and the load balancer can reach it. It can only reach DNS, its namespace and its database, unless it lists more.

Add `runtime: ecs` and the same file runs on Fargate instead, minus the features that are Kubernetes-only for now.

Developers don't write the file by hand. A Backstage form writes it and opens a pull request, so nothing in the portal calls a cloud API and Git is the only way in. Services get dev, staging and prod as namespaces. Promotion is a pull request that copies the image staging already ran into prod, so prod only runs what staging ran.

## The shape

1. **Backstage** opens a pull request as a GitHub App.
2. **Argo CD** watches the repo and creates a namespace and an application for each team folder, or each environment of a service.
3. **Crossplane** owns the `WebService` API. One composition, written with Go templates, turns each one into the resources for its runtime and options.
4. **Controllers do the rest:** the AWS Load Balancer Controller and ExternalDNS for the URL, CloudNativePG or provider-sql for the database.

Guardrails apply to every team namespace: Pod Security's `restricted` profile, Kyverno policies (no `:latest`, approved registries, resource requests) and keyless image signing. CI signs images with cosign using its GitHub identity, and Kyverno only admits `ghcr.io/kushan94` images signed by this repo's workflows on `main`, so there are no signing keys to store.

I chose Crossplane because I wanted the developer API to be a Kubernetes resource, so Argo CD, Backstage and `kubectl` all treat it the same. The cost is that I upgrade it and its providers myself. I self-hosted Backstage because a SaaS portal would have hidden the parts I wanted to learn.

## What destroying it every night forces

**Anything that must survive lives outside the cluster.** A small bootstrap Terraform stack creates the state bucket, the container registry, the DNS zones and certificate, and the GitHub App keys in Secrets Manager, once.

**Credentials can't live only in the cluster.** External Secrets reads Secrets Manager through EKS Pod Identity, which works on a cluster that is ten minutes old. Sealed Secrets would need a decryption key for every new cluster.

**Nobody copies a token between steps.** The EKS API only allows my IP, so cluster setup runs on a CI runner inside the VPC. At boot, the runner signs a JWT with a GitHub App key using nothing but `openssl`, and exchanges it for a registration token. It installs Argo CD and External Secrets, and Argo CD takes over, including managing itself from then on.

**Destroy needs as much care as create.** Controllers still running during `terraform destroy` recreated what I was deleting: the load balancer controller rebuilt an ALB, and ExternalDNS rewrote records. The destroy now removes their IAM permissions first.

**Backups have to outlive the cluster.** In the production shape, RDS keeps seven days of automated backups after the instance is deleted, which is what makes them useful, and in-cluster databases get EBS snapshots. Each has a restore drill script that writes a marker row, restores to a new instance, checks the row and times it. On EKS, the in-cluster database was backed up in under two minutes and restored in 34 seconds, and a point-in-time restore of the shared RDS server was available in about eight minutes, each with its marker row intact.

**And a scheduled workflow is a safety net, not a timer.** GitHub has run my 22:00 destroy as late as 03:56. Once I started a session at 21:55, and the destroy queued behind my apply and would have torn the cluster down mid-test.

## The upgrade that didn't upgrade

The account started on AWS's Free plan. Its organization policy denies IAM OIDC providers and, as far as the policy simulator can tell, Spot requests, and only allows Free Tier instance types. My first EKS apply created the cluster, the VPC and a NAT gateway, then failed on the node group with `The specified instance type is not eligible for Free Tier`, and the half-built cluster cost money until I fixed it. `terraform plan` can't see a service control policy. You find out at apply, after the expensive parts exist.

The limits shaped the design in good ways. No OIDC provider meant Pod Identity instead of IRSA, which turned out simpler. When I wanted production features, I upgraded to the Paid plan.

The limits didn't lift. The account reported `PAID` and `ACTIVE`, but it is a member of an AWS organization whose policy still denied OIDC hours later, and days later. IAM's policy simulator shows this without creating anything:

```sh
aws iam simulate-principal-policy --policy-source-arn <your role ARN> \
  --action-names iam:CreateOpenIDConnectProvider ec2:RequestSpotInstances \
  --context-entries ContextKeyName=aws:RequestedRegion,ContextKeyValues=eu-north-1,ContextKeyType=string \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

That `--context-entries` line matters. The organization's policy depends on the region, and without it the simulator reports that even an administrator can't create a cluster. With it, I also learned the organization refuses the other regions I tried: `us-east-1`, `us-west-2` and `eu-west-1`. And I had reported `ec2:CreateFleet`, and so Karpenter, as blocked for days from a run without the region. With the region supplied, `CreateFleet` is allowed. It never was blocked.

**Lesson: read the account's limits before writing Terraform, and check that the thing you changed actually changed.**

## Pods ran out before memory did

Two small nodes have 4 vCPUs and 16 GiB between them. What ran out first was neither. The VPC CNI gives each pod a real VPC IP, and this instance type gets 29. With the monitoring stack in, both nodes were full while CPU requests were two-thirds used, and new pods sat in `Pending` with `Too many pods`.

Prefix delegation in the `vpc-cni` add-on hands out /28 prefixes instead of single IPs and raised the limit to 110. Managed node groups only read it when they're created, so the add-on has to be configured first.

## Testing the sign-in before AWS allowed it

Without an OIDC provider, GitHub Actions can't sign in to AWS with short-lived credentials. CI uses IAM user keys instead. I built the OIDC version, role trust policies included, but couldn't try it.

Rather than wait for AWS Support, I tested everything that doesn't need AWS. A tiny workflow prints the claims in the token GitHub would present, without calling any AWS API. My trust policies compared the token's subject with this:

```
repo:OWNER/NAME:environment:aws-plan
```

The real token's subject was:

```
repo:OWNER@123/NAME@456:environment:aws-plan
```

The repository uses immutable subjects, so GitHub puts the numeric owner and repository IDs in. Every sign-in would have been refused with `AccessDenied`, and I'd have found out only after AWS lifted the block, debugging it blind. The fix is stronger than what I had: a repository that is renamed, or deleted and recreated under the same name, gets a new ID and can't inherit the trust.

**Lesson: test the exact token, not your memory of the documentation.** The check also has to be able to fail. I broke the trust policy nine ways (a mistyped ID, a loosened condition, a typo in the Terraform expression) and made sure each one was caught. One slipped past my first version of the check until I tightened it.

## OpenCost silently broke my alerts

Cost per service was the last of the hardening features. The recording rule passed its unit test the first time. On a real cluster it returned nothing.

OpenCost publishes its own copy of `kube_pod_labels`. With two copies, Prometheus refuses every join on pod labels as many-to-many. That included my existing `WebServiceDown` alert, which would have stopped working the moment OpenCost was installed, with nothing to say so.

Turning the duplicate off then left OpenCost with no prices at all. I blamed the setting I had just changed. The real cause was in its log all along: it stores price data in `/var/configs`, and its container's filesystem is read-only. With both fixed, a pod with 0.25 CPU and 256 MiB cost $0.008962 an hour, exactly my hand calculation.

**Lesson: a unit test feeds your rule clean data. Only a real cluster feeds it the data you'll actually get.**

## In a NetworkPolicy, two selectors are AND and two entries are OR

Each service's NetworkPolicy lets in its own namespace, Prometheus and the load balancer, and anything else is declared:

```yaml
spec:
  allowFrom:            # who may call it
    - team: shop
  allowTo:              # what it calls
    - team: billing
      service: invoices
  allowInternet: true   # public internet; private ranges stay blocked
```

"Billing's invoices service" has to put the namespace selector and the pod selector in the same `from` entry. Split into two entries, any pod named `invoices` in any namespace gets in. My live test included exactly such a pod, and it was blocked.

The second trap was trusting a label the team controls. To share one Backstage ID across environments, the ID comes from a label on the `WebService`, which any team could set to claim another team's. The network rules use two labels instead: one that Argo CD puts on namespaces, which teams can't change, and the name label the composition puts on pods.

And the VPC CNI ignores NetworkPolicies unless enforcement is turned on in the add-on, without saying so.

## Tests that pass for the wrong reason

A test that fails for the wrong reason looks exactly like a pass. Mine did:

- Four of my `yq` assertions passed by luck, because `select(...) | A and B` checks `B` against every document.
- An Argo CD permission check returned 415, not the 403 I expected, because I'd left out a content type.
- My first network isolation test on EKS used the wrong Service port, so every "blocked" result would have been the same with no policy at all. A block test needs a control that proves the target is reachable otherwise.
- A Terraform validation passed on an empty folder. I'd run it in Docker on my Mac, and Docker only shares my home directory, so the container saw nothing and found nothing wrong.

Each of those is the same failure. Now I break the thing on purpose and check that the test notices, and I check that the tool actually saw the input.

## Writing runbooks audited my platform

The newest part is a dashboard and an assistant for diagnosing the cluster. The dashboard shows nodes, namespaces, Argo CD applications, warnings and the pods that need attention. Next to each problem is a Diagnose button, and it opens an assistant: a Claude model with read-only tools for pods, events, logs, a fixed list of objects and Prometheus. Its role can't write, and it can't read Secrets.

Because a diagnosis costs money, it has limits: a token budget after which it must answer from what it has, a daily spend cap, a few minutes of caching for repeats, and a log line for every question with its cost.

To teach it this platform, I wrote ten short runbooks (crash loops, image pulls, pending pods, network blocks and so on) that it loads when the symptoms match. A script checks every concrete claim in them against the real composition and policies, so a runbook fails the check when the platform changes under it.

Writing them found two gaps in my own platform:

- **A service's resources were fixed.** Every service got a 256Mi memory limit, and a `WebService` had no field to change it. A runbook can't tell a developer to raise the limit, because there was nothing to raise.
- **The composition added no readiness or liveness probes.** A pod counted as ready as soon as its container ran.

I'd been building the platform for two weeks without noticing either. I noticed when I sat down to write down what it actually does. Both are fixed now: a `WebService` can set its `resources` and a `healthCheck`, and every service gets at least a readiness check on its port. It passed its tests on kind, and then on EKS: a service with a good health path came up Ready with its own sizes, and one with a bad path was reported not Ready, with an event naming the 404, where before it would have looked healthy.

I should be honest about the state of it. The tools are tested against deliberately broken workloads on kind, and the loop and the limits against a scripted model. The comparison of runbooks on against off runs against a stand-in for the API, which tests the harness and not the model. **I haven't yet run it against the real model, so I can't tell you how often it's right.** It also has no login yet, so it isn't deployed.

## The production shape found four bugs, then a fifth problem

The hardening work had only ever run on a local cluster. A single session on the production profile found four bugs that nothing local could have, and every one was in something I'd already called done.

**Backstage never became ready.** The production shape runs two replicas, and the database is new every session. Both replicas ran the same migrations at once, and the race wrote one of knex's lock rows twice. With two rows, knex can never take its lock, so one plugin failed to start for good. Backstage's liveness endpoint kept answering 200, so nothing restarted the pods, and restarting wouldn't have helped. Earlier sessions ran the one-replica shape, so I'd never seen it. The fix makes each replica take a Postgres advisory lock before it starts and hold it until it's ready. It's tested against a real Postgres, and a second session confirmed it on EKS: the first replica was ready in 10 seconds, the second waited about 9 seconds for it and was ready 18 seconds later.

**Both restore drills could never pass.** Newer `psql` prints a command tag for every statement, so each drill read `CREATE TABLE` or `INSERT 0 1` as its marker. The data was restored correctly every time, and the check was wrong.

**Every promotion failed.** A leftover branch named `promote`, from the pull request mix-up, blocked every branch named `promote/...`, because Git can't hold both.

**Each session left a volume behind.** Kubernetes keeps a StatefulSet's volume claims when it's deleted, so Loki's 5 GiB volume outlived every destroy. I only found it by counting what was left after the destroy. The destroy now sweeps these, and it has run in real destroys: the nightly one deleted the leftover volume, and the next one found nothing left.

A second session on the same shape turned up a fifth, smaller problem. The cluster went from nothing to healthy in about 37 minutes: 17 for Terraform, about 4 to install Argo CD and the platform settings, and 15 waiting for the apps, which finished with 19 seconds to spare. Nothing was broken. The load balancer controller's chart makes a new certificate every time it is rendered, so Argo CD kept seeing it as drift and re-syncing it, with longer and longer pauses between tries. It now ignores those fields, and I checked on the live cluster that changing them leaves the app in sync while a real change is still caught. I haven't yet seen a build without the delay.

None of these were in the features. They were at the edges: first boot, a check's parsing, a stale branch, the order of a deletion. A platform you destroy every night crosses those edges every day, which is the point.

## Where it stands

- **Two shapes, one switch.** A `profile` input picks between them. `study` is two zones, one NAT gateway and two nodes, at about $0.40 an hour. `production` is three zones with a NAT gateway and a node in each, Multi-AZ RDS, more replicas of the platform's components and backups, at roughly $0.60 an hour. Even production is destroyed every night.
- **On EKS:** the architecture, both runtimes, databases, guardrails, metrics and alerts, and a deliberately broken service that fired in Slack after exactly five minutes. Then, in one session on the production shape, the hardening work: replicas spread across zones, network isolation enforced by the VPC CNI in both directions, a real promotion through a pull request, autoscaling reading live metrics, logs per environment, cost per service, and both restore drills. That session ran about two hours, roughly $1.2 at the profile's hourly rate.
- **Not tried yet:** the dashboard and assistant aren't deployed, because they have no login and I haven't run them against the real model. The clean rebuild time is about 37 minutes, but it includes the 15-minute wait above, so the next build should be shorter.
- **Waiting on AWS:** GitHub OIDC for CI, which that organization policy blocks. What it denies is anything that creates another way to sign in to the account, which looks deliberate, so I've stopped expecting it to lift. Karpenter looked blocked too, but that was a false result, and I haven't tried it yet.
- **Not done:** one AWS account is not a production setup, and a real platform would separate accounts under AWS Organizations.

What carries over to any platform is the shape: one small API, Git as the only way to change anything, controllers doing the work, credentials that never sit in a repo or on a laptop, and tests you've watched fail.

---

*All the code, two dozen decision records, and notes on everything that broke: [github.com/kushan94/eks-internal-developer-platform](https://github.com/kushan94/eks-internal-developer-platform).*
