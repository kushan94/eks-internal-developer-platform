# ADR 0006: Run Terraform from GitHub Actions with access keys

**Status:** Accepted (2026-11-05)

## Context
Infrastructure changes should be reviewed and applied the same way every time, not from a laptop. GitHub's usual keyless sign-in to AWS needs an IAM OIDC provider, which the AWS Free plan denies. The repo is public, so Actions logs are public too.

## Decision
- A one-time bootstrap stack, applied locally, creates an S3 state bucket and two IAM users. `github-plan` has read-only access, and `github-apply` has administrator access.
- Their access keys are stored as GitHub environment secrets:
  - `aws-plan` has the read-only key, for plans on pull requests.
  - `aws-apply` has the admin key, needs approval and only runs from `main`.
  - `aws-destroy` has the admin key, only runs from `main`, and is used by the nightly destroy.
- Apply runs only from a manual workflow run, after a plan whose summary is visible while approval is pending.
- A scheduled run destroys everything at 22:00 UTC each night, so a forgotten session can't use up the credits.
- Logs print resource addresses and actions only, never attribute values, and mask the account ID and allowed IP.
- Actions are pinned to commit SHAs.

## Consequences
- The access keys are long-lived, so they should be rotated, which means replacing them in the bootstrap stack and rerunning `make github-setup`, and removed once the project ends.
- `github-apply` has administrator access, so the `aws-apply` approval rule and the `main`-only restriction are the main protections.
- Pull requests from forks only run `validate`, because they don't get secrets.
- If the account moves to the Paid plan, switch to GitHub OIDC with short-lived role credentials and delete both users.
- The bootstrap stack's state is local and holds the access keys, so it must never be committed.
