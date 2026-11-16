---
name: image-or-admission
description: Pods show ImagePullBackOff or ErrImagePull, or the WebService is refused by a policy (latest tag, registry, signature, pod security)
tools: list_pods, get_events, get_resource
---
# Image pull errors and policy refusals

Two different failures look alike from outside: **the image can't be pulled** (a pod exists and is stuck), or **a policy refused the workload** (no pod is created at all).

**Image pull (`ImagePullBackOff`, `ErrImagePull`):** `list_pods` shows the waiting reason and `get_events` the registry's message.
- `not found` or `manifest unknown`: the tag doesn't exist. Compare the tag in the `WebService`'s `spec.image` with what was built. For `ghcr.io/kushan94/idp-visits` the tag is the commit SHA.
- `unauthorized` or `denied`: the registry needs credentials, or the package is private. Packages under `ghcr.io/kushan94` must be **public**: Kyverno reads their signatures anonymously, and the platform sets no pull credentials on pods.
- Timeouts: the node can't reach the registry. On EKS check the NAT gateway and egress; this is not a workload problem.

**Policy refusals:** nothing appears in `list_pods`. Look at the **`WebService`** with `get_resource` (kind `webservices`) and read its `Synced` condition, which carries the policy's message.
- `disallow-latest-tag`: "use a version tag or digest instead of :latest or no tag". Pin a version.
- `allowed-registries`: images may only come from `ghcr.io/kushan94`, `ghcr.io/stefanprodan`, `ghcr.io/cloudnative-pg` and `docker.io/nginxinc`. Anything else is refused.
- Signed images: an image under `ghcr.io/kushan94/*` must be signed by one of this repo's GitHub Actions workflows on `main`. An image pushed by hand or from a branch is refused. Kyverno must also reach GHCR and Sigstore, so a network problem there refuses valid images too.
- `require-resources`: the composition sets requests and a memory limit, so services created through it pass. A refusal here points to a hand-made workload.
- `prod-replicas`: see `webservice-not-ready`.
- Pod security (`restricted`): no root, no privilege escalation, all capabilities dropped. An image that names its user instead of numbering it needs `spec.runAsUser`.

**Fix:** change `spec.image` (or `runAsUser`) in the service's `WebService` in Git. Never use a tag that moves.
