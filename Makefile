CLUSTER_NAME ?= idplatformkit-local
CROSSPLANE_NAMESPACE ?= crossplane-system
CROSSPLANE_VERSION ?= 2.4.0

POSTGRES_NAMESPACE ?= postgres-system
POSTGRES_RELEASE ?= postgres-server
POSTGRES_ADMIN_PASSWORD ?= postgres-local-dev

OPENBAO_NAMESPACE ?= openbao-system
OPENBAO_RELEASE ?= openbao
OPENBAO_DEV_ROOT_TOKEN ?= root-local-dev

.PHONY: kind-up kind-down crossplane-install crossplane-uninstall \
	providers-apply openbao-providerconfig-apply \
	postgres-server-install postgres-server-uninstall \
	openbao-server-install openbao-server-uninstall \
	compositions-apply compositions-delete \
	try-postgres-database try-tenant local-up local-down

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
postgres-server-install:
	kubectl create namespace $(POSTGRES_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
	helm repo update bitnami
	helm upgrade --install $(POSTGRES_RELEASE) bitnami/postgresql \
		--namespace $(POSTGRES_NAMESPACE) \
		--values platform/postgres-server/values.yaml \
		--set auth.postgresPassword=$(POSTGRES_ADMIN_PASSWORD) \
		--wait
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
openbao-server-install:
	kubectl create namespace $(OPENBAO_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm repo add openbao https://openbao.github.io/openbao-helm --force-update
	helm repo update openbao
	helm upgrade --install $(OPENBAO_RELEASE) openbao/openbao \
		--namespace $(OPENBAO_NAMESPACE) \
		--values platform/openbao-server/values.yaml \
		--set server.dev.devRootToken=$(OPENBAO_DEV_ROOT_TOKEN) \
		--wait
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

local-down: kind-down
	@echo "Local cluster '$(CLUSTER_NAME)' deleted."
