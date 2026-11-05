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

