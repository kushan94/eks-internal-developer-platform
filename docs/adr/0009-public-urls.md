# ADR 0009: Public URLs through Gateway API and a Route 53 subdomain

**Status:** Accepted (2026-11-06)

## Context
Services need public HTTPS URLs under `skyforgelab.cloud`. The domain is registered at Porkbun, and its nameservers pointed at an Azure DNS zone that no longer answered. The platform should control only its own part of the domain, so a working parent zone was needed too.

## Decision
- **DNS:** Route 53 hosts `skyforgelab.cloud`, and the registrar points the domain at that zone. The parent zone delegates `idp.skyforgelab.cloud` to a separate zone, so the platform's tools can only change records there. Both zones are in the bootstrap stack, so their nameservers stay stable across sessions.
- **Certificate:** a wildcard ACM certificate for `*.idp.skyforgelab.cloud`, also in the bootstrap stack and validated through Route 53. The AWS Load Balancer Controller finds it by the listener's hostname, so no certificate ARN is committed.
- **Routing:** Gateway API on EKS. One shared Gateway in `gateway-system` becomes one internet-facing ALB.
  - HTTP redirects to HTTPS.
  - A gateway-wide `TargetGroupConfiguration` sends traffic straight to pod IPs, so Services stay ClusterIP.
- **DNS records:** ExternalDNS publishes each HTTPRoute's hostname. It can change only the platform zone.
- **Developer interface:** `public: true` on a WebService.
  - The composition adds an HTTPRoute for `<name>-<namespace>.idp.skyforgelab.cloud` and writes the URL to `status.url`.
  - One label is used under the domain because a wildcard certificate covers only one level.
- **Versions:** the controller and ExternalDNS are installed by Argo CD with pinned charts, and the controller's IAM policy is pinned to its version. The Gateway API CRDs come from the upstream repo at the version the controller supports, v1.6.0.
- **Cleanup:** the controller creates the ALB outside Terraform. Before Terraform runs, the destroy job does three things:
  1. Removes the controller's IAM policy, so a restarting controller can't recreate the ALB.
  2. Deletes the load balancers, target groups and security groups tagged with the cluster's name.
  3. Deletes the DNS records ExternalDNS owns, found through its TXT ownership records.

## Consequences
- **ECS:** Gateway API only routes to Kubernetes, so ECS services stay reachable only inside the VPC. Giving them public URLs needs a separate path, such as a second load balancer managed by the composition.
- **Cost:** the shared ALB costs money while the cluster runs, and the two hosted zones cost $0.50 a month each.
- **Wildcard record:** the redirect route has no hostname of its own, so it inherits the HTTP listener's `*.idp.skyforgelab.cloud`, and ExternalDNS publishes a wildcard record for it. Any unknown name under the domain reaches the ALB and gets a 404, which is acceptable.
- **Duplicated domain:** the domain is set in both the Gateway manifest and the `platform` EnvironmentConfig.
