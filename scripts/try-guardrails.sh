#!/usr/bin/env bash
# Checks the tenant guardrails with server-side dry runs: admission runs in
# full, nothing is created. Against the demo-team tenant (make try-tenant) by
# default, or TENANT=<name>.
set -euo pipefail
cd "$(dirname "$0")/.."
tenant=${TENANT:-demo-team}

# The examples, in the tenant's namespace.
dry_run() { sed "s/namespace: demo-team/namespace: $tenant/" "$1" | kubectl apply --dry-run=server -f - "${@:2}"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

refused() { # file, expected words in the error
  local out
  if out=$(dry_run "$1" 2>&1); then
    fail "$1 was accepted"
  fi
  echo "$out" | grep -q "$2" || fail "$1 refused for another reason: $out"
  echo "refused, as expected: $(echo "$out" | tail -1)"
}

owner=$(kubectl get namespace "$tenant" -o jsonpath='{.metadata.labels.platform\.idplatformkit\.io/owner}')
[ -n "$owner" ] || fail "namespace $tenant has no owner label"
echo "$tenant is owned by $owner"

echo "1. A privileged pod (Pod Security Admission, baseline)"
refused examples/guardrails/privileged-pod.yaml 'violates PodSecurity "baseline'

echo "2. A Deployment without resources (tenant-require-resources)"
refused examples/guardrails/no-resources.yaml 'resources.requests.cpu'

echo "3. A compliant Deployment claiming another owner (tenant-owner-label)"
got=$(dry_run examples/guardrails/compliant.yaml -o jsonpath='{.spec.template.metadata.labels.platform\.idplatformkit\.io/owner}')
[ "$got" = "$owner" ] || fail "owner label is '$got', expected '$owner'"
echo "accepted, owner label set to $got"

echo "4. Outside tenant namespaces, nothing changes"
sed 's/namespace: demo-team/namespace: default/' examples/guardrails/no-resources.yaml \
  | kubectl apply --dry-run=server -f - >/dev/null || fail "refused outside a tenant"
echo "accepted in default"
