# Services from other repos

Each YAML file here deploys a folder of `WebService` files from another repo. For example, `apps/orders.yaml`:

```yaml
name: orders
namespace: team-a
repoURL: https://github.com/kushan94/orders-service.git
directory: deploy
targetRevision: main
```

The repo must be under the GitHub account in `gitops/root/values.yaml`, and the GitHub App must be installed on it. The `workloads` project only allows `WebService` resources, in namespaces other than the platform's own.

## Building the image in the app repo

An app repo that builds its own image calls the platform's `app-deploy.yml`. It scans the image, pushes it to `ghcr.io/<owner>/<repo>`, signs it, and commits the new tag to `deploy/web.yaml`, which Argo CD then deploys. The cluster trusts the signature because it comes from this repo's workflow, so an image can't skip the scan. Put this in the app repo as `.github/workflows/deploy.yml`:

```yaml
name: Deploy
on:
  push:
    branches: [main]
    paths-ignore: [deploy/**]
jobs:
  deploy:
    permissions: { contents: write, packages: write, id-token: write }
    uses: kushan94/eks-internal-developer-platform/.github/workflows/app-deploy.yml@main
```

It builds `Dockerfile` at the repo root and edits `deploy/web.yaml`, which must have exactly one `  image:` line. The `context`, `file` and `deploy-file` inputs change those. It only runs from the repo's default branch. See [ADR 0030](../docs/adr/0030-app-repos.md).
