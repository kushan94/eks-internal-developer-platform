# Article notes

Add to this while building, because details are hard to reconstruct later.

## Log
Copy this for each session:

### YYYY-MM-DD: Topic
- **Goal:**
- **What happened:**
- **What surprised me:**
- **Mistakes and fixes:**
- **AWS cost:**

### 2026-11-03: Local core and GitOps
- **Goal:** Run the `WebService` API on kind, then have Argo CD deliver everything from Git.
- **What happened:** From the root application, Argo CD brought up Crossplane, the API and a workload in 103 seconds on a cluster that already had Argo CD and its images.
- **What surprised me:** Crossplane creates its CRDs after it starts, so Argo CD can't dry-run those resources yet. `SkipDryRunOnMissingResource` and retries solved the ordering without sync waves.
- **Mistakes and fixes:**
  - `kube-proxy` crash-looped with `too many open files`, because another kind cluster shared the Docker VM and the inotify limit was 128.
  - The `alpine/git` image has no `git daemon`, so the Git server exited immediately. `docker run -d` hid this, so `make local-git` now checks that the server responds.
  - Pods can't resolve Docker container names on the kind network, so Argo CD uses the Git server's IP address.
  - A test `git commit -a` swept up uncommitted Makefile fixes, and deleting the test branch removed them. `git reflog` recovered them.
- **AWS cost:** $0

### 2026-11-03: Backstage template
- **Goal:** Let a developer fill in a form and get a pull request that deploys a service.
- **What happened:** The template opened a real pull request. Argo CD deployed that branch on a fresh cluster, and the service returned HTTP 200.
- **What surprised me:**
  - Argo CD applies every YAML file in a workload folder, so Backstage catalog files had to live in a separate `catalog/` folder.
  - A free-text namespace field would let anyone request a service in `kube-system`, so the form now rejects system namespaces. Pull request review is still the real control.
  - Commits made through the GitHub API can carry a personal email, so `scaffolder.defaultAuthor` is set to a noreply address.
- **AWS cost:** $0

### 2026-11-05: Two runtimes behind one API
- **Goal:** Let developers choose Kubernetes or ECS Fargate in the same form.
- **What happened:** One field, `runtime`, picks which resources the composition builds. I validated the ECS output offline against the provider schemas, without an AWS account.
- **What surprised me:**
  - The AWS provider's v2 resources are namespaced (`ecs.aws.m.upbound.io`), and some fields differ from older examples. For instance, `networkConfiguration` is an object, not a list.
  - Reading the provider's schemas first was faster than writing YAML from memory and fixing errors one by one.
  - `crossplane render` and `crossplane resource validate` test compositions without a cluster or cloud account. A deliberately broken field confirmed the validation really catches mistakes.
- **Mistakes and fixes:**
  - Storing commands in zsh variables broke test scripts twice, because zsh doesn't split them into words. Shell functions work instead.
  - The Crossplane CLI moved to its own repo and download host from v2.3, so older install instructions point to missing files.
- **AWS cost:** $0

### 2026-11-05: AWS Free plan
- **Goal:** Prepare AWS without spending credits until each piece is needed.
- **What happened:** The account is on the Free plan with $100 of credits. A read-only `terraform plan` and a budget alert came before creating anything.
- **What surprised me:**
  - The Free plan's service control policies deny Spot instances, OIDC providers and `ec2:CreateFleet`. That rules out Spot nodes, IRSA, Karpenter and EKS Auto Mode. None of this shows up in `terraform plan`; it would only fail during `apply`.
  - Regions are fixed by the account's contact address. Norway maps to eu-north-1, and other regions are denied.
  - `aws login` gives the CLI short-lived credentials from a console sign-in, so no access keys are needed. Its credentials last 15 minutes, though, which is too short for Crossplane on kind, so Crossplane uses EKS Pod Identity.
  - In eu-north-1, an ECS-only session costs about $0.08 an hour, and an EKS session about $0.33. The EKS control plane alone is $0.10 an hour, so a cluster can't stay up all month within $50.
- **AWS cost:** $0 so far

### 2026-11-06: First EKS apply failed
- **What happened:** The node group failed with `The specified instance type is not eligible for Free Tier`. The EKS cluster, VPC and NAT gateway were created first, so they kept costing money until the fix.
- **What surprised me:** This limit isn't in the Free plan's published service control policies, so reading them wasn't enough. `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true` lists the allowed types. In eu-north-1 those are t3/t4g micro and small, `c7i-flex.large` and `m7i-flex.large`.
- **Fix:** Switch to `m7i-flex.large`, with 2 vCPUs and 8 GiB at $0.10 an hour.

### 2026-11-06: Argo CD and private repos
- **Goal:** Let Argo CD deploy from any approved repo, the way production platforms do.
- **What happened:** I chose a GitHub App, with its key in Secrets Manager and External Secrets creating Argo CD's credential template. On kind, Argo CD projects blocked a `kube-system` destination, a raw Deployment and a foreign repo, and allowed an approved external repo.
- **What surprised me:**
  - Argo CD needs repo credentials before it can read anything from Git, so the credential path can't come from Git. It needs a small bootstrap step.
  - With Go templates, the ApplicationSet git files generator reserves `.path` for the file's own location, which silently overrode a field with the same name.
  - Clusters destroyed nightly rule out keeping credentials only in the cluster, and they make Sealed Secrets awkward, because each new cluster would need the decryption key.
- **AWS cost:** about $1 for the half-built cluster from the failed apply

### 2026-11-06: A runner inside the VPC
- **Goal:** Set up each new cluster from CI, without opening the API to GitHub's network.
- **What happened:** I chose a self-hosted runner in a private subnet. It registers itself at boot with a short-lived token from a second GitHub App, whose key it reads from Secrets Manager.
- **What surprised me:**
  - GitHub Apps can be created from code through the app manifest flow, which leaves only two clicks in the browser.
  - A JWT built with `openssl` in a shell script was accepted by GitHub, so the boot script needs no extra tools.
  - My first test of the "wait until healthy" logic falsely passed a broken state. The cause was testing in zsh while `make` uses `sh`. Rerunning under `sh` showed the Makefile was correct.
- **AWS cost:** $0, all checked offline

### 2026-11-06: First full run on EKS
- **Goal:** Run the whole platform on EKS from the pipelines.
- **What happened:**
  - The Infrastructure workflow created EKS, and the VPC runner registered itself.
  - The Cluster workflow installed Argo CD and External Secrets, and Argo CD read the private repo through the GitHub App.
  - Crossplane's AWS providers authenticated through Pod Identity.
  - A `runtime: ecs` WebService became a running Fargate task that answered HTTP 200 from inside the VPC.
  - Deleting it removed every AWS resource it had created.
- **Mistakes and fixes:**
  - The Cluster workflow applied an `EnvironmentConfig` seconds after handing over to Argo CD, before Crossplane had installed that type. It now waits for the type. Locally I had always run it later, so the race only appeared in CI.
  - The provider builds the ECS service ID as `service/<cluster>/<name>`, so `cluster` must be the cluster name, not its ARN. Offline schema validation couldn't catch this, because both are valid strings. Only a real apply did.
- **AWS cost:** about $0.40 for a 1-hour session

### 2026-11-06: DNS delegation
- **What happened:** The domain's nameservers pointed at a deleted Azure DNS zone, so nothing resolved. A first fix set the registrar's nameservers to the `idp` zone's, which can't work: those servers only answer for the subdomain.
- **Fix:** Route 53 now hosts the parent zone too. The registrar points at the parent zone, and the parent delegates `idp` to its own zone with NS records.
- **Lesson:** "delegate a subdomain" means NS records *inside the parent zone*, not changing the domain's nameservers. Writing the delegation as a Terraform resource makes the relationship explicit.

### 2026-11-06: First public URL
- **What happened:** `https://hello-demo.idp.example.com` answered HTTP 200 from the internet.
  - The certificate was found in ACM by hostname.
  - ExternalDNS created the records.
  - HTTP redirects to HTTPS with a 301, and unknown hosts get a 404.
- **What surprised me:**
  - Pods only get Pod Identity credentials if their association exists when they start. Merging the change mid-session let Argo CD start the load balancer controller 17 minutes before Terraform created its association, and a restart fixed it. In a fresh session, Terraform runs first, so this doesn't happen.
  - Argo CD flagged the redirect HTTPRoute as OutOfSync, because the API server added default fields. Writing those defaults in Git fixed it.
  - The load balancer controller puts `:443` in the redirect URL. It works, but isn't as clean as a plain `https://` URL.

### 2026-11-09: Destroy hardening
- **What happened:** The first destroy after public URLs removed the ALB and destroyed 80 resources cleanly. Two gaps remained:
  - A load balancer controller restarting mid-destroy could recreate the ALB and block deleting the VPC. The cleanup now removes its IAM policy first.
  - ExternalDNS records outlived the ALB they pointed at, so the destroy now deletes them, using ExternalDNS's own TXT ownership records to pick only its records.
- **What surprised me:** GitHub ran the nightly destroy about 3 hours late. Scheduled workflows aren't punctual, so they're a safety net, not a timer.

### 2026-11-09: Backstage in the cluster
- **Goal:** Run Backstage on EKS with GitHub sign-in, RDS and no personal credentials.
- **What happened:**
  - The multi-stage image built in under 3 minutes with caching.
  - Against a real Postgres 18, the backend was ready in 9 seconds and created 13 plugin databases.
  - Guest sign-in is refused in production, and GitHub sign-in redirects correctly.
- **What surprised me:**
  - The Backstage chart passes `extraDeploy` through `tpl`, which silently turned every ExternalSecret placeholder into an empty string. Rendering the real chart caught it, and the fix was escaping them twice.
  - Recent PostgreSQL versions on RDS require TLS, so the image now includes the RDS CA bundle, pinned by checksum.
  - The ECR address includes the account ID, which shouldn't be in Git, so it's passed in when the root app is applied.
  - BuildKit features in the Dockerfile need the buildx plugin, which Colima doesn't include.

### 2026-11-09: First Backstage deploy on EKS
- **What happened:** The apply first failed on an apostrophe in a security group description, which EC2 rejects. Validation and planning can't catch that. After the fix, RDS came up, and External Secrets synced both secrets through Pod Identity. Backstage then crash-looped with `Invalid type in config for key 'backend.listen'`.
- **Cause:** The Helm chart sets `APP_CONFIG_backend_listen_port`, which makes `backend.listen` an object, while the generated production config had the string `':7007'`. My local smoke test didn't set that variable, so it passed.
- **Lesson:** Smoke tests should use the same environment as the deployment. Rerunning the old image with the chart's variable reproduced the crash, and the fixed image started cleanly.

### 2026-11-09: Catalog model and Kubernetes plugin
- **What happened:** On kind, Backstage loaded the platform model with no errors. Running as its own service account, it found the demo's pods, Deployment, Service, `WebService` and HTTPRoute.
- **What surprised me:**
  - The demo `WebService` failed completely on kind, because `public: true` creates an HTTPRoute and kind had no Gateway API CRDs. The CRDs are now installed on every cluster.
  - The destroy cleanup deleted ExternalDNS's records, but ExternalDNS was still running and recreated them within a minute, the same race the load balancer controller had. It now loses its permissions first.
  - The Kubernetes plugin asks for ConfigMaps and metrics by default, which showed as errors with least-privilege RBAC and no metrics-server. `kubernetes.objectTypes` and `skipMetricsLookup` fixed both.

### 2026-11-09: Argo CD in Backstage
- **What happened:** A read-only Argo CD account gets a fresh token each session, which Backstage's proxy uses.
  - On kind, the token could read applications, and Argo CD refused sync, delete and admin-token requests with `permission denied ... sub: backstage`.
  - Through Backstage's proxy, signed-in requests returned the demo's sync and health, and anonymous requests got 401.
- **What surprised me:** My first checks of sync and delete returned 415, not 403, because I'd left out the JSON content type. A test that fails for the wrong reason looks like a pass, so it's worth checking the error says what you expect.

### 2026-11-09: Databases on request
- **Goal:** Developers get a Postgres database by adding one field to their `WebService`, and pick managed (shared RDS) or in-cluster (CloudNativePG), the way they pick a runtime.
- **What happened:**
  - On kind, a CloudNativePG cluster stood in for RDS, so the managed class could be tested without AWS.
  - Both classes became Ready in about 90 seconds. A pod with the service's exact environment created a table, wrote and read it over TLS on both.
  - A second service's login was refused on the first one's database with `User does not have CONNECT privilege`.
  - Deleting the services dropped their databases and logins within 10 seconds.
- **What surprised me:**
  - On RDS the admin isn't a superuser, and since Postgres 16 it can't create a database owned by another role unless it's a member of that role. The composition grants that membership, and Crossplane retries until it exists.
  - ECS can't read Kubernetes Secrets, so the managed class copies the password to Secrets Manager and holds back the task definition until its ARN exists. Rendering the composition with and without that observed state tested both paths.
  - EKS has no default StorageClass or EBS driver, so in-cluster databases would have stayed Pending on EKS while working fine on kind.

### 2026-11-09: Databases on EKS
- **What happened:** All three cases worked on the first EKS run.
  - **Managed on Kubernetes:** the service's login wrote to its own database on RDS PostgreSQL 18.3, over TLS.
  - **In-cluster:** CloudNativePG ran PostgreSQL 18.6 on a 1 GiB gp3 EBS volume.
  - **Managed on ECS:** the task started with `PGPASSWORD` from Secrets Manager, and the stored copy matched the login's password.
  - **Isolation:** one service's login was refused on another's database on RDS too.
  - **Deletion:** removing the services deleted the ECS service and Secrets Manager secret within 20 seconds, and left no databases or logins on RDS.
- **What surprised me:**
  - Every `terraform plan` failed while a session was running, because refreshing a Secrets Manager secret version reads its value, and AWS's ReadOnlyAccess policy doesn't allow that. Earlier plans had only passed because nothing was deployed. The plan user can now read the two secrets Terraform writes, which it could already read in the state.
  - My first password comparison said they differed. The AWS CLI's text output adds a newline, so I was hashing different strings. Another test that fails for the wrong reason.

### 2026-11-09: A demo app and a repeatable database test
- **What happened:**
  - `visits` is a 100-line Go app that counts page views in Postgres. It connects with `DATABASE_URL`, or the `PG*` variables when that isn't set, so one image works with both classes and both runtimes. It's built for amd64 and arm64 and published to GitHub's registry, so no AWS account ID ends up in Git.
  - On kind, its two replicas shared one count in their own database, over TLS.
  - `make test-db` runs the whole database check in about a minute on kind: both classes Ready in 26 seconds, logins over TLS, isolation, and nothing left on the shared server after deletion.
  - On EKS it passed the same checks against RDS and EBS, with both classes Ready in 86 seconds.
  - Meanwhile, the golden path worked end to end on EKS: a service created in Backstage with a managed database became a pull request from the app's bot, and once it was merged, Argo CD and Crossplane gave it its own database on RDS.
- **What surprised me:** The test script's first run failed three checks that had actually passed. Postgres prints a boolean as `true` when it's joined into text but as `t` on its own, and macOS `paste` needs `-` to read stdin. The checks were right; the assertions weren't.

### 2026-11-09: Guardrails
- **Goal:** Stop unsafe workloads before they run, with messages a developer can act on, while the golden path passes without effort.
- **What happened:**
  - Team namespaces get the `restricted` Pod Security profile and three Kyverno CEL policies through labels Argo CD sets when it creates them.
  - On kind, `:latest`, no tag and a Docker Hub image outside the allowed list were all refused. Each `WebService` showed the reason in its `Synced` condition, and a compliant service became Ready next to them.
  - Signature checking worked both ways with a real keyless-signed image: podinfo was admitted with its own workflows as the identity and refused with this repo's.
  - `make test` now runs `kyverno test` against sample pods, and flipping one expectation makes it fail.
- **What surprised me:**
  - podinfo's image says `USER app`. Kubernetes can't prove a named user isn't root, so `runAsNonRoot` refuses to start it. The API gained an optional `runAsUser`.
  - The visits image was rejected before Kyverno even looked for a signature: its GHCR package is private, and Kyverno reads anonymously.
  - Kyverno's chart renders some CRDs with `labels: {}`. The API server drops empty maps, so Argo CD's default comparison showed the app as out of sync forever. Server-side diff fixed it; `ignoreDifferences` didn't.

### 2026-11-10: Metrics and dashboards
- **Goal:** Developers see how their service behaves without setting anything up, and services with their own metrics get them scraped by adding one field.
- **What happened:**
  - On kind, `kubectl top` worked, and Prometheus scraped both visits pods through the `PodMonitor` the composition created. It counted all 30 test page views.
  - The `WebService` dashboard's queries found the service's two app pods and its in-cluster database through the Backstage ID label, with CPU and memory for each.
  - Grafana loaded the dashboard at the URL the Backstage links use.
- **What surprised me:**
  - Both charts create a few objects in `kube-system`, which the platform's Argo CD project didn't allow, so they sat at "Missing" with a clear message.
  - The monitoring stack pushed an 8 GB Colima VM, shared with another kind cluster, to a load average of 90, and the API server stopped answering. Pausing the other cluster fixed it. The platform now needs more than a laptop's spare memory.
  - The newest kube-prometheus-stack was a day old. I pinned one from two weeks earlier, since a chart released that often is safer once it's had time to settle.


### 2026-11-10: Checking guardrails, metrics and databases on EKS
- **Goal:** See everything built on kind since the last EKS session work on the real cluster.
- **What happened:**
  - Kyverno refused `:latest` and a Docker Hub image with the same messages as on kind, and admitted the signed visits image. Pod Security refused pods without a security context before Kyverno saw them.
  - visits counted page views in RDS at its public URL, over TLS.
  - Grafana's GitHub login worked after one fix, and only for the listed user.
- **What surprised me:**
  - **The nodes ran out of pods, not memory.** An m7i-flex.large gets 29 pod IPs from its network interfaces. After the monitoring stack, both nodes held 29 or 30 pods while CPU and memory requests were at most two-thirds used, so `make test-db`'s pods stayed Pending. VPC CNI prefix delegation raises the limit to 110.
  - **Grafana's GitHub login needs `read:org`** even when nothing uses teams. Grafana always asks GitHub for the user's teams, and GitHub answers 404 without that scope, which Grafana shows as an internal error.
  - **Argo CD kept the Grafana route OutOfSync** because the API server fills in defaults the manifest left out. The other routes already spelled them out; this one hadn't.
  - **The nightly destroy runs late.** It's scheduled for 22:00 UTC, but GitHub has started it as late as 03:56. Start a session at 21:55 and it may still tear the cluster down halfway through.
  - **Two bots raced to push to `main`.** A merge that changed both apps started both image workflows, and the second push was rejected. The Backstage tag in Git had been stale for two merges without anyone noticing.

### 2026-11-13: Alerts
- **Goal:** Find out that a service is down without watching a dashboard.
- **What happened:**
  - Two rules cover every `WebService`: no ready pods for 5 minutes, and repeated restarts. Each names the service and links to its dashboard.
  - On EKS they go to a Slack or Discord channel through Alertmanager. The webhook URL lives in Secrets Manager.
  - `make test` unit-tests the rules with `promtool`. Removing the "only the app's own pods" filter makes a test fail.
- **What surprised me:** CloudNativePG pods carry the service's label too, which is what lets the dashboard show the database. For "is the service down", that's wrong: a healthy database pod would hide a dead app. The rule counts only pods owned by a ReplicaSet.

### 2026-11-13: Alerts and the fixes on EKS
- **Goal:** Check the alerts on EKS, and the fixes from the previous session on a fresh cluster.
- **What happened:**
  - The Cluster workflow passed on the first try, with every app Synced and Healthy. Nodes allowed 110 pods instead of 29.
  - `make test-db` passed: all databases Ready in 92 seconds, cleanup in 14.
  - **Alerts:** a deliberately broken service (podinfo without `runAsUser`, so its container never starts) fired `WebServiceDown` in Slack after exactly 5 minutes. Fixing it sent the resolved message within a minute.
  - Kyverno refused an unsigned image with the policy's own message: "ghcr.io/kushan94 images must be signed by a GitHub Actions workflow in kushan94/eks-internal-developer-platform on main". The signed visits image was admitted.
- **What surprised me:**
  - **Finding an unsigned image to test with took a trick.** Every visits build is signed. The `sha256-…` tags in the same package are the signatures themselves, stored as OCI artifacts, and they aren't signed, so one of them made an honest test.
  - **Scaling a Crossplane-managed Deployment down by hand doesn't work for testing.** Crossplane puts the replica count straight back. A realistic mistake, an image with a named user, made a better broken service.
- **AWS cost:** under $1, for about 2 hours.

### 2026-11-13: Production hardening, built on kind
- **Goal:** Take the study platform to a production shape without paying for production around the clock: survive a lost zone, keep and restore data, find logs, isolate teams, promote between environments, scale, and show cost.
- **What happened:**
  - Upgraded the AWS account from the Free plan to the Paid plan, to lift its limits on OIDC, Spot and Karpenter. The remaining $146 of credits carried over.
  - Built twelve pull requests, #38 to #49:
    - a `production` Terraform profile with 3 AZs, a NAT gateway and node per AZ, Multi-AZ RDS, and more replicas
    - RDS backups that outlive the nightly destroy, and CloudNativePG backups as EBS snapshots, each with a restore drill
    - logs with Loki and Alloy
    - inbound and outbound NetworkPolicies, with `allowFrom` and `allowTo` between teams
    - dev, staging and prod as namespaces, a Promote workflow, and a Backstage template that creates all three
    - CPU autoscaling
    - Argo CD managing itself
    - cost per service with OpenCost
  - Everything risky ran on a throwaway kind cluster with its own kubeconfig before it reached a pull request: network enforcement, autoscaling under load, Argo CD adopting its own Helm release, log shipping, and cost figures.
  - Merging #50 started both image workflows at the same second, and both pushed to `main`, which the earlier retry fix (#34) is for. The new visits build went to dev only, leaving staging and prod on the old image.
- **What surprised me:**
  - **The Paid plan didn't lift the Free plan's limits.** The account reported `PAID / ACTIVE`, but stayed in AWS's Free plan organization, whose policy still denied `iam:CreateOpenIDConnectProvider` and `ec2:CreateFleet` hours later. IAM's policy simulator (`simulate-principal-policy`) showed it without creating anything. GitHub OIDC is built but waiting.
  - **OpenCost broke the existing alerts.** By default it publishes its own copy of `kube_pod_labels`. With two copies, Prometheus refuses every join on pod labels as many-to-many, so `WebServiceDown` and the cost rule both failed the moment OpenCost started. The unit test passed, because it feeds clean data; only the live test showed it. `emitKsmV1Metrics: false` fixed it. The narrower `emitKsmV1MetricsOnly` doesn't, because it still emits `kube_pod_labels`.
  - **OpenCost had no prices at all on a fresh pod.** Its filesystem is read-only, and it stores price data in `/var/configs`. The log said so (`mkdir /var/configs: permission denied`), but I first blamed the setting I had just changed. On EKS this would have meant no AWS pricing. An `emptyDir` fixed it.
  - **In a NetworkPolicy, one entry with two selectors is AND; two entries are OR.** `allowFrom: {team: billing, service: invoices}` must put the namespace and pod selectors in the same `from` entry. Split up, any pod named `invoices` in any namespace would get in. The live test included exactly that pod, and it was blocked.
  - **A service's Backstage ID can't be trusted for security.** Once environments needed a shared ID, it came from a label on the WebService, so any team could claim another's. Network rules use the team label Argo CD puts on namespaces, which teams can't set, and the name label the composition puts on pods.
  - **The Kustomize image crashed on my Mac.** `registry.k8s.io/kustomize` is amd64 only. Under emulation on Apple Silicon it failed now and then and left a core dump in the repo, which I first mistook for a Docker caching issue. `kubectl kustomize` runs natively.
  - **My yq assertions passed by luck, four times.** `select(...) | A and B` runs `B` on every document. A stray `false` in the test output was the only sign. The Makefile now has a note, and every assertion was re-checked to fail on a wrong value.
  - **Stacked pull requests merged into each other, not `main`.** #38 went into `main` first, then #39 to #49 each merged into the branch below it, so `main` only had #38. Nothing was lost: the top branch held every commit, and one more pull request (#50) brought them in.
  - **Server-side diff keeps solving the same problem.** Kyverno's CRDs, Argo CD's own secret and External Secrets' webhook certificates all have fields that something other than Git fills in.
- **AWS cost:** $0 for building; everything ran on kind.

### 2026-11-14 to 2026-11-16: A cluster dashboard with an AI assistant, and testing OIDC without the provider
- **Goal:** Build a dashboard that shows the state of the cluster and diagnoses problems with an AI assistant, and test as much of the GitHub OIDC sign-in as possible while AWS still blocks the provider.
- **What happened:**
  - Built a Go service with a dashboard (Overview, Workloads, Nodes, Delivery, Events tabs) and an assistant behind a Diagnose button: a Claude model with read-only tools for pods, events, logs, a fixed list of objects and Prometheus. Its role has no write verbs and no access to Secrets.
  - Added limits, because a diagnosis costs money: a token budget (at 70% the model must answer from what it has, so a long investigation ends with a partial answer instead of nothing), a daily spend cap, a concurrency limit, a cache for repeated questions, and a log line per diagnosis with its cost.
  - Wrote nine runbooks the assistant loads when the symptoms match, and a script that checks their concrete claims (fields, resource sizes, policy names, quoted messages) against the real composition and policies.
  - Built an eval: seven broken workloads on kind, and a `--compare` mode that diagnoses them without and then with the runbooks. A `--dry-run` mode runs the comparison against a stand-in for the Claude API, which tests the harness and not the model.
  - For OIDC: a workflow that prints the claims in the token GitHub would present, a script that checks the role trust policies against it, and policy-simulator checks of what the CI identities may do.
- **What surprised me:**
  - **The real OIDC token's subject had the owner and repository IDs in it.** The repository uses immutable subjects, so the subject is `repo:OWNER@ID/NAME@ID:environment:...`, and my trust policies compared the name-only form. Every sign-in would have been refused after AWS lifted the block. A renamed or recreated repository now can't inherit the trust either.
  - **Writing the runbooks found two gaps in my own platform.** Every service gets a fixed 256Mi memory limit and a `WebService` has no field to change it, and the composition adds no readiness or liveness probes.
  - **The IAM policy simulator needs the region.** Without `aws:RequestedRegion`, even an administrator looked denied for every regional action, because the organization's policy depends on the region. It also showed the organization refuses `us-east-1`, `us-west-2` and `eu-west-1`.
  - **My page's own Content-Security-Policy silently dropped every inline bar width,** so a 36% CPU bar showed full. Only the browser console said so. Widths are now set through the CSS object model.
  - **A Terraform validation passed on an empty folder.** Docker on my Mac only shares the home directory, so a copy in `/private/tmp` mounted as nothing.
  - **The dry run found that the Dockerfile didn't copy the runbooks,** so the image would not have built. A failed diagnosis also used up an hourly allowance although it cost nothing.
- **Mistakes and fixes:**
  - I committed a 17 MB compiled binary by letting `go build` write it into the source folder. It is removed and ignored, but it stays in that branch's history, so the pull request needs a squash merge.
  - My stubbed answer in a browser test told the user to raise the memory limit in the `WebService`, which has no such field. The runbook now says so instead.
  - A mutation test hung for many minutes once. It never reproduced with a timeout, so I suspect Docker.
  - macOS's bash 3.2 has no associative arrays, which broke a script.
  - I wrote several claims into runbooks that were wrong (how kind schedules a single node, what Argo CD prunes) and caught them by re-reading against the repo.
- **AWS cost:** $0. Everything ran on kind, the policy simulator and GitHub. No Claude API calls were made: the assistant has only run against a scripted model and a stand-in API.

### 2026-11-17: Exploring what the AWS account really allows
- **Goal:** AWS Support hadn't answered the case about the blocked OIDC provider after several days, so find out what could be learned without them.
- **What happened:**
  - `aws organizations describe-organization` showed the account is a member of an organization whose management account is a different account, with a personal Gmail address. I had assumed AWS runs it. A member account can't read the policy (`DescribePolicy` is denied).
  - The account has a generated name ("Big Ideas Live Here"), was created on 2026-11-05, and is signed in to through a role called `AccountFullAccessRole`. The console presents it as a project.
  - I probed 24 actions with the policy simulator and the region supplied. Denied: `iam:CreateOpenIDConnectProvider`, `iam:CreateSAMLProvider`, `iam:CreateAccountAlias`, `iam:ListAccountAliases`, `sso:CreateInstance`, `rolesanywhere:CreateTrustAnchor` and `ec2:RequestSpotInstances`. Allowed: users, access keys, roles, `eks:CreateCluster`, `ec2:CreateFleet`, `bedrock:InvokeModel`. The denied ones are about creating ways to sign in to the account, which looks deliberate for this kind of account, not like a leftover Free plan limit.
- **What surprised me:**
  - **`ec2:CreateFleet` was never blocked.** I had reported it, and so Karpenter, as denied for days, from simulator runs without a region. With `eu-north-1` supplied it is allowed. The same mistake that made administrators look unable to create clusters, and it is in the notes from 2026-11-05 and 2026-11-13, in two ADRs, the README and the article draft. The ADRs and README are corrected, the article is corrected, and these old log entries are left as written.
  - **`iam:ListAccountAliases`, a harmless read, is denied.** That is not what a Free plan resource limit looks like.
  - Claude models are listed on Bedrock in `eu-north-1`, so the assistant could use Bedrock with Pod Identity and no API key, if the account's model access allows it. I haven't tried a call.
- **Mistakes and fixes:** I repeated "the Free plan denies CreateFleet" in four documents without ever having checked it with a real call.
- **AWS cost:** $0. Read-only calls and the policy simulator.

### 2026-11-17: Hardening verified on EKS, production profile
- **Goal:** Run everything built on kind since 2026-11-13 on a real cluster for the first time, on the `production` profile: three zones, a node and NAT gateway in each, Multi-AZ RDS.
- **What happened:**
  - The Infrastructure workflow took 17 minutes (15:57 to 16:13 UTC), and destroy took 14 minutes (17:53 to 18:07). Cluster setup took 23 minutes, but 15 of those were its wait for Argo CD apps to become healthy, which timed out on Backstage, so there is still no clean "empty account to healthy platform" time.
  - Verified on EKS: all 30 Argo CD apps healthy (including Argo CD managing itself, Loki, Alloy, OpenCost); visits in dev, staging and prod with public HTTPS; replicas spread across zones and disruption budgets; network isolation enforced by the VPC CNI in both directions; `make test-db` with the egress rules; metrics, per-environment logs and cost per service; the prod-replicas policy; autoscaling reading real CPU; and PR #55's probes and resources, including a bad health path being reported not Ready and restarted after its startup window.
  - Both restore drills passed on EKS, for the first time. In-cluster database: backup in 1m51s, restore healthy in 34s. RDS point-in-time restore: available in 8m07s, with the marker row and all databases intact.
  - A real dev-to-staging promotion went through a pull request, and staging rolled to the new image.
- **What surprised me:**
  - **Backstage's two replicas race on a brand-new database.** The production profile runs two, and the database is new every session. Both ran the catalog's migrations at once, and the race inserted the knex lock row twice in one plugin's database. With two rows, knex can never take the lock (`Migration table is already locked`), and Backstage's own liveness endpoint kept saying 200, so nothing restarted the pods. Restarting did not help. Deleting the duplicate row fixed it in 12 seconds. Earlier sessions ran the study profile, with one replica.
  - **Both restore drills had a bug in how they read their marker.** Newer `psql` prints a command tag (`CREATE TABLE`, `INSERT 0 1`) for every statement, so taking the first or last line gave the wrong value. The RDS drill waited for a restore point "after" `INSERT 0 1`. The data was fine, and the check was wrong. Both now take the line that looks like a timestamp.
  - **A stale branch named `promote` blocked every promotion.** Git can't hold `promote` and `promote/...`. It was the head of merged PR #44, left from the stacked pull request mix-up.
  - **Loki's volume outlived the cluster.** Kubernetes keeps a StatefulSet's claims when it is deleted, so a 5 GiB volume was left behind, and one more would have been after every session.
  - **RDS keeps automated backups of both instances after the destroy.** That is the intended behaviour, and it is what makes a restore possible afterwards.
- **Mistakes and fixes:**
  - My first network isolation test used the wrong Service ports (`hello` listens on 80, not 9898), so "blocked" meant nothing. I redid it with pod IPs and a control for every block.
  - My lock-table query first looked at the wrong table names. The one that mattered had a prefix (`backstage_backend_public_keys__knex_migrations_lock`).
  - A deletion of the leftover volume was refused by the permission check, correctly, since it had not been approved. It is left for the user to decide.
- **AWS cost:** about two hours of the production profile at roughly $0.60 an hour, so around $1.2, plus a few minutes of the temporary RDS instance for the drill. That is an estimate from the hourly rate. Cost Explorer has the real number.


## 2026-11-18 — Why the second session's wait took 15 minutes

- **What I found:** the `aws-load-balancer-controller` Argo CD app was OutOfSync, off and on, from its first sync at 10:48 until 11:04:38. Self-heal re-applied the same three resources each time (the TLS Secret and the two webhook configurations), eight times, with the delay between tries growing to about five minutes. The load balancer controller pods themselves were Ready at 10:49:39.
- **Likely cause:** the chart makes a new CA and certificate every time it is rendered. Rendering it twice with `helm template` gives different `tls.crt`, `tls.key`, `ca.crt` and nine `caBundle` values. Argo CD compares a fresh render with the cluster, so those fields can look like drift.
- **Not proven:** a hard refresh on the running cluster did not make the app OutOfSync again, probably because Argo CD reuses a cached render. I did not reproduce the exact moment the render changed.
- **First fix (wrong):** ignore the Secret's data and the webhooks' `caBundle`. Tested by editing those fields on the live cluster, which stayed Synced, and by a control that scaled a Deployment, which was caught.
- **What the third session showed (2026-11-18, cluster built 12:41):** the Secret was created at 12:46:03 and the webhook configurations at 12:46:50, in different syncs, so from different renders. With the fields ignored, Argo CD never reconciled them, and the webhook's `caBundle` didn't match the Secret's CA. Every call to the webhook failed (`tls: failed to verify certificate`). Backstage's sync failed, the Prometheus operator couldn't create `prometheus-operated` through the Service webhook, OpenCost crash-looped, and the wait step failed after 27 minutes (limit 25).
- **Repaired live:** patched `caBundle` to the Secret's `ca.crt`, restarted the Prometheus operator. The fix was reverted.
- **Also found:** the destroy leaves target groups behind (three, in the deleted VPC), which block the gateway by name (`DuplicateTargetGroupName`), and a restart of the controller was needed for the gateway to retry.
- **Better fix, not done yet:** a certificate that is the same on every render (cert-manager, or a fixed one in `webhookTLS`, which means a private key in Git).
- **Lesson:** my test changed the fields I ignored and watched the app stay Synced. It never checked that the Secret and the webhook still matched.

## 2026-11-18, fourth session: cert-manager for the ALB certificate, and a new stall

- **The certificate fix worked.** With `enableCertManager: true` the controller, cert-manager and the Gateway were Synced and Healthy on the first sync, both Certificates were Ready, and the webhook's `caBundle` matched the Secret's CA. Two `helm template` renders are now byte-identical (they differed before). No webhook TLS errors, and Backstage, the demo apps and Grafana answered over HTTPS. Backstage was running the image built after the dependency upgrade (tar 6 to 7, no npm) without errors in its logs.
- **A different stall, not caused by the certificate.** The Cluster workflow's wait step still failed at its 25-minute limit. From 18:42 to about 18:56 the EKS API server answered about 145 writes with `etcdserver: throttle: too many requests`, including the Prometheus operator's Deployment, Services and about 40 rules. Argo CD retried once at 18:37, but the sync stayed in "Running" (waiting for a Prometheus that can't start without its operator) until it failed at 19:02. OpenCost crash-looped because it couldn't reach Prometheus.
- **Repair:** terminate the stuck operation (`status.operationState.phase: Terminating`), then start a new sync by setting `operation` on the Application. It was Healthy within 90 seconds, and I restarted OpenCost once Prometheus was up. All 30 applications ended Synced and Healthy.
- **What was loading etcd.** I measured instead of guessing: the EKS audit log (CloudWatch) showed Crossplane making about 95,000 mutating requests per 10 minutes, and `etcd_request_duration_seconds_count` showed about 30 real etcd writes a second at idle, 897 of 1,010 in 30 seconds being `update serviceaccounts`. All four AWS provider revisions shared one service account (`provider-aws`, from one DeploymentRuntimeConfig) and each claimed it as controller, so they rewrote its owner references in an endless loop, about 40 times a second for the whole session. Nothing in Argo CD, Kubernetes or Crossplane reported it; the cluster looked healthy. The fix was one runtime config, service account and Pod Identity association per provider (#73).
- **Result on the running cluster:** real etcd writes fell from 1,010 to 102 in 30 seconds (lease renewals only), and the service account stopped changing. On the rebuild, the idle audit rate was 187 mutating requests per 2 minutes, down from tens of thousands.
- **The throttle was not gone, but the build finished.** On the rebuild, Argo CD still logged about 200 `etcdserver: throttle` errors (20:45 and 20:49 to 20:50), during Crossplane's provider and CRD installation. This time kube-prometheus-stack recovered by itself, and the Cluster workflow's wait step passed in 12 minutes (last time it failed at 27). So the loop was a heavy contributor, not the only cause, and I don't know whether the earlier stuck sync can still happen.
- **Timing, the first usable number:** apply started 20:19, cluster Active 20:21, Cluster workflow 20:36:52 to 20:53:22 (16.5 minutes, of which the Argo CD wait was 12), all 30 applications Synced and Healthy. About 34 minutes from the start of the apply to a healthy platform, with no manual repair. One run, so not yet a measurement of variance.
- **Lesson:** a loop that makes no noise is invisible. Counting writes by user and resource in the audit log took ten minutes and found it; I'd have kept blaming Argo CD.
- **Process:** the auto-mode classifier denied me dispatching the apply workflow, so the user started it from the Actions tab.

## 2026-11-19, fifth and sixth sessions: Karpenter

- **Checking before building.** Instead of trusting the notes (which had already been wrong once), I tested what the account allows. The policy simulator said Karpenter's actions were allowed, and denied the known-blocked ones as a control. A dry-run said Spot would work. A real Spot launch through `CreateFleet` was refused: `ec2:RunInstances on instance/*`, explicit deny in the organization's service control policy. The dry-run had passed because it only checks the top-level call. **Lesson: a dry-run isn't a launch.** On-demand `m7i`, `m6i`, `c7i` and `t3` were allowed, so the README's "Free Tier-eligible types only" was out of date.
- **On-demand only.** No Spot, so no interruption queue. A NodePool limit of 8 vCPU caps what a mistake can cost (about $0.40 an hour). Terraform owns the instance profile, so Karpenter needs no IAM write access and leaves no IAM objects outside Terraform.
- **It worked on the first run:** the OCI chart pulled with no registry entry; three pods that didn't fit made it launch three nodes, each initialized about 30 seconds after the decision; deleting the pods removed the nodes about 3 minutes later.
- **The thing around it broke.** My cert-manager change from the previous session deadlocked on a build: the load balancer controller's webhook rejects every new Service until the controller runs, the controller needs a certificate, and the certificate needs cert-manager's webhook, whose Service the first webhook rejected. It worked in the earlier session only because of the order things happened to start in. Deleting the webhook configuration freed it within a minute. The fix is a namespace exemption on that webhook. I first looked at sync waves, and found Argo CD wasn't assessing the health of child Applications in this cluster, so a wave wouldn't have waited for anything.
- **A test that used the same wrong assumption as the code.** The destroy sweep looked for launch templates by a tag that Karpenter's documentation names and Karpenter doesn't set. The test's fake `aws` used the same tag, so it passed. I only saw it by reading the tags off a real template. Fakes built from the same belief as the code can't catch that belief being wrong.
- **The destroy sweep, tested for real:** with a Karpenter node still running, the destroy removed the controller's permissions first (so it couldn't launch replacements), terminated the node, and finished (122 resources) with nothing left blocking the VPC.
- **Rebuild time, second run:** apply started 18:23, Cluster workflow 18:40:01, healthy about 18:54: 31 minutes, no repair by hand (the first usable run was about 34 minutes). The etcd throttle still shows up (99 messages in the hour) and nothing stalled this time. Two runs now, 31 and 34 minutes.

## 2026-11-20, seventh session: making the repository public, and keeping the domain out of it

- **Before going public:** a gitleaks scan of all 128 commits found one hit, a sample JWT in a redaction test. The audit found no account ID, no IP address and no real ARN (the ones in examples are placeholders). The checklist of what *wasn't* safe was shorter: the self-hosted runner (only `cluster.yml` uses it, and only from `workflow_run` on main and manual dispatch, never a pull request), and the long-lived AWS access keys, which I rotated just before the switch.
- **After going public:** `aws-apply` now needs a reviewer, secret scanning and push protection are on, and fork pull requests need approval. These can't be set while the repo is private, which the setup script already warned about.
- **Branch protection fought the automation.** I required a pull request and four checks on main. The Backstage image workflow commits its own tag bump to main, so its last step was rejected, and a rerun can't push the same immutable ECR tag again. A personal repository can't add the Actions bot as a bypass actor (the API says the integration "must be part of the ruleset source or owner organization"). I relaxed it to blocking force-push and deletion. Lesson: a control that blocks your own deploy path will be switched off, so find out what writes to the branch before protecting it.
- **The domain.** Going public made the owner's domain visible in 24 files, though it is already public in DNS and certificate logs. I kept it out of the files (they carry `idp.example.com`) and supplied it from outside: a GitHub variable, Terraform variables with no default, a root-app parameter, and a `publicDomain` value in the Terraform-generated `aws-platform` EnvironmentConfig. Argo CD applies Kustomize patches for the Gateway listeners, Grafana's route and the Slack message. Git history still has the old domain in 13 commits; I didn't rewrite it.
- **My bug, found by the cluster.** I added a second `extraEnvVars` key next to the one that sets `NODE_PATH`. The later key won, `NODE_PATH` was lost, and Backstage crash-looped with `Cannot find module 'pg'`. `make test` passed. The existing check compared a variable that was missing, and a comparison on nothing passes (the file even had a comment warning about it). It now counts matches. Lesson: a check that cannot fail on absence isn't checking the thing.
- **A test that only failed on the runner.** The new domain test used `yq -i` in a container. On a Mac the mount is permissive, so it passed. On the runner the container couldn't write files the runner owned, so four checks failed. `#81` merged with the failing check, because I had left admins able to bypass.
- **What the session verified:** both Gateway listeners, Grafana's route and the visits URLs carried the real domain, Backstage's GitHub sign-in redirect used it, the loaded Alertmanager config had it, and a test alert posted to Alertmanager arrived in Slack with the right dashboard link. Not verified: the production profile (the session used the study profile).
- **Timing, not a clean rebuild number:** apply 14 minutes 40 seconds, then the Cluster workflow ran 12:33 to 13:05 and failed its 25-minute wait because of the Backstage bug above, so this is not a build time.
- **Process:** the classifier blocked my first mutation checks, which restored files with `git checkout` and would have wiped my uncommitted edits. I committed first and used file copies.

## 2026-11-21 to 22, eighth session: deploying from other repos, and moving the images to ECR

- **Most of it already existed.** An ApplicationSet already deployed a folder of `WebService` files from another repo (`apps/*.yaml`). What was missing was the image: the cluster only runs `ghcr.io/kushan94` images signed by a workflow in the platform repo, so an app repo that built its own would be refused. Reading the policy before designing saved building a second mechanism.
- **A reusable workflow, `app-deploy.yml`, as the only way in.** App repos call it: it scans, builds, signs and commits the tag to their deploy folder. I had expected to widen the signing policy. I didn't need to: the certificate's identity comes from the *called* workflow, not the app repo, so the existing regex already trusts it. I checked it with `cosign verify` rather than assuming. One trap: cosign v2 reports "no signatures found" for an image signed by v3, which stores signatures as referrers in a newer format. Verify with v3.
- **A guard the signature can't give.** The signature doesn't record which branch called the workflow, so a feature branch could have got an image the cluster trusts. The workflow refuses to run anywhere but the default branch. Its shell steps are tested by extracting them from the workflow file and running them against a real repo with a remote; breaking the guard, the one-image-line check and the retry each made the test fail.
- **ghcr.io first, and it was private.** The first build worked, but the package came out private and the cluster couldn't have pulled it. The cause was simple in hindsight: the sample repo was private, and a package takes its repo's visibility. Package visibility can't be set through the API, so it is a manual step per app. (ADR 0030 first described this wrongly, as the source label failing to work.)
- **Why ECR, for the article.** It is the AWS-native answer, images are private by default, and there is no visibility step. The cost is that, with the OIDC provider blocked, each app repo needs a stored AWS key. I gave each app its own push-only user, limited to its own repository, created by the bootstrap stack for every file in `apps/`, so one leaked key can't push to another app's registry. A new file in `apps/` gets a registry on the next bootstrap apply.
- **Keeping the account ID out of a public repo.** An ECR address contains it. App repos write `image: idp-apps/<repo>:<tag>`, and the WebService composition adds the registry from the `aws-platform` EnvironmentConfig, which Terraform generates. The same trick as the domain, and the policies match the address by pattern for the same reason, with the signature as the real gate. A Kyverno test covers a lookalike host and another region, and a mutation of the rule was caught.
- **What failed: environment secrets don't reach a called workflow.** I stored the key in an environment limited to main, and named that environment in the reusable workflow's job. The first ECR build failed at the AWS login with no credentials at all. Searching confirmed it: environment secrets aren't passed into a called workflow, even when the job names the environment. The key is now two repository secrets that the caller passes explicitly. That loses the "only main can use it" limit. I accepted it because the key can only push to one immutable-tag registry, the cluster only runs images the platform workflow signed, and that workflow signs only from the default branch, so someone with write access can push junk but can't deploy it. The repo no longer needs to be public for this. It is another reason to want OIDC.
- **The risky part worked.** Kyverno has to read signatures from private ECR. Its docs describe IRSA (blocked here) or a node role, and don't mention Pod Identity. I gave the admission controller a Pod Identity role limited to `idp-apps/*` and it worked first time; its log shows the cosign check on the ECR image, plus a harmless "Could not save cache" because its filesystem is read-only.
- **Checked on a running study-profile cluster:** 32 of 32 applications Synced and Healthy; the WebService's short image name became the full ECR address in the Deployment; both pods pulled it in under a second and started; an unsigned copy of the image pushed to the same repository was denied with "must be signed", and the signed one was admitted (server-side dry runs). I deleted the test image afterwards. Not tested: a pull on a Karpenter-launched node, and the production profile.
- **Small slips, for honesty.** I ran a command whose output printed the AWS account ID in the terminal; it never reached Git. I pushed a follow-up commit to a branch whose pull request had already merged, so it needed a new pull request. The cluster was gone by morning: the scheduled destroy had run at 01:51 UTC instead of 22:00 (GitHub delays scheduled runs), and nothing billable was left.
- **Risks recorded in ADR 0030, with follow-ups:** every repo under the account that calls the workflow is inside the trust boundary and the scan is the only gate; callers use `@main` so a bad change reaches every app at once; the default-branch guard trusts whoever can push there. Next: pin callers to a tag, require review under `.github/workflows/`, test a Karpenter-node pull, then replace the stored keys with OIDC.
