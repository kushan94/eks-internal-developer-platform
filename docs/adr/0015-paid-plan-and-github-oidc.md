# ADR 0015: Move to the Paid plan, and sign CI in to AWS through GitHub OIDC

**Status:** Accepted (2026-11-13). Replaces the access keys in [ADR 0006](0006-infrastructure-pipeline.md) and [ADR 0010](0010-backstage-in-cluster.md).

## Context
The platform was built on the AWS Free plan, which denies IAM OIDC providers, Spot instances, `ec2:CreateFleet` and instance types outside the Free Tier. Several production practices were blocked by those limits, starting with keyless CI. The Free plan also ends six months after the account is opened, or when the credits run out, and then the account closes.

GitHub Actions used three IAM users with long-lived access keys: `github-plan`, `github-apply` and `github-image-push`. Keys like these leak through logs, forks and laptops, and need rotating.

## Decision
- **Upgrade the account to the Paid plan.** The remaining credits ($146 at the time) still apply to bills. The nightly destroy and the $50 budget alert stay.
- **GitHub OIDC for every workflow that uses AWS.** The bootstrap stack creates the `token.actions.githubusercontent.com` provider and three roles under `/github/`, with the same permissions the users had:

  | Role | Trusted GitHub environments | Permissions |
  |---|---|---|
  | `github-plan` | `aws-plan` | ReadOnlyAccess, the state lock, and the two secrets Terraform writes |
  | `github-apply` | `aws-apply`, `aws-destroy` | AdministratorAccess |
  | `github-image-push` | `aws-build` | Push to the Backstage ECR repository |

- **Trust is scoped by environment, not branch.** Each role's trust policy matches the token's `sub` claim, `repo:<owner>/<repo>:environment:<name>`. The environments keep their own rules: `aws-apply` needs approval and only runs from `main`, and `aws-destroy` only runs from `main`. So the apply role is only reachable through those rules.
- **Only jobs that sign in to AWS get `id-token: write`.** The permission is set per job, not per workflow.
- **The role ARNs are environment secrets** (`AWS_ROLE_ARN`), because they contain the account ID and the repo is public.
- **The IAM users, their keys and the key secrets are deleted.**

## Alternatives considered
- **Keep the access keys and rotate them:** less change, but rotation is manual, and a leaked key works from anywhere until someone notices.
- **Trust by branch (`ref:refs/heads/main`) instead of environment:** pull request plans run from other branches, and the environment is where approval lives, so it's the better boundary.
- **One role for everything:** simpler, but a plan on a pull request would then have administrator access.

## Consequences
- **No long-lived AWS credentials exist outside AWS.** Each job gets credentials for up to an hour.
- **The apply role still has AdministratorAccess.** Narrowing it to the services Terraform manages is a later step.
- **The bootstrap stack's state no longer holds access keys,** though it should still stay out of Git.
- **The Free plan limits are gone,** so Spot, Karpenter, IAM Identity Center and larger instance types are now options. Usage beyond the credits is billed.
