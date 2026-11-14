# The installation: your GitHub org, its instances repository and the
# portal's OAuth App. Written by `make setup` (git-ignored, never committed).
-include .idpk.env
IDPK_INSTANCES_REPO ?= instances
export IDPK_GITHUB_ORG IDPK_INSTANCES_REPO AUTH_GITHUB_CLIENT_ID AUTH_GITHUB_CLIENT_SECRET
# The portal image (ghcr.io/idplatformkit/portal), built by idPlatformKit/portal.
PORTAL_IMAGE_TAG ?= main

CLUSTER_NAME ?= idplatformkit-local
CROSSPLANE_NAMESPACE ?= crossplane-system
CROSSPLANE_VERSION ?= 2.4.0
# Chart versions: keep in sync with bootstrap/apps/values.yaml so the local
# and GitOps flows install the same thing.
POSTGRES_CHART_VERSION ?= 18.12.15
OPENBAO_CHART_VERSION ?= 0.30.4
ESO_CHART_VERSION ?= 2.14.0
CERT_MANAGER_CHART_VERSION ?= v1.21.3
ENVOY_GATEWAY_CHART_VERSION ?= v1.9.3

# Local CA signing the platform's HTTPS certificates. Generated once, kept
# outside the cluster so it survives `make local-down` (see local-ca below).
LOCAL_CA_DIR ?= .local-ca
LOCAL_CA_SECRET ?= idplatformkit-local-ca
PLATFORM_DOMAIN ?= 127.0.0.1.nip.io

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

.PHONY: setup up down status require-config portal-secret portal-install \
	kind-up kind-down crossplane-install crossplane-uninstall \
	providers-apply openbao-providerconfig-apply \
	postgres-server-install postgres-server-uninstall \
	openbao-server-install openbao-server-uninstall \
	compositions-apply compositions-delete \
	try-postgres-database try-tenant local-up local-down \
	postgres-bootstrap-secrets openbao-bootstrap-secrets bootstrap-secrets \
	argocd-install gitops-root-apply gitops-wait local-up-gitops \
	backstage-reader-apply backstage-token \
	external-secrets-install external-secrets-uninstall \
	local-ca local-ca-secret local-ca-trust local-ca-untrust \
	cert-manager-install envoy-gateway-install gateway-apply try-gateway

# --- Guided install (see docs/install.md) ---

# Asks for your GitHub org, creates your instances repository from
# idPlatformKit/instances-template and walks you through the portal's OAuth
# App. Writes .idpk.env. Safe to re-run: it offers to keep what's there.
setup:
	@./scripts/setup.sh

# The whole platform on a new kind cluster, from your configuration: Argo CD
# installs everything from Git, then syncs your instances repository.
up: require-config local-up-gitops status

down: local-down

# Where everything is, and what's left to do.
status:
	@./scripts/status.sh

require-config:
	@if [ -z "$(IDPK_GITHUB_ORG)" ]; then \
		echo "No installation configured yet. Run 'make setup' first: it asks for your"; \
		echo "GitHub org and writes .idpk.env."; \
		exit 1; \
	fi

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
		-f providers/function-sequencer.yaml \
		-f providers/tenant-native-resources-rbac.yaml
	kubectl wait --for=condition=Healthy --timeout=180s \
		provider.pkg.crossplane.io/provider-sql \
		provider.pkg.crossplane.io/provider-vault
	kubectl wait --for=condition=Healthy --timeout=180s \
		function.pkg.crossplane.io/function-patch-and-transform \
		function.pkg.crossplane.io/function-auto-ready \
		function.pkg.crossplane.io/function-cel-filter \
		function.pkg.crossplane.io/function-sequencer
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

# External Secrets Operator: pulls each tenant's OpenBao secrets into
# Kubernetes Secrets through the SecretStore its Tenant composes.
external-secrets-install:
	helm repo add external-secrets https://charts.external-secrets.io --force-update
	helm repo update external-secrets
	helm upgrade --install external-secrets external-secrets/external-secrets \
		--namespace external-secrets \
		--create-namespace \
		--version $(ESO_CHART_VERSION) \
		--values platform/external-secrets/values.yaml \
		--wait

external-secrets-uninstall:
	helm uninstall external-secrets --namespace external-secrets

# --- HTTPS entry point (see docs/gateway.md) ---

# A root CA for the local platform, generated once on the host and reused by
# every cluster you create (.local-ca/, git-ignored). Delete the directory to
# rotate it, then trust the new one again.
local-ca:
	@if [ -f $(LOCAL_CA_DIR)/ca.crt ]; then \
		echo "Reusing the local CA in $(LOCAL_CA_DIR)/"; \
	else \
		mkdir -p $(LOCAL_CA_DIR) && \
		openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
			-subj "/O=IdPlatformKit/CN=IdPlatformKit local CA" \
			-addext "basicConstraints=critical,CA:TRUE" \
			-addext "keyUsage=critical,keyCertSign,cRLSign" \
			-keyout $(LOCAL_CA_DIR)/ca.key -out $(LOCAL_CA_DIR)/ca.crt && \
		chmod 600 $(LOCAL_CA_DIR)/ca.key && \
		echo "Generated a new local CA in $(LOCAL_CA_DIR)/. Trust it once with: make local-ca-trust"; \
	fi

# The CA key pair cert-manager's ClusterIssuer signs with
# (platform/gateway/cluster-issuer.yaml). A bootstrap Secret, like the
# Postgres and OpenBao ones: never in Git.
local-ca-secret: local-ca
	kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret tls $(LOCAL_CA_SECRET) \
		--namespace cert-manager \
		--cert=$(LOCAL_CA_DIR)/ca.crt --key=$(LOCAL_CA_DIR)/ca.key \
		--dry-run=client -o yaml | kubectl apply -f -

# Adds the local CA to the host's trust store (asks for sudo). Once per CA,
# not per cluster. Firefox keeps its own store: import ca.crt there by hand.
local-ca-trust: local-ca
	@case "$$(uname -s)" in \
		Darwin) sudo security add-trusted-cert -d -r trustRoot \
			-k /Library/Keychains/System.keychain $(LOCAL_CA_DIR)/ca.crt ;; \
		Linux) sudo cp $(LOCAL_CA_DIR)/ca.crt /usr/local/share/ca-certificates/idplatformkit-local-ca.crt && \
			sudo update-ca-certificates ;; \
		*) echo "Unsupported OS: trust $(LOCAL_CA_DIR)/ca.crt by hand" && exit 1 ;; \
	esac

local-ca-untrust:
	@case "$$(uname -s)" in \
		Darwin) sudo security remove-trusted-cert -d $(LOCAL_CA_DIR)/ca.crt && \
			sudo security delete-certificate -c "IdPlatformKit local CA" /Library/Keychains/System.keychain ;; \
		Linux) sudo rm -f /usr/local/share/ca-certificates/idplatformkit-local-ca.crt && \
			sudo update-ca-certificates --fresh ;; \
		*) echo "Unsupported OS" && exit 1 ;; \
	esac

cert-manager-install: local-ca-secret
	helm repo add jetstack https://charts.jetstack.io --force-update
	helm repo update jetstack
	helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager \
		--create-namespace \
		--version $(CERT_MANAGER_CHART_VERSION) \
		--values platform/cert-manager/values.yaml \
		--wait

envoy-gateway-install:
	helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
		--namespace envoy-gateway-system \
		--create-namespace \
		--version $(ENVOY_GATEWAY_CHART_VERSION) \
		--values platform/envoy-gateway/values.yaml \
		--wait

# Retried: cert-manager's webhook can refuse requests for a few seconds after
# its Deployment reports Ready.
gateway-apply:
	@for i in 1 2 3 4 5 6; do \
		kubectl apply -k platform/gateway/ && break; \
		[ $$i -eq 6 ] && exit 1; echo "Retrying in 10s..."; sleep 10; \
	done
	kubectl wait --for=condition=Ready --timeout=120s \
		certificate/platform-tls -n platform-gateway
	kubectl wait --for=condition=Programmed --timeout=180s \
		gateway/platform -n platform-gateway

# Checks the platform hostnames from the host, verifying the certificate
# against the local CA only (not the system trust store).
try-gateway:
	@echo "http://openbao.$(PLATFORM_DOMAIN) -> $$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://openbao.$(PLATFORM_DOMAIN)/)"
	curl -fsS --cacert $(LOCAL_CA_DIR)/ca.crt https://openbao.$(PLATFORM_DOMAIN)/v1/sys/health; echo
	@if kubectl get namespace $(ARGOCD_NAMESPACE) >/dev/null 2>&1; then \
		echo "https://argocd.$(PLATFORM_DOMAIN) -> $$(curl -fsS --cacert $(LOCAL_CA_DIR)/ca.crt -o /dev/null -w '%{http_code}' https://argocd.$(PLATFORM_DOMAIN)/)"; \
	fi
	@if kubectl get deployment portal -n backstage-system >/dev/null 2>&1; then \
		r=$$(curl -fsS --cacert $(LOCAL_CA_DIR)/ca.crt https://portal.$(PLATFORM_DOMAIN)/.backstage/health/v1/readiness) || exit 1; \
		echo "https://portal.$(PLATFORM_DOMAIN) readiness -> $$r"; \
	fi
	@echo "Certificate served:"; \
	openssl s_client -connect 127.0.0.1:443 -servername openbao.$(PLATFORM_DOMAIN) </dev/null 2>/dev/null | \
		openssl x509 -noout -subject -issuer -ext subjectAltName

# --- Portal (see platform/portal/) ---

# The portal's credentials: the GitHub token its catalog reads the org with
# (GITHUB_TOKEN, or your gh CLI token), and the OAuth App from .idpk.env.
# A bootstrap Secret like the others: never in Git. Not echoed.
portal-secret: require-config
	@kubectl create namespace backstage-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@token="$${GITHUB_TOKEN:-$$(gh auth token 2>/dev/null)}"; \
	if [ -z "$$token" ]; then \
		echo "No GitHub token for the portal: run 'gh auth login', or set GITHUB_TOKEN."; exit 1; \
	fi; \
	kubectl create secret generic portal-secrets --namespace backstage-system \
		--from-literal=GITHUB_TOKEN="$$token" \
		--from-literal=AUTH_GITHUB_CLIENT_ID="$$AUTH_GITHUB_CLIENT_ID" \
		--from-literal=AUTH_GITHUB_CLIENT_SECRET="$$AUTH_GITHUB_CLIENT_SECRET" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null && \
	echo "secret/portal-secrets configured"

# Local flow only: the GitOps flow installs the same chart with Argo CD.
portal-install: portal-secret backstage-reader-apply
	helm upgrade --install portal platform/portal \
		--namespace backstage-system \
		--set github.org=$(IDPK_GITHUB_ORG) \
		--set github.instancesRepo=$(IDPK_INSTANCES_REPO) \
		--set image.tag=$(PORTAL_IMAGE_TAG) \
		--wait --timeout 5m

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
	kubectl get serviceaccount demo-app -n demo-team
	kubectl get secretstore openbao -n demo-team
	@# Write a secret into the tenant's own OpenBao namespace (dev root token),
	@# then let External Secrets Operator deliver it as a Kubernetes Secret.
	kubectl exec -n $(OPENBAO_NAMESPACE) $(OPENBAO_RELEASE)-0 -- \
		env BAO_TOKEN=$(OPENBAO_DEV_ROOT_TOKEN) BAO_NAMESPACE=demo-team \
		bao kv put secret/db-credentials password=from-openbao-demo-team
	kubectl apply -f examples/tenant-external-secret.yaml
	kubectl wait --for=condition=Ready --timeout=60s -f examples/tenant-external-secret.yaml
	@echo "db-credentials/password in Kubernetes: $$(kubectl get secret db-credentials -n demo-team -o jsonpath='{.data.password}' | base64 -d)"

# Read-only ServiceAccount for the portal's Kubernetes plugin
# (platform/backstage-reader/). The GitOps flow installs it with Argo CD.
backstage-reader-apply:
	kubectl apply -k platform/backstage-reader/

# Prints what the portal needs to reach this cluster, as environment
# variables for its app-config (see idPlatformKit/portal README):
#   eval "$$(make -s backstage-token)"
backstage-token:
	@echo "export K8S_CLUSTER_URL=$$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
	@echo "export K8S_CLUSTER_TOKEN=$$(kubectl get secret backstage-reader-token -n backstage-system -o jsonpath='{.data.token}' | base64 -d)"

local-up: kind-up crossplane-install providers-apply postgres-server-install openbao-server-install openbao-providerconfig-apply external-secrets-install cert-manager-install envoy-gateway-install gateway-apply compositions-apply backstage-reader-apply
	@echo "Local cluster '$(CLUSTER_NAME)' is ready: Crossplane, provider-sql, provider-vault, the shared Postgres server, and the shared OpenBao server are installed, compositions applied, HTTPS on https://<name>.$(PLATFORM_DOMAIN)."

# --- GitOps flow (see docs/gitops.md) ---
# Same end state as local-up, but only Argo CD and the bootstrap Secrets are
# installed by hand; Argo CD installs everything else from this repo.

bootstrap-secrets: postgres-bootstrap-secrets openbao-bootstrap-secrets local-ca-secret portal-secret

# --timeout 10m: helm's default 5m was hit in CI while the kind node was
# still pulling Argo CD's images. The redis ImagePullBackOff seen there turned
# out to be ECR Public rate limiting (429), fixed in bootstrap/argocd/values.yaml;
# the longer timeout covers genuinely slow pulls from shared CI runners.
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
gitops-root-apply: require-config
	sed -e 's|https://github.com/idPlatformKit/Orchestrator.git|$(GITOPS_REPO_URL)|' \
		-e 's|targetRevision: main|targetRevision: $(GITOPS_REVISION)|' \
		-e 's|__IDPK_GITHUB_ORG__|$(IDPK_GITHUB_ORG)|' \
		-e 's|__IDPK_INSTANCES_REPO__|$(IDPK_INSTANCES_REPO)|' \
		-e 's|__PORTAL_IMAGE_TAG__|$(PORTAL_IMAGE_TAG)|' \
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

local-up-gitops: require-config kind-up argocd-install bootstrap-secrets gitops-root-apply gitops-wait
	@echo "Local cluster '$(CLUSTER_NAME)' is ready, bootstrapped by Argo CD from $(GITOPS_REPO_URL)@$(GITOPS_REVISION)."

local-down: kind-down
	@echo "Local cluster '$(CLUSTER_NAME)' deleted."
