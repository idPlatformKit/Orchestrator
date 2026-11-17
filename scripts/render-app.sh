#!/usr/bin/env bash
# Renders examples/app/app.yaml with the App function built from
# functions/app, without a cluster: crossplane render against the function
# running locally. ENV=prod renders it in a prod namespace; DB_READY=false
# renders it before its database is ready. Needs Go and the crossplane CLI.
set -euo pipefail

env=${ENV:-staging}
fn=functions/app
tmp=$(mktemp -d)
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

(cd "$fn" && go build -o "$tmp/function-app" .)
"$tmp/function-app" --insecure --address=localhost:9443 &
pid=$!
sleep 1

sed "s/namespace: demo-team-staging/namespace: demo-team-$env/" examples/app/app.yaml > "$tmp/app.yaml"
observed=()
if [ "${DB_READY:-true}" = true ]; then
  observed=(-o "$fn/testdata/observed-db-ready-$env.yaml")
fi
crossplane render "$tmp/app.yaml" compositions/app/composition.yaml "$fn/testdata/functions.yaml" \
  -e "$fn/testdata/namespace-$env.yaml" "${observed[@]}" -r
