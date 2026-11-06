# ADR 0009: Public URLs through Gateway API and a Route 53 subdomain

**Status:** Accepted (2026-11-06)

## Context
Services need public HTTPS URLs under `skyforgelab.cloud`. The domain is registered at Porkbun, and its nameservers pointed at an Azure DNS zone that no longer answered. The platform should control only its own part of the domain.

## Decision
- **DNS:** Route 53 hosts only `idp.skyforgelab.cloud`, created by the bootstrap stack so its nameservers stay stable across sessions. The parent zone delegates it with four NS records.
- **Certificate:** a wildcard ACM certificate for `*.idp.skyforgelab.cloud`, also in the bootstrap stack and validated through Route 53. The AWS Load Balancer Controller finds it by the listener's hostname, so no certificate ARN is committed.
- **Routing:** Gateway API on EKS. One shared Gateway in `gateway-system` becomes one internet-facing ALB.
  - HTTP redirects to HTTPS.
  - A gateway-wide `TargetGroupConfiguration` sends traffic straight to pod IPs, so Services stay ClusterIP.
- **DNS records:** ExternalDNS publishes each HTTPRoute's hostname. It can change only the platform zone.
- **Developer interface:** `public: true` on a WebService.
  - The composition adds an HTTPRoute for `<name>-<namespace>.idp.skyforgelab.cloud` and writes the URL to `status.url`.
  - One label is used under the domain because a wildcard certificate covers only one level.
- **Versions:** the controller and ExternalDNS are installed by Argo CD with pinned charts, and the controller's IAM policy is pinned to its version. The Gateway API CRDs come from the upstream repo at the version the controller supports, v1.6.0.
- **Cleanup:** the controller creates the ALB outside Terraform, so the destroy job first deletes load balancers, target groups and security groups tagged with the cluster's name.

## Consequences
- **ECS:** Gateway API only routes to Kubernetes, so ECS services stay reachable only inside the VPC. Giving them public URLs needs a separate path, such as a second load balancer managed by the composition.
- **Cost:** the shared ALB costs money while the cluster runs, and the hosted zone costs $0.50 a month.
- **Stale DNS:** a nightly destroy leaves ExternalDNS records pointing at a deleted ALB until the next session updates them, which it can because it owns them through its TXT records.
- **Duplicated domain:** the domain is set in both the Gateway manifest and the `platform` EnvironmentConfig.
