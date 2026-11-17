#!/usr/bin/env bash
# The protection of an App's data, on hello in demo-team-staging (make
# try-app first): a service removed from the spec is kept until its deletion
# is confirmed, and the App can't be deleted until all its services are.
# Ends with hello in staging deleted, its data included.
set -euo pipefail

ns=demo-team-staging
app=apps.platform.idplatformkit.io/hello
pg=postgresdatabases.database.idplatformkit.io
annotation=platform.idplatformkit.io/delete-services
image=$(sed -n 's/^ *hello: \(ghcr.io.*\)$/\1/p' examples/app/app.yaml)

kubectl get "$app" -n "$ns" >/dev/null || { echo "no hello App in $ns: run make try-app first" >&2; exit 1; }

hello() { # hello <extra services>: apply hello with db, plus extra ones
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: platform.idplatformkit.io/v1alpha1
kind: App
metadata: { name: hello, namespace: $ns }
spec:
  images: { hello: "$image" }
  services:
    db: { type: postgres }
$(for s in "$@"; do echo "    $s: { type: postgres }"; done)
  components:
    web:
      image: hello
      port: 8080
      env: { DATABASE_URL: "\${services.db.url}" }
      expose: { path: / }
YAML
}
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_for() { # wait_for <description> <command...>: up to 120 s
  local what=$1; shift
  for _ in $(seq 1 60); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done
  fail "$what"
}

echo "--- add a service, old, then remove it from the spec"
hello old
kubectl wait "$app" -n "$ns" --for=condition=Ready --timeout=180s >/dev/null
kubectl get "$pg" hello-old -n "$ns" >/dev/null
hello
wait_for "old reported in status.retainedServices" \
  sh -c "kubectl get $app -n $ns -o jsonpath='{.status.retainedServices.old.secret}' | grep -q hello-old-conn"
sleep 10
kubectl get "$pg" hello-old -n "$ns" >/dev/null || fail "hello-old was deleted"
echo "OK: old was removed from the spec, its database is kept:"
kubectl get "$app" -n "$ns" -o jsonpath='  status.retainedServices: {.status.retainedServices}{"\n"}'
kubectl get events -n "$ns" --field-selector involvedObject.name=hello,type=Warning \
  -o jsonpath='{range .items[-1:]}  event: {.message}{"\n"}{end}'

echo "--- delete the App without confirming"
if out=$(kubectl delete "$app" -n "$ns" 2>&1); then fail "the App was deleted: $out"; fi
echo "OK: refused: $out"

echo "--- confirm the deletion of old"
kubectl annotate "$app" -n "$ns" "$annotation=old" --overwrite >/dev/null
wait_for "hello-old deleted" sh -c "! kubectl get $pg hello-old -n $ns"
kubectl get "$pg" hello-db -n "$ns" >/dev/null || fail "hello-db was deleted too"
[ -z "$(kubectl get "$app" -n "$ns" -o jsonpath='{.status.retainedServices}')" ] || fail "old is still in status.retainedServices"
echo "OK: hello-old deleted, hello-db kept"

echo "--- delete the App: still refused, db isn't confirmed"
if out=$(kubectl delete "$app" -n "$ns" 2>&1); then fail "the App was deleted: $out"; fi
echo "OK: refused: $out"

echo "--- confirm every service, then delete the App"
kubectl annotate "$app" -n "$ns" "$annotation=*" --overwrite >/dev/null
kubectl delete "$app" -n "$ns" --cascade=foreground --timeout=180s >/dev/null
wait_for "hello-db deleted" sh -c "! kubectl get $pg hello-db -n $ns"
echo "OK: hello and its database deleted"
