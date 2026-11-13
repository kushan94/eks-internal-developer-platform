#!/usr/bin/env bash
# Renders the Backstage WebService template with and without environments,
# and with autoscaling, the way Backstage's fetch:template does, then builds every
# environment and validates the WebServices against the XRD. Run `make test`
# first, which downloads the schemas into .test/schemas.
set -euo pipefail

NODE_IMAGE="${NODE_IMAGE:-node:22-alpine}"
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
render autoscaling skeleton
render autoscaling skeleton-envs

for env in dev staging prod; do
  kubectl kustomize "$out/environments/workloads/team-b/shop/envs/$env" > "$out/shop-$env.yaml"
  "$CROSSPLANE" resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas "$out/shop-$env.yaml" | tail -n 1
done
"$CROSSPLANE" resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas "$out/single/workloads/team-b/shop.yaml" | tail -n 1

# Prod gets at least two replicas, even when the form asked for one.
run "$YQ_IMAGE" -e '.spec.replicas == 2' "$out/shop-prod.yaml" > /dev/null

# With autoscaling, each environment combines the base's maximum with its own
# minimum, and prod's minimum is at least two.
for env in dev staging prod; do
  kubectl kustomize "$out/autoscaling/workloads/team-b/shop/envs/$env" > "$out/shop-autoscaling-$env.yaml"
  "$CROSSPLANE" resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas "$out/shop-autoscaling-$env.yaml" | tail -n 1
done
run "$YQ_IMAGE" -e '.spec.autoscaling.minReplicas == 1 and .spec.autoscaling.maxReplicas == 6' "$out/shop-autoscaling-dev.yaml" > /dev/null
run "$YQ_IMAGE" -e '.spec.autoscaling.minReplicas == 2 and .spec.autoscaling.maxReplicas == 6' "$out/shop-autoscaling-prod.yaml" > /dev/null
echo "Template renders and validates with and without environments and autoscaling; prod has at least 2 replicas."
