# ADR 0030: Deploying from application repos with a shared build workflow

**Status:** Built, not yet run end to end (2026-11-21). The workflow's shell steps are tested; the signing identity and the registry visibility are not yet confirmed against a real app repo and cluster.

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
- **The first package push may be private.** The image carries the source label, so it should take the repo's visibility, but I haven't confirmed that. A private package needs an image pull secret, or setting it public once.
- **The workflow calls the scan by its full name at `@main`,** because a `./` path would look in the app repo. A change to the scan reaches app repos when it merges, not when a pull request tests it.
- **Not yet done:** promotion across environments in an app repo (the Promote workflow edits only this repo), and a Backstage form.
