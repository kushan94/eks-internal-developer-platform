---
name: pending-or-unschedulable
description: A pod stays Pending, or events say FailedScheduling, Insufficient cpu or memory, Too many pods, or a volume won't bind
tools: list_pods, get_events, get_resource, query_prometheus
---
# Pending and unschedulable pods

**Look at:** `get_events` for the pod's `FailedScheduling` message, which says how many nodes were tried and why each refused. `list_pods` shows the pod's `PodScheduled` condition.

**Read the message:**
- `Insufficient cpu` or `Insufficient memory`: no node has enough unreserved capacity for the pod's **requests**. Scheduling uses requests, not usage. Use `get_resource` with kind `nodes` for allocatable capacity, and `list_pods` across namespaces to see what is reserved. A service requests 50m CPU and 64Mi by default, or what its `spec.resources` says, and a service that sets `spec.resources.memory` requests that much, so a large one can't be placed on a nearly full node. If the pod is a platform component, the cluster is simply full: more or bigger nodes.
- `Too many pods`: the node reached its pod limit. On EKS the VPC CNI is set up with prefix delegation so nodes allow 110 pods. If that setting is missing, a small node allows far fewer.
- `node(s) had untolerated taint(s)`: the only nodes with room carry taints the pod doesn't tolerate. Control-plane nodes are tainted, so on a cluster with workers, pods only land on the workers.
- `didn't match pod topology spread constraints`: the platform's spread rules are soft (`ScheduleAnyway`), so they shouldn't block scheduling. If this appears, someone added a hard rule.
- `unbound immediate PersistentVolumeClaims` or `volume node affinity conflict`: a service with `database.class: in-cluster` needs a 1 GiB volume. On EKS it comes from the EBS CSI driver (`gp3`), and an EBS volume lives in one zone, so the pod must run there. Check the claim with `get_resource` (kind `persistentvolumeclaims`) and its `ProvisioningFailed` events.

**Autoscaled services** (`spec.autoscaling`): the HPA adds pods up to `maxReplicas`. If those are Pending, the cluster has no room, and the HPA can't fix that.

**Fix:** if the cause is capacity, a full cluster needs more or bigger nodes, which is a platform change. A service can help by asking for less in `spec.resources` (CPU from 10m, memory from 32Mi), or by reducing `replicas` or `autoscaling.maxReplicas`, in Git. Don't suggest that for a service that is already small: it frees little.
