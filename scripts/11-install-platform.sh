#!/usr/bin/env bash
# Install every platform app into a single vcluster.
#
# A "platform app" is any directory under platform/ that has an install.sh, e.g.
#   platform/argocd/install.sh
# For each app we run that install.sh *inside* the vcluster (via `vcluster
# connect ... --`, which points KUBECONFIG at the vcluster), passing:
#   APP_NAME      the directory name (e.g. argocd)
#   APP_HOST      <vc>-<app>.<DOMAIN>  -- one label deep, covered by Universal SSL
#   TUNNEL_CNAME  <tunnel-id>.cfargotunnel.com
# The app's manifests carry the external-dns target annotation, so the host
# External-DNS creates the proxied CNAME for APP_HOST automatically.
#
# Usage: ./scripts/11-install-platform.sh <vc-name> [namespace]
#   e.g. ./scripts/11-install-platform.sh ec-00
#
# Env:
#   DOMAIN        zone to publish under (required), e.g. ff26.it
#   TUNNEL_ID     tunnel whose CNAME the records point at (default: the vcluster tunnel)
#   TUNNEL_CNAME  overrides TUNNEL_ID-derived value if set
#   HOST_CONTEXT  host kube-context (default: xeon-local)
#   PLATFORM_DIR  where the apps live (default: <repo>/platform)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

NAME="${1:?usage: 11-install-platform.sh <vc-name> [namespace]}"
NAMESPACE="${2:-vcluster-${NAME}}"
DOMAIN="${DOMAIN:?set DOMAIN (the Cloudflare zone), e.g. ff26.it}"
HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
TUNNEL_ID="${TUNNEL_ID:-82051912-b874-49e9-955b-7a73552b75bc}"
TUNNEL_CNAME="${TUNNEL_CNAME:-${TUNNEL_ID}.cfargotunnel.com}"
PLATFORM_DIR="${PLATFORM_DIR:-$here/../platform}"

shopt -s nullglob
apps=("$PLATFORM_DIR"/*/install.sh)
if [[ ${#apps[@]} -eq 0 ]]; then
  echo "   (no platform apps found in ${PLATFORM_DIR})"; exit 0
fi

for app_install in "${apps[@]}"; do
  app="$(basename "$(dirname "$app_install")")"
  app_host="${NAME}-${app}.${DOMAIN}"
  echo "   - [${NAME}] platform app '${app}' -> https://${app_host}"
  vcluster connect "$NAME" --namespace "$NAMESPACE" --context "$HOST_CONTEXT" -- \
    env APP_NAME="$app" APP_HOST="$app_host" TUNNEL_CNAME="$TUNNEL_CNAME" \
        bash "$app_install"
done
