#!/usr/bin/env bash
# Renders the Backstage WebService template both ways, with and without
# environments, the way Backstage's fetch:template does, then builds every
# environment and validates the WebServices against the XRD. Run `make test`
# first, which downloads the schemas into .test/schemas.
set -euo pipefail

NODE_IMAGE="${NODE_IMAGE:-node:22-alpine}"
KUSTOMIZE_IMAGE="${KUSTOMIZE_IMAGE:-registry.k8s.io/kustomize/kustomize:v5.7.1}"
YQ_IMAGE="${YQ_IMAGE:-mikefarah/yq:4.47.2}"
CROSSPLANE="${CROSSPLANE:-crossplane}"
template=backstage/templates/webservice
# A new folder each run: Docker on macOS can briefly show a stale view of a
# folder that was deleted and recreated.
out=".test/template/$(date +%s)"
run() { docker run --rm -v "$PWD":/repo -w /repo "$@"; }

if [ ! -d .test/node/node_modules/nunjucks ]; then
  mkdir -p .test/node
  run -w /repo/.test/node "$NODE_IMAGE" sh -c 'npm init -y > /dev/null && npm i --silent nunjucks@3.2.4'
fi

render() { # variant, skeleton
  run -e NODE_PATH=/repo/.test/node/node_modules "$NODE_IMAGE" \
    node tests/template/render.js "$template/$2" "$out/$1" "$(cat "tests/template/values-$1.json")" > /dev/null
}
render environments skeleton
render environments skeleton-envs
render single skeleton
render single skeleton-single

for env in dev staging prod; do
  run "$KUSTOMIZE_IMAGE" build "$out/environments/workloads/team-b/shop/envs/$env" 2>/dev/null > "$out/shop-$env.yaml"
  "$CROSSPLANE" resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas "$out/shop-$env.yaml" | tail -n 1
done
"$CROSSPLANE" resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas "$out/single/workloads/team-b/shop.yaml" | tail -n 1

# Prod gets at least two replicas, even when the form asked for one.
run "$YQ_IMAGE" -e '.spec.replicas == 2' "$out/shop-prod.yaml" > /dev/null
echo "Template renders and validates both ways; prod has 2 replicas."
