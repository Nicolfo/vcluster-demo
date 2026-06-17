#!/usr/bin/env bash
# Install Argo CD into the cluster pointed at by the current KUBECONFIG, with its
# public ingress host and the Cloudflare tunnel target filled in.
#
# Normally invoked per-vcluster by scripts/11-install-platform.sh (which runs it
# under `vcluster connect ... --`, so KUBECONFIG already points at the vcluster).
# You can also run it standalone against any kube-context:
#   APP_HOST=ec-00-argocd.ff26.it TUNNEL_CNAME=<id>.cfargotunnel.com \
#     ./platform/argocd/install.sh
#
# Required env:
#   APP_HOST      public hostname for the Argo CD UI (e.g. ec-00-argocd.ff26.it)
#   TUNNEL_CNAME  <tunnel-id>.cfargotunnel.com
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

: "${APP_HOST:?set APP_HOST (e.g. ec-00-argocd.ff26.it)}"
: "${TUNNEL_CNAME:?set TUNNEL_CNAME (e.g. <tunnel-id>.cfargotunnel.com)}"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

# Render the values template (only the two placeholders, leave everything else).
values="$(mktemp)"; trap 'rm -f "$values"' EXIT
APP_HOST="$APP_HOST" TUNNEL_CNAME="$TUNNEL_CNAME" \
  envsubst '${APP_HOST} ${TUNNEL_CNAME}' < "$here/values.yaml" > "$values"

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  -f "$values"
