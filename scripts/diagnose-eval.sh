#!/usr/bin/env bash
# Tests the cluster assistant against deliberately broken workloads, on a
# throwaway kind cluster. Each file in tests/diagnose/faults/ is one fault, and
# its first line says what the cause looks like: "# expect: <regex>".
#
#   1. Evidence: the assistant's tools, run without a model, must show the cause.
#      This needs no API key, and checks the tools, the read-only role and the
#      in-cluster client.
#   2. Diagnosis (unless --evidence-only): the model must name the cause. This
#      calls the Claude API with ANTHROPIC_API_KEY and costs money, a few cents
#      per fault.
#
# Usage: scripts/diagnose-eval.sh [--evidence-only]
# Set KEEP=1 to leave the cluster running.
set -uo pipefail
cd "$(dirname "$0")/.."

CLUSTER=idp-assistant-eval
export KUBECONFIG="$(mktemp)"
MODE="${1:-}"
FAULTS=tests/diagnose/faults
failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
k() { kubectl "$@"; }

if [ "$MODE" != --evidence-only ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY isn't set. Set it, or pass --evidence-only to skip the model."
  exit 1
fi

cleanup() {
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2> /dev/null
  [ "${KEEP:-}" = 1 ] || kind delete cluster --name "$CLUSTER" > /dev/null 2>&1
  rm -f "$KUBECONFIG"
}
trap cleanup EXIT

echo "Creating the kind cluster $CLUSTER"
kind delete cluster --name "$CLUSTER" > /dev/null 2>&1
kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" > /dev/null || exit 1

echo "Building the assistant and starting it with its read-only role"
docker build -q -t cluster-assistant:eval apps/cluster-assistant > /dev/null || exit 1
kind load docker-image cluster-assistant:eval --name "$CLUSTER" > /dev/null || exit 1
k apply -f platform/cluster-assistant/rbac.yaml -f tests/diagnose/assistant.yaml > /dev/null || exit 1
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  k -n cluster-assistant create secret generic anthropic --from-literal=api-key="$ANTHROPIC_API_KEY" > /dev/null
  k -n cluster-assistant rollout restart deploy/cluster-assistant > /dev/null 2>&1
fi
k -n cluster-assistant rollout status deploy/cluster-assistant --timeout=120s > /dev/null || { echo "assistant didn't start"; exit 1; }
k apply -f "$FAULTS" > /dev/null || exit 1

evidence() { k -n cluster-assistant exec deploy/cluster-assistant -- /cluster-assistant evidence "$1" 2>&1; }
expect_of() { sed -n '1s/^# expect: //p' "$FAULTS/$1.yaml"; }

echo "1. Evidence: do the tools show the cause?"
for f in "$FAULTS"/*.yaml; do
  name="$(basename "$f" .yaml)"
  expect="$(expect_of "$name")"
  start=$SECONDS
  found=
  while [ $((SECONDS - start)) -lt 180 ]; do
    # Captured first: grep -q closing the pipe early would fail the pipeline.
    seen="$(evidence "fault-$name")"
    if grep -Eq -- "$expect" <<< "$seen"; then found=1; break; fi
    sleep 5
  done
  if [ -n "$found" ]; then pass "$name: found /$expect/ after $((SECONDS - start))s"; else fail "$name: /$expect/ never appeared"; fi
done

echo "2. The assistant can't read what it shouldn't"
for what in secrets configmaps; do
  if k auth can-i get "$what" --all-namespaces --as=system:serviceaccount:cluster-assistant:cluster-assistant > /dev/null 2>&1; then
    fail "the role can read $what"
  else
    pass "the role can't read $what"
  fi
done
for verb in create update patch delete; do
  if k auth can-i "$verb" pods --all-namespaces --as=system:serviceaccount:cluster-assistant:cluster-assistant > /dev/null 2>&1; then
    fail "the role can $verb pods"
  else
    pass "the role can't $verb pods"
  fi
done

if [ "$MODE" != --evidence-only ]; then
  echo "3. Diagnosis: does the model name the cause?"
  k -n cluster-assistant port-forward svc/cluster-assistant 18080:8080 > /dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  total_in=0 total_out=0
  for f in "$FAULTS"/*.yaml; do
    name="$(basename "$f" .yaml)"
    expect="$(expect_of "$name")"
    start=$SECONDS
    out="$(curl -s --max-time 300 -X POST localhost:18080/api/diagnose -H 'Content-Type: application/json' \
      -d "{\"namespace\":\"fault-$name\",\"service\":\"web\"}")"
    answer="$(jq -r '.answer // empty' <<< "$out" 2> /dev/null)"
    in="$(jq -r '.inputTokens // 0' <<< "$out" 2> /dev/null)" out_t="$(jq -r '.outputTokens // 0' <<< "$out" 2> /dev/null)"
    total_in=$((total_in + in)) total_out=$((total_out + out_t))
    steps="$(jq -r '[.steps[].tool] | join(",")' <<< "$out" 2> /dev/null)"
    if grep -Eqi -- "$expect" <<< "$answer"; then
      pass "$name: named /$expect/ in $((SECONDS - start))s using $steps"
    else
      fail "$name: answer didn't match /$expect/: ${answer:-$out}"
    fi
  done
  echo "  tokens: $total_in in, $total_out out"
fi

echo
if [ "$failures" = 0 ]; then echo "All checks passed."; else echo "$failures check(s) failed."; exit 1; fi
