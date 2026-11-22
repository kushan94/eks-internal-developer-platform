# I Let an AI Agent Build My Platform From Zero. These Are the Rules That Kept It Honest.

*What worked, what broke, and the decisions that were mine*

<!-- Draft. Anything in [YOU: ...] is a guess at your reasons or feelings: replace it, or cut the sentence. -->

I wanted to see how far an AI coding agent could take a platform engineering project from nothing. Not a demo: an internal developer platform on AWS EKS, with Crossplane, Argo CD and a self-hosted Backstage, built from an empty account. I used Claude Code for most of the typing, and I made the decisions and approved every change that touched AWS.

It worked better than I expected, and it also failed in ways I couldn't have predicted. The code isn't what I'd tell you about. The rules around it are, because they decided whether I could trust what it built.

## The rule I set before anything else

Every night at 22:00 UTC, a scheduled workflow destroys the whole thing: the cluster, the databases, the load balancer, the DNS records. Next session starts from nothing, and everything has to come back from Git, Terraform and a few secrets.

I did it partly because the platform runs on AWS credits and the EKS control plane alone costs $0.10 an hour. [YOU: but also because you knew an agent would be writing most of it, and wanted something that would tell you when it was wrong.]

That turned out to be the most useful decision of the project. An agent can write a convincing destroy script and a convincing test for it. A cluster that has to be rebuilt tomorrow can't be argued with. The first real destroys found that the load balancer controller rebuilt an ALB while Terraform was deleting it, that ExternalDNS rewrote records I had just removed, and that Loki's volume survived every destroy because Kubernetes keeps a StatefulSet's claims. None of that showed up in a test.

## I approve every apply

I gave the agent wide freedom to read, write and test, and kept one gate: it never creates AWS resources on its own. It opens a pull request, I merge it, and I dispatch and approve each apply and destroy. At one point its attempt to start one itself was refused by the permission setup, which is how I'd want it to go.

The gate earned its keep. On the last day, a policy change of the agent's blocked every signed image on a production-shaped cluster. I'll come back to it, but the point here is where it happened: on a study cluster I was watching, which I could destroy in 16 minutes, and not on anything that mattered. [YOU: add how it felt to see it fail with you in the loop.]

## "Can you do it yourself inside a Docker container?"

For a while I was the one checking things. The agent would produce an architecture diagram, I'd look at a screenshot and tell it what was wrong, and we'd go around again. Then I asked whether it could verify its own work in a container.

It could, and the pattern stuck. After that, the checks that mattered ran without me: the workflow's shell steps pulled out and run against a real git repo, mutated copies of the code to confirm the tests failed when they should, Terraform validated on a clean copy in Docker. I stopped being the test harness and went back to deciding things. [YOU: if this changed how you worked, say how.]

It's not a cure. Which brings me to the failure.

## The test that passed while production was down

To let applications in other repos deploy through the platform, the cluster has to trust images that a shared build workflow signs. Kyverno checks the signature. When I wanted it to trust a second signing workflow, the agent put two identities in one attestor.

Kyverno accepts one identity per attestor. The policy denied every signed image, including the ones already running. `make test` passed, because the Kyverno CLI test can't run the signature verifier. I found it on the cluster, from a Crossplane event and then Kyverno's logs, and the fix was one attestor per workflow.

The lesson isn't that the agent made a mistake. A person would have made it too. The lesson is that tests written by the same author, from the same understanding, share the same blind spot, and the only thing that disagreed was a real cluster. I verified the fix live with server dry-runs against the cluster, and the repo's tests now cover both identities. [YOU: say whether a cluster check before merging is now a rule.] It cost an afternoon, and the lesson is the part I'd keep.

## Cutting what we'd already built

We built a dashboard with an AI assistant that diagnoses cluster problems, with read-only tools, a token budget and a daily spend cap. It was tested against deliberately broken workloads on kind. It had no login, and I couldn't call a model from my AWS account: Claude on Amazon Bedrock needed a use-case form for the older models and wasn't available for the newest ones here.

I decided to keep it as a feature to turn on later. [YOU: your reason in your own words.] An agent will happily keep building, and "built and tested" feels like "done". But it had never run against the real model, so I couldn't say how often it was right, and I didn't want to ship what I couldn't run. The article says so, and I think it's stronger for it.

## Choosing the harder registry

For application repos, the simplest registry was GitHub's. I asked to move to ECR and to record the risks first, and told the agent I thought AWS would make a better article. [YOU: confirm, or give the real reason.]

It was more work. Each app gets its own repository and a push-only key. Images are immutable. The cluster reads signatures from private ECR with its own Pod Identity role. And it taught me two things I wouldn't have found otherwise: environment secrets don't reach a reusable workflow, and a signature carries the shared workflow's identity, not the calling branch, so the workflow has to refuse to run anywhere but the default branch. I also corrected a plan that assumed I could limit a key to `main`: my sample repo wasn't public, so its environment couldn't be limited. That became repository secrets, written down as a known limit.

In the end, a small Go service in its own repo built, scanned, signed and pushed an image. The cluster admitted it and ran it, and refused an unsigned image from the same registry. That's the moment the project felt like a platform.

## What I'd tell someone starting

- **Set the rules before the code.** A nightly destroy, a human gate on anything that creates resources, and no feature counts as done until it has run on a real cluster.
- **Make the agent verify itself, and then don't trust the verification.** It's good at the first part. The Kyverno incident is the second.
- **Cut things.** An agent has no cost for building more, but you do.
- **Write the failures down as they happen.** I kept notes after every session, and the article is mostly those notes. Memory is the thing the agent doesn't have between sessions, and you do.

The platform rebuilds from nothing in about half an hour, at roughly sixty cents an hour in its production shape. The agent wrote a great deal of it. The part that was mine was deciding what to build, what to refuse and what to throw away, and I'd do it the same way again.

---

*The code, 30 decision records, and notes on everything that broke: [github.com/kushan94/eks-internal-developer-platform](https://github.com/kushan94/eks-internal-developer-platform).*
