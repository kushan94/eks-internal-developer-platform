#!/usr/bin/env bash
# Tests the WebService's resources and healthCheck fields on a real API server
# and real pods, on a throwaway kind cluster. The offline tests (make test)
# can't see two things: whether the API server accepts the XRD's CEL rules
# (it has a cost budget and its own quantity handling), and how the probes
# behave on pods. Run make test first, which renders what this applies.
#
# Usage: scripts/test-resources-and-health.sh        Set KEEP=1 to leave the cluster.
set -uo pipefail
cd "$(dirname "$0")/.."

CLUSTER=idp-health-test
export KUBECONFIG="$(mktemp)"
YQ="docker run --rm -v $PWD:/repo -w /repo ${YQ_IMAGE:-mikefarah/yq:4.47.2}"
failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
cleanup() { [ "${KEEP:-}" = 1 ] || kind delete cluster --name "$CLUSTER" > /dev/null 2>&1; rm -f "$KUBECONFIG"; }
trap cleanup EXIT

for f in .test/kubernetes.yaml .test/health-check.yaml .test/resources.yaml; do
  [ -f "$f" ] || { echo "$f is missing. Run make test first."; exit 2; }
done

echo "Creating the kind cluster $CLUSTER"
kind delete cluster --name "$CLUSTER" > /dev/null 2>&1
kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" > /dev/null || exit 1

echo "1. The API server accepts the XRD's schema and enforces its rules"
# Crossplane builds a CustomResourceDefinition from the XRD's schema. The same schema as a plain CRD
# is what the API server evaluates, including the CEL rules and their cost budget.
$YQ '{"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition", "metadata": {"name": "webservices.platform.example.org"},
  "spec": {"group": "platform.example.org", "scope": "Namespaced", "names": {"kind": "WebService", "plural": "webservices"},
  "versions": [{"name": "v1alpha1", "served": true, "storage": true, "schema": {"openAPIV3Schema": .spec.versions[0].schema.openAPIV3Schema}}]}}' \
  platform/crossplane/webservice/definition.yaml > .test/webservice-crd.yaml
if out="$(kubectl apply -f .test/webservice-crd.yaml 2>&1)"; then pass "the schema is accepted as a CustomResourceDefinition"; else fail "the API server refused the schema: $out"; exit 1; fi
kubectl wait --for=condition=Established crd/webservices.platform.example.org --timeout=60s > /dev/null || { fail "the CRD never became established"; exit 1; }
kubectl create namespace team-a > /dev/null

try() { kubectl apply --dry-run=server -f "$1" 2>&1; }
for f in tests/render/xr-resources.yaml tests/render/xr-resources-numbers.yaml tests/render/xr-health-check.yaml; do
  out="$(try "$f")" && pass "$(basename "$f") is accepted" || fail "$(basename "$f") was refused: $out"
done
for f in tests/render/xr-resources-invalid-*.yaml tests/render/xr-health-check-invalid.yaml; do
  if out="$(try "$f")"; then fail "$(basename "$f") was accepted"; else pass "$(basename "$f") is refused: $(grep -oE '(cpu|memory) must be[^"]*|should match.*|must be of type.*' <<< "$out" | head -1 | cut -c1-90)"; fi
done

echo "2. Pods: what the probes do"
# The Deployments the composition rendered, each in its own namespace. The owner reference to the
# WebService is dropped: there is no such WebService here, and Kubernetes would garbage collect them.
apply_rendered() { # file namespace
  kubectl create namespace "$2" > /dev/null
  $YQ 'select(.kind == "Deployment") | .metadata.namespace = "'"$2"'" | .spec.replicas = 1 | del(.metadata.ownerReferences)' "$1" | kubectl apply -f - > /dev/null
}
ready() { kubectl -n "$1" get pods -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2> /dev/null; }
wait_ready() { local i; for i in $(seq 1 "${2:-60}"); do [ "$(ready "$1")" = True ] && return 0; sleep 2; done; return 1; }

# Nothing configured: a port check, so a running web server is ready.
apply_rendered .test/kubernetes.yaml default-check
wait_ready default-check && pass "with no health check, a service that accepts connections becomes ready" || fail "the default port check never made the pod ready"
kubectl -n default-check get deploy -o jsonpath='{.items[0].spec.template.spec.containers[0].readinessProbe.tcpSocket.port}{"\n"}' | grep -q http && pass "...by a TCP check on the named port" || fail "no TCP readiness probe"

# A path that answers 200: ready. nginx serves / with 200.
sed 's#path: /healthz#path: /#' .test/health-check.yaml > .test/health-ok.yaml
# Four: the WebService's own healthCheck.path, and the three probes rendered from it.
[ "$(grep -c 'path: /$' .test/health-ok.yaml)" = 4 ] || { fail "couldn't point the health check and all three probes at / in the 200 variant"; exit 1; }
apply_rendered .test/health-ok.yaml health-ok
wait_ready health-ok && pass "a health check path that answers 200 makes the pod ready" || fail "the pod never became ready on a path that answers 200"

# A path that answers 404: never ready, and restarted once the startup window is over.
apply_rendered .test/health-check.yaml health-bad
sleep 20
if [ "$(ready health-bad)" != True ]; then pass "a health check path that answers 404 keeps the pod not ready"; else fail "the pod became ready on a path that doesn't exist"; fi
events="$(kubectl -n health-bad get events 2>&1)"
grep -q "Startup probe failed: HTTP probe failed with statuscode: 404" <<< "$events" && pass "...and the event says why (statuscode 404)" || fail "no startup probe event naming the 404"
echo "  (waiting for the startup window, about a minute, to see the restart)"
for i in $(seq 1 50); do
  restarts="$(kubectl -n health-bad get pods -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2> /dev/null)"
  [ "${restarts:-0}" -ge 1 ] && break
  sleep 3
done
[ "${restarts:-0}" -ge 1 ] && pass "...and once the startup window passes, the container is restarted ($restarts restart)" || fail "the container was never restarted"

echo "3. Resources on the pod"
apply_rendered .test/resources.yaml sized
for i in $(seq 1 30); do kubectl -n sized get pods -o name 2> /dev/null | grep -q pod && break; sleep 2; done
res="$(kubectl -n sized get pods -o jsonpath='{.items[0].spec.containers[0].resources}' 2> /dev/null)"
for want in '"cpu":"250m"' '"memory":"512Mi"'; do grep -q "$want" <<< "$res" && pass "the pod has $want" || fail "the pod lacks $want: $res"; done
grep -q '"limits":{"memory":"512Mi"}' <<< "$res" && pass "the limit is memory only, with no CPU limit" || fail "unexpected limits: $res"
qos="$(kubectl -n sized get pods -o jsonpath='{.items[0].status.qosClass}' 2> /dev/null)"
[ "$qos" = Burstable ] && pass "the pod is Burstable: memory is reserved, CPU can burst" || fail "unexpected QoS class: $qos"

echo
if [ "$failures" = 0 ]; then echo "The API accepts the new fields, and the pods behave as described."; else echo "$failures check(s) failed."; exit 1; fi
