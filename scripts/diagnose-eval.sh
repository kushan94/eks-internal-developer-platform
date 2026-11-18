#!/usr/bin/env bash
# Tests the cluster assistant against deliberately broken workloads, on a
# throwaway kind cluster. Each file in tests/diagnose/faults/ is one fault, and
# its first lines say what to look for:
#   # expect: <regex>    what the tools' evidence must contain
#   # answer: <regex>    what a correct diagnosis says (default: the same)
#   # runbook: <name>    the runbook that fits it, or "none"
#   # target: <service>  what to diagnose (default: web)
#
#   1. Evidence: the assistant's tools, run without a model, must show the cause.
#      This needs no API key, and checks the tools, the read-only role and the
#      in-cluster client.
#   2. Diagnosis (unless --evidence-only): the model must name the cause. This
#      calls the Claude API with ANTHROPIC_API_KEY and costs money. It stops
#      when it has spent EVAL_BUDGET_USD (default 5), estimated at list prices.
#      Every request asks for a fresh diagnosis, so cached answers don't count.
#   --compare runs the diagnosis twice, without and then with the runbooks, and
#      reports what they changed: how many faults were diagnosed, and the cost.
#
#   --dry-run runs the same comparison against a stand-in for the Claude API
#      (tests/diagnose/fake-anthropic.yaml), which costs nothing and needs no key.
#      It tests the assistant's plumbing and this script, not the model: the
#      stand-in answers correctly only when it is given runbooks.
#
# Usage: scripts/diagnose-eval.sh [--evidence-only | --compare | --dry-run]
# Set KEEP=1 to leave the cluster running.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=idp-assistant-eval
KUBECONFIG="$(mktemp)"
export KUBECONFIG
MODE="${1:-}"
FAULTS=tests/diagnose/faults
failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
k() { kubectl "$@"; }

if [ "$MODE" != --evidence-only ] && [ "$MODE" != --dry-run ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY isn't set. Set it, or pass --evidence-only to skip the model, or --dry-run to test against a stand-in."
  exit 1
fi

cleanup() {
  if [ -n "${PF_PID:-}" ]; then pkill -P "$PF_PID" 2> /dev/null; kill "$PF_PID" 2> /dev/null; fi
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
header() { sed -n "s/^# $2: //p" "$FAULTS/$1.yaml" | head -n 1; }
expect_of() { header "$1" expect; }
answer_of() { local a; a="$(header "$1" answer)"; echo "${a:-$(expect_of "$1")}"; }
runbook_of() { local r; r="$(header "$1" runbook)"; echo "${r:-none}"; }
target_of() { local t; t="$(header "$1" target)"; echo "${t:-web}"; }

echo "1. Evidence: do the tools show the cause?"
for f in "$FAULTS"/*.yaml; do
  name="$(basename "$f" .yaml)"
  expect="$(expect_of "$name")"
  start=$SECONDS
  found=
  while [ $((SECONDS - start)) -lt 300 ]; do
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

EVAL_BUDGET_USD="${EVAL_BUDGET_USD:-5}"
RESULTS=()
# Forwards the assistant's port, reconnecting when its pod is replaced (a port-forward
# can attach to the old pod while it is terminating), and waits until it answers.
start_forward() {
  if [ -n "${PF_PID:-}" ]; then pkill -P "$PF_PID" 2> /dev/null; kill "$PF_PID" 2> /dev/null; wait "$PF_PID" 2> /dev/null; fi
  (while true; do kubectl port-forward -n cluster-assistant svc/cluster-assistant 18080:8080 > /dev/null 2>&1; sleep 1; done) &
  PF_PID=$!
  disown "$PF_PID" 2> /dev/null
  for _ in $(seq 1 60); do
    curl -sf -m 2 localhost:18080/healthz > /dev/null 2>&1 && return 0
    sleep 1
  done
  echo "the assistant didn't answer through the port-forward"; exit 1
}
# Turns the runbooks on or off ("on" or "off") and restarts the assistant.
set_runbooks() {
  k -n cluster-assistant set env deploy/cluster-assistant RUNBOOKS="$([ "$1" = off ] && echo off || echo on)" > /dev/null
  k -n cluster-assistant rollout status deploy/cluster-assistant --timeout=120s > /dev/null || { echo "assistant didn't restart"; exit 1; }
  start_forward
}

# Diagnoses every fault once with the assistant as it is now.
run_phase() {
  local label="$1" named=0 total=0 loaded=0 wanted=0 tokens_in=0 tokens_out=0 cost_total=0 f name
  echo "3. Diagnosis ($label): does the model name the cause?"
  for f in "$FAULTS"/*.yaml; do
    name="$(basename "$f" .yaml)"
    if awk -v spent="$SPENT" -v cap="$EVAL_BUDGET_USD" 'BEGIN { exit !(spent >= cap) }'; then
      echo "  stopped: the eval's budget of \$$EVAL_BUDGET_USD is spent (EVAL_BUDGET_USD raises it)"
      break
    fi
    local expect runbook start out answer steps cost in_t out_t used
    expect="$(answer_of "$name")" runbook="$(runbook_of "$name")" start=$SECONDS
    out="$(curl -s --max-time 300 -X POST localhost:18080/api/diagnose -H 'Content-Type: application/json' \
      -d "{\"namespace\":\"fault-$name\",\"service\":\"$(target_of "$name")\",\"fresh\":true}")"
    if [ -z "$out" ]; then fail "$name: no response from the assistant"; total=$((total + 1)); continue; fi
    answer="$(jq -r '.answer // empty' <<< "$out" 2> /dev/null)"
    in_t="$(jq -r '.inputTokens // 0' <<< "$out" 2> /dev/null)" out_t="$(jq -r '.outputTokens // 0' <<< "$out" 2> /dev/null)"
    cost="$(jq -r '.costUSD // 0' <<< "$out" 2> /dev/null)"
    steps="$(jq -r '[.steps[].tool] | join(",")' <<< "$out" 2> /dev/null)"
    used="$(jq -r '[.steps[] | select(.tool == "load_runbook") | .input.name] | join(",")' <<< "$out" 2> /dev/null)"
    total=$((total + 1)) tokens_in=$((tokens_in + in_t)) tokens_out=$((tokens_out + out_t))
    cost_total="$(awk -v a="$cost_total" -v b="${cost:-0}" 'BEGIN { printf "%.4f", a + b }')"
    SPENT="$(awk -v a="$SPENT" -v b="${cost:-0}" 'BEGIN { printf "%.4f", a + b }')"
    local note=""
    if [ "$runbook" != none ] && [ "$label" != "runbooks off" ]; then
      wanted=$((wanted + 1))
      if grep -qw -- "$runbook" <<< "$used"; then loaded=$((loaded + 1)); note=", loaded $runbook"; else note=", did not load $runbook (loaded: ${used:-none})"; fi
    fi
    if grep -Eqi -- "$expect" <<< "$answer"; then
      named=$((named + 1)); pass "$name: named /$expect/ in $((SECONDS - start))s, \$$cost, $steps$note"
    elif [ "$label" = "runbooks off" ]; then
      # A miss without runbooks is a measurement, not a failure.
      echo "  miss  $name: answer didn't match /$expect/ (steps: $steps)"
    else
      fail "$name: answer didn't match /$expect/ (steps: $steps$note): ${answer:-$out}"
    fi
  done
  local summary="$label: $named of $total faults diagnosed, about \$$cost_total, $tokens_in tokens in and $tokens_out out"
  [ "$wanted" -gt 0 ] && summary="$summary, the fitting runbook loaded in $loaded of $wanted"
  RESULTS+=("$summary")
  echo "  $summary"
  LAST_NAMED=$named LAST_TOTAL=$total LAST_LOADED=$loaded LAST_WANTED=$wanted
}

if [ "$MODE" != --evidence-only ]; then
  SPENT=0
  echo "3. The diagnosis calls the Claude API. It stops at \$$EVAL_BUDGET_USD estimated spend."
  k -n cluster-assistant set env deploy/cluster-assistant MAX_DAILY_SPEND_USD=1000 MAX_DIAGNOSES_PER_HOUR=1000 > /dev/null
  if [ "$MODE" = --dry-run ]; then
    echo "  (dry run: the answers come from a stand-in, so this tests the plumbing, not the model)"
    k apply -f tests/diagnose/fake-anthropic.yaml > /dev/null || exit 1
    k -n fake-anthropic rollout status deploy/fake-anthropic --timeout=180s > /dev/null || { echo "the stand-in didn't start"; exit 1; }
    k -n cluster-assistant set env deploy/cluster-assistant ANTHROPIC_API_KEY=dummy ANTHROPIC_BASE_URL=http://fake-anthropic.fake-anthropic.svc:8080 > /dev/null
  fi
  if [ "$MODE" = --compare ] || [ "$MODE" = --dry-run ]; then
    set_runbooks off; run_phase "runbooks off"; off_named=$LAST_NAMED
    set_runbooks on; run_phase "runbooks on"
    echo; echo "Comparison:"; printf '  %s\n' "${RESULTS[@]}"
    if [ "$MODE" = --dry-run ]; then
      echo "Dry-run checks"
      # The stand-in answers wrongly without runbooks, so a miss on every fault is the expected result.
      [ "$off_named" = 0 ] && pass "without runbooks the stand-in diagnosed nothing" || fail "without runbooks it diagnosed $off_named"
      [ "$LAST_NAMED" = "$LAST_TOTAL" ] && [ "$LAST_TOTAL" -gt 0 ] && pass "with runbooks it diagnosed all $LAST_TOTAL" || fail "with runbooks it diagnosed $LAST_NAMED of $LAST_TOTAL"
      [ "$LAST_WANTED" -gt 0 ] && [ "$LAST_LOADED" = "$LAST_WANTED" ] && pass "the fitting runbook was loaded for all $LAST_WANTED faults that have one" || fail "runbook loaded $LAST_LOADED of $LAST_WANTED"
      awk -v s="$SPENT" 'BEGIN { exit !(s > 0.2 && s < 0.5) }' && pass "the spend was tallied (about \$$SPENT, from 1,000 tokens in and 200 out per call)" || fail "unexpected spend: $SPENT"
    fi
  else
    set_runbooks on; run_phase "runbooks on"
  fi
fi

echo
if [ "$failures" = 0 ]; then echo "All checks passed."; else echo "$failures check(s) failed."; exit 1; fi
