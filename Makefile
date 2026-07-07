SHELL := /bin/bash
REPO_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
JAVA21_HOME ?= /usr/lib/jvm/java-21-openjdk-amd64
PYTHON ?= python3
PIP_INDEXER := semantic-search/indexer
QUERY_API := semantic-search/query-api
COMPOSE := docker compose -f docker-compose.dev.yml

.DEFAULT_GOAL := help

help: ## Show available targets
	@printf "Available targets:\n"
	@grep -E '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/: /'

format: ## Run local formatters
	$(PYTHON) -m pip install -q -e './$(PIP_INDEXER)[dev]'
	$(PYTHON) -m ruff format $(PIP_INDEXER)/src $(PIP_INDEXER)/tests scripts
	@if command -v terraform >/dev/null 2>&1; then terraform -chdir=terraform fmt -recursive; else echo 'terraform not installed; skipping'; fi

validate: ## Run available validation checks
	$(PYTHON) -m pip install -q jsonschema pyyaml
	./scripts/validation/validate-json-schema.py
	python3 semantic-search/evaluation/check_openapi.py
	$(MAKE) terraform-validate
	$(MAKE) kubernetes-validate
	@if command -v ansible-lint >/dev/null 2>&1; then $(MAKE) ansible-lint; else echo 'ansible-lint not installed; skipping'; fi
	@if command -v promtool >/dev/null 2>&1; then promtool test rules slo/prometheus-rules.test.yaml; else echo 'promtool not installed; skipping'; fi
	@if command -v shellcheck >/dev/null 2>&1; then find scripts -name '*.sh' -print0 | xargs -0 -r shellcheck; else echo 'shellcheck not installed; skipping'; fi
	@if command -v pwsh >/dev/null 2>&1; then pwsh -NoLogo -NoProfile -Command "Invoke-ScriptAnalyzer -Path hyperv/powershell -Recurse -Severity Warning,Error" || true; else echo 'pwsh not installed; skipping PSScriptAnalyzer'; fi

test: test-unit test-integration ## Run unit and integration tests

test-unit: ## Run Python and Java unit tests
	$(PYTHON) -m pip install -q -e './$(PIP_INDEXER)[dev]'
	$(PYTHON) -m pytest $(PIP_INDEXER)/tests
JAVA_HOME=$(JAVA21_HOME) PATH=$(JAVA21_HOME)/bin:$$PATH mvn -q -f $(QUERY_API)/pom.xml test

test-integration: ## Run integration checks against Docker Compose stack
	./scripts/validation/test-integration.sh

dev-up: ## Start the local Milestone 1 stack
	$(COMPOSE) up -d --build

dev-down: ## Stop the local Milestone 1 stack
	$(COMPOSE) down --remove-orphans

dev-reset: ## Remove local Milestone 1 state and restart cleanly
	$(COMPOSE) down -v --remove-orphans
	$(COMPOSE) up -d --build

seed-events: ## Publish deterministic seed events to Kafka
	$(PYTHON) -m pip install -q -e ./$(PIP_INDEXER)
PYTHONPATH=$(PIP_INDEXER)/src $(PYTHON) scripts/bootstrap/seed-events.py

evaluate-search: ## Evaluate search quality against the deterministic dataset
	$(PYTHON) -m pip install -q -e ./$(PIP_INDEXER)
PYTHONPATH=$(PIP_INDEXER)/src $(PYTHON) semantic-search/evaluation/evaluate_search.py

terraform-validate: ## Format and validate Terraform where available
	@if command -v terraform >/dev/null 2>&1; then terraform -chdir=terraform fmt -check -recursive && terraform -chdir=terraform/environments/lab init -backend=false -input=false >/dev/null && terraform -chdir=terraform/environments/lab validate; else echo 'terraform not installed; skipping'; fi

ansible-lint: ## Run Ansible linting
	ansible-lint ansible/playbooks/site.yml ansible/playbooks/validate.yml ansible/playbooks/cluster.yml

yamllint: ## Run YAML linting
	yamllint .

kubernetes-validate: ## Validate Kubernetes YAML syntax locally
	$(PYTHON) ./scripts/validation/validate-kubernetes.py

cluster-up: ## Bootstrap the kubeadm cluster and platform add-ons (Milestone 3)
	cd ansible && ansible-playbook playbooks/cluster.yml

tenant-apply: ## Apply the tenant Terraform module to the running cluster (Milestone 3)
	terraform -chdir=terraform/environments/lab init -input=false
	terraform -chdir=terraform/environments/lab apply -auto-approve

provision-all: ## One-touch: provision Hyper-V VMs, wait for SSH, then bootstrap the cluster (run in elevated PowerShell)
	@command -v pwsh >/dev/null 2>&1 || { echo 'pwsh is required to run the one-touch provisioner'; exit 1; }
	@if [ -z "$(VHD_ROOT)" ]; then echo 'Set VHD_ROOT, e.g. make provision-all VHD_ROOT="C:\\HyperV\\VHDs" [ISO=...]'; exit 1; fi
	pwsh -NoLogo -NoProfile -File scripts/bootstrap/Start-LabProvisioning.ps1 -VhdRootPath "$(VHD_ROOT)" $(if $(ISO),-InstallIsoPath "$(ISO)" -Autoinstall -BuildAutoinstallIso,)


