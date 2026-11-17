#!/usr/bin/env bash
# The App platform API end to end: builds the hello demo app, loads its image
# into kind, deploys it in demo-team-staging with a Postgres database, and
# checks over HTTPS, through the Gateway, that the app reaches its database.
# Needs the demo-team tenant (make try-tenant).
set -euo pipefail

cluster=${KIND_CLUSTER:-idplatformkit-local}
ns=demo-team-staging
app=apps.platform.idplatformkit.io/hello   # "app" alone is Argo CD's Application

kubectl get namespace "$ns" >/dev/null || { echo "no $ns namespace: run make try-tenant first" >&2; exit 1; }

docker build -q -t idpk-hello:dev examples/app/hello >/dev/null
kind load docker-image idpk-hello:dev --name "$cluster"

kubectl apply -f examples/app/app.yaml
start=$(date +%s)
kubectl wait "$app" -n "$ns" --for=condition=Ready --timeout=300s
echo "App Ready in $(( $(date +%s) - start ))s"
kubectl get "$app" -n "$ns" -o jsonpath='{.status}' && echo

url=$(kubectl get "$app" -n "$ns" -o jsonpath='{.status.url}')
want="${ns}_hello-db"
body=$(curl -sS --fail --cacert .local-ca/ca.crt "$url/")
echo "GET $url/ -> $body"
case "$body" in
  *"\"database\":\"$want\""*) echo "OK: the app reaches its database $want" ;;
  *) echo "FAIL: expected database $want" >&2; exit 1 ;;
esac
