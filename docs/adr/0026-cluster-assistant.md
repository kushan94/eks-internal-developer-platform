# ADR 0026: A cluster dashboard with a read-only AI assistant

**Status:** Proposed (2026-11-14). The dashboard, the tools and their tests are built, and the dashboard was checked in a browser against a kind cluster. The model has not been run against the fault set yet, and nothing is deployed.

## Context
When something is wrong with a cluster, an engineer first needs to see it: which nodes, namespaces and pods are unhealthy, how full the cluster is, and what Argo CD says. Then comes the slower part.

When a service breaks, an engineer reads pod status, events, logs, the objects around them and sometimes metrics, then puts the cause together. That is a good job for a model with tools, if it can't make things worse. The platform already holds what it needs to know: who owns a service, what a `WebService` becomes, and where logs and metrics are.

## Decision
- **A dashboard, served by the same Go service, shows the cluster.** It has five tabs: Overview (summary cards, capacity, charts, a ranked "needs attention" list of unhealthy pods, nodes and Argo CD applications, and the latest warnings), Workloads (namespace tiles with a drill-down, and a searchable pod list), Nodes (utilisation, and the Kubernetes versions of the control plane and nodes, with a hint when nodes lag, the state right after a control plane upgrade), Delivery (Argo CD applications) and Events (all warnings, filterable). The header shows the number of things needing attention and a count on each tab, so a problem is visible from any tab. Tabs have their own addresses, so views can be linked. The pod and event lists are fetched only when their tab is open. Last-hour charts come from fixed Prometheus queries when `PROMETHEUS_URL` is set. Everything except the charts is computed from read-only API calls, so it works without Prometheus.
- **The page is plain HTML, CSS and JavaScript embedded in the binary.** There is no build step and no third-party script, font or request. The Content-Security-Policy allows only its own files. Cluster text is untrusted, so the page builds elements from text nodes and never uses `innerHTML`.
- **A Diagnose button** on each problem and on each unhealthy pod opens the assistant, which streams each tool call as it happens and then shows the cause, evidence and fix. It runs only when a person presses Run, because each run costs money.
- **The assistant, `apps/cluster-assistant`,** takes a namespace and an optional service and question, and returns a diagnosis with the evidence behind it. It runs Claude in a tool loop of at most 12 model calls, with `claude-opus-5-5` unless `MODEL` says otherwise.
- **Five read-only tools:** `list_pods`, `get_events`, `get_pod_logs`, `get_resource` and `query_prometheus`. `get_resource` reads only the kinds in a fixed list. Secrets and ConfigMaps aren't on it.
- **Read-only in two places.** The code only sends GET requests, and its ClusterRole (`platform/cluster-assistant/rbac.yaml`) has no write verbs and no Secrets. The role is tested on kind with `kubectl auth can-i`.
- **Output is treated as untrusted and as sensitive.** Names and namespaces are checked before they go into a URL. Tool output has credentials redacted (connection strings, tokens, keys, `password=` pairs) and is capped at 12 KB before the model sees it. The system prompt says that logs and object fields are data that may contain instructions.
- **Changes would go through Git.** The assistant ends with a fix expressed as a change to the `WebService` or to Git. Any later feature that writes will open a pull request, like the Promote workflow, and a person merges it.
- **Cost limits:**
  - **Per diagnosis:** 12 model calls and 150,000 tokens in all. At 70% of the token budget, or on the last call, the model can't use tools (`tool_choice: none`, because the history has tool calls in it and the API requires the tools to stay defined) and is told to answer from what it has. A partial answer, marked as partial, is worth more than none, and the wrap-up costs one more call.
  - **Per day:** an estimated spend cap (`MAX_DAILY_SPEND_USD`, 5), from token counts and list prices. A model with no known price is priced as the most expensive. The tally is in memory and resets on restart, so the log line per diagnosis, with its cost, is the record.
  - **Per hour and at once:** 30 diagnoses an hour and 3 at a time. A request refused for concurrency or the daily cap doesn't use up the hourly allowance.
  - **Repeats:** an identical question within five minutes is answered from memory and counts against no limit, since a colleague opening the same alert shouldn't cost twice. The page asks for a fresh diagnosis when you run again.
  - A failed diagnosis still counts what it spent before failing.
- **Audit:** one JSON log line per question, per tool call, and per diagnosis with its tokens and cost. Alloy ships those to Loki like any other service's logs.
- **A five-second cache** on the dashboard's reads, so open dashboards cost the API server one read.
- **Testing has two layers:**
  - Unit tests with a scripted model check the loop (all results of a turn come back in one message, failures reach the model as errors, the turn limit holds, refusals are reported), the tools against a fake API server, and redaction. `make test-assistant`.
  - The dashboard's numbers (totals, capacity, node requests, problems, versions, drill-down, charts) are tested against a fake API server. A regression test checks every list the page reads arrives as an array. It was written after the page crashed on a node without conditions, and fails if the fix is reverted.
  - Browser tests (`make test-dashboard`, puppeteer-core) drive the page in Chrome against the demo cluster: every tab and deep link, Back, keyboard navigation, the filters, the assistant panel with a stubbed stream, an answer containing `<img onerror>` that must be shown as text, dark mode, and phone width with no horizontal overflow. They fail on any console error.
  - The page itself was run in Chrome against a kind cluster with healthy services, the six faults, stand-in Argo CD applications and fake metrics (`scripts/dashboard-demo.sh`), in light, dark and phone width, with the console checked for errors. That found two bugs the unit tests could not: the Content-Security-Policy silently dropped every inline bar width, and a crashed render left half the page empty.
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
- **The model call costs money:** a few cents per fault on the test set, to be measured. The caps are estimates from list prices, not billing, and the tally resets on restart. Set a spend limit in the Anthropic Console as well.
- **A wrap-up answer is weaker than a full investigation.** The page says when an answer is partial.
- **Metrics and logs history:** it can read the current and previous container logs, and ask Prometheus. Loki queries and Argo CD history aren't in yet.
- **The upgrade advisor isn't built.** The dashboard shows version skew, but not EKS upgrade insights, deprecated API usage or add-on compatibility.
- **No history of past diagnoses.** Each one is in the logs, but the page doesn't list them.
