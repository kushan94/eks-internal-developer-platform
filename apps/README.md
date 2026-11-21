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

An app repo that builds its own image calls the platform's `app-deploy.yml`. It scans the image, pushes it to the platform's private ECR registry as `idp-apps/<repo>`, signs it, and commits the new tag to `deploy/web.yaml`, which Argo CD then deploys. The cluster trusts the signature because it comes from this repo's workflow, so an image can't skip the scan.

The deploy file names the image as `idp-apps/<repo>:<commit>`, without the registry address, which holds the AWS account ID. The WebService composition adds the address from the cluster's environment.

To onboard a repo:
1. Add `apps/<repo>.yaml` here and merge it.
2. Run `make bootstrap`, which creates the repo's ECR repository and a push-only key for it, then `scripts/app-repo-setup.sh <repo>`, which stores that key in the repo's `aws-build` environment, limited to main. The repo must be public, because GitHub can't limit an environment to a branch in a private repo on the free plan.
3. Put this in the app repo as `.github/workflows/deploy.yml`:

```yaml
name: Deploy
on:
  push:
    branches: [main]
    paths-ignore: [deploy/**]
jobs:
  deploy:
    permissions: { contents: write, id-token: write }
    uses: kushan94/eks-internal-developer-platform/.github/workflows/app-deploy.yml@main
```

It builds `Dockerfile` at the repo root and edits `deploy/web.yaml`, which must have exactly one `  image:` line. The `context`, `file` and `deploy-file` inputs change those. It only runs from the repo's default branch. See [ADR 0030](../docs/adr/0030-app-repos.md).
