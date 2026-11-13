# ADR 0024: Limit where services can connect

**Status:** Accepted (2026-11-13)

## Context
[ADR 0020](0020-network-policies.md) limited who can reach a service, but a service could still connect anywhere: other teams' services, the cloud metadata endpoint, or any address on the internet. A compromised service could exfiltrate data or move sideways. ADR 0020 left outbound rules as the next step, because a missing allowance silently breaks a service.

## Decision
- **Every Kubernetes `WebService`'s NetworkPolicy now restricts outbound traffic too.** By default, its pods can only reach:
  - DNS: CoreDNS in `kube-system`, port 53, UDP and TCP.
  - Their own namespace, including their own in-cluster database and sibling services.
  - Their managed database, on its port. On EKS that's RDS, which the policy allows by the VPC's address range, since RDS has no pod labels. On kind it's the stand-in server's namespace, which the `managed-postgres` EnvironmentConfig names (`managedPostgres.namespace`). With neither, the composition fails rather than cut a service off from its database.
- **`allowTo`** lists other teams' services this one calls, the outbound half of `allowFrom`. Both sides must agree.
  - It's identified by the same trusted labels as `allowFrom`: the namespace's team label, set by Argo CD, and the pod's name label, set by the composition.
  - It's environment-bound the same way.
- **`allowInternet: true`** allows any public address. Private ranges stay blocked: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, and `169.254.0.0/16`, which includes the cloud metadata endpoint.
- **Database pods keep open egress.** CloudNativePG's instance manager needs the Kubernetes API. Policy engines see that traffic after the Service address is rewritten to the API server's own address, which differs between kind and EKS, so a precise rule would be fragile.
- **Kubernetes runtime only.** ECS services keep their security group, and `allowTo` and `allowInternet` on ECS fail with a clear message.
- **Testing:**
  - `make test` checks the rules for kind and EKS, `allowTo`'s environment, and the blocked private ranges.
  - On a throwaway kind cluster, the rendered policy for a service in `shop-prod` allowed DNS, its namespace, the database port and the listed service in prod. It blocked another port in the database's namespace, another service of the same team, the listed service in dev, and the internet unless `allowInternet` was set. Everything was reachable before the policy.

## Alternatives considered
- **Allow all outbound traffic to the VPC:** simpler, but it lets a service reach every other service's pods, since pods have VPC addresses.
- **An egress gateway or a proxy with hostname allow-lists:** names like `api.stripe.com` instead of "the internet". Kubernetes NetworkPolicies only understand addresses, so this needs a service mesh or a CNI with DNS-aware policies, such as Cilium.
- **Opt-in instead of default:** no service would break, but no service would be protected until someone remembered.

## Consequences
- **Services that call external APIs need `allowInternet: true`.** Ones that call other teams' services need `allowTo` there and `allowFrom` on the other side. A missing entry shows up as connection timeouts.
- **On EKS, the managed database rule allows the database port anywhere in the VPC,** not just RDS's own address.
- **Not tested on EKS yet.** The VPC CNI's handling of DNS and of Service addresses still needs checking there.
