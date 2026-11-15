#!/usr/bin/env bash
# `make status`: where everything is on the local platform, and what's left
# to do. Read-only. Also printed at the end of `make up`.

set -uo pipefail

cd "$(dirname "$0")/.."
CLUSTER=idplatformkit-local
DOMAIN=127.0.0.1.nip.io
CA=.local-ca/ca.crt

if [ -t 1 ]; then
	bold=$(printf '\033[1m'); red=$(printf '\033[31m'); green=$(printf '\033[32m')
	yellow=$(printf '\033[33m'); reset=$(printf '\033[0m')
else
	bold=''; red=''; green=''; yellow=''; reset=''
fi
ok() { printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$1"; }
fail() { printf '  %s✗%s %s\n' "$red" "$reset" "$1"; }

IDPK_GITHUB_ORG=''; IDPK_INSTANCES_REPO=instances
# shellcheck disable=SC1091
[ -f .idpk.env ] && . ./.idpk.env

printf '\n%sIdPlatformKit status%s\n\n' "$bold" "$reset"

if [ -z "$IDPK_GITHUB_ORG" ]; then
	fail "Not configured: run make setup"
	exit 1
fi
ok "GitHub org $IDPK_GITHUB_ORG, claims in https://github.com/$IDPK_GITHUB_ORG/$IDPK_INSTANCES_REPO"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
	fail "No cluster: run make up"
	exit 1
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null 2>&1

if kubectl get namespace argocd >/dev/null 2>&1; then
	unhealthy=$(kubectl get applications -n argocd --no-headers 2>/dev/null |
		awk '$2 != "Synced" || $3 != "Healthy" {print $1 " (" $2 "/" $3 ")"}')
	if [ -z "$unhealthy" ]; then
		ok "Argo CD: every application Synced and Healthy"
	else
		warn "Argo CD: not settled yet: $(echo "$unhealthy" | tr '\n' ' ')"
		printf '      Watch: kubectl get applications -n argocd -w\n'
	fi
fi

if kubectl get deployment portal -n backstage-system >/dev/null 2>&1; then
	if [ "$(kubectl get deployment portal -n backstage-system -o jsonpath='{.status.readyReplicas}')" = 1 ]; then
		ok "Portal running"
	else
		warn "Portal not ready yet: kubectl get pods -n backstage-system"
	fi
fi

# The browser only trusts https://*.$DOMAIN once the local CA is trusted.
trusted=0
if [ -f "$CA" ]; then
	case "$(uname -s)" in
		Darwin) security verify-cert -c "$CA" -p ssl >/dev/null 2>&1 && trusted=1 ;;
		Linux) [ -f /usr/local/share/ca-certificates/idplatformkit-local-ca.crt ] && trusted=1 ;;
	esac
fi
if [ "$trusted" = 1 ]; then
	ok "Local CA trusted by this machine"
else
	warn "Your browser won't trust the platform's certificate yet: run make local-ca-trust (once, sudo)"
fi

printf '\n%sOpen%s\n' "$bold" "$reset"
printf '  Portal    https://portal.%s   sign in with GitHub (a member of %s)\n' "$DOMAIN" "$IDPK_GITHUB_ORG"
if kubectl get namespace argocd >/dev/null 2>&1; then
	pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
	printf '  Argo CD   https://argocd.%s   admin / %s\n' "$DOMAIN" "${pw:-?}"
fi
printf '  OpenBao   https://openbao.%s/ui   token root-local-dev\n' "$DOMAIN"

printf '\n%sTry it%s\n' "$bold" "$reset"
printf '  In the portal: Create > New Tenant. It opens a pull request on %s/%s.\n' "$IDPK_GITHUB_ORG" "$IDPK_INSTANCES_REPO"
printf '  Merge it: within a few minutes Argo CD syncs it and the tenant shows up in the catalog.\n'
printf '\n  Local dev credentials, for this laptop only. make down deletes the cluster.\n\n'
