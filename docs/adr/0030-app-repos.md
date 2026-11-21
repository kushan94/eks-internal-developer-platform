# ADR 0030: Deploying from application repos with a shared build workflow

**Status:** Built (2026-11-21). The first real run, from `idp-sample-service`, passed the scan, pushed and committed the tag. The new ghcr package came out private, so a cluster couldn't pull it until it was made public by hand. With the package public, `cosign verify` against the policy's identity regex passed on the built image, which confirms the signature carries this repo's workflow identity. Admission on a cluster is not yet confirmed.

## Context
`apps/*.yaml` already deploys a folder of `WebService` files from another repo (`external-apps`). That covers the manifests, but not the image. The cluster only runs `ghcr.io/kushan94` images signed by a workflow in this repo (`verify-platform-images`), so an app repo that builds and signs its own image would be refused, and one that doesn't sign would need an exception.

## Decision
- **A reusable workflow, `.github/workflows/app-deploy.yml`,** that app repos call on pushes to main. It lints and scans the Dockerfile with the platform's scan, pushes `ghcr.io/<owner>/<repo>:<commit>`, signs the digest and commits the new tag to the app repo's `deploy/web.yaml`, which Argo CD watches.
- **The signature carries the reusable workflow's identity.** Fulcio takes the certificate's subject from the called workflow (`job_workflow_ref`), not from the app repo. The existing policy regex, which accepts any workflow in this repo on main, therefore already trusts it, and the policy didn't change. An image can only get a trusted signature by going through this workflow's scan.
- **The workflow refuses to run from any branch but the repo's default.** The signature doesn't record the caller's branch, so without the guard a feature branch could obtain a trusted image.
- **Repos are onboarded by hand** with a pull request that adds `apps/<name>.yaml`. A Backstage form that creates the repo and opens that pull request can come later.
- **The tag line is exact.** The step fails unless the deploy file has exactly one `  image:` line, so a wrong path can't silently deploy nothing.

## Alternatives considered
- **Allow unsigned images from app repos:** least work, but removes the check that every image passed the scan.
- **Widen the policy to any workflow in any repo under the account:** each app repo could then sign without scanning, and the policy would depend on repo naming.
- **Update tags from this repo (Argo CD Image Updater or a dispatch):** keeps the tag out of the app repo, but adds a component and a second place that holds the truth about what runs.

## Consequences
- **App repos need only `contents: write`, `packages: write` and `id-token: write` in the calling job,** and a `deploy/` folder.
- **The first package push is private,** although the image carries the source label (confirmed 2026-11-21: an anonymous pull was refused). Package visibility can't be set through the API, so each app repo needs a one-time change to Public in its package settings, or an image pull secret.
- **The workflow calls the scan by its full name at `@main`,** because a `./` path would look in the app repo. A change to the scan reaches app repos when it merges, not when a pull request tests it.
- **Not yet done:** promotion across environments in an app repo (the Promote workflow edits only this repo), and a Backstage form.

## Risks and follow-ups
- **The trust boundary is every repo under the account that calls the workflow.** The cluster trusts the platform workflow's signature, so the scan is the only gate: a compromised app repo or token can ship any code that passes it. The `workloads` project limits manifests, not code.
- **App repos call the workflow at `@main`,** so a bad change to `app-deploy.yml` or `quality-image.yml` reaches every app at once, and this repo's branch protection only blocks force-push and deletion.
- **The branch guard trusts the app repo's default branch.** Whoever can push to it can deploy, and nothing here requires review in the app repo.
- **Unverified:** admission on a real cluster, and a private package failing as `ImagePullBackOff`. Verify locally with cosign v3: the signature is stored in the newer bundle format, and cosign v2 reports "no signatures found".

Follow-ups, in order:
1. Pin app repos to a tag or SHA of the workflow instead of `@main`, and release the tag deliberately.
2. Require review for changes under `.github/workflows/` (a CODEOWNERS rule, or a ruleset if the Actions push problem in the notes is solved).
3. Run an admission test on a real cluster, then record the result here. (The signature itself is verified.)

### Moving to ECR (2026-11-22: decided to do it now, with stored keys)
The article is stronger with an AWS-native registry, so this is being done before OIDC (PR #37). With the OIDC provider blocked, each app repo holds its own push-only key, until OIDC replaces the keys with a role. The steps:
1. **Registries and keys (done in the bootstrap stack):** `infra/bootstrap/apps.tf` creates `idp-apps/<repo>` (immutable tags, scan on push, last 10 images kept) and a user that can push only to it, for every file in `apps/`. Registries outlive the nightly destroy. `scripts/app-repo-setup.sh <repo>` stores the key in the app repo's `aws-build` environment, which only main can use.
2. The reusable workflow and the policies move to ECR, then an admission test on a cluster.

Things to get right:
- Kyverno needs credentials, through Pod Identity, to read signatures from private ECR. A mistake there makes `required: true` refuse every pod.
- The policies name `ghcr.io/kushan94/`. An ECR address contains the account ID, which is kept out of Git, so it has to be passed in like the domain, with a test that a wrong or missing value can't allow too much or reject everything.
- Tags are immutable, so a rerun of the same commit can't push again.
- ECR repositories need creating per app, and the nightly destroy must leave their images alone.
- Both registries have to be allowed during the move, because the Backstage and visits images stay where they are.
