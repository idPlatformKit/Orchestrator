CLUSTER_NAME ?= idplatformkit-local
CROSSPLANE_NAMESPACE ?= crossplane-system
CROSSPLANE_VERSION ?= 2.4.0

POSTGRES_NAMESPACE ?= postgres-system
POSTGRES_RELEASE ?= postgres-server
POSTGRES_ADMIN_PASSWORD ?= postgres-local-dev

.PHONY: kind-up kind-down crossplane-install crossplane-uninstall \
	providers-apply postgres-server-install postgres-server-uninstall \
	compositions-apply compositions-delete \
	try-postgres-database local-up local-down

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

# Applied as plain files (not `kubectl apply -k providers/`) because the
# ClusterProviderConfig's CRD is only registered once provider-sql reports
# Healthy, so the Provider/Functions must land and be waited on first.
providers-apply:
	kubectl apply -f providers/provider-sql.yaml -f providers/function-patch-and-transform.yaml -f providers/function-auto-ready.yaml
	kubectl wait --for=condition=Healthy --timeout=180s provider.pkg.crossplane.io/provider-sql
	kubectl wait --for=condition=Healthy --timeout=180s \
		function.pkg.crossplane.io/function-patch-and-transform \
		function.pkg.crossplane.io/function-auto-ready
	kubectl apply -f providers/postgres-providerconfig.yaml

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

compositions-apply:
	kubectl apply -k compositions/

compositions-delete:
	kubectl delete -k compositions/ --ignore-not-found

try-postgres-database:
	kubectl apply -f examples/postgres-database.yaml
	kubectl wait --for=condition=Ready --timeout=180s -f examples/postgres-database.yaml
	kubectl get secret demo-app-db-conn -n default -o yaml

local-up: kind-up crossplane-install providers-apply postgres-server-install compositions-apply
	@echo "Local cluster '$(CLUSTER_NAME)' is ready: Crossplane, provider-sql, and the shared Postgres server are installed, compositions applied."

local-down: kind-down
	@echo "Local cluster '$(CLUSTER_NAME)' deleted."
