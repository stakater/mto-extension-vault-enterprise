# Vault Enterprise extension for MTO: the two charts, their checks, and a local lab.
#
# `make` runs every check CI runs (lint, render tests, CRD validation). A
# contributor who runs `make`, sees green and pushes must have actually tested
# the change.
#
# The lab is one kind cluster with everything the extension needs:
#   cert-manager                 t-op-v2's and VCO's webhook certificates
#   MTO Tenant CRD               the parent Template's input (MTO itself is not installed)
#   template-operator-v2         the renderer
#   Vault (dev mode)             Enterprise with VAULT_LICENSE_FILE, or VAULT_EDITION=ce
#   vault-config-operator (VCO)  built from the checkout at VCO_SRC, not a release
#
# `make lab-up` builds all of it; every target is idempotent, so a re-run after
# a failure reuses what is already up. `make lab-vco` alone rebuilds and
# redeploys VCO after an edit in VCO_SRC.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := all

LOCALBIN ?= $(CURDIR)/bin

CLUSTER_NAME ?= vault-ent-lab
KIND_CONFIG  ?= hack/lab/kind-config.yaml
# Every target names its context: never the ambient current-context.
CONTEXT ?= kind-$(CLUSTER_NAME)
KUBECTL ?= kubectl
KIND    ?= kind
CONTAINER_TOOL ?= docker
KC = $(KUBECTL) --context $(CONTEXT)

CERT_MANAGER_VERSION ?= v1.20.0
CERT_MANAGER_URL     ?= https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml

# template-operator-v2's public release. The release name MUST be
# template-operator-v2: the chart's Certificate hardcodes
# issuerRef.name=template-operator-v2-selfsigned-issuer, so any other release
# name never gets a webhook certificate.
TOV2_NS            ?= stakater-template-operator
TOV2_RELEASE       := template-operator-v2
TOV2_CHART         ?= oci://ghcr.io/stakater/public/charts/template-operator-v2
TOV2_CHART_VERSION ?= 0.0.7
TOV2_DEPLOYMENT    ?= template-operator-v2-controller-manager

ESO_CHART_VERSION      ?= 2.11.0
RELOADER_CHART_VERSION ?= 2.2.17

VAULT_NS            ?= vault
VAULT_CHART_VERSION ?= 0.34.1
VAULT_VERSION       ?= 2.1.1
# ent needs VAULT_LICENSE_FILE. ce runs without one, but has no namespaces, so
# nothing tenant-shaped can be tested on it. There is no silent fallback.
VAULT_EDITION       ?= ent
VAULT_LICENSE_FILE  ?=

# VCO is built from this checkout, so an unmerged fix can be tested.
VCO_SRC      ?= ../vault-config-operator
VCO_NS       ?= vault-config-operator
VCO_RELEASE  ?= vault-config-operator
VCO_IMG_REPO ?= vault-config-operator
VCO_IMG_TAG  ?= lab
VCO_CHART    := $(VCO_SRC)/charts/vault-config-operator
# Drift detection is off by default in VCO. The lab turns it on with a short
# period, so out-of-band edits are visible quickly — and so the e2e suite can
# watch objects across several drift reconciles in well under a minute.
VCO_SYNC_PERIOD_SECONDS ?= 30

# The Kubernetes namespace that holds every VCO CR, and the ServiceAccount the
# CRs log in to Vault with (spec.authentication.serviceAccount).
CONFIG_NS ?= vault-config
CONFIG_SA ?= vco-admin
VERIFY_LOGIN ?= 1

.PHONY: help
help: ## Show the targets.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

define wait-crd
	@ok=""; for i in 1 2 3; do \
		$(KC) wait crd $(1) --for=condition=Established --timeout=60s && { ok=1; break; }; \
		echo "  CRDs not established yet, retrying ($$i/3)"; sleep 5; \
	done; \
	if [ -z "$$ok" ]; then echo "error: CRDs $(1) never became Established" >&2; exit 1; fi
endef

# ─── Checks ──────────────────────────────────────────────────────────

# The VCO CRDs the charts are validated against: a vendored copy of the 8 kinds
# the charts render. Vendored because the charts need
# spec.authentication.targetNamespace (upstream issue #291), which is in no VCO
# release yet, and CI cannot see a local VCO checkout. hack/vco-crds/README.md
# records where the copy came from. Once a VCO release has the field, pull that
# release's CRDs here instead — a version is immutable, a branch is not.
VCO_CRD_DIR ?= hack/vco-crds
VCO_CRD_KINDS := namespaces secretenginemounts authenginemounts kubernetesauthengineconfigs \
                 kubernetesauthengineroles policies jwtoidcauthengineconfigs jwtoidcauthengineroles

.PHONY: all
all: helm-lint helm-render-test crd-validate ## Everything CI runs: lint, render tests (incl. version pin), CRD schema check.

.PHONY: helm-lint
helm-lint: helm ## Lint both charts.
	$(HELM) lint $(TENANT_CHART_DIR) --strict --set tenant=lint
	$(HELM) lint $(BOOTSTRAP_CHART_DIR) --strict

.PHONY: helm-render-test
helm-render-test: helm yq ## Render tests: golden, slices, guards, RBAC, toggles, plumbing, version pin.
	HELM=$(HELM) YQ=$(YQ_BIN) ./hack/chart-render-tests.sh

.PHONY: crd-validate
crd-validate: helm yq ## Validate every rendered VCO CR against VCO's CRDs (apiserver admission pipeline).
	@test -d $(VCO_CRD_DIR) || { echo "error: VCO_CRD_DIR=$(VCO_CRD_DIR) does not exist" >&2; exit 1; }
	HELM=$(HELM) YQ=$(YQ_BIN) ./hack/crd-validate.sh $(VCO_CRD_DIR)

.PHONY: vco-crds-sync
vco-crds-sync: ## Refresh hack/vco-crds from the VCO checkout at VCO_SRC. Update hack/vco-crds/README.md with it.
	@test -d $(VCO_SRC)/config/crd/bases || { echo "error: VCO_SRC=$(VCO_SRC) is not a vault-config-operator checkout" >&2; exit 1; }
	@for k in $(VCO_CRD_KINDS); do cp $(VCO_SRC)/config/crd/bases/redhatcop.redhat.io_$$k.yaml hack/vco-crds/; done
	@echo "copied $(words $(VCO_CRD_KINDS)) CRDs from $(VCO_SRC) @ $$(git -C $(VCO_SRC) rev-parse --short HEAD)$$(git -C $(VCO_SRC) diff --quiet || echo ' + uncommitted changes')"

# ─── Release ─────────────────────────────────────────────────────────

# Each chart publishes at its own Chart.yaml version.
TENANT_CHART_DIR    ?= charts/mto-extension-vault-enterprise
BOOTSTRAP_CHART_DIR ?= charts/mto-extension-vault-enterprise-bootstrap
TENANT_VERSION    := $(shell awk '/^version:/{print $$2; exit}' $(TENANT_CHART_DIR)/Chart.yaml)
BOOTSTRAP_VERSION := $(shell awk '/^version:/{print $$2; exit}' $(BOOTSTRAP_CHART_DIR)/Chart.yaml)

HELM_REGISTRY ?= ghcr.io/stakater/charts
# GHCR_* is what the workflows set; GIT_* is a local override for pushing to
# your own registry.
GIT_USER  ?= $(GHCR_USERNAME)
GIT_TOKEN ?= $(GHCR_TOKEN)

.PHONY: helm-login
helm-login: helm ## Log in to the OCI chart registry.
	@if [ -z "$(GIT_USER)" ] || [ -z "$(GIT_TOKEN)" ]; then \
		echo "GIT_USER/GIT_TOKEN (or GHCR_USERNAME/GHCR_TOKEN) must be set"; exit 1; \
	fi
	@echo "$(GIT_TOKEN)" | $(HELM) registry login $(firstword $(subst /, ,$(HELM_REGISTRY))) -u "$(GIT_USER)" --password-stdin

# helm push has no existence check and no --force, and GHCR permits tag
# overwrite, so a republished version silently replaces what tenants pull.
#
# Fails closed: only an explicit not-found means the tag is free. helm show chart
# also exits non-zero on DNS failure and an expired token, and treating those as
# free would publish over tenants on a network blip. Must run after helm-login —
# unauthenticated, GHCR answers 403 for absent and published tags alike.
define check-tag-free
@out=$$($(HELM) show chart oci://$(HELM_REGISTRY)/$(1) --version $(2) 2>&1); rc=$$?; \
if [ $$rc -eq 0 ]; then \
	echo "$(1) $(2) is already published — bump Chart.yaml before releasing"; exit 1; \
fi; \
if ! grep -qiE 'not found|manifest unknown|name unknown' <<<"$$out"; then \
	echo "cannot determine whether $(1) $(2) is published — refusing to push:"; \
	printf '%s\n' "$$out" | head -3; exit 1; \
fi
endef

.PHONY: helm-release
# Tenant chart FIRST: the bootstrap pins it by exact version, so publishing the
# bootstrap first leaves a window where its child Templates name a chart tag that
# 404s and every tenant renders nothing.
helm-release: helm-release-tenant helm-release-bootstrap ## Release both charts to OCI.

.PHONY: helm-release-tenant
helm-release-tenant: helm helm-login ## Lint, package and push the tenant chart.
	$(HELM) lint $(TENANT_CHART_DIR) --strict --set tenant=lint
	$(call check-tag-free,mto-extension-vault-enterprise,$(TENANT_VERSION))
	@mkdir -p dist
	$(HELM) package $(TENANT_CHART_DIR) -d dist
	$(HELM) push dist/mto-extension-vault-enterprise-$(TENANT_VERSION).tgz oci://$(HELM_REGISTRY)

.PHONY: helm-release-bootstrap
helm-release-bootstrap: helm helm-login ## Lint, package and push the bootstrap chart.
	$(HELM) lint $(BOOTSTRAP_CHART_DIR) --strict
	$(call check-tag-free,mto-extension-vault-enterprise-bootstrap,$(BOOTSTRAP_VERSION))
	@mkdir -p dist
	$(HELM) package $(BOOTSTRAP_CHART_DIR) -d dist
	$(HELM) push dist/mto-extension-vault-enterprise-bootstrap-$(BOOTSTRAP_VERSION).tgz oci://$(HELM_REGISTRY)

# ─── Tools ───────────────────────────────────────────────────────────

# A system binary wins over the pinned download, so *_VERSION is what we fetch
# and *_MIN is the floor enforced against whatever is actually used. curl -f
# matters: without it curl writes the HTTP error body to the destination and
# exits 0, so an error page becomes the cached tool.
HELM         ?= $(shell command -v helm || echo $(LOCALBIN)/helm)
HELM_VERSION ?= v3.19.0
HELM_MIN     ?= 3.14
YQ_BIN       ?= $(shell command -v yq || echo $(LOCALBIN)/yq)
YQ_VERSION   ?= v4.44.3
# 4.40 is where the render harness runs clean; older builds get sort_keys wrong
# and fail as a golden diff with no hint that yq is the cause.
YQ_MIN       ?= 4.40

OS_LOWER = $$(uname | tr '[:upper:]' '[:lower:]')
ARCH_GO  = $$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: helm
helm: ## Ensure a helm binary of at least $(HELM_MIN) is available.
	@if [ ! -x "$(HELM)" ]; then \
		echo "Downloading helm $(HELM_VERSION)"; mkdir -p $(LOCALBIN); tmp=$$(mktemp -d); \
		curl -fsSL -o $$tmp/helm.tar.gz "https://get.helm.sh/helm-$(HELM_VERSION)-$(OS_LOWER)-$(ARCH_GO).tar.gz"; \
		tar -zxf $$tmp/helm.tar.gz -C $$tmp; mv $$tmp/$(OS_LOWER)-$(ARCH_GO)/helm $(LOCALBIN)/helm; \
		chmod +x $(LOCALBIN)/helm; rm -rf $$tmp; \
	fi
	@have=$$($(HELM) version --template '{{.Version}}' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1); \
	if [ -z "$$have" ]; then echo "$(HELM) is not a working helm binary — delete it and re-run"; exit 1; fi; \
	if [ "$$(printf '%s\n%s\n' "$(HELM_MIN)" "$$have" | sort -V | head -1)" != "$(HELM_MIN)" ]; then \
		echo "helm $$have is older than the required $(HELM_MIN) ($(HELM))"; exit 1; \
	fi

.PHONY: yq
yq: ## Ensure a yq binary of at least $(YQ_MIN) is available.
	@if [ ! -x "$(YQ_BIN)" ]; then \
		echo "Downloading yq $(YQ_VERSION)"; mkdir -p $(LOCALBIN); tmp=$$(mktemp); \
		curl -fsSL -o $$tmp "https://github.com/mikefarah/yq/releases/download/$(YQ_VERSION)/yq_$(OS_LOWER)_$(ARCH_GO)"; \
		chmod +x $$tmp; $$tmp --version >/dev/null; mv $$tmp $(LOCALBIN)/yq; \
	fi
	@have=$$($(YQ_BIN) --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1); \
	if [ -z "$$have" ]; then echo "$(YQ_BIN) is not a working yq binary — delete it and re-run"; exit 1; fi; \
	if [ "$$(printf '%s\n%s\n' "$(YQ_MIN)" "$$have" | sort -V | head -1)" != "$(YQ_MIN)" ]; then \
		echo "yq $$have is older than the required $(YQ_MIN) ($(YQ_BIN))"; exit 1; \
	fi

# ─── E2E ─────────────────────────────────────────────────────────────

# The suite (tests/e2e) installs and uninstalls the bootstrap chart itself, and
# brings its own tenants, so it runs against the plain lab. It needs Vault
# ENTERPRISE — it refuses Community Edition, where namespaces are ignored.
E2E_WAIT_TIMEOUT ?= 4m

.PHONY: e2e-up
e2e-up: lab-cluster lab-cert-manager lab-tenant-crd lab-tov2 lab-eso lab-reloader lab-vault lab-vco lab-chart-repo ## The lab without the bootstrap chart: what the e2e suite starts from.
	$(MAKE) lab-vault-bootstrap VERIFY_LOGIN=0

.PHONY: e2e-test
e2e-test: helm ## Run tests/e2e against the lab. E2E_KEEP=1 leaves the install in place.
	E2E=1 KUBE_CONTEXT=$(CONTEXT) HELM=$(HELM) KUBECTL=$(KUBECTL) \
		E2E_CHART_REPO_URL=$(CHART_REPO_URL) \
		E2E_TOV2_SA=system:serviceaccount:$(TOV2_NS):$(TOV2_RELEASE) \
		E2E_CONFIG_NAMESPACE=$(CONFIG_NS) E2E_VAULT_NAMESPACE=$(VAULT_NS) \
		E2E_VAULT_SERVER=http://vault.$(VAULT_NS).svc:8200 \
		E2E_WAIT_TIMEOUT=$(E2E_WAIT_TIMEOUT) E2E_VCO_SYNC_PERIOD=$(VCO_SYNC_PERIOD_SECONDS)s \
		go test ./tests/e2e/ -count=1 -v -timeout 60m

.PHONY: e2e-kind
e2e-kind: ## Build the lab and run the suite. Needs VAULT_LICENSE_FILE. Dumps ./e2e-logs on failure.
	$(MAKE) e2e-up && $(MAKE) e2e-test || { $(MAKE) e2e-diagnostics; exit 1; }

.PHONY: e2e-diagnostics
e2e-diagnostics: ## Dump cluster state and controller logs into ./e2e-logs.
	@mkdir -p e2e-logs
	-$(KC) get templateinstances,templates -A -o wide > e2e-logs/templates.txt 2>&1
	-$(KC) -n $(CONFIG_NS) get $(LAB_VCO_KINDS) -o yaml > e2e-logs/vco-crs.yaml 2>&1
	-$(KC) get externalsecrets,secretstores -A -o yaml > e2e-logs/eso.yaml 2>&1
	-$(KC) get pods -A -o wide > e2e-logs/pods.txt 2>&1
	-$(KC) -n $(TOV2_NS) logs deploy/$(TOV2_DEPLOYMENT) --tail=5000 > e2e-logs/tov2.log 2>&1
	-$(KC) -n $(VCO_NS) logs deploy/$(VCO_RELEASE) --tail=5000 > e2e-logs/vco.log 2>&1
	-$(KC) -n external-secrets logs deploy/external-secrets --tail=2000 > e2e-logs/eso.log 2>&1
	-$(KC) -n reloader logs deploy/reloader-reloader --tail=2000 > e2e-logs/reloader.log 2>&1
	-$(KC) -n $(VAULT_NS) logs vault-0 --tail=2000 > e2e-logs/vault.log 2>&1
	@echo "diagnostics in ./e2e-logs"

# ─── Lab ─────────────────────────────────────────────────────────────

.PHONY: lab-up
lab-up: lab-cluster lab-cert-manager lab-tenant-crd lab-tov2 lab-eso lab-reloader lab-vault lab-vco lab-chart-repo lab-bootstrap lab-vault-bootstrap ## Build the whole lab.

.PHONY: lab-down
lab-down: ## Delete the lab cluster.
	$(KIND) delete cluster --name $(CLUSTER_NAME)

.PHONY: lab-cluster
lab-cluster: ## Create the kind cluster (idempotent).
	@if $(KIND) get clusters | grep -qx '$(CLUSTER_NAME)'; then \
		echo "kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		$(KIND) create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
	fi

.PHONY: lab-cert-manager
lab-cert-manager: ## Install cert-manager and wait until its webhook answers.
	$(KC) apply -f $(CERT_MANAGER_URL)
	$(KC) wait deployment.apps/cert-manager-webhook --for=condition=Available -n cert-manager --timeout=300s
	$(call wait-crd,certificates.cert-manager.io issuers.cert-manager.io)
	@# Available=True does not mean the webhook answers. Issuing a throwaway
	@# Issuer is the check; on exhaustion the target fails with the last error.
	@probe='{"apiVersion":"cert-manager.io/v1","kind":"Issuer","metadata":{"name":"cm-readiness-probe","namespace":"cert-manager"},"spec":{"selfSigned":{}}}'; \
	ok=""; for i in $$(seq 1 30); do \
		echo "$$probe" | $(KC) apply -f - >/dev/null 2>&1 && \
		$(KC) delete issuer cm-readiness-probe -n cert-manager >/dev/null 2>&1 && { ok=1; break; }; \
		echo "  cert-manager webhook not ready yet ($$i/30)"; sleep 4; \
	done; \
	if [ -z "$$ok" ]; then \
		echo "error: cert-manager webhook never became ready; the last attempt said:" >&2; \
		echo "$$probe" | $(KC) apply -f - 1>&2 || true; \
		exit 1; \
	fi

.PHONY: lab-tenant-crd
lab-tenant-crd: ## Install MTO's Tenant CRD (only the CRD, not MTO).
	$(KC) apply -f hack/lab/crds/tenantoperator.stakater.com_tenants.yaml
	$(call wait-crd,tenants.tenantoperator.stakater.com)

.PHONY: lab-tov2
lab-tov2: ## Install template-operator-v2 from its public chart.
	$(KC) create namespace $(TOV2_NS) --dry-run=client -o yaml | $(KC) apply -f -
	$(HELM) upgrade --install $(TOV2_RELEASE) $(TOV2_CHART) --version $(TOV2_CHART_VERSION) \
		--kube-context $(CONTEXT) -n $(TOV2_NS) --reset-values
	@# Before the rollout wait: an unscoped sync-enforcement webhook deadlocks
	@# the cluster. The script explains why; on the published chart it only
	@# confirms the scoping.
	KUBECTL=$(KUBECTL) E2E_CONTEXT=$(CONTEXT) \
		WEBHOOK_NAME=$(TOV2_RELEASE)-template-operator-v2-sync-enforcement \
		./hack/lab/scope-tov2-webhook.sh
	$(KC) -n $(TOV2_NS) rollout status deploy/$(TOV2_DEPLOYMENT) --timeout=300s

.PHONY: lab-eso
lab-eso: ## Install External Secrets Operator (the .eso slice's SecretStore/ExternalSecret).
	$(HELM) repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
	$(HELM) upgrade --install external-secrets external-secrets/external-secrets \
		--version $(ESO_CHART_VERSION) \
		--kube-context $(CONTEXT) -n external-secrets --create-namespace --reset-values \
		--wait --timeout 5m
	$(call wait-crd,secretstores.external-secrets.io externalsecrets.external-secrets.io)

.PHONY: lab-reloader
lab-reloader: ## Install Stakater Reloader: restarts a Deployment when a Secret or ConfigMap it uses changes.
	$(HELM) repo add stakater https://stakater.github.io/stakater-charts --force-update >/dev/null
	$(HELM) upgrade --install reloader stakater/reloader \
		--version $(RELOADER_CHART_VERSION) \
		--kube-context $(CONTEXT) -n reloader --create-namespace --reset-values \
		--wait --timeout 5m

.PHONY: lab-vault
lab-vault: ## Install Vault in dev mode. VAULT_EDITION=ent (needs VAULT_LICENSE_FILE) or ce.
	@case "$(VAULT_EDITION)" in \
		ent) if [ -z "$(VAULT_LICENSE_FILE)" ] || [ ! -r "$(VAULT_LICENSE_FILE)" ]; then \
			echo "error: VAULT_EDITION=ent needs VAULT_LICENSE_FILE=<readable .hclic file>; got '$(VAULT_LICENSE_FILE)'." >&2; \
			echo "       Use VAULT_EDITION=ce to run without a licence (no namespaces)." >&2; exit 1; fi ;; \
		ce) echo "note: Vault Community Edition has no namespaces; tenant namespaces cannot be tested." ;; \
		*) echo "error: VAULT_EDITION must be ent or ce, got '$(VAULT_EDITION)'" >&2; exit 1 ;; \
	esac
	$(KC) create namespace $(VAULT_NS) --dry-run=client -o yaml | $(KC) apply -f -
	$(HELM) repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null
ifeq ($(VAULT_EDITION),ent)
	@# The licence goes straight from the file into a Secret; it is never echoed.
	$(KC) -n $(VAULT_NS) create secret generic vault-ent-license \
		--from-file=license=$(VAULT_LICENSE_FILE) --dry-run=client -o yaml | $(KC) apply -f - >/dev/null
	$(HELM) upgrade --install vault hashicorp/vault --version $(VAULT_CHART_VERSION) \
		--kube-context $(CONTEXT) -n $(VAULT_NS) -f hack/lab/vault-values.yaml \
		--set server.image.repository=hashicorp/vault-enterprise \
		--set server.image.tag=$(VAULT_VERSION)-ent \
		--set server.enterpriseLicense.secretName=vault-ent-license
else
	$(HELM) upgrade --install vault hashicorp/vault --version $(VAULT_CHART_VERSION) \
		--kube-context $(CONTEXT) -n $(VAULT_NS) -f hack/lab/vault-values.yaml \
		--set server.image.repository=hashicorp/vault \
		--set server.image.tag=$(VAULT_VERSION)
endif
	@# The chart's StatefulSet uses OnDelete, so an upgrade (image, licence) only
	@# reaches the pod when the pod is deleted. Dev mode is in-memory anyway.
	$(KC) -n $(VAULT_NS) delete pod vault-0 --ignore-not-found --wait=true
	$(KC) -n $(VAULT_NS) wait --for=condition=Ready pod/vault-0 --timeout=300s

.PHONY: lab-vault-bootstrap
lab-vault-bootstrap: ## Give VCO a kubernetes-auth login in Vault's root namespace, and prove it.
	CONTEXT=$(CONTEXT) KUBECTL=$(KUBECTL) VAULT_NS=$(VAULT_NS) \
		CONFIG_NS=$(CONFIG_NS) SA=$(CONFIG_SA) ROLE=$(CONFIG_SA) VERIFY_LOGIN=$(VERIFY_LOGIN) \
		./hack/lab/vault-bootstrap.sh

# VCO's chart target uses GNU sed and `basename -z`. The shim puts gsed first
# on PATH as `sed`, and OPERATOR_NAME is passed so `basename -z` never runs.
$(LOCALBIN)/gnu/sed:
	mkdir -p $(LOCALBIN)/gnu
	@# Linux sed is GNU sed already; macOS needs gsed (brew install gnu-sed).
	@if sed --version 2>/dev/null | grep -q GNU; then ln -sf "$$(command -v sed)" $(LOCALBIN)/gnu/sed; \
	elif command -v gsed >/dev/null; then ln -sf "$$(command -v gsed)" $(LOCALBIN)/gnu/sed; \
	else echo "error: GNU sed is required: brew install gnu-sed" >&2; exit 1; fi

.PHONY: lab-vco-build
lab-vco-build: $(LOCALBIN)/gnu/sed ## Build VCO's image and chart from VCO_SRC and load the image into kind.
	@test -f $(VCO_SRC)/go.mod || { echo "error: VCO_SRC=$(VCO_SRC) is not a vault-config-operator checkout" >&2; exit 1; }
	$(CONTAINER_TOOL) build -t $(VCO_IMG_REPO):$(VCO_IMG_TAG) $(VCO_SRC)
	@# Not `kind load docker-image`: older kind fails on Docker Desktop's
	@# containerd image store ("failed to detect containerd snapshotter").
	@# Importing into the node's containerd works with any kind version.
	$(CONTAINER_TOOL) save $(VCO_IMG_REPO):$(VCO_IMG_TAG) | \
		$(CONTAINER_TOOL) exec -i $(CLUSTER_NAME)-control-plane ctr --namespace=k8s.io images import --digests -
	PATH="$(LOCALBIN)/gnu:$$PATH" $(MAKE) -C $(VCO_SRC) helmchart \
		OPERATOR_NAME=vault-config-operator IMG=$(VCO_IMG_REPO):$(VCO_IMG_TAG) VERSION=0.0.0-lab

.PHONY: lab-vco
lab-vco: lab-vco-build ## (Re)deploy VCO from VCO_SRC, pointed at the lab Vault.
	@# helm installs crds/ only on the first install and never upgrades them, so
	@# the CRDs are applied explicitly: a field added in VCO_SRC must reach the
	@# cluster, or the apiserver prunes it from every CR.
	$(KC) apply --server-side --force-conflicts -f $(VCO_CHART)/crds/
	$(HELM) upgrade --install $(VCO_RELEASE) $(VCO_CHART) \
		--kube-context $(CONTEXT) -n $(VCO_NS) --create-namespace --skip-crds \
		--set enableCertManager=true \
		--set enableMonitoring=false \
		--set image.repository=$(VCO_IMG_REPO) \
		--set image.tag=$(VCO_IMG_TAG) \
		--set env[0].name=VAULT_ADDR --set env[0].value=http://vault.$(VAULT_NS).svc:8200 \
		--set env[1].name=ENABLE_DRIFT_DETECTION --set-string env[1].value=true \
		--set env[2].name=SYNC_PERIOD_SECONDS --set-string env[2].value=$(VCO_SYNC_PERIOD_SECONDS)
	@# enableMonitoring=false: the chart otherwise renders a ServiceMonitor, and
	@# kind has no Prometheus CRDs (upstream issue #221).
	@# Same tag, new image: restart so the pod picks up the build just loaded.
	$(KC) -n $(VCO_NS) rollout restart deploy/$(VCO_RELEASE)
	$(KC) -n $(VCO_NS) rollout status deploy/$(VCO_RELEASE) --timeout=300s

CHART_REPO_URL ?= http://chart-repo.chart-repo.svc.cluster.local

.PHONY: lab-chart-repo
lab-chart-repo: ## Serve THIS checkout's tenant chart from an in-cluster HTTP repo for t-op-v2 to pull.
	$(KC) apply -f hack/lab/chart-repo.yaml
	KUBECTL=$(KUBECTL) HELM=$(HELM) E2E_CONTEXT=$(CONTEXT) CHART_DIR=charts/mto-extension-vault-enterprise \
		./hack/lab/chart-repo-publish.sh

.PHONY: lab-bootstrap
lab-bootstrap: ## Install the bootstrap chart from this checkout, pulling the tenant chart from the lab repo.
	@# ESO is not on the lab cluster, so parent.eso=disabled: an enabled eso slice
	@# would fail every tenant's .eso TemplateInstance on the missing CRDs.
	$(HELM) upgrade --install mto-extension-vault-enterprise-bootstrap charts/mto-extension-vault-enterprise-bootstrap \
		--kube-context $(CONTEXT) -n $(CONFIG_NS) --create-namespace \
		--set configNamespace=$(CONFIG_NS) \
		--set vco.serviceAccount=$(CONFIG_SA) --set vco.role=$(CONFIG_SA) \
		--set templateOperator.serviceAccountName=$(TOV2_RELEASE) \
		--set templateOperator.namespace=$(TOV2_NS) \
		--set tenantChart.registry=$(CHART_REPO_URL) \
		--set parent.vaultServer=http://vault.$(VAULT_NS).svc:8200 \
		--set parent.eso=disabled

.PHONY: lab-uninstall
lab-uninstall: ## Uninstall the bootstrap chart in the documented order (charts/README.md → Uninstall).
	$(KC) -n $(CONFIG_NS) delete templateinstance mto-extension-vault-enterprise-parent --ignore-not-found --wait --timeout=5m
	@# The RBAC and the VCO login ServiceAccount must outlive every CR they
	@# tear down, so the release goes only once no VCO CR is left.
	@left=""; for i in $$(seq 1 60); do \
		left=$$($(KC) -n $(CONFIG_NS) get $(LAB_VCO_KINDS) --no-headers 2>/dev/null | wc -l | tr -d ' '); \
		[ "$$left" = 0 ] && break; sleep 5; \
	done; \
	if [ "$$left" != 0 ]; then echo "error: $$left VCO CRs still in $(CONFIG_NS) after 5m — not uninstalling the release:" >&2; \
		$(KC) -n $(CONFIG_NS) get $(LAB_VCO_KINDS) >&2; exit 1; fi
	$(HELM) uninstall mto-extension-vault-enterprise-bootstrap --kube-context $(CONTEXT) -n $(CONFIG_NS) --wait

LAB_VCO_KINDS := namespaces.redhatcop.redhat.io,secretenginemounts.redhatcop.redhat.io,authenginemounts.redhatcop.redhat.io,kubernetesauthengineconfigs.redhatcop.redhat.io,kubernetesauthengineroles.redhatcop.redhat.io,policies.redhatcop.redhat.io,jwtoidcauthengineconfigs.redhatcop.redhat.io,jwtoidcauthengineroles.redhatcop.redhat.io

.PHONY: lab-render
lab-render: ## Apply the sample Tenants, their labelled namespaces and annotated ServiceAccounts.
	$(KC) apply -f hack/lab/sample-tenants.yaml
