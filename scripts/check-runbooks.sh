#!/usr/bin/env bash
# Checks that what the assistant's runbooks say about the platform is still
# true, so a runbook can't go stale when the composition or a policy changes.
# It checks the concrete claims: spec fields, resource sizes, policy names,
# and the messages the platform emits. It can't check advice.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

RUNBOOKS=apps/cluster-assistant/runbooks
COMPOSITION=platform/crossplane/webservice/composition.yaml
DEFINITION=platform/crossplane/webservice/definition.yaml
failures=0
# Text files only, and not downloaded providers: infra/ can hold gigabytes under .terraform.
search() { grep -rqFI --exclude-dir=.terraform --exclude-dir=node_modules -- "$1" "${@:2}" 2> /dev/null; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
pass() { echo "  PASS  $*"; }

echo "Runbook claims against the platform"

# 1. Every spec.<field> a runbook mentions is a field of the WebService API.
bad=0
for path in $(grep -ohE 'spec\.[a-zA-Z.]+' "$RUNBOOKS"/*.md | sort -u); do
  for part in $(echo "${path#spec.}" | tr . ' '); do
    grep -qE "^ *$part:" "$DEFINITION" || { fail "$path: the WebService has no field '$part'"; bad=1; }
  done
done
# Fields named without the spec. prefix, such as `allowInternet: true`. Kubernetes' own
# fields are listed here, because they aren't in the WebService API.
for field in $(grep -ohE '`[a-z]+([A-Z][a-z]+)+' "$RUNBOOKS"/*.md | tr -d '`' | sort -u); do
  case "$field" in lastState | kubeletVersion | readyInstances | podSelector | namespaceSelector) continue ;; esac
  grep -qE "^ *$field:" "$DEFINITION" || { fail "$field: the WebService has no such field"; bad=1; }
done
[ $bad = 0 ] && pass "every WebService field mentioned exists in the WebService API"

# 2. The resource defaults the runbooks state are the ones the composition sets, and the bounds
# and probe timings they describe are the ones in the API and the composition.
bad=0
for value in 'default "50m"' 'default "64Mi"' 'default "256Mi"'; do
  grep -qF "$value" "$COMPOSITION" || { fail "the composition no longer has $value; update crash-or-oom, pending-or-unschedulable and node-problems"; bad=1; }
done
for bound in "quantity('10m')" "quantity('2')" "quantity('32Mi')" "quantity('4Gi')"; do
  grep -qF "$bound" "$DEFINITION" || { fail "the WebService no longer bounds resources with $bound; update crash-or-oom"; bad=1; }
done
for probe in "startupProbe:" "readinessProbe:" "livenessProbe:" "failureThreshold: 30" "periodSeconds: 10" "tcpSocket:"; do
  grep -qF "$probe" "$COMPOSITION" || { fail "the composition no longer has '$probe'; update health-checks"; bad=1; }
done
grep -qF "32Mi to 4Gi" "$RUNBOOKS/crash-or-oom.md" || { fail "crash-or-oom doesn't state the memory bounds"; bad=1; }
for value in 256Mi 64Mi 50m; do
  grep -qF "$value" "$RUNBOOKS/crash-or-oom.md" || { fail "crash-or-oom doesn't mention $value"; bad=1; }
done
[ $bad = 0 ] && pass "the stated resource defaults, bounds and probe timings match the composition and API"

# 3. Names in backticks that aren't runbooks (policies, namespaces, ...) exist in the platform.
bad=0
names=$(ls "$RUNBOOKS" | sed 's/\.md$//')
for token in $(grep -ohE '`[a-z]+(-[a-z]+)+`' "$RUNBOOKS"/*.md | tr -d '`' | sort -u); do
  if echo "$names" | grep -qx "$token"; then continue; fi
  # Postgres' sslmode values, which are facts about Postgres, not about this platform.
  case "$token" in verify-ca | verify-full) continue ;; esac
  search "$token" platform gitops infra || { fail "'$token' isn't found in platform/, gitops/ or infra/"; bad=1; }
done
[ $bad = 0 ] && pass "every policy, namespace and other name mentioned exists"

# 4. Messages quoted from the platform are still emitted. A quote with "…" is checked in pieces.
bad=0
while IFS= read -r quote; do
  quote="${quote#\"}"; quote="${quote%\"}"
  while IFS= read -r piece; do
    [ ${#piece} -lt 15 ] && continue
    search "$piece" platform gitops || { fail "quoted message no longer in the platform: \"$piece\""; bad=1; }
  done < <(echo "$quote" | sed 's/…/\n/g')
done < <(grep -ohE '"[^"]{25,}"' "$RUNBOOKS"/*.md | sort -u)
[ $bad = 0 ] && pass "every quoted platform message is still in the composition or policies"

# 5. The registries the runbook lists are the ones the policy allows.
bad=0
for registry in ghcr.io/kushan94 ghcr.io/stefanprodan ghcr.io/cloudnative-pg docker.io/nginxinc; do
  grep -qF "$registry" "$RUNBOOKS/image-or-admission.md" || { fail "image-or-admission doesn't list $registry"; bad=1; }
  grep -qF "$registry" platform/policies/workload-images.yaml || { fail "the policy no longer allows $registry"; bad=1; }
done
[ $bad = 0 ] && pass "the allowed registries match the policy"

echo
if [ "$failures" = 0 ]; then echo "The runbooks match the platform."; else echo "$failures claim(s) no longer match."; exit 1; fi
