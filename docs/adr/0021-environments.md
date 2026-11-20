# ADR 0021: Environments as namespaces, promoted through Git

**Status:** Accepted (2026-11-13)

## Context
Each service ran once, and a new image went straight to the only copy. Production platforms give a service several environments, typically dev, staging and prod, and move a tested build from one to the next on purpose. Running a cluster per environment would multiply the cost of every session.

## Decision
- **Environments are namespaces in one cluster:** `<team>-dev`, `<team>-staging` and `<team>-prod`.
- **A service with environments uses a Kustomize layout:**
  ```
  workloads/<team>/<service>/base/            the WebService, without an image
  workloads/<team>/<service>/envs/<env>/      image, replicas and other overrides
  ```
  The `workload-environments` ApplicationSet makes an Argo CD app for each `envs/<env>` folder, deploying to `<team>-<env>`. Single-file services in `workloads/<team>/` keep working as before.
- **Each environment's namespace is labelled `platform.example.org/environment: <env>`** by Argo CD, next to the guardrail labels. Policies key on it: Kyverno's `prod-replicas` refuses a prod `WebService` with fewer than 2 replicas.
- **One identity across environments.**
  - The base sets the service's `backstage.io/kubernetes-id`, and each environment's kustomization labels the `WebService` with its environment. The composition copies both onto the pods.
  - One Backstage component shows every environment's pods and Argo CD apps.
  - The Grafana dashboard has an environment picker, alerts carry an `environment` label, and logs are labelled the same way.
- **Data never crosses environments.** A service's managed database is named `<namespace>-<name>`, so each environment gets its own. Network policies already block traffic between namespaces.
- **Promotion is a pull request.** New builds go to dev automatically.
  - The `Promote` workflow (`service`, `to: staging | prod`) copies the exact image from the previous environment's file into the next, and opens a pull request showing the old and new image. So prod only runs what staging ran, and merging the pull request is the approval.
  - The repo doesn't let Actions open pull requests, because that setting would also let workflows approve them. So the workflow falls back to pushing the branch and linking a one-click pull request in its summary.
- **The Backstage template creates services with environments by default.** It writes `base` and `envs/{dev,staging,prod}`, with prod at no fewer than 2 replicas, and a catalog entry that shows every environment. Unchecking the option gives the single-file layout. `make test-template` renders both variants with Nunjucks the way Backstage does, and validates the result.

## Alternatives considered
- **A cluster per environment:** the strongest isolation, and what larger organizations do for prod. It would double or triple the cost of every session, and needs Argo CD managing several clusters. The Git layout maps onto it later by pointing each environment's destination at another cluster.
- **Branches per environment:** promotion by merging branches, which mixes up unrelated changes and makes the difference between environments hard to see.
- **Helm values files per environment:** works, but the platform's resources are already plain YAML, which Kustomize patches without templates.

## Consequences
- **Each environment uses its own resources:** visits now runs 4 pods and 3 databases instead of 2 pods and 1.
- **Public URLs include the environment,** for example `visits-demo-prod.idp.example.com`.
- **Namespace-level isolation is weaker than separate clusters.** A cluster-wide failure, or a mistake in a cluster-scoped resource, affects every environment at once.
- **A team directory holding only services with environments still gets an empty `workload-<team>` app and namespace,** from the original ApplicationSet. That's harmless, and could be avoided by moving such teams to a separate folder.
