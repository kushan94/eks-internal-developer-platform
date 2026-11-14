# ADR 0026: A read-only AI assistant for diagnosing the cluster

**Status:** Proposed (2026-11-14). The tools and their tests are built; the model has not been run against the fault set yet, and the assistant isn't deployed.

## Context
When a service breaks, an engineer reads pod status, events, logs, the objects around them and sometimes metrics, then puts the cause together. That is a good job for a model with tools, if it can't make things worse. The platform already holds what it needs to know: who owns a service, what a `WebService` becomes, and where logs and metrics are.

## Decision
- **A small Go service, `apps/cluster-assistant`,** takes a namespace and an optional service and question, and returns a diagnosis with the evidence behind it. It runs Claude in a tool loop of at most 12 model calls, with `claude-opus-5-5` unless `MODEL` says otherwise.
- **Five read-only tools:** `list_pods`, `get_events`, `get_pod_logs`, `get_resource` and `query_prometheus`. `get_resource` reads only the kinds in a fixed list. Secrets and ConfigMaps aren't on it.
- **Read-only in two places.** The code only sends GET requests, and its ClusterRole (`platform/cluster-assistant/rbac.yaml`) has no write verbs and no Secrets. The role is tested on kind with `kubectl auth can-i`.
- **Output is treated as untrusted and as sensitive.** Names and namespaces are checked before they go into a URL. Tool output has credentials redacted (connection strings, tokens, keys, `password=` pairs) and is capped at 12 KB before the model sees it. The system prompt says that logs and object fields are data that may contain instructions.
- **Changes would go through Git.** The assistant ends with a fix expressed as a change to the `WebService` or to Git. Any later feature that writes will open a pull request, like the Promote workflow, and a person merges it.
- **Cost and audit:** a cap on diagnoses per hour (`MAX_DIAGNOSES_PER_HOUR`, 30), and one JSON log line per question and per tool call. Alloy ships those to Loki like any other service's logs.
- **Testing has two layers:**
  - Unit tests with a scripted model check the loop (all results of a turn come back in one message, failures reach the model as errors, the turn limit holds, refusals are reported), the tools against a fake API server, and redaction. `make test-assistant`.
  - Fault tests break six workloads on kind on purpose: a bad image tag, an out-of-memory kill, a crash with an explanatory log line, a readiness probe on the wrong port, a pod no node can fit, and a missing Secret. `make test-diagnose` checks without a model that the tools show each cause. `scripts/diagnose-eval.sh` without `--evidence-only` also asks the model and checks that its answer names the cause.

## Alternatives considered
- **K8sGPT or HolmesGPT:** both already diagnose clusters. They don't know what a `WebService` is, which environment a namespace is, or who owns a service. A thin layer that does is the part worth building here.
- **A Backstage plugin:** shared login and a place on the service page, but plugins are slow to build and test. A standalone service can be linked from Backstage later.
- **Claude on Amazon Bedrock:** it would keep traffic inside the AWS account and use Pod Identity instead of an API key. It needs a model access request, and it isn't clear that the Free plan policy allows it. The Anthropic API is used for now, with the key in Secrets Manager through External Secrets when it deploys.
- **Letting it fix things directly:** faster, but a wrong guess would run against live workloads, and Argo CD would revert it anyway.

## Consequences
- **Not deployed.** It has no login in front of it. Before it goes on EKS it needs authentication (oauth2-proxy with GitHub, as for Grafana), a NetworkPolicy, and the key in Secrets Manager.
- **Logs leave the cluster.** Redaction is pattern-based and will miss some secrets. Teams with sensitive logs may not want this on their namespaces.
- **A diagnosis is a hypothesis.** The answer lists what the assistant looked at so an engineer can check it.
- **The model call costs money:** a few cents per fault on the test set, to be measured.
- **Metrics and logs history:** it can read the current and previous container logs, and ask Prometheus. Loki queries and Argo CD history aren't in yet.
