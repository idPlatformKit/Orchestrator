#!/usr/bin/env bash
# Renders a template from local/ for this installation:
#   __LOCAL_CA__        (alone on its line) -> the local CA certificate,
#                       indented like the placeholder
#   __IDPK_GITHUB_ORG__ -> the installation's GitHub org
# Usage: scripts/render.sh <template> <output>
set -euo pipefail
template=$1 output=$2
ca=${LOCAL_CA_DIR:-.local-ca}/ca.crt
[ -f "$ca" ] || { echo "No local CA in $ca: run make local-ca" >&2; exit 1; }
mkdir -p "$(dirname "$output")"
awk -v ca="$ca" '
	/^[[:space:]]*__LOCAL_CA__[[:space:]]*$/ {
		match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
		while ((getline line < ca) > 0) print indent line
		close(ca); next
	}
	{ print }
' "$template" | sed "s|__IDPK_GITHUB_ORG__|${IDPK_GITHUB_ORG:-}|g" > "$output"
