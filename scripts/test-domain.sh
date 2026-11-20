#!/usr/bin/env bash
# Checks that the public domain stays out of Git and still reaches every place
# that needs it. The real domain comes from outside the repository (the
# IDP_DOMAIN variable, Terraform variables, `make gitops DOMAIN=...`), and the
# files carry idp.example.com as a placeholder. The patches that Argo CD applies
# must replace every placeholder, or a hostname silently stays wrong.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
yq() { docker run --rm -i -v "$PWD":/repo -w /repo mikefarah/yq:4.47.2 "$@"; }

real="skyforge""lab"
placeholder="idp.example.com"
domain="idp.test.example"

echo "nothing specific to the owner is committed"
if git grep -qI "$real" -- . ':!scripts/test-domain.sh'; then
  fail "a tracked file still names the real domain: $(git grep -lI "$real" -- . ':!scripts/test-domain.sh' | tr '\n' ' ')"
else
  pass "no tracked file names the real domain"
fi
defaults=0
for f in infra/bootstrap/dns.tf infra/terraform/ingress.tf; do
  grep -qE 'variable "(platform_domain|parent_domain)"' "$f" || { fail "$f no longer declares a domain variable, so this check can't run"; defaults=1; }
  grep -A6 -E 'variable "(platform_domain|parent_domain)"' "$f" | grep -qE '^ *default *=' && { fail "a Terraform domain variable in $f has a default"; defaults=1; }
done
[ "$defaults" -eq 0 ] && pass "Terraform has no default domain"

rendered="$(helm template root gitops/root --set aws.enabled=true --set awsAccountId=000000000000 --set backstage.imageTag=test --set domain="$domain")" \
  || { echo "the root chart doesn't render"; exit 1; }
default_render="$(helm template root gitops/root --set aws.enabled=true --set awsAccountId=000000000000 --set backstage.imageTag=test)"

echo "the root chart"
grep -q "https://backstage.$domain" <<< "$rendered" && pass "Backstage's public URL follows the domain" || fail "Backstage's URL ignores the domain"
grep -q "$placeholder" <<< "$default_render" && pass "without a domain, the placeholder is used" || fail "no placeholder default"

build() { # name, directory: the directory built with the Application's patches
  local name="$1" dir="$2" out=".test/domain/$1"
  rm -rf "$out" && mkdir -p "$out" && cp -R "$dir"/. "$out"/
  yq "select(.kind == \"Application\" and .metadata.name == \"$name\") | .spec.source.kustomize.patches" <<< "$rendered" > "$out/patches.yaml"
  [ -s "$out/patches.yaml" ] && [ "$(cat "$out/patches.yaml")" != null ] || { fail "$name has no kustomize patches"; return 1; }
  yq -i ".patches = load(\"$out/patches.yaml\")" "$out/kustomization.yaml"
  kubectl kustomize "$out" > "$out/built.yaml" 2> "$out/err" || { fail "$name doesn't build: $(cat "$out/err")"; return 1; }
}

echo "the gateway"
if build gateway platform/gateway; then
  hosts="$(yq 'select(.kind == "Gateway") | .spec.listeners[].hostname' < .test/domain/gateway/built.yaml | grep -v '^$' | paste -sd, -)"
  [ "$hosts" = "*.$domain,*.$domain" ] && pass "both listeners use the domain" || fail "listener hostnames: $hosts"
fi

echo "Grafana and the alert message"
if build observability-aws platform/observability/aws; then
  built=.test/domain/observability-aws/built.yaml
  [ "$(yq 'select(.kind == "HTTPRoute") | .spec.hostnames[0]' < $built)" = "grafana.$domain" ] && pass "Grafana's route uses the domain" || fail "Grafana's hostname"
  want="$(yq 'select(.kind == "AlertmanagerConfig") | .spec.receivers[0].slackConfigs[0].text' < platform/observability/aws/alerting.yaml | sed "s/$placeholder/$domain/")"
  got="$(yq 'select(.kind == "AlertmanagerConfig") | .spec.receivers[0].slackConfigs[0].text' < $built)"
  [ "$want" = "$got" ] && pass "the Slack message is the committed one, with the domain swapped in" || fail "the patched Slack message differs from alerting.yaml"
  grep -q "$placeholder" $built && fail "a placeholder survived in the built Grafana and alerting manifests" || pass "no placeholder survives"
fi

echo "the WebService composition"
grep -q 'dig "publicDomain" "" $env' platform/crossplane/webservice/composition.yaml && pass "reads publicDomain from aws-platform" || fail "ignores publicDomain"
grep -q "publicDomain *= *var.platform_domain" infra/terraform/outputs.tf && pass "Terraform supplies publicDomain" || fail "Terraform doesn't supply publicDomain"

[ "$failures" -eq 0 ] && echo "ok" || { echo "$failures failed"; exit 1; }
