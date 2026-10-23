CLUSTER_NAME ?= idplatformkit-local
CROSSPLANE_NAMESPACE ?= crossplane-system
CROSSPLANE_VERSION ?= 2.4.0
# Chart versions: keep in sync with bootstrap/apps/values.yaml so the local
# and GitOps flows install the same thing.
POSTGRES_CHART_VERSION ?= 18.12.15
OPENBAO_CHART_VERSION ?= 0.30.4

POSTGRES_NAMESPACE ?= postgres-system
POSTGRES_RELEASE ?= postgres-server
POSTGRES_ADMIN_PASSWORD ?= postgres-local-dev

OPENBAO_NAMESPACE ?= openbao-system
OPENBAO_RELEASE ?= openbao
OPENBAO_DEV_ROOT_TOKEN ?= root-local-dev

ARGOCD_NAMESPACE ?= argocd
ARGOCD_CHART_VERSION ?= 10.11.1
GITOPS_REPO_URL ?= https://github.com/idPlatformKit/Orchestrator.git
GITOPS_REVISION ?= main

.PHONY: kind-up kind-down crossplane-install crossplane-uninstall \
	providers-apply openbao-providerconfig-apply \
	postgres-server-install postgres-server-uninstall \
	openbao-server-install openbao-server-uninstall \
	compositions-apply compositions-delete \
	try-postgres-database try-tenant local-up local-down \
	postgres-bootstrap-secrets openbao-bootstrap-secrets bootstrap-secrets \
	argocd-install gitops-root-apply gitops-wait local-up-gitops

kind-up:
	kind create cluster --name $(CLUSTER_NAME) --config local/kind-config.yaml

kind-down:
	kind delete cluster --name $(CLUSTER_NAME)

crossplane-install:
	helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update
	helm repo update crossplane-stable
	helm upgrade --install crossplane crossplane-stable/crossplane \
		--namespace $(CROSSPLANE_NAMESPACE) \
		--create-namespace \
		--version $(CROSSPLANE_VERSION) \
		--wait

crossplane-uninstall:
	helm uninstall crossplane --namespace $(CROSSPLANE_NAMESPACE)

# Providers, Functions and the tenant RBAC grant only -- applied as plain
# files (not `kubectl apply -k providers/`) because the Postgres/Vault
# ClusterProviderConfigs' CRDs only exist once their Providers report
# Healthy, and the Vault one also needs openbao-server-install to have run
# first (see openbao-providerconfig-apply below).
providers-apply:
	kubectl apply \
		-f providers/provider-sql.yaml \
		-f providers/provider-vault.yaml \
		-f providers/function-patch-and-transform.yaml \
		-f providers/function-auto-ready.yaml \
		-f providers/function-cel-filter.yaml \
		-f providers/tenant-native-resources-rbac.yaml
	kubectl wait --for=condition=Healthy --timeout=180s \
		provider.pkg.crossplane.io/provider-sql \
		provider.pkg.crossplane.io/provider-vault
	kubectl wait --for=condition=Healthy --timeout=180s \
		function.pkg.crossplane.io/function-patch-and-transform \
		function.pkg.crossplane.io/function-auto-ready \
		function.pkg.crossplane.io/function-cel-filter
	kubectl apply -f providers/postgres-providerconfig.yaml

# The Vault ClusterProviderConfig needs the openbao-creds Secret and a
# reachable OpenBao server, so it can only run after openbao-server-install
# (not part of providers-apply). It has no Healthy/Ready condition to wait
# on -- connectivity/credential errors only surface on resources that use it
# (e.g. a Tenant's VaultNamespace), so this just applies it.
openbao-providerconfig-apply:
	kubectl apply -f providers/openbao-providerconfig.yaml

# Shared, local-dev-only Postgres server that provider-sql manages logical
# databases/roles against (see platform/postgres-server/values.yaml).
postgres-server-install: postgres-bootstrap-secrets
	helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
	helm repo update bitnami
	helm upgrade --install $(POSTGRES_RELEASE) bitnami/postgresql \
		--namespace $(POSTGRES_NAMESPACE) \
		--version $(POSTGRES_CHART_VERSION) \
		--values platform/postgres-server/values.yaml \
		--wait

# Dev-default credentials, created imperatively so they never sit in Git:
# the admin password the chart reads (auth.existingSecret), and the
# connection Secret provider-sql's ClusterProviderConfig reads. Shared by
# the local and GitOps flows.
postgres-bootstrap-secrets:
	kubectl create namespace $(POSTGRES_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic postgres-server-auth \
		--namespace $(POSTGRES_NAMESPACE) \
		--from-literal=postgres-password=$(POSTGRES_ADMIN_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic postgres-admin-conn \
		--namespace $(POSTGRES_NAMESPACE) \
		--from-literal=endpoint=$(POSTGRES_RELEASE)-postgresql.$(POSTGRES_NAMESPACE).svc.cluster.local \
		--from-literal=port=5432 \
		--from-literal=username=postgres \
		--from-literal=password=$(POSTGRES_ADMIN_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -

postgres-server-uninstall:
	helm uninstall $(POSTGRES_RELEASE) --namespace $(POSTGRES_NAMESPACE)

# Shared, local-dev-only OpenBao server (dev mode: in-memory, auto-unsealed,
# fixed root token -- see platform/openbao-server/values.yaml) that
# provider-vault manages per-tenant Namespaces/Mounts/Policies against.
openbao-server-install: openbao-bootstrap-secrets
	helm repo add openbao https://openbao.github.io/openbao-helm --force-update
	helm repo update openbao
	helm upgrade --install $(OPENBAO_RELEASE) openbao/openbao \
		--namespace $(OPENBAO_NAMESPACE) \
		--version $(OPENBAO_CHART_VERSION) \
		--values platform/openbao-server/values.yaml \
		--set server.dev.devRootToken=$(OPENBAO_DEV_ROOT_TOKEN) \
		--wait

# The token provider-vault's ClusterProviderConfig authenticates with. In
# dev mode it is the fixed root token set in platform/openbao-server/values.yaml.
openbao-bootstrap-secrets:
	kubectl create namespace $(OPENBAO_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic openbao-creds \
		--namespace $(OPENBAO_NAMESPACE) \
		--from-literal=credentials='{"token_name":"orchestrator-local","token":"$(OPENBAO_DEV_ROOT_TOKEN)"}' \
		--dry-run=client -o yaml | kubectl apply -f -

openbao-server-uninstall:
	helm uninstall $(OPENBAO_RELEASE) --namespace $(OPENBAO_NAMESPACE)

compositions-apply:
	kubectl apply -k compositions/

compositions-delete:
	kubectl delete -k compositions/ --ignore-not-found

try-postgres-database:
	kubectl apply -f examples/postgres-database.yaml
	kubectl wait --for=condition=Ready --timeout=180s -f examples/postgres-database.yaml
	kubectl get secret demo-app-db-conn -n default -o yaml

try-tenant:
	kubectl apply -f examples/tenant.yaml
	kubectl wait --for=condition=Ready --timeout=180s -f examples/tenant.yaml
	kubectl get namespace demo-team
	kubectl get resourcequota,limitrange,rolebinding,networkpolicy -n demo-team
	kubectl get vaultnamespace.vault.vault.m.upbound.io,mount.vault.vault.m.upbound.io,policy.vault.vault.m.upbound.io -n demo-team

local-up: kind-up crossplane-install providers-apply postgres-server-install openbao-server-install openbao-providerconfig-apply compositions-apply
	@echo "Local cluster '$(CLUSTER_NAME)' is ready: Crossplane, provider-sql, provider-vault, the shared Postgres server, and the shared OpenBao server are installed, compositions applied."

# --- GitOps flow (see docs/gitops.md) ---
# Same end state as local-up, but only Argo CD and the bootstrap Secrets are
# installed by hand; Argo CD installs everything else from this repo.

bootstrap-secrets: postgres-bootstrap-secrets openbao-bootstrap-secrets

# --timeout 10m: helm's default 5m was hit twice in CI (PR #10) while the
# kind node was still pulling Argo CD's images (redis ImagePullBackOff, then
# argocd-redis-secret-init stuck in ContainerCreating). Same chart and images
# pulled in seconds locally and in earlier CI runs: slow registries, not a bug.
argocd-install:
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm repo update argo
	helm upgrade --install argocd argo/argo-cd \
		--namespace $(ARGOCD_NAMESPACE) \
		--create-namespace \
		--version $(ARGOCD_CHART_VERSION) \
		--values bootstrap/argocd/values.yaml \
		--wait --timeout 10m

# GITOPS_REPO_URL/GITOPS_REVISION let you point Argo CD at a fork or a
# branch, e.g. `make local-up-gitops GITOPS_REVISION=my-branch`.
gitops-root-apply:
	sed -e 's|https://github.com/idPlatformKit/Orchestrator.git|$(GITOPS_REPO_URL)|' \
		-e 's|targetRevision: main|targetRevision: $(GITOPS_REVISION)|' \
		bootstrap/root-app.yaml | kubectl apply -f -

# Waits on the root app only: with the Application health check restored in
# bootstrap/argocd/values.yaml, it is Healthy once every child app is.
# Sync first: right after creation the root app has no resources yet and
# reports Healthy before it has synced anything.
gitops-wait:
	kubectl wait application/platform -n $(ARGOCD_NAMESPACE) \
		--for=jsonpath='{.status.sync.status}'=Synced --timeout=900s
	kubectl wait application/platform -n $(ARGOCD_NAMESPACE) \
		--for=jsonpath='{.status.health.status}'=Healthy --timeout=600s
	kubectl wait applications --all -n $(ARGOCD_NAMESPACE) \
		--for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
	kubectl get applications -n $(ARGOCD_NAMESPACE)

local-up-gitops: kind-up argocd-install bootstrap-secrets gitops-root-apply gitops-wait
	@echo "Local cluster '$(CLUSTER_NAME)' is ready, bootstrapped by Argo CD from $(GITOPS_REPO_URL)@$(GITOPS_REVISION)."

local-down: kind-down
	@echo "Local cluster '$(CLUSTER_NAME)' deleted."
