# ADR 0012: Guardrails with Pod Security Admission, Kyverno and signed images

**Status:** Accepted (2026-11-09)

## Context
Developers can now create services, databases and public URLs from a form. The platform should stop unsafe or unpredictable workloads before they run: images that change under you, images from unknown sources, containers that can run as root, and pods without resource limits. The rules should explain themselves, so a developer can fix their service without asking the platform team.

## Decision
Guardrails apply to **workload namespaces** only. The two ApplicationSets that create team namespaces label them through `managedNamespaceMetadata`. Platform namespaces aren't labeled, so the rules can't break Argo CD, Crossplane or Kyverno itself.

- **Pod security:** Kubernetes' built-in Pod Security Admission enforces the `restricted` profile in labeled namespaces: no root, no privilege escalation, all capabilities dropped, and the default seccomp profile. Nothing extra to install or maintain.
- **Kyverno 1.19 `ValidatingPolicy` (CEL):**
  - `disallow-latest-tag`: images need a version tag or digest.
  - `allowed-registries`: images come only from `ghcr.io/kushan94`, `ghcr.io/stefanprodan`, `ghcr.io/cloudnative-pg` and `docker.io/nginxinc`. Kyverno's image library normalizes references, so `nginx` counts as `index.docker.io/library/nginx`.
  - `require-resources`: containers set CPU and memory requests and a memory limit.
- **Signed images:** an `ImageValidatingPolicy` requires `ghcr.io/kushan94/*` images to be signed by one of this repo's GitHub Actions workflows on `main`. The visits workflow signs each image with cosign keyless: the workflow's GitHub identity goes into a short-lived certificate recorded in Sigstore's public transparency log, so there are no signing keys to store or rotate.
- **Secure by default:** the `WebService` composition sets the security context and default resources, so services created through the golden path pass every rule. An optional `runAsUser` covers images that name their user instead of numbering it.
- **Feedback:** the policies also check Deployments (autogen), so Crossplane's apply is rejected and the `WebService` shows the reason in its `Synced` condition, for example `Policy disallow-latest-tag failed: use a version tag or digest instead of :latest or no tag`.

## Alternatives considered
- **Kyverno's older `ClusterPolicy`:** more examples online, but the CEL-based policy types are where Kyverno is heading, and CEL is the same language as Kubernetes' own ValidatingAdmissionPolicy.
- **Kubernetes ValidatingAdmissionPolicy alone:** no image signature verification and no image parsing library.
- **Signing with a stored key:** a key pair is one more secret to protect and rotate. Keyless ties the signature to the workflow that built the image.

## Consequences
- **Developers can only use approved registries.** Adding one is a one-line change to `allowed-registries`.
- **Signature checks need the internet:** Kyverno reaches GHCR and Sigstore when pods start. If they're unreachable, pods with `ghcr.io/kushan94` images are refused.
- **Packages must be public:** Kyverno reads signatures anonymously, so `ghcr.io/kushan94` packages need public visibility.
- **The Backstage image isn't signed yet.** It lives in ECR, in a platform namespace the rules don't cover.
- **Test namespaces created by hand aren't guarded** unless labeled, which `make test-db` relies on to run its `psql` pods.
- **Kyverno's chart renders some CRDs with empty labels,** so Argo CD compares the Kyverno app with server-side diff to avoid a permanent out-of-sync status.
