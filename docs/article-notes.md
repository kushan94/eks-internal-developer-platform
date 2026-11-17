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
- **What happened:** `https://hello-demo.idp.skyforgelab.cloud` answered HTTP 200 from the internet.
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

