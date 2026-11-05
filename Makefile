CLUSTER ?= idp-local
KUBE_CONTEXT ?= kind-$(CLUSTER)
KUBECTL = kubectl --context $(KUBE_CONTEXT)
ARGOCD_CHART_VERSION ?= 10.11.6
GIT_IMAGE ?= alpine:3.22
GIT_CONTAINER ?= idp-git
# Argo CD reads committed changes from here. Override it to use a hosted repo.
REPO_URL ?= git://$(shell docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' $(GIT_CONTAINER))/eks-idp
CROSSPLANE ?= crossplane
# crossplane render ignores Docker contexts such as Colima's, so pass the active context's socket.
export DOCKER_HOST ?= $(shell docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
# Installs the Crossplane AWS providers. Only works on EKS, where they get credentials from Pod Identity.
AWS_ENABLED ?= false
TF_IMAGE ?= hashicorp/terraform:latest
TF_RUN = docker run --rm -v $(CURDIR)/infra/terraform:/workspace -w /workspace $(TF_IMAGE)

.PHONY: local-up local-down cluster argocd local-git gitops demo status backstage aws-environment test tf-validate

local-up: cluster argocd local-git gitops ## Create the kind cluster and hand the platform to Argo CD

local-down: ## Delete the kind cluster and local Git server
	-docker rm -f $(GIT_CONTAINER)
	kind delete cluster --name $(CLUSTER)

cluster:
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER)

argocd:
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm upgrade --install argocd argo/argo-cd --version $(ARGOCD_CHART_VERSION) \
		--namespace argocd --create-namespace --wait --kube-context $(KUBE_CONTEXT)

local-git: ## Serve this repo's commits to Argo CD over the kind network
	-docker rm -f $(GIT_CONTAINER)
	docker run -d --name $(GIT_CONTAINER) --network kind -v $(CURDIR):/srv/eks-idp:ro $(GIT_IMAGE) sh -c \
		"apk add --no-cache git-daemon && git config --global safe.directory '*' && exec git daemon --base-path=/srv --export-all --reuseaddr /srv/eks-idp"
	for i in $$(seq 1 30); do docker exec $(GIT_CONTAINER) git ls-remote git://localhost/eks-idp HEAD >/dev/null 2>&1 && exit 0; sleep 2; done; \
		echo "Git server did not start:"; docker logs $(GIT_CONTAINER); exit 1

gitops: ## Apply the root application
	sed -e 's|REPO_URL|$(REPO_URL)|' -e 's|AWS_ENABLED|$(AWS_ENABLED)|' gitops/root-app.yaml | $(KUBECTL) apply -f -

demo: ## Wait for Argo CD to deliver the example WebService
	for i in $$(seq 1 60); do $(KUBECTL) -n demo get webservice hello >/dev/null 2>&1 && break; sleep 5; done
	$(KUBECTL) -n demo wait webservice hello --for=condition=Ready --timeout=300s
	$(KUBECTL) -n demo get webservice,deployment,service

status: ## Show Argo CD applications
	$(KUBECTL) -n argocd get applications

backstage: ## Run Backstage locally, using your GitHub CLI login to open pull requests
	cd backstage && GITHUB_TOKEN=$$(gh auth token) yarn start

aws-environment: ## Apply the aws-platform EnvironmentConfig from Terraform outputs
	terraform -chdir=infra/terraform output -raw aws_platform_environment | $(KUBECTL) apply -f -

test: ## Render the WebService composition for both runtimes and validate it against the provider schemas
	@rm -rf .test && mkdir -p .test/schemas
	cp platform/crossplane/aws/providers.yaml platform/crossplane/webservice/definition.yaml .test/schemas/
	$(CROSSPLANE) render --include-full-xr tests/render/xr-kubernetes.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml > .test/kubernetes.yaml
	$(CROSSPLANE) render --include-full-xr tests/render/xr-ecs.yaml \
		platform/crossplane/webservice/composition.yaml platform/crossplane/webservice/functions.yaml \
		--extra-resources platform/crossplane/aws/environment.example.yaml > .test/ecs.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/kubernetes.yaml
	$(CROSSPLANE) resource validate --error-on-missing-schemas --cache-dir .test/cache .test/schemas .test/ecs.yaml

tf-validate: ## Check the Terraform without touching AWS
	$(TF_RUN) init -backend=false -input=false
	$(TF_RUN) fmt -check
	$(TF_RUN) validate
