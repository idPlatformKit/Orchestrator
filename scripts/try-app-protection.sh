#!/usr/bin/env bash
# The protection of an App's data, on hello (make try-app first), checked in
# Postgres itself:
#   staging: a service removed from the spec is kept until its deletion is
#            confirmed, and the App can't be deleted until all its services
#            are; confirmed, they're dropped.
#   prod:    deleting the tenant keeps the database (orphaned, no hang);
#            re-creating the tenant and the App adopts it, data included.
# Ends with the demo-team tenant re-created, without Apps.
set -euo pipefail

app=hello
xr=apps.platform.idplatformkit.io
pg=postgresdatabases.database.idplatformkit.io
annotation=platform.idplatformkit.io/delete-services
image=$(sed -n 's/^ *hello: \(ghcr.io.*\)$/\1/p' examples/app/app.yaml)
admin_password=$(kubectl get secret postgres-server-auth -n postgres-system -o jsonpath='{.data.postgres-password}' | base64 -d)

fail() { echo "FAIL: $*" >&2; exit 1; }
psql_admin() { # psql_admin <database> <sql>
  kubectl exec -n postgres-system postgres-server-postgresql-0 -- \
    env PGPASSWORD="$admin_password" psql -U postgres -d "$1" -tAc "$2"
}
db_exists() { [ "$(psql_admin postgres "select count(*) from pg_database where datname = '$1'")" = 1 ]; }
db_gone() { ! db_exists "$1"; }
retained() { kubectl get "$xr/$app" -n "$1" -o jsonpath="{.status.retainedServices.$2.secret}" | grep -q .; }
deletes() { # deletes <namespace> <PostgresDatabase>: Delete reached its Database object
  [ "$(kubectl get "$pg" "$2" -n "$1" -o jsonpath='{.status.databaseManagementPolicies}')" = '["*"]' ]
}
namespaces_gone() { ! kubectl get namespace demo-team-staging && ! kubectl get namespace demo-team-prod; }
wait_for() { # wait_for <description> <command...>: up to 180 s
  local what=$1; shift
  for _ in $(seq 1 90); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done
  fail "$what"
}
hello() { # hello <namespace> <extra services...>: apply hello with db, plus extra ones
  local ns=$1; shift
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: platform.idplatformkit.io/v1alpha1
kind: App
metadata: { name: $app, namespace: $ns }
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
delete_refused() { # delete_refused <namespace>
  local out
  if out=$(kubectl delete "$xr/$app" -n "$1" 2>&1); then fail "the App was deleted: $out"; fi
  echo "OK: refused: ${out#*denied the request: }"
}

for ns in demo-team-staging demo-team-prod; do
  kubectl get "$xr/$app" -n "$ns" >/dev/null || fail "no hello App in $ns: run make try-app first"
done

ns=demo-team-staging
echo "=== staging: removing a service, deleting the App"

echo "--- add a service, old, then remove it from the spec"
hello "$ns" old
kubectl wait "$xr/$app" -n "$ns" --for=condition=Ready --timeout=180s >/dev/null
db_exists "${ns}_hello-old" || fail "no database ${ns}_hello-old"
hello "$ns"
wait_for "old reported in status.retainedServices" retained "$ns" old
sleep 10
db_exists "${ns}_hello-old" || fail "the database ${ns}_hello-old was dropped"
echo "OK: old was removed from the spec, its database is kept"
kubectl get "$xr/$app" -n "$ns" -o jsonpath='  status.retainedServices: {.status.retainedServices}{"\n"}'

echo "--- delete the App without confirming"
delete_refused "$ns"

echo "--- confirm the deletion of old"
kubectl annotate "$xr/$app" -n "$ns" "$annotation=old" --overwrite >/dev/null
wait_for "the database ${ns}_hello-old dropped" db_gone "${ns}_hello-old"
db_exists "${ns}_hello-db" || fail "the database ${ns}_hello-db was dropped too"
echo "OK: ${ns}_hello-old dropped, ${ns}_hello-db kept"

echo "--- delete the App: still refused, db isn't confirmed"
delete_refused "$ns"

echo "--- confirm every service, then delete the App"
kubectl annotate "$xr/$app" -n "$ns" "$annotation=*" --overwrite >/dev/null
wait_for "Delete reaching hello-db" deletes "$ns" hello-db
kubectl delete "$xr/$app" -n "$ns" --cascade=foreground --timeout=180s >/dev/null
wait_for "the database ${ns}_hello-db dropped" db_gone "${ns}_hello-db"
echo "OK: hello and ${ns}_hello-db dropped"

ns=demo-team-prod
db="${ns}_hello-db"
echo "=== prod: deleting the tenant, then re-creating it"

psql_admin "$db" "create table if not exists marker (x int); insert into marker values (42)" >/dev/null
echo "--- delete the demo-team tenant, with hello still in prod"
start=$(date +%s)
kubectl delete -f examples/tenant.yaml --wait=false >/dev/null
wait_for "the tenant's namespaces deleted" namespaces_gone
echo "OK: namespaces gone in $(( $(date +%s) - start ))s"
db_exists "$db" || fail "the database $db was dropped with the tenant"
echo "OK: $db is kept, with its data: marker = $(psql_admin "$db" "select x from marker")"

echo "--- re-create the tenant and hello in prod"
kubectl apply -f examples/tenant.yaml >/dev/null
kubectl wait --for=condition=Ready --timeout=180s -f examples/tenant.yaml >/dev/null
sed "s/namespace: demo-team-staging/namespace: $ns/" examples/app/app.yaml | kubectl apply -f - >/dev/null
kubectl wait "$xr/$app" -n "$ns" --for=condition=Ready --timeout=300s >/dev/null
url=$(kubectl get "$xr/$app" -n "$ns" -o jsonpath='{.status.url}')
body=$(curl -sS --fail --cacert .local-ca/ca.crt "$url/")
case "$body" in *"\"database\":\"$db\""*) ;; *) fail "GET $url/ -> $body" ;; esac
[ "$(psql_admin "$db" "select x from marker")" = 42 ] || fail "the marker is gone"
echo "OK: hello adopted $db again, data included, and reaches it: $body"

echo "--- clean up: confirm, then delete hello in prod"
kubectl annotate "$xr/$app" -n "$ns" "$annotation=*" --overwrite >/dev/null
wait_for "Delete reaching hello-db" deletes "$ns" hello-db
kubectl delete "$xr/$app" -n "$ns" --cascade=foreground --timeout=180s >/dev/null
wait_for "the database $db dropped" db_gone "$db"
echo "OK: hello and $db dropped"
