#!/usr/bin/env bash
# Checks the tenant guardrails with server-side dry runs: admission runs in
# full, nothing is created. Against the demo-team tenant (make try-tenant) by
# default, or TENANT=<name>; it needs both environments.
set -euo pipefail
cd "$(dirname "$0")/.."
tenant=${TENANT:-demo-team}
staging=$tenant-staging
prod=$tenant-prod

# An example, in the given namespace.
dry_run() { # namespace, file, kubectl args...
  sed -E "s/namespace: demo-team-(staging|prod)$/namespace: $1/" "$2" | kubectl apply --dry-run=server -f - "${@:3}"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

refused() { # namespace, file, expected words in the error...
  local out word
  if out=$(dry_run "$1" "$2" 2>&1); then
    fail "$2 was accepted in $1"
  fi
  for word in "${@:3}"; do
    echo "$out" | grep -q -- "$word" || fail "$2 refused in $1, but without '$word': $out"
  done
  echo "refused, as expected: $(echo "$out" | grep -v '^Warning' | tail -1)"
}

owner=$(kubectl get namespace "$staging" -o jsonpath='{.metadata.labels.platform\.idplatformkit\.io/owner}')
[ -n "$owner" ] || fail "namespace $staging has no owner label"
echo "$tenant is owned by $owner"

echo "== $staging"
echo "1. A privileged pod (Pod Security Admission, baseline)"
refused "$staging" examples/guardrails/privileged-pod.yaml 'violates PodSecurity "baseline'

echo "2. A Deployment without resources (tenant-require-resources)"
refused "$staging" examples/guardrails/no-resources.yaml 'resources.requests.cpu'

echo "3. A Deployment that declares its resources, image by tag, 1 replica"
out=$(dry_run "$staging" examples/guardrails/compliant.yaml 2>&1) || fail "compliant.yaml was refused in staging: $out"
echo "$out" | grep -q 'would violate PodSecurity "restricted' || fail "no warning about prod's Pod Security Standard: $out"
echo "accepted, with the warning that its pods wouldn't run in prod: $(echo "$out" | grep -o 'would violate PodSecurity "restricted[^"]*"')"

echo "4. A pod claiming another owner, without resources (tenant-owner-label, LimitRange)"
pod=$(dry_run "$staging" examples/guardrails/other-owner-pod.yaml -o json 2>/dev/null)
got=$(echo "$pod" | jq -r '.metadata.labels["platform.idplatformkit.io/owner"]')
[ "$got" = "$owner" ] || fail "owner label is '$got', expected '$owner'"
mem=$(echo "$pod" | jq -r '.spec.containers[0].resources.limits.memory')
[ "$mem" != null ] || fail "the LimitRange's defaults weren't applied"
echo "accepted, owner label set to $got, memory limit $mem from the LimitRange"

echo "== $prod"
echo "5. The same Deployment as 3 (prod-images-by-digest, prod-min-replicas)"
refused "$prod" examples/guardrails/compliant.yaml 'pinned by digest' 'at least 2 replicas'

echo "6. A pod that isn't restricted (Pod Security Admission, restricted)"
refused "$prod" examples/guardrails/other-owner-pod.yaml 'violates PodSecurity "restricted'

echo "7. A Deployment by digest, 2 replicas, restricted"
out=$(dry_run "$prod" examples/guardrails/prod-compliant.yaml 2>&1) || fail "prod-compliant.yaml was refused in prod: $out"
echo "$out" | grep -q Warning && fail "unexpected warning: $out"
echo "accepted, without warnings"

echo "== outside tenant namespaces"
echo "8. Nothing changes"
sed -E 's/namespace: demo-team-staging$/namespace: default/' examples/guardrails/no-resources.yaml \
  | kubectl apply --dry-run=server -f - >/dev/null || fail "refused outside a tenant"
echo "accepted in default"
