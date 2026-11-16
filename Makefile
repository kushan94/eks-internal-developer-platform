CLUSTER ?= idp-local
KUBE_CONTEXT ?= kind-$(CLUSTER)
KUBECTL = kubectl --context $(KUBE_CONTEXT)
# Argo CD manages these after the first install; the versions live in gitops/root/values.yaml.
ARGOCD_CHART_VERSION ?= $(shell awk '/^argocd:/ {f=1} f && /chartVersion:/ {print $$2; exit}' gitops/root/values.yaml)
ESO_CHART_VERSION ?= $(shell awk '/^externalSecrets:/ {f=1} f && /chartVersion:/ {print $$2; exit}' gitops/root/values.yaml)
# GitHub account whose repos Argo CD can read with the GitHub App.
GITHUB_OWNER ?= kushan94
GIT_IMAGE ?= alpine:3.22
GIT_CONTAINER ?= idp-git
# Argo CD reads committed changes from here. Override it to use a hosted repo.
REPO_URL ?= git://$(shell docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' $(GIT_CONTAINER))/eks-idp
CROSSPLANE ?= crossplane
# crossplane render ignores Docker contexts such as Colima's, so pass the active context's socket.
export DOCKER_HOST ?= $(shell docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
# Installs the Crossplane AWS providers. Only works on EKS, where they get credentials from Pod Identity.
AWS_ENABLED ?= false
# Only needed on EKS, where Backstage pulls its image from ECR.
AWS_ACCOUNT_ID ?= $(if $(filter true,$(AWS_ENABLED)),$(shell aws sts get-caller-identity --query Account --output text 2>/dev/null))
# The production profile's extra replicas. The Cluster workflow reads it from Terraform.
HIGH_AVAILABILITY ?= false
TF_IMAGE ?= hashicorp/terraform:latest
TF_STATE_BUCKET ?= $(shell terraform -chdir=infra/bootstrap output -raw state_bucket 2>/dev/null)
KYVERNO_CLI_IMAGE ?= ghcr.io/kyverno/kyverno-cli:v1.19.2
YQ_IMAGE ?= mikefarah/yq:4.47.2
PROMETHEUS_IMAGE ?= prom/prometheus:v3.7.3
ALLOY_IMAGE ?= grafana/alloy:v1.21.3
NODE_IMAGE ?= node:22-alpine
TF_RUN = docker run --rm -v $(CURDIR)/infra/terraform:/workspace -w /workspace $(TF_IMAGE)

.PHONY: local-up local-down cluster argocd argocd-backstage-token external-secrets platform-bootstrap wait-apps local-git gitops demo status backstage aws-environment test tf-validate tf-init bootstrap github-setup

local-up: cluster argocd local-git gitops ## Create the kind cluster and hand the platform to Argo CD

local-down: ## Delete the kind cluster and local Git server
	-docker rm -f $(GIT_CONTAINER)
	kind delete cluster --name $(CLUSTER)

cluster:
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER)

argocd:
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm upgrade --install argocd argo/argo-cd --version $(ARGOCD_CHART_VERSION) \
		--values platform/bootstrap/argocd-values.yaml \
		--namespace argocd --create-namespace --wait --kube-context $(KUBE_CONTEXT)

argocd-backstage-token: ## Give Backstage a read-only Argo CD token for this cluster
	KUBE_CONTEXT=$(KUBE_CONTEXT) scripts/argocd-backstage-token.sh

external-secrets:
	helm repo add external-secrets https://charts.external-secrets.io --force-update
	helm upgrade --install external-secrets external-secrets/external-secrets --version $(ESO_CHART_VERSION) \
		--namespace external-secrets --create-namespace --wait --kube-context $(KUBE_CONTEXT)

platform-bootstrap: argocd external-secrets ## On EKS: install Argo CD and External Secrets, then give Argo CD the GitHub App credentials
	$(KUBECTL) apply -f platform/bootstrap/cluster-secret-store.yaml
	sed 's|GITHUB_OWNER|$(GITHUB_OWNER)|' platform/bootstrap/argocd-repo-creds.yaml | $(KUBECTL) apply -f -
	$(KUBECTL) -n argocd wait externalsecret github-app-repo-creds --for=condition=Ready --timeout=120s

local-git: ## Serve this repo's commits to Argo CD over the kind network
	-docker rm -f $(GIT_CONTAINER)
	docker run -d --name $(GIT_CONTAINER) --network kind -v $(CURDIR):/srv/eks-idp:ro $(GIT_IMAGE) sh -c \
		"apk add --no-cache git-daemon && git config --global safe.directory '*' && exec git daemon --base-path=/srv --export-all --reuseaddr /srv/eks-idp"
	for i in $$(seq 1 30); do docker exec $(GIT_CONTAINER) git ls-remote git://localhost/eks-idp HEAD >/dev/null 2>&1 && exit 0; sleep 2; done; \
		echo "Git server did not start:"; docker logs $(GIT_CONTAINER); exit 1

gitops: ## Apply the root application
	sed -e 's|REPO_URL|$(REPO_URL)|' -e 's|AWS_ENABLED|$(AWS_ENABLED)|' -e 's|AWS_ACCOUNT_ID|$(AWS_ACCOUNT_ID)|' -e 's|HIGH_AVAILABILITY|$(HIGH_AVAILABILITY)|' gitops/root-app.yaml | $(KUBECTL) apply -f -

demo: ## Wait for Argo CD to deliver the example WebService
	for i in $$(seq 1 60); do $(KUBECTL) -n demo get webservice hello >/dev/null 2>&1 && break; sleep 5; done
	$(KUBECTL) -n demo wait webservice hello --for=condition=Ready --timeout=300s
	$(KUBECTL) -n demo get webservice,deployment,service

wait-apps: ## Wait until every Argo CD application is Synced and Healthy (up to 15 minutes)
	@for i in $$(seq 1 90); do \
		apps=$$($(KUBECTL) -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null); \
		if [ -n "$$apps" ] && ! echo "$$apps" | grep -qv '=Synced/Healthy$$'; then echo "$$apps"; echo "All applications are Synced and Healthy."; exit 0; fi; \
		sleep 10; \
	done; echo "Timed out. Not ready:"; echo "$$apps" | grep -v '=Synced/Healthy$$'; exit 1

status: ## Show Argo CD applications
	$(KUBECTL) -n argocd get applications

backstage: ## Run Backstage locally, using your GitHub CLI login to open pull requests
	cd backstage && GITHUB_TOKEN=$$(gh auth token) yarn start

aws-environment: ## Apply the aws-platform EnvironmentConfig from Terraform outputs, once Crossplane is installed
	@echo "Waiting for Argo CD to install Crossplane's EnvironmentConfig type..."
	@for i in $$(seq 1 60); do $(KUBECTL) get crd environmentconfigs.apiextensions.crossplane.io >/dev/null 2>&1 && break; sleep 10; done
	$(KUBECTL) wait crd environmentconfigs.apiextensions.crossplane.io --for=condition=Established --timeout=60s
	terraform -chdir=infra/terraform output -raw aws_platform_environment | $(KUBECTL) apply -f -

test: ## Render the WebService composition for each runtime, database class, profile and environment, build every environment, validate it, test the Kyverno policies, the alert rules and the log pipeline
	@rm -rf .test && mkdir -p .test/schemas
	cp platform/crossplane/aws/providers.yaml platform/crossplane/webservice/definition.yaml .test/schemas/
	$(CROSSPLANE) render --include-full-xr tests/render/xr-kubernetes.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml > .test/kubernetes.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-ecs.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/crossplane/aws/environment.example.yaml > .test/ecs.yaml
	@# With the AWS example settings too, so the load balancer's subnets are known.
	{ cat platform/crossplane/webservice/environment.yaml; echo ---; cat platform/crossplane/aws/environment.example.yaml; } > .test/environment-public.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-public.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources .test/environment-public.yaml > .test/public.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-db-in-cluster.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml > .test/db-in-cluster.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-db-in-cluster.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources tests/render/environment-ha.yaml > .test/db-in-cluster-ha.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-db-managed.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/managed-postgres/local/shared-postgres.yaml > .test/db-managed.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-db-managed-ecs.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/crossplane/aws/environment.example.yaml \
		--observed-resources tests/render/observed-db-managed-ecs.yaml > .test/db-managed-ecs.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-environment.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/managed-postgres/local/shared-postgres.yaml > .test/environment.yaml
	@# Every environment of every service builds, and is a valid WebService.
	for env in workloads/*/*/envs/*; do \
		kubectl kustomize $$env > .test/env-$$(echo $$env | tr / -).yaml || exit 1; \
	done
	$(CROSSPLANE) render --include-full-xr tests/render/xr-autoscaling.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml > .test/autoscaling.yaml
	@# Autoscaling is Kubernetes-only, so an ECS service with it must fail to render.
	! $(CROSSPLANE) render tests/render/xr-autoscaling-ecs.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/crossplane/aws/environment.example.yaml > /dev/null 2>&1
	$(CROSSPLANE) render --include-full-xr tests/render/xr-resources.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml > .test/resources.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-resources-numbers.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml > .test/resources-numbers.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-health-check.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml > .test/health-check.yaml
	@# resources and healthCheck are Kubernetes-only: an ECS service with them must fail to render, with that reason.
	$(CROSSPLANE) render tests/render/xr-resources-ecs.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/crossplane/aws/environment.example.yaml 2>&1 | grep -q "resources and healthCheck are only available for the kubernetes runtime"
	$(CROSSPLANE) render --include-full-xr tests/render/xr-allow-from.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml > .test/allow-from.yaml
	! $(CROSSPLANE) render tests/render/xr-allow-from-ecs.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/crossplane/aws/environment.example.yaml > /dev/null 2>&1
	$(CROSSPLANE) render --include-full-xr tests/render/xr-egress.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/crossplane/aws/environment.example.yaml > .test/egress.yaml
	cp platform/crossplane/webservice/provider-sql.yaml .test/schemas/
	curl -fsSL -o .test/schemas/httproutes.yaml \
		https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
	curl -fsSL -o .test/schemas/cnpg-clusters.yaml \
		https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.30.1/config/crd/bases/postgresql.cnpg.io_clusters.yaml
	curl -fsSL -o .test/schemas/cnpg-scheduledbackups.yaml \
		https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.30.1/config/crd/bases/postgresql.cnpg.io_scheduledbackups.yaml
	curl -fsSL -o .test/schemas/podmonitors.yaml \
		https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.94.2/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/kubernetes.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/ecs.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/public.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/db-in-cluster.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/db-in-cluster-ha.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/db-managed.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/environment.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/autoscaling.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/allow-from.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/egress.yaml
	@# The XRD refuses maxReplicas below minReplicas.
	! $(CROSSPLANE) resource validate --cache-dir .test/cache .test/schemas tests/render/xr-autoscaling-invalid.yaml > /dev/null 2>&1
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/resources.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/resources-numbers.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/health-check.yaml
	@# Memory and CPU outside the allowed range (including 0.5, which must be 500m), and a health check path without a slash, are refused.
	for f in tests/render/xr-resources-invalid-*.yaml tests/render/xr-health-check-invalid.yaml; do \
		if $(CROSSPLANE) resource validate --cache-dir .test/cache .test/schemas $$f > /dev/null 2>&1; then echo "$$f was accepted"; exit 1; fi; \
	done
	for f in .test/env-*.yaml; do $(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas $$f || exit 1; done
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/db-managed-ecs.yaml
	@# yq assertions below: wrap everything after "select(...) |" in one pair of
	@# parentheses, and each comparison in its own. "select(...) | (A) and (B)" runs B
	@# on every document and can pass by luck.
	@# The production profile runs in-cluster databases as three instances; the study profile as one.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Cluster") | .spec.instances == 3' .test/db-in-cluster-ha.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Cluster") | .spec.instances == 1' .test/db-in-cluster.yaml
	@# allowFrom: a team in the same environment, and a team's one service, where the
	@# namespace and pod selectors must be in the same entry so both have to match.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy") | (.spec.ingress[1].from[0].namespaceSelector.matchLabels | ((.["platform.example.org/team"] == "shop") and (.["platform.example.org/environment"] == "prod")))' .test/allow-from.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy") | (.spec.ingress[2].from | ((length == 1) and (.[0].podSelector.matchLabels["app.kubernetes.io/name"] == "invoices")))' .test/allow-from.yaml
	@# Outbound: on kind the managed database is reached in its namespace, on EKS in the
	@# VPC's range; allowTo is environment-bound; allowInternet keeps private ranges blocked.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy") | (((.spec.egress | length) == 3) and (.spec.egress[2].to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "crossplane-system"))' .test/db-managed.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy") | ((.spec.egress[2].to[0].ipBlock.cidr == "10.42.0.0/16") and (.spec.egress[2].ports[0].port == 5432))' .test/egress.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy") | ((.spec.egress[3].to[0].namespaceSelector.matchLabels["platform.example.org/environment"] == "prod") and (.spec.egress[3].to[0].podSelector.matchLabels["app.kubernetes.io/name"] == "invoices"))' .test/egress.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy") | (.spec.egress[4].to[0].ipBlock.except | contains(["10.0.0.0/8", "169.254.0.0/16"]))' .test/egress.yaml
	@# Resources: the platform's defaults when a service sets none, and its own memory and CPU when it does.
	@# Setting memory requests the same amount as the limit.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Deployment") | (.spec.template.spec.containers[0].resources | ((.requests.cpu == "50m") and (.requests.memory == "64Mi") and (.limits.memory == "256Mi")))' .test/kubernetes.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Deployment") | (.spec.template.spec.containers[0].resources | ((.requests.cpu == "250m") and (.requests.memory == "512Mi") and (.limits.memory == "512Mi")))' .test/resources.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Deployment") | (.spec.template.spec.containers[0].resources.limits | has("cpu") | not)' .test/resources.yaml
	@# Plain numbers, which YAML reads as integers, work too, and come out as quantities.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Deployment") | (.spec.template.spec.containers[0].resources | ((.requests.cpu == "1") and (.requests.memory == "1073741824") and (.limits.memory == "1073741824")))' .test/resources-numbers.yaml
	@# Health: a port check by default, which is ready without restarting anything; with a path, all three HTTP probes.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Deployment") | (.spec.template.spec.containers[0] | ((.readinessProbe.tcpSocket.port == "http") and (has("livenessProbe") | not) and (has("startupProbe") | not)))' .test/kubernetes.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Deployment") | (.spec.template.spec.containers[0] | ((.readinessProbe.httpGet.path == "/healthz") and (.livenessProbe.httpGet.path == "/healthz") and (.startupProbe.httpGet.path == "/healthz") and (.readinessProbe | has("tcpSocket") | not)))' .test/health-check.yaml
	@# With autoscaling, the HorizontalPodAutoscaler owns the replica count.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Deployment") | (.spec | has("replicas") | not)' .test/autoscaling.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "HorizontalPodAutoscaler") | (.spec.minReplicas == 2 and .spec.maxReplicas == 8)' .test/autoscaling.yaml
	@# Environments share the service's Backstage ID but get their own database.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Deployment") | (.spec.template.metadata.labels["platform.example.org/environment"] == "prod" and .spec.template.metadata.labels["backstage.io/kubernetes-id"] == "demo-visits")' .test/environment.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Database") | .metadata.annotations["crossplane.io/external-name"] == "demo-prod-visits"' .test/environment.yaml
	@# Every service is isolated; public ones also let in the load balancer's subnets.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy") | .spec.ingress | length == 1' .test/kubernetes.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy") | .spec.ingress[1].from[0].ipBlock.cidr == "10.42.128.0/20"' .test/public.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "NetworkPolicy" and .metadata.name == "catalog-db") | .spec.podSelector.matchLabels["cnpg.io/cluster"] == "catalog-db"' .test/db-in-cluster.yaml
	@# Only the production profile backs in-cluster databases up, as EBS snapshots.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "Cluster") | .spec.backup.volumeSnapshot.className == "ebs-snapshots"' .test/db-in-cluster-ha.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) -e 'select(.kind == "ScheduledBackup") | .spec.method == "volumeSnapshot"' .test/db-in-cluster-ha.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) ea -e '[select(.kind == "ScheduledBackup")] | length == 0' .test/db-in-cluster.yaml
	docker run --rm -v $(CURDIR):/repo -w /repo $(KYVERNO_CLI_IMAGE) test tests/policies
	mkdir -p .test/alerts
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) '.spec' platform/observability/alerts/webservice.yaml > .test/alerts/webservice.yaml
	docker run --rm --entrypoint promtool -v $(CURDIR):/repo -w /repo $(PROMETHEUS_IMAGE) check rules .test/alerts/webservice.yaml
	docker run --rm --entrypoint promtool -v $(CURDIR):/repo -w /repo $(PROMETHEUS_IMAGE) test rules tests/alerts/webservice-test.yaml
	@# Alloy's log pipeline must parse.
	docker run --rm -v $(CURDIR):/repo -w /repo $(YQ_IMAGE) '.data["config.alloy"]' platform/observability/logs/alloy-config.yaml > .test/config.alloy
	docker run --rm -v $(CURDIR)/.test:/w $(ALLOY_IMAGE) fmt /w/config.alloy > /dev/null

test-template: ## Render the Backstage template with and without environments, build every environment and validate the WebServices (run make test first)
	NODE_IMAGE=$(NODE_IMAGE) YQ_IMAGE=$(YQ_IMAGE) CROSSPLANE=$(CROSSPLANE) tests/template/test.sh

test-health: ## On a throwaway kind cluster: the real API server accepts the WebService's resources and healthCheck fields (CEL rules and all), and the probes and sizes behave on real pods (run make test first)
	scripts/test-resources-and-health.sh

test-db: ## On a running cluster: create both database classes, log in, check isolation and cleanup
	scripts/test-databases.sh $(KUBE_CONTEXT)

rds-restore-drill: ## On EKS with the production profile: restore the shared RDS server to a point in time and check the copy
	scripts/rds-restore-drill.sh $(KUBE_CONTEXT)

cnpg-restore-drill: ## On EKS with the production profile: back up an in-cluster database as EBS snapshots, restore it and check the copy
	scripts/cnpg-restore-drill.sh $(KUBE_CONTEXT)

bootstrap: ## Create the Terraform state bucket and GitHub IAM users (once, from your laptop)
	terraform -chdir=infra/bootstrap init
	terraform -chdir=infra/bootstrap apply

github-setup: ## Create the GitHub environments and secrets from the bootstrap outputs
	scripts/github-setup.sh

tf-init: ## Point the main Terraform stack at the S3 state bucket
	terraform -chdir=infra/terraform init -reconfigure -backend-config="bucket=$(TF_STATE_BUCKET)"

tf-validate: ## Check the Terraform without touching AWS
	$(TF_RUN) init -backend=false -input=false
	$(TF_RUN) fmt -check
	$(TF_RUN) validate
