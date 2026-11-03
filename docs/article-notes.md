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

