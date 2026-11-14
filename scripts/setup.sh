#!/usr/bin/env bash
# Guided setup of an IdPlatformKit installation: `make setup`.
#
# Checks the prerequisites, then configures the installation on YOUR GitHub
# org: creates its instances repository from idPlatformKit/instances-template
# and walks you through the portal's OAuth App. Writes .idpk.env (git-ignored,
# readable by you only). Safe to re-run: it offers to keep existing values.
#
# Works with macOS's bash 3.2.

set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=.idpk.env
TEMPLATE_REPO=idPlatformKit/instances-template
PORTAL_URL=https://portal.127.0.0.1.nip.io
CALLBACK_URL=$PORTAL_URL/api/auth/github/handler/frame

if [ -t 1 ]; then
	bold=$(printf '\033[1m'); dim=$(printf '\033[2m'); red=$(printf '\033[31m')
	green=$(printf '\033[32m'); yellow=$(printf '\033[33m'); reset=$(printf '\033[0m')
else
	bold=''; dim=''; red=''; green=''; yellow=''; reset=''
fi

step() { printf '\n%s%s%s\n' "$bold" "$1" "$reset"; }
ok() { printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$1"; }
fail() { printf '  %s✗%s %s\n' "$red" "$reset" "$1"; }
info() { printf '    %s\n' "$1"; }

# ask VAR "Question" [default]
ask() {
	local var=$1 question=$2 default=${3:-} answer
	if [ -n "$default" ]; then
		printf '  %s %s[%s]%s ' "$question" "$dim" "$default" "$reset"
	else
		printf '  %s ' "$question"
	fi
	read -r answer
	eval "$var=\${answer:-\$default}"
}

# confirm "Question" (default yes)
confirm() {
	local answer
	printf '  %s %s[Y/n]%s ' "$1" "$dim" "$reset"
	read -r answer
	case "$answer" in [nN]*) return 1 ;; *) return 0 ;; esac
}

open_url() {
	if command -v open >/dev/null 2>&1; then open "$1" >/dev/null 2>&1 || true
	elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 || true
	fi
}

printf '%sIdPlatformKit setup%s\n' "$bold" "$reset"
printf 'Installs nothing yet: it checks your machine, then prepares your GitHub org.\n'
printf 'At the end, %smake up%s builds the platform.\n' "$bold" "$reset"

# Existing configuration, if any.
IDPK_GITHUB_ORG=''; IDPK_INSTANCES_REPO=''; AUTH_GITHUB_CLIENT_ID=''; AUTH_GITHUB_CLIENT_SECRET=''
if [ -f "$ENV_FILE" ]; then
	# shellcheck disable=SC1090
	. "./$ENV_FILE"
	printf '\nFound %s: its values are offered as defaults.\n' "$ENV_FILE"
fi

# --- 1. Tools ---------------------------------------------------------------
step "1/5  Tools"
missing=0
need() {
	local cmd=$1 hint=$2
	if command -v "$cmd" >/dev/null 2>&1; then
		ok "$cmd"
	else
		fail "$cmd is missing. $hint"
		missing=1
	fi
}
need docker "Install Docker Desktop, OrbStack or Colima: https://docs.docker.com/get-docker/"
need kind "brew install kind, or https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
need kubectl "brew install kubectl, or https://kubernetes.io/docs/tasks/tools/"
need helm "brew install helm, or https://helm.sh/docs/intro/install/"
need gh "brew install gh, or https://cli.github.com/"
need openssl "brew install openssl, or your package manager"
need git "https://git-scm.com/downloads"
need curl "your package manager"
if [ "$missing" = 1 ]; then
	printf '\nInstall the missing tools, then run %smake setup%s again.\n' "$bold" "$reset"
	exit 1
fi

if docker info >/dev/null 2>&1; then
	ok "Docker is running"
else
	fail "Docker isn't running. Start Docker Desktop, OrbStack or Colima, then run make setup again."
	exit 1
fi

# Ports 80 and 443 must be free for the platform's HTTPS entry point, unless
# they're already held by this very cluster.
if kind get clusters 2>/dev/null | grep -qx idplatformkit-local; then
	ok "kind cluster idplatformkit-local already exists (make down removes it)"
else
	for port in 80 443; do
		if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
			fail "Port $port is in use. The platform serves https://<name>.127.0.0.1.nip.io on 80 and 443."
			info "Find what holds it: lsof -nP -iTCP:$port -sTCP:LISTEN"
			exit 1
		fi
	done
	ok "Ports 80 and 443 are free"
fi

# --- 2. GitHub CLI ----------------------------------------------------------
step "2/5  GitHub access"
if ! gh auth status -h github.com >/dev/null 2>&1; then
	fail "The GitHub CLI isn't signed in."
	info "Run: gh auth login -h github.com -s read:org,read:user,user:email"
	exit 1
fi
GH_USER=$(gh api user --jq .login)
ok "Signed in to GitHub as $GH_USER"

# The portal's catalog imports your org's members and teams with this token:
# GitHub requires read:user or user:email for their e-mail addresses.
scopes=$(gh auth status -h github.com 2>&1 | sed -n 's/.*Token scopes: //p' | tr -d "'")
missing_scopes=''
for s in read:org read:user user:email; do
	case ",$(echo "$scopes" | tr -d ' ')," in
		*",$s,"*) ;;
		*) missing_scopes="$missing_scopes,$s" ;;
	esac
done
missing_scopes=${missing_scopes#,}
if [ -z "$scopes" ]; then
	warn "Couldn't read your token's scopes (fine-grained token?)."
	info "The portal needs read:org, read:user and user:email on the org."
elif [ -n "$missing_scopes" ]; then
	warn "Your GitHub CLI token lacks: $missing_scopes"
	info "The portal reads your org's members and teams with it."
	if confirm "Add them now? (opens GitHub in your browser)"; then
		gh auth refresh -h github.com -s read:org,read:user,user:email
		ok "Scopes added"
	else
		fail "Run make setup again once you've run: gh auth refresh -h github.com -s read:org,read:user,user:email"
		exit 1
	fi
else
	ok "Token scopes: read:org, read:user, user:email"
fi

# --- 3. Your GitHub org -------------------------------------------------------
step "3/5  Your GitHub org"
info "IdPlatformKit runs on a GitHub org: its members sign in to the portal, and"
info "its teams own the tenants. Use a test org if you just want to try it."
orgs=$(gh api user/orgs --jq '.[].login' 2>/dev/null | tr '\n' ' ')
if [ -n "$orgs" ]; then
	info "Your orgs: $orgs"
else
	warn "You aren't a member of any org yet."
	info "Create one (free) at https://github.com/account/organizations/new, then run make setup again."
	exit 1
fi
default_org=${IDPK_GITHUB_ORG:-$(echo "$orgs" | awk '{print $1}')}
while :; do
	ask org "GitHub org:" "$default_org"
	if gh api "orgs/$org" >/dev/null 2>&1; then break; fi
	fail "Org '$org' not found, or not visible to you."
done
role=$(gh api "user/memberships/orgs/$org" --jq .role 2>/dev/null || echo none)
if [ "$role" = admin ]; then
	ok "$org: you're an owner"
else
	warn "$org: you're '$role', not an owner. Creating the repository and the OAuth App may need an owner."
fi

teams=$(gh api "orgs/$org/teams" --jq '.[].slug' 2>/dev/null | tr '\n' ' ')
if [ -n "$teams" ]; then
	ok "Teams: $teams"
else
	warn "$org has no teams. A tenant is owned by a team: the New Tenant form lists them."
	info "Create one at https://github.com/orgs/$org/new-team (you can do it later)."
fi

# --- 4. Your instances repository -------------------------------------------
step "4/5  Your instances repository"
info "Every Tenant and database on your platform is a file in this repository."
info "The portal opens pull requests to it, Argo CD syncs it."
ask repo "Repository name:" "${IDPK_INSTANCES_REPO:-instances}"
if gh repo view "$org/$repo" >/dev/null 2>&1; then
	visibility=$(gh repo view "$org/$repo" --json visibility --jq .visibility)
	ok "$org/$repo exists ($visibility), it'll be used as is"
	if [ "$visibility" != PUBLIC ]; then
		warn "It's not public: Argo CD reads it anonymously on the local install, so syncing will fail."
		info "Make it public, or use another name."
	fi
else
	info "$org/$repo doesn't exist: it'll be created from $TEMPLATE_REPO,"
	info "public (Argo CD reads it anonymously) and empty."
	if confirm "Create $org/$repo?"; then
		gh repo create "$org/$repo" --public --template "$TEMPLATE_REPO" \
			--description "IdPlatformKit instances: the claims Argo CD syncs onto the platform" >/dev/null
		ok "Created https://github.com/$org/$repo"
	else
		fail "No instances repository: create it, then run make setup again."
		exit 1
	fi
fi

# --- 5. The portal's OAuth App ----------------------------------------------
step "5/5  Signing in to the portal"
info "The portal signs you in with GitHub through an OAuth App owned by $org."
info "GitHub has no API to create one: it takes a minute in the browser."
reuse=1
if [ -n "$AUTH_GITHUB_CLIENT_ID" ] && [ "${IDPK_GITHUB_ORG:-}" = "$org" ]; then
	confirm "Keep the OAuth App from $ENV_FILE ($AUTH_GITHUB_CLIENT_ID)?" || reuse=0
else
	reuse=0
fi
if [ "$reuse" = 0 ]; then
	new_app_url="https://github.com/organizations/$org/settings/applications/new"
	printf '\n'
	info "Open ${bold}$new_app_url${reset}"
	info "and fill in:"
	info "  Application name             IdPlatformKit portal"
	info "  Homepage URL                 $PORTAL_URL"
	info "  Authorization callback URL   $CALLBACK_URL"
	info "Leave \"Enable Device Flow\" unchecked, click Register application,"
	info "then Generate a new client secret."
	printf '\n'
	if confirm "Open that page now?"; then open_url "$new_app_url"; fi
	ask AUTH_GITHUB_CLIENT_ID "Client ID:"
	printf '  Client secret (hidden): '
	read -rs AUTH_GITHUB_CLIENT_SECRET
	printf '\n'
	if [ -z "$AUTH_GITHUB_CLIENT_ID" ] || [ -z "$AUTH_GITHUB_CLIENT_SECRET" ]; then
		fail "Both are needed. Run make setup again when you have them."
		exit 1
	fi
	ok "OAuth App configured"
fi

# --- Write the configuration ------------------------------------------------
umask 077
cat > "$ENV_FILE" <<EOF
# IdPlatformKit installation, written by \`make setup\`. Git-ignored: it holds
# the OAuth App's client secret. Read by the Makefile.
IDPK_GITHUB_ORG=$org
IDPK_INSTANCES_REPO=$repo
AUTH_GITHUB_CLIENT_ID=$AUTH_GITHUB_CLIENT_ID
AUTH_GITHUB_CLIENT_SECRET=$AUTH_GITHUB_CLIENT_SECRET
EOF

step "Ready"
ok "Wrote $ENV_FILE"
printf '\nNext:\n'
printf '  %smake up%s            builds the platform on kind (about 6 minutes)\n' "$bold" "$reset"
printf '  %smake local-ca-trust%s  once per machine, so your browser trusts the platform (sudo)\n' "$bold" "$reset"
printf '\nThen open %s%s%s and sign in with GitHub.\n' "$bold" "$PORTAL_URL" "$reset"
