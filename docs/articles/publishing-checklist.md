# Publishing checklist for the Medium article

The article is `building-an-idp-on-eks.md`. Work through this before posting.

## Decisions and facts to settle
- **The repository is private.** The article links to it as the place to read the code. Make it public first, or change the two links and the sentence that says the code is there.
- **The rebuild time is in the article, from two runs:** 34 minutes (2026-11-18) and 31 (2026-11-19, with Karpenter and the cert-manager deadlock fix), both from the start of the apply to a healthy platform with no repair by hand. If the opening still quotes the earlier 37-minute figure, replace it. Two runs say little about variance.
- **"Where it stands" and the new Karpenter section reflect 2026-11-19.** They say the dashboard and assistant were left out on purpose, and that Karpenter is on-demand only because Spot is denied. Check the Karpenter figures against ADR 0029 if you edit them.
- **The Backstage fix is confirmed on EKS** (second session) and the article says so. Nothing to change unless the launcher changes.
- **The assistant is deferred (2026-11-19) and has not been run against the real model.** The last section says so, and should say it is a feature kept for later, with why (see ADR 0026, "Enabling it later"). Bedrock isn't usable from this account yet. If you run `scripts/diagnose-eval.sh --compare` with a key before publishing, add the result (diagnosed N of 7 without and with runbooks, and the cost). That is the most interesting number the article could have.

## Images
- **A diagram of the shape.** The article uses a numbered list, because Medium doesn't render ASCII diagrams. A simple SVG of Backstage, GitHub, Argo CD, Crossplane and the resources it creates would help.
- **Screenshots** are in `docs/articles/images/` on the `cluster-assistant` branch (PR #52): the dashboard overview, the events tab and the assistant's answer. They come from a demo cluster, so they contain no account IDs. Check any others before using them.
- The Backstage template form and a Slack alert would suit the opening sections.

## Medium formatting
- Only `##` headings are used, because Medium has two heading levels.
- No tables. Code blocks have no syntax highlighting on Medium; they are short, but a longer one would be better as a GitHub Gist.
- The OIDC section uses placeholder IDs (`OWNER@123/NAME@456`) on purpose.

## Posting
- Tags: `Kubernetes`, `Platform Engineering`, `AWS`, `DevOps`.
- Cross-post a shorter version to LinkedIn, and consider r/kubernetes and r/devops.
- Candidates for follow-up articles: the Crossplane composition that serves two runtimes, and network isolation with the AND-versus-OR trap.

## Numbers that must stay true
Each traces to a record in the repo, so re-check it if the platform changes.
- About $0.40 an hour for the study shape, and roughly $0.60 for production (notes, ADR 0016).
- The EKS control plane costs $0.10 an hour (notes).
- The destroy ran as late as 03:56, and a session was started at 21:55 (notes).
- 29 pods per node, raised to 110 by prefix delegation (notes).
- A pod with 0.25 CPU and 256 MiB cost $0.008962 an hour (ADR 0025).
- A deliberately broken service fired in Slack after exactly five minutes (notes).
- The two gaps that writing the runbooks found, and that ADR 0027 fixed: `platform/crossplane/webservice/composition.yaml` and `definition.yaml`. `scripts/check-runbooks.sh` verifies the defaults, bounds and probe timings the runbooks state. The article says the fix hasn't run on EKS yet: update that after the EKS session.
