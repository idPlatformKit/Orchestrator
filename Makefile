# The installation: your GitHub org, its instances repository and the
# portal's OAuth App. Written by `make setup` (git-ignored, never committed).
-include .idpk.env
IDPK_INSTANCES_REPO ?= instances
export IDPK_GITHUB_ORG IDPK_INSTANCES_REPO AUTH_GITHUB_CLIENT_ID AUTH_GITHUB_CLIENT_SECRET \
	DEX_GITHUB_CLIENT_ID DEX_GITHUB_CLIENT_SECRET
# The portal image (ghcr.io/idplatformkit/portal), built by idPlatformKit/portal.
# Pinned like the charts: keep in sync with bootstrap/apps/values.yaml.
PORTAL_IMAGE_TAG ?= sha-c0f4d73

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
DEX_CHART_VERSION ?= 0.26.0

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
	dex-secret dex-install kubeconfig-sso agent-kubeconfig break-glass break-glass-log \
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
	cert-manager-install envoy-gateway-install gateway-apply try-gateway try-ci-identity

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

# The cluster, then CoreDNS answering every *.127.0.0.1.nip.io name with the
# platform Gateway's ClusterIP (local/coredns.yaml), so pods reach the
# platform's HTTPS hostnames the way the browser does.
kind-up: local-ca
	scripts/render.sh local/authentication-config.yaml .idpk/apiserver/authentication-config.yaml
	cp local/audit-policy.yaml .idpk/apiserver/audit-policy.yaml
	sed 's|__ORCHESTRATOR_DIR__|$(CURDIR)|' local/kind-config.yaml | \
		kind create cluster --name $(CLUSTER_NAME) --config -
	kubectl apply -f local/coredns.yaml
	kubectl rollout restart deployment/coredns -n kube-system
	kubectl rollout status deployment/coredns -n kube-system --timeout=120s

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
	@# The certificate alone (no key), for in-cluster clients of the
	@# platform's HTTPS hostnames: OpenBao, to reach Dex.
	kubectl create namespace $(OPENBAO_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap idpk-local-ca --namespace $(OPENBAO_NAMESPACE) \
		--from-file=ca.crt=$(LOCAL_CA_DIR)/ca.crt \
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
	@if kubectl get deployment dex -n dex >/dev/null 2>&1; then \
		issuer=$$(curl -fsS --cacert $(LOCAL_CA_DIR)/ca.crt https://dex.$(PLATFORM_DOMAIN)/.well-known/openid-configuration | sed -n 's/.*"issuer": *"\([^"]*\)".*/\1/p') || exit 1; \
		echo "https://dex.$(PLATFORM_DOMAIN) issuer -> $$issuer"; \
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

# --- Single sign-on with Dex (see docs/sso.md) ---

# Dex's credentials: its own GitHub OAuth App (from .idpk.env), the
# installation's org, and the Argo CD client secret, generated once and kept
# on re-runs. Argo CD reads the same client secret from dex-argocd.
dex-secret: require-config
	@if [ -z "$$DEX_GITHUB_CLIENT_ID" ] || [ -z "$$DEX_GITHUB_CLIENT_SECRET" ]; then \
		echo "No GitHub OAuth App for Dex in .idpk.env: run 'make setup'."; exit 1; \
	fi
	@kubectl create namespace dex --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@argocd_secret=$$(kubectl get secret dex-secrets -n dex -o jsonpath='{.data.ARGOCD_CLIENT_SECRET}' 2>/dev/null | base64 -d); \
	[ -n "$$argocd_secret" ] || argocd_secret=$$(openssl rand -hex 24); \
	openbao_secret=$$(kubectl get secret dex-secrets -n dex -o jsonpath='{.data.OPENBAO_CLIENT_SECRET}' 2>/dev/null | base64 -d); \
	[ -n "$$openbao_secret" ] || openbao_secret=$$(openssl rand -hex 24); \
	kubectl create secret generic dex-secrets --namespace dex \
		--from-literal=IDPK_GITHUB_ORG="$$IDPK_GITHUB_ORG" \
		--from-literal=GITHUB_CLIENT_ID="$$DEX_GITHUB_CLIENT_ID" \
		--from-literal=GITHUB_CLIENT_SECRET="$$DEX_GITHUB_CLIENT_SECRET" \
		--from-literal=ARGOCD_CLIENT_SECRET="$$argocd_secret" \
		--from-literal=OPENBAO_CLIENT_SECRET="$$openbao_secret" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null && \
	kubectl create namespace $(OPENBAO_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f - >/dev/null && \
	kubectl create secret generic openbao-oidc --namespace $(OPENBAO_NAMESPACE) \
		--from-literal=client-secret="$$openbao_secret" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null && \
	if kubectl get namespace $(ARGOCD_NAMESPACE) >/dev/null 2>&1; then \
		kubectl create secret generic dex-argocd --namespace $(ARGOCD_NAMESPACE) \
			--from-literal=clientSecret="$$argocd_secret" --dry-run=client -o yaml | \
			kubectl label --local -f - app.kubernetes.io/part-of=argocd -o yaml | \
			kubectl apply -f - >/dev/null; \
	fi && \
	echo "secret/dex-secrets configured"

# Local flow only: the GitOps flow installs the same chart and RBAC with Argo CD.
dex-install: dex-secret
	helm repo add dex https://charts.dexidp.io --force-update
	helm repo update dex
	helm upgrade --install dex dex/dex \
		--namespace dex \
		--version $(DEX_CHART_VERSION) \
		--values platform/dex/values.yaml \
		--wait
	kubectl apply -k platform/access/
	kubectl apply -k platform/openbao-sso/

# --- Non-human identities (see docs/access.md) ---

AGENT_TOKEN_DURATION ?= 8h

# A kubeconfig for one agent: its own ServiceAccount in idpk-agents, read-only
# (platform/access/agents.yaml), with a token that expires. Written to
# .idpk/agents/<name>.kubeconfig (git-ignored, readable by you only).
agent-kubeconfig:
	@[ -n "$(NAME)" ] || { echo "Usage: make agent-kubeconfig NAME=<agent> [AGENT_TOKEN_DURATION=8h]"; exit 1; }
	@kubectl create serviceaccount $(NAME) --namespace idpk-agents --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@mkdir -p .idpk/agents
	@cluster=kind-$(CLUSTER_NAME); \
	server=$$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$$cluster\")].cluster.server}"); \
	ca=$$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$$cluster\")].cluster.certificate-authority-data}"); \
	token=$$(kubectl create token $(NAME) --namespace idpk-agents --duration=$(AGENT_TOKEN_DURATION)) || exit 1; \
	f=.idpk/agents/$(NAME).kubeconfig; umask 077; \
	printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: %s\n  cluster:\n    server: %s\n    certificate-authority-data: %s\nusers:\n- name: agent-%s\n  user:\n    token: %s\ncontexts:\n- name: agent-%s\n  context:\n    cluster: %s\n    user: agent-%s\ncurrent-context: agent-%s\n' \
		"$$cluster" "$$server" "$$ca" "$(NAME)" "$$token" "$(NAME)" "$$cluster" "$(NAME)" "$(NAME)" > $$f; \
	echo "Wrote $$f: read-only, expires in $(AGENT_TOKEN_DURATION)."; \
	echo "Try: KUBECONFIG=$$f kubectl get tenants"

BREAK_GLASS_SECONDS ?= 3600

# Emergency cluster-admin, for when single sign-on is down: a client
# certificate for break-glass:<WHO>, in the idpk:break-glass group
# (platform/access/break-glass.yaml), signed by the cluster's CA through a
# CertificateSigningRequest and valid one hour. Issued with the cluster
# owner's own admin credentials; every request it makes is audited
# (`make break-glass-log`). Written to .idpk/break-glass/ (git-ignored).
break-glass:
	@[ -n "$(WHO)" ] || { echo "Usage: make break-glass WHO=<your name>"; exit 1; }
	@d=.idpk/break-glass; mkdir -p $$d; umask 077; \
	csr=break-glass-$(WHO)-$$(date +%s); \
	openssl req -new -newkey rsa:2048 -nodes -keyout $$d/$(WHO).key \
		-subj "/O=idpk:break-glass/CN=break-glass:$(WHO)" -out $$d/$(WHO).csr 2>/dev/null || exit 1; \
	printf 'apiVersion: certificates.k8s.io/v1\nkind: CertificateSigningRequest\nmetadata:\n  name: %s\nspec:\n  request: %s\n  signerName: kubernetes.io/kube-apiserver-client\n  expirationSeconds: %s\n  usages: [client auth]\n' \
		"$$csr" "$$(base64 < $$d/$(WHO).csr | tr -d '\n')" "$(BREAK_GLASS_SECONDS)" | kubectl apply -f - >/dev/null || exit 1; \
	kubectl certificate approve $$csr >/dev/null; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		crt=$$(kubectl get csr $$csr -o jsonpath='{.status.certificate}'); [ -n "$$crt" ] && break; sleep 1; \
	done; \
	[ -n "$$crt" ] || { echo "The certificate wasn't issued: kubectl describe csr $$csr"; exit 1; }; \
	kubectl delete csr $$csr >/dev/null; \
	cluster=kind-$(CLUSTER_NAME); \
	server=$$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$$cluster\")].cluster.server}"); \
	ca=$$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$$cluster\")].cluster.certificate-authority-data}"); \
	key=$$(base64 < $$d/$(WHO).key | tr -d '\n'); \
	f=$$d/$(WHO).kubeconfig; \
	printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: %s\n  cluster:\n    server: %s\n    certificate-authority-data: %s\nusers:\n- name: break-glass-%s\n  user:\n    client-certificate-data: %s\n    client-key-data: %s\ncontexts:\n- name: break-glass-%s\n  context:\n    cluster: %s\n    user: break-glass-%s\ncurrent-context: break-glass-%s\n' \
		"$$cluster" "$$server" "$$ca" "$(WHO)" "$$crt" "$$key" "$(WHO)" "$$cluster" "$(WHO)" "$(WHO)" > $$f; \
	rm -f $$d/$(WHO).key $$d/$(WHO).csr; \
	echo "Wrote $$f: cluster-admin as break-glass:$(WHO), until $$(echo $$crt | base64 -d | openssl x509 -noout -enddate | cut -d= -f2)."; \
	echo "Every request is audited: make break-glass-log"

# What break-glass credentials did, from the API server's audit log.
break-glass-log:
	@docker exec $(CLUSTER_NAME)-control-plane cat /var/log/kubernetes/audit/audit.log 2>/dev/null | \
		jq -r 'select(.stage == "ResponseComplete") | "\(.requestReceivedTimestamp)  \(.user.username)  \(.verb) \(.objectRef.resource // .requestURI)\(if .objectRef.namespace then " -n " + .objectRef.namespace else "" end)\(if .objectRef.name then " " + .objectRef.name else "" end)  \(.responseStatus.code)"' | \
		tail -n 50

# CI identity check, only inside a GitHub Actions job with `id-token: write`:
# the job's OIDC token, and nothing else, signs in to the cluster.
try-ci-identity:
	@[ -n "$$ACTIONS_ID_TOKEN_REQUEST_URL" ] || { echo "Runs in a GitHub Actions job with 'id-token: write' only."; exit 1; }
	@token=$$(curl -fsS -H "Authorization: bearer $$ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$$ACTIONS_ID_TOKEN_REQUEST_URL&audience=idplatformkit" | jq -r .value) || exit 1; \
	cluster=kind-$(CLUSTER_NAME); \
	server=$$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$$cluster\")].cluster.server}"); \
	kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$$cluster\")].cluster.certificate-authority-data}" | base64 -d > /tmp/idpk-ci-ca.crt; \
	k="kubectl --kubeconfig=/dev/null --server=$$server --certificate-authority=/tmp/idpk-ci-ca.crt --token=$$token"; \
	$$k auth whoami; \
	for check in "yes get tenants.platform.idplatformkit.io" "no get secrets -n kube-system" "no create namespaces"; do \
		want=$${check%% *}; got=$$($$k auth can-i $${check#* } 2>/dev/null); \
		echo "can-i $${check#* }: $$got"; [ "$$got" = "$$want" ] || { echo "expected $$want"; exit 1; }; \
	done

# Adds an `idpk-sso` context to your kubeconfig: kubectl as yourself, signed
# in with GitHub through Dex (kubelogin opens your browser). What you can do
# depends on your teams: edit on your tenants' namespaces, everything for
# platform-admins.
kubeconfig-sso: local-ca
	@kubectl oidc-login --help >/dev/null 2>&1 || { \
		echo "kubelogin is missing: brew install kubelogin, or kubectl krew install oidc-login"; exit 1; }
	kubectl config set-credentials idpk-sso \
		--exec-api-version=client.authentication.k8s.io/v1 \
		--exec-interactive-mode=IfAvailable \
		--exec-command=kubectl \
		--exec-arg=oidc-login \
		--exec-arg=get-token \
		--exec-arg=--oidc-issuer-url=https://dex.$(PLATFORM_DOMAIN) \
		--exec-arg=--oidc-client-id=kubernetes \
		--exec-arg=--oidc-extra-scope=profile \
		--exec-arg=--oidc-extra-scope=groups \
		--exec-arg=--certificate-authority=$(CURDIR)/$(LOCAL_CA_DIR)/ca.crt
	kubectl config set-context idpk-sso --cluster=kind-$(CLUSTER_NAME) --user=idpk-sso
	@echo "Try: kubectl --context idpk-sso auth whoami"

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
	@echo "export K8S_CLUSTER_TOKEN=$$(kubectl create token backstage-reader -n backstage-system --duration=8h)"
	@echo "# Expires in 8 hours: run this again then."

local-up: kind-up crossplane-install providers-apply postgres-server-install openbao-server-install openbao-providerconfig-apply external-secrets-install cert-manager-install envoy-gateway-install gateway-apply compositions-apply backstage-reader-apply
	@echo "Local cluster '$(CLUSTER_NAME)' is ready: Crossplane, provider-sql, provider-vault, the shared Postgres server, and the shared OpenBao server are installed, compositions applied, HTTPS on https://<name>.$(PLATFORM_DOMAIN)."

# --- GitOps flow (see docs/gitops.md) ---
# Same end state as local-up, but only Argo CD and the bootstrap Secrets are
# installed by hand; Argo CD installs everything else from this repo.

bootstrap-secrets: postgres-bootstrap-secrets openbao-bootstrap-secrets local-ca-secret portal-secret dex-secret

# --timeout 10m: helm's default 5m was hit in CI while the kind node was
# still pulling Argo CD's images. The redis ImagePullBackOff seen there turned
# out to be ECR Public rate limiting (429), fixed in bootstrap/argocd/values.yaml;
# the longer timeout covers genuinely slow pulls from shared CI runners.
# Sign-in through Dex: local/argocd-sso-values.yaml, rendered with the
# installation's org and the local CA.
argocd-install: require-config local-ca
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm repo update argo
	scripts/render.sh local/argocd-sso-values.yaml .idpk/argocd-sso-values.yaml
	helm upgrade --install argocd argo/argo-cd \
		--namespace $(ARGOCD_NAMESPACE) \
		--create-namespace \
		--version $(ARGOCD_CHART_VERSION) \
		--values bootstrap/argocd/values.yaml \
		--values .idpk/argocd-sso-values.yaml \
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
