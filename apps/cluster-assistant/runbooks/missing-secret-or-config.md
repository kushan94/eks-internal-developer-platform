---
name: missing-secret-or-config
description: A container is stuck in CreateContainerConfigError, or an event says a secret or key was not found
tools: list_pods, get_events, get_resource
---
# Missing Secret or config

**Look at:** `list_pods` shows `CreateContainerConfigError` and the message, such as `secret "x" not found` or `couldn't find key y in Secret`. `get_events` repeats it.

You can't read Secrets, and shouldn't need to: whether one exists is visible from the pod's message, and what created it is visible from the `WebService`.

**For a service with `spec.database`**, the password and login come from a Secret the platform expects to exist:
- `database.class: in-cluster`: the Secret is `<service>-db-app`, created by CloudNativePG when its cluster (`<service>-db`) is bootstrapped. If the pod starts before the database is ready, it waits. Check the `clusters` resource (`<service>-db`) with `get_resource` for its phase and `readyInstances`, and look for a stuck volume claim (load `pending-or-unschedulable`).
- `database.class: managed`: the Secret is `<service>-db`, written by Crossplane for the database login (`Role`). The `WebService`'s `Ready` condition and `status.database` show whether Crossplane has finished. If the managed server is unreachable or the name is too long, the login is never created (load `database-connection`).

**For anything else**, the Secret isn't one the platform creates, so a `WebService` can't reference arbitrary Secrets or ConfigMaps today. If a pod references one, it came from a hand-made workload, and the namespace's owner must create it.

**Wait before concluding:** a Secret that appears a minute later is normal during first creation. A pod that has been stuck for several minutes is not.

**Fix:** for a database, fix the database (see above). Don't create the Secret by hand: it hides the real problem, which is that the database isn't ready, and it won't exist in the next environment.
