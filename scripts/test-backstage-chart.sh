#!/usr/bin/env bash
# Renders the Backstage Application the way Argo CD does, then the Backstage Helm
# chart with the values it carries, and checks the launcher is wired in: the
# container runs it, it is mounted from a ConfigMap that holds the real file,
# and the chart's own probes and replicas are unchanged.
# Needs Docker and the internet (for the chart). Not run by make test for that reason.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

HELM="docker run --rm -v $PWD:/repo -w /repo ${HELM_IMAGE:-alpine/helm:latest}"
YQ="docker run --rm -v $PWD:/repo -w /repo ${YQ_IMAGE:-mikefarah/yq:4.47.2}"
failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
mkdir -p .test/backstage-chart

for ha in true false; do
  want_replicas=$([ "$ha" = true ] && echo 2 || echo 1)
  echo "highAvailability=$ha"
  d=.test/backstage-chart/$ha
  mkdir -p $d
  $HELM template root gitops/root --set aws.enabled=true --set awsAccountId=000000000000 --set backstage.imageTag=test \
    --set highAvailability=$ha --show-only templates/backstage.yaml > $d/application.yaml 2> $d/error.txt || { fail "couldn't render the root chart: $(head -3 $d/error.txt)"; continue; }
  repo="$($YQ '.spec.source.repoURL' $d/application.yaml)" chart="$($YQ '.spec.source.chart' $d/application.yaml)" version="$($YQ '.spec.source.targetRevision' $d/application.yaml)"
  $YQ '.spec.source.helm.valuesObject' $d/application.yaml > $d/values.yaml
  $HELM template backstage "$chart" --repo "$repo" --version "$version" -f $d/values.yaml > $d/rendered.yaml 2> $d/error.txt || { fail "couldn't render the $chart chart $version: $(head -3 $d/error.txt)"; continue; }

  # The Deployment on its own: against the whole file, yq would evaluate each check once per
  # document (there are nine) and print a result for each.
  $YQ 'select(.kind == "Deployment")' $d/rendered.yaml > $d/deployment.yaml
  [ "$($YQ -r '.kind' $d/deployment.yaml)" = Deployment ] || { fail "couldn't isolate the Deployment"; continue; }
  check() { # description yq-expression (must print exactly: true)
    [ "$($YQ -r "$2" $d/deployment.yaml 2> /dev/null)" = true ] && pass "$1" || fail "$1"
  }
  # yq can't compare whole arrays with ==, so they are joined into strings first.
  check "the container runs the launcher, which starts the backend" '(.spec.template.spec.containers[0].command | join(" ")) == "node /launcher/start.js node packages/backend"'
  check "the backend still gets its configuration files" '(.spec.template.spec.containers[0].args | join(" ")) == "--config app-config.yaml --config app-config.production.yaml"'
  # Counts of matching items, not compound booleans: in yq, "select(...) | A and B" evaluates B against
  # every document and can pass by luck (see the note in the Makefile).
  check "the launcher is mounted at /launcher, read-only" '([.spec.template.spec.containers[0].volumeMounts[] | select(.name == "launcher" and .mountPath == "/launcher" and .readOnly == true)] | length) == 1'
  check "...from the ConfigMap backstage-start" '.spec.template.spec.volumes[] | select(.name == "launcher") | .configMap.name == "backstage-start"'
  check "the launcher can find the pg module" '.spec.template.spec.containers[0].env[] | select(.name == "NODE_PATH") | .value == "/app/node_modules"'
  check "the database secret is still passed" '([.spec.template.spec.containers[0].envFrom[].secretRef | select(.name == "backstage-database")] | length) == 1'
  check "the GitHub App secret is still passed" '([.spec.template.spec.containers[0].envFrom[].secretRef | select(.name == "backstage-github-app")] | length) == 1'
  check "the chart's readiness probe is still the real one" '.spec.template.spec.containers[0].readinessProbe.httpGet.path == "/.backstage/health/v1/readiness"'
  check "the startup probe is the liveness endpoint, which the waiting launcher answers" '.spec.template.spec.containers[0].startupProbe.httpGet.path == "/.backstage/health/v1/liveness"'
  check "there are $want_replicas replica(s)" ".spec.replicas == $want_replicas"
  $YQ -r 'select(.kind == "ConfigMap" and .metadata.name == "backstage-start") | .data["start.js"]' $d/rendered.yaml > $d/start.js 2> /dev/null
  # yq adds a newline when it prints a scalar, so trailing newlines are ignored.
  if [ -s $d/start.js ] && [ "$(cat $d/start.js)" = "$(cat gitops/root/files/backstage-start.js)" ]; then pass "the ConfigMap holds exactly the launcher file"; else fail "the ConfigMap doesn't hold the launcher file"; fi
done

echo
[ "$failures" = 0 ] && echo "The launcher is wired into Backstage as intended." || { echo "$failures check(s) failed."; exit 1; }
