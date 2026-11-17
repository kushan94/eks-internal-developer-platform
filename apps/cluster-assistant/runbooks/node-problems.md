---
name: node-problems
description: A node is NotReady or under memory, disk or PID pressure, pods were evicted, or nodes run an older Kubernetes version than the control plane
tools: get_resource, list_pods, get_events, query_prometheus
---
# Node problems

**Look at:** `get_resource` with kind `nodes` (leave `name` empty to list them): `status.conditions` (`Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure`), `status.allocatable`, and `status.nodeInfo.kubeletVersion`. `get_events` shows `NodeNotReady` and evictions. Events about a node itself are in the `default` namespace.

**NotReady:** the kubelet stopped reporting. Pods on it will be rescheduled after a few minutes, which is why a service with several replicas, spread across nodes and zones, usually keeps running. The reason is an infrastructure one (the instance, its network or the kubelet), so say what you see and hand it to the platform team: the node name, the condition message, and when it started.

**Pressure:**
- `MemoryPressure`: the kubelet evicts pods. By default a service **requests 64Mi but may use up to 256Mi**, so a node can be over-committed on memory: requests fit, but the pods actually use more. A service that sets `spec.resources.memory` requests the same as its limit, so it doesn't add to that. Evicted pods show as `Failed` with reason `Evicted` in `list_pods`.
- `DiskPressure`: usually images and logs filling the node's disk.
- `PIDPressure`: a runaway process or fork bomb in some pod.
- `query_prometheus` can show the trend: `node_memory_MemAvailable_bytes` and `node_filesystem_avail_bytes`.

**Version skew:** compare each node's `kubeletVersion` with the control plane's (`/version`, shown on the dashboard). Right after a control plane upgrade, nodes lag by design until the node group is upgraded. Kubernetes supports nodes up to three minor versions behind the control plane, so one version behind is normal and three is the limit. Don't upgrade the control plane again until the nodes catch up.

**Capacity, not a fault:** if every node is Ready and just full, that is `pending-or-unschedulable`, not this.

**Fix:** nodes are the platform team's. A `WebService` can't fix a node. It can reduce its replicas or autoscaling maximum to take load off a full one.
