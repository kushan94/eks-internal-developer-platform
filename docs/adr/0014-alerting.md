# ADR 0014: Alerts per service, sent to a chat webhook

**Status:** Accepted (2026-11-13)

## Context
Grafana shows how a service behaves, but only to someone who is looking. Nothing said when a service stopped answering or kept restarting. ADR 0013 left Alertmanager off until alerts had somewhere to go. Clusters live for one session, so alerts are mainly for those sessions and for showing what the platform gives a team.

## Decision
- **Alertmanager on every cluster**, from kube-prometheus-stack, with 32–128 MiB of memory.
- **Two platform rules for every `WebService`**, matched through the `backstage.io/kubernetes-id` pod label like the dashboard. Each carries a `service` label and a link to the service's dashboard.
  - `WebServiceDown` (critical): none of the service's own pods are ready for 5 minutes. Only pods owned by a ReplicaSet count, so a ready CloudNativePG pod can't hide a dead app.
  - `WebServiceRestarting` (warning): the service's containers, its database included, restarted more than twice in 15 minutes.
- **The chart's default rules stay on**, except those for etcd, the scheduler, the controller manager and kube-proxy. EKS hides the first three, and kube-proxy serves metrics only on localhost, so their "down" alerts would always fire.
- **On EKS, warning and critical alerts go to a Slack-format webhook.** Slack takes it directly, and Discord through its Slack-compatible endpoint, the webhook URL plus `/slack`.
  - The URL lives in Secrets Manager (`idp/alerting/webhook`) and reaches the cluster through External Secrets.
  - Routing is an `AlertmanagerConfig` in a plain manifest, because its message templates use `{{ }}`, which the root Helm chart would try to render.
  - Alertmanager only reads `AlertmanagerConfig`s labelled `platform.example.org/alerting: "true"` in `monitoring`, so a team can't reroute platform alerts. They apply to alerts from every namespace.
- **On kind, alerts stay in Alertmanager and Grafana.** Nothing is sent.
- **Tests:** `make test` checks the rules with `promtool` and runs unit tests, including one where the database pod is ready and the app isn't.

## Alternatives considered
- **Email through SES:** needs a verified address and SMTP credentials, and the account starts in the SES sandbox.
- **Grafana alerting instead of Alertmanager:** rules would live in Grafana's database, which disappears with the cluster, instead of in Git.
- **Discord's native receiver:** looks nicer, but a Slack-format webhook works for both Slack and Discord with one configuration.
- **Alerts for the shared RDS server:** its metrics are in CloudWatch, not Prometheus. A full in-cluster database disk is already covered by the chart's `KubePersistentVolumeFillingUp`.

## Consequences
- **Another manual step:** creating the webhook happens in Slack or Discord, and its URL is stored with the CLI.
- **The webhook secret must exist** before the EKS cluster starts. Otherwise the `observability-aws` app stays degraded and the Cluster workflow waits for it.
- **Alerts only for the Kubernetes runtime.** ECS services aren't in Prometheus.
- **Alerts don't cover a `WebService` that Crossplane can't create**, because it has no pods yet. Its `Synced` condition and Argo CD show those.
