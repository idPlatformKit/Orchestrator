#!/usr/bin/env bash
# The App platform API end to end: deploys the hello demo app with a Postgres
# database in demo-team-staging, then promotes the same image, by digest, to
# demo-team-prod. In each environment, checks over HTTPS, through the
# Gateway, that the app reaches its own database, and checks prod's rules.
# Needs the demo-team tenant (make try-tenant).
set -euo pipefail

app=apps.platform.idplatformkit.io/hello   # "app" alone is Argo CD's Application

for env in staging prod; do
  ns=demo-team-$env
  kubectl get namespace "$ns" >/dev/null || { echo "no $ns namespace: run make try-tenant first" >&2; exit 1; }

  echo "--- $env"
  sed "s/namespace: demo-team-staging/namespace: $ns/" examples/app/app.yaml | kubectl apply -f -
  start=$(date +%s)
  kubectl wait "$app" -n "$ns" --for=condition=Ready --timeout=300s
  echo "App Ready in $(( $(date +%s) - start ))s"

  url=$(kubectl get "$app" -n "$ns" -o jsonpath='{.status.url}')
  want="${ns}_hello-db"
  body=$(curl -sS --fail --cacert .local-ca/ca.crt "$url/")
  echo "GET $url/ -> $body"
  case "$body" in
    *"\"database\":\"$want\""*) echo "OK: $env reaches its own database, $want" ;;
    *) echo "FAIL: expected database $want" >&2; exit 1 ;;
  esac
done

replicas=$(kubectl get deployment hello-web -n demo-team-prod -o jsonpath='{.status.availableReplicas}')
pdb=$(kubectl get poddisruptionbudget hello-web -n demo-team-prod -o jsonpath='{.spec.maxUnavailable}')
staging_image=$(kubectl get deployment hello-web -n demo-team-staging -o jsonpath='{.spec.template.spec.containers[0].image}')
prod_image=$(kubectl get deployment hello-web -n demo-team-prod -o jsonpath='{.spec.template.spec.containers[0].image}')
[ "$replicas" = 2 ] && [ "$pdb" = 1 ] && [ "$staging_image" = "$prod_image" ] || {
  echo "FAIL: prod has $replicas available replicas, PodDisruptionBudget maxUnavailable '$pdb', image $prod_image (staging: $staging_image)" >&2
  exit 1
}
echo "OK: prod runs 2 replicas with a PodDisruptionBudget, and the image staging ran: $prod_image"
