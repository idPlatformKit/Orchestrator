#!/usr/bin/env bash
# Checks the demo-team tenant (examples/tenant.yaml) once it's Ready: one
# namespace per environment with its own rules, and each environment's
# OpenBao secrets delivered by External Secrets Operator to that
# environment only.
set -euo pipefail
cd "$(dirname "$0")/.."
tenant=demo-team
openbao_ns=${OPENBAO_NAMESPACE:-openbao-system}
openbao_pod=${OPENBAO_RELEASE:-openbao}-0
token=${OPENBAO_DEV_ROOT_TOKEN:-root-local-dev}

fail() { echo "FAIL: $*" >&2; exit 1; }

for env in staging prod; do
  ns=$tenant-$env
  echo "== $ns"
  pss=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
  role=$(kubectl get rolebinding "$tenant" -n "$ns" -o jsonpath='{.roleRef.name}')
  echo "Pod Security: $pss, owner team: $role"
  kubectl get resourcequota,limitrange,networkpolicy -n "$ns"
  kubectl get serviceaccount demo-app -n "$ns"
  kubectl get secretstore openbao -n "$ns"

  # A different value per environment, written with the dev root token into
  # the environment's mount of the tenant's OpenBao namespace.
  kubectl exec -n "$openbao_ns" "$openbao_pod" -- \
    env BAO_TOKEN="$token" BAO_NAMESPACE="$tenant" \
    bao kv put "$env/db-credentials" password="from-openbao-$env" >/dev/null
  sed "s/namespace: $tenant-staging/namespace: $ns/" examples/tenant-external-secret.yaml | kubectl apply -f -
  kubectl wait --for=condition=Ready --timeout=60s externalsecret/db-credentials -n "$ns"
  got=$(kubectl get secret db-credentials -n "$ns" -o jsonpath='{.data.password}' | base64 -d)
  [ "$got" = "from-openbao-$env" ] || fail "$ns got '$got', expected from-openbao-$env"
  echo "db-credentials/password in $ns: $got"
done

# Isolation in OpenBao itself, with staging's identity: its token can't
# read prod's mount, and it can't log in with prod's role.
bao() { kubectl exec -i -n "$openbao_ns" "$openbao_pod" -- env BAO_NAMESPACE="$tenant" "$@"; }
jwt=$(kubectl create token demo-app -n "$tenant-staging" --duration=10m)
staging_token=$(bao bao write -field=token auth/kubernetes/login role=staging jwt="$jwt")
if out=$(bao env BAO_TOKEN="$staging_token" bao kv get prod/db-credentials 2>&1); then
  fail "staging's identity read prod's secret"
fi
echo "$out" | grep -q "Code: 403" || fail "unexpected error reading prod with staging's token: $out"
echo "staging's token reading prod's secret: refused (403)"
if out=$(bao bao write auth/kubernetes/login role=prod jwt="$jwt" 2>&1); then
  fail "staging's ServiceAccount logged in with prod's role"
fi
echo "staging's ServiceAccount logging in with prod's role: refused ($(echo "$out" | grep -o 'namespace not authorized\|service account .* not authorized\|invalid .*' | head -1))"

[ "$(kubectl get namespace $tenant-staging -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = baseline ] || fail "staging isn't baseline"
[ "$(kubectl get namespace $tenant-prod -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = restricted ] || fail "prod isn't restricted"
[ "$(kubectl get rolebinding $tenant -n $tenant-staging -o jsonpath='{.roleRef.name}')" = edit ] || fail "the team can't edit staging"
[ "$(kubectl get rolebinding $tenant -n $tenant-prod -o jsonpath='{.roleRef.name}')" = view ] || fail "the team isn't read-only in prod"
echo "OK: staging (baseline, edit) and prod (restricted, view), each reading its own secrets"
