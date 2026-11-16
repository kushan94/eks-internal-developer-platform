---
name: blocked-traffic
description: Connections time out between services, to a database, to DNS or to an external API, or a service can't be reached from another namespace
tools: list_pods, get_resource, get_events, get_pod_logs
---
# Blocked traffic (NetworkPolicies)

Every Kubernetes `WebService` gets a NetworkPolicy, named after the service, that limits **both directions**. A blocked connection usually **times out** rather than being refused. Read the policy with `get_resource` (kind `networkpolicies`), then compare it with what the service is trying to reach.

**Inbound** to a service is allowed from: pods in its own namespace, Prometheus in `monitoring`, the load balancer when `public: true` (on the service's port), and callers listed in `spec.allowFrom` (a whole team, or one of a team's services).

**Outbound** from a service is allowed to: DNS (CoreDNS in `kube-system`, port 53), its own namespace (including its own in-cluster database and sibling services), its managed database on the database's port, services listed in `spec.allowTo`, and the public internet only if `allowInternet: true`. Even then, private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and `169.254.0.0/16` (cloud metadata) stay blocked.

**Both sides must agree** for a call between teams: the caller needs `allowTo` and the callee `allowFrom`. Check both services' policies, not just one.

**Common causes:**
- A call to an external API times out: `allowInternet: true` is missing.
- A call to another team's service times out: one side of `allowFrom` / `allowTo` is missing, or the other service is in a different environment. Callers are matched by the namespace's `platform.example.org/team` label and the pod's `app.kubernetes.io/name` label, and **environments are separate**: dev can't call prod.
- A call to a database host or port the platform doesn't know about: only the service's own `spec.database` is allowed.
- In a policy, a `from` or `to` entry with both a `namespaceSelector` and a `podSelector` means **both must match**. Separate entries mean either can match.
- In-cluster databases have their own policy (`<service>-db`): their namespace, the CloudNativePG operator in `cnpg-system`, and Prometheus. Their outbound traffic is open.

**Other things to rule out:** the target pod isn't running or ready (`list_pods`), the port in the call doesn't match `spec.port`, or the log shows a DNS error (`get_pod_logs`), which points at the DNS rule.

**ECS services** don't use NetworkPolicies, and `allowFrom`, `allowTo` and `allowInternet` aren't available for them.

**Fix:** add the missing `allowFrom`, `allowTo` or `allowInternet` to the `WebService` in Git, on the correct side. Open only what the service needs.
