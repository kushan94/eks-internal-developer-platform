#!/usr/bin/env bash
# Runs the cluster dashboard against a throwaway kind cluster filled with
# healthy services, broken ones (tests/diagnose/faults), fake Argo CD
# applications and fake metrics, so there is something to look at.
#
# Usage: scripts/dashboard-demo.sh
# Then open http://localhost:18080. Press Ctrl-C to delete the cluster.
# Set ANTHROPIC_API_KEY to try the assistant too, which calls the Claude API.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=idp-dashboard-demo
KUBECONFIG="$(mktemp)"
export KUBECONFIG
cleanup() {
  [ -n "${PF_PID:-}" ] && { pkill -P "$PF_PID" 2> /dev/null; kill "$PF_PID" 2> /dev/null; }
  kind delete cluster --name "$CLUSTER" > /dev/null 2>&1
  rm -f "$KUBECONFIG"
}
trap cleanup EXIT INT TERM

echo "Creating a two-node kind cluster"
kind delete cluster --name "$CLUSTER" > /dev/null 2>&1
cat <<YAML | kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --config - > /dev/null || exit 1
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
YAML
# Labels an EKS node would have.
i=0
for node in $(kubectl get nodes -o name); do
  kubectl label "$node" "topology.kubernetes.io/zone=eu-north-1$(printf "\\x$(printf %x $((97 + i % 2)))")" node.kubernetes.io/instance-type=t3.medium --overwrite > /dev/null
  i=$((i + 1))
done

echo "Building and starting the dashboard"
docker build -q -t cluster-assistant:eval apps/cluster-assistant > /dev/null || exit 1
kind load docker-image cluster-assistant:eval --name "$CLUSTER" > /dev/null || exit 1
kubectl apply -f tests/diagnose/demo/argocd.yaml > /dev/null 2>&1; sleep 2
kubectl apply -f tests/diagnose/demo/argocd.yaml -f tests/diagnose/demo/healthy.yaml -f tests/diagnose/demo/fake-prometheus.yaml \
  -f platform/cluster-assistant/rbac.yaml -f tests/diagnose/assistant.yaml -f tests/diagnose/faults > /dev/null || exit 1
kubectl -n cluster-assistant set env deploy/cluster-assistant PROMETHEUS_URL=http://fake-prometheus.monitoring.svc:9090 > /dev/null
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  kubectl -n cluster-assistant create secret generic anthropic --from-literal=api-key="$ANTHROPIC_API_KEY" > /dev/null
  kubectl -n cluster-assistant rollout restart deploy/cluster-assistant > /dev/null
fi
kubectl -n cluster-assistant rollout status deploy/cluster-assistant --timeout=120s > /dev/null || exit 1

# Reconnects when the pod is replaced, so a rebuilt image can be rolled out
# without restarting the demo:
#   docker build -t cluster-assistant:eval apps/cluster-assistant
#   kind load docker-image cluster-assistant:eval --name idp-dashboard-demo
#   kubectl --context kind-idp-dashboard-demo -n cluster-assistant rollout restart deploy/cluster-assistant
while true; do kubectl -n cluster-assistant port-forward svc/cluster-assistant 18080:8080 > /dev/null 2>&1; sleep 1; done &
PF_PID=$!
echo "Dashboard: http://localhost:18080  (Ctrl-C deletes the cluster)"
wait "$PF_PID"
