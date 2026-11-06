# Services from other repos

Each YAML file here deploys a folder of `WebService` files from another repo. For example, `apps/orders.yaml`:

```yaml
name: orders
namespace: team-a
repoURL: https://github.com/kushan94/orders-service.git
path: deploy
targetRevision: main
```

The repo must be under the GitHub account in `gitops/root/values.yaml`, and the GitHub App must be installed on it. The `workloads` project only allows `WebService` resources, in namespaces other than the platform's own.
