.DEFAULT_GOAL := help
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
REGION     ?= asia-south1
CLUSTER    ?= build-info-dev
IMAGE      := build-info-api
COMMIT     := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
BRANCH     := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n",$$1,$$2}'

install: ## Install dependencies from the lockfile
	npm ci

test: ## Lint + unit tests
	npm run lint && npm test

run: ## Run the API locally on :8080 (auto-reload)
	GIT_COMMIT=$(COMMIT) GIT_BRANCH=$(BRANCH) APP_VERSION=$$(cat VERSION) npm run dev

docker-run: ## Build and run the container locally
	docker build -t $(IMAGE):local \
	  --build-arg APP_VERSION=$$(cat VERSION) --build-arg GIT_COMMIT=$(COMMIT) \
	  --build-arg GIT_BRANCH=$(BRANCH) --build-arg BUILD_TIME=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
	  --build-arg BUILD_ID=local .
	docker run --rm -p 8080:8080 $(IMAGE):local

infra: ## terraform init + apply (needs terraform/terraform.tfvars)
	cd terraform && terraform init -backend-config="bucket=$(PROJECT_ID)-tfstate" && terraform apply

deploy: ## Run the Cloud Build pipeline manually from the working tree
	gcloud builds submit --config cloudbuild.yaml --region $(REGION) \
	  --service-account projects/$(PROJECT_ID)/serviceAccounts/build-info-cloudbuild@$(PROJECT_ID).iam.gserviceaccount.com \
	  --substitutions=_GIT_COMMIT=$(COMMIT),_GIT_BRANCH=$(BRANCH),_REGION=$(REGION),_CLUSTER=$(CLUSTER) .

creds: ## Point kubectl at the cluster via the DNS endpoint
	gcloud container clusters get-credentials $(CLUSTER) --region $(REGION) --dns-endpoint

smoke: ## curl the public endpoint
	curl -s http://$$(kubectl -n build-info get svc build-info-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/build-info | python3 -m json.tool

.PHONY: help install test run docker-run infra deploy creds smoke
