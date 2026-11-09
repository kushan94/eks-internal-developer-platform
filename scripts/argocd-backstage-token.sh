#!/usr/bin/env bash
# Creates an API token for Argo CD's read-only backstage account and stores it
# as the backstage-argocd secret, which Backstage's proxy sends to Argo CD.
# The token is created fresh for each cluster and never leaves it.
set -euo pipefail

KUBECTL=(kubectl --context "${KUBE_CONTEXT:?set KUBE_CONTEXT}")
PORT="${PORT:-18443}"

"${KUBECTL[@]}" -n argocd rollout status deploy/argocd-server --timeout=180s > /dev/null
password="$("${KUBECTL[@]}" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

"${KUBECTL[@]}" -n argocd port-forward svc/argocd-server "$PORT:443" > /dev/null 2>&1 &
forward=$!
trap 'kill $forward 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -sk -o /dev/null "https://localhost:$PORT/healthz" && break; sleep 1; done

# The server uses a self-signed certificate, and the connection is a local port-forward.
api() { curl -sSfk -H 'Content-Type: application/json' "$@"; }
session="$(api -d "$(jq -n --arg p "$password" '{username: "admin", password: $p}')" "https://localhost:$PORT/api/v1/session" | jq -r .token)"
token="$(api -X POST -H "Authorization: Bearer $session" -d '{"id": "backstage-'"$(date +%s)"'"}' \
  "https://localhost:$PORT/api/v1/account/backstage/token" | jq -r .token)"
[ -n "$token" ] && [ "$token" != null ] || { echo "Argo CD returned no token" >&2; exit 1; }

"${KUBECTL[@]}" create namespace backstage --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - > /dev/null
"${KUBECTL[@]}" -n backstage create secret generic backstage-argocd \
  --from-literal=ARGOCD_AUTH_TOKEN="argocd.token=$token" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - > /dev/null
echo "Stored a token for Argo CD's backstage account in backstage/backstage-argocd."
