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

