#!/usr/bin/env bash
# Install Harbor (container/OCI registry) into the sa4 cluster, exposed at
# https://${HARBOR_HOST} via Traefik with a Let's Encrypt certificate issued by
# the cert-manager ClusterIssuer "letsencrypt" (both already present on sa4).
#
# Prereqs (already satisfied on sa4):
#   - IngressClass "traefik"
#   - ClusterIssuer "letsencrypt" (HTTP-01 over traefik)
#   - DNS: HARBOR_HOST must already resolve to sa4's Traefik (51.89.21.199) so
#     the ACME HTTP-01 challenge can complete.
#
# Usage:
#   ./registry/install.sh
#   HARBOR_ADMIN_PASSWORD='s3cret' ./registry/install.sh
#
# Env:
#   KUBE_CONTEXT           kube-context to install into (default: sa4)
#   HARBOR_HOST            public hostname (default: registry.ff26.it)
#   HARBOR_ADMIN_PASSWORD  initial 'admin' password (default: Harbor12345)
#   NAMESPACE              target namespace (default: harbor)
#   CHART_VERSION          harbor/harbor chart version (default: 1.19.1)
#
# NOTE: chart 1.3.2 (artifacthub link, appVersion 1.10.2) renders an
# extensions/v1beta1 Ingress, removed in k8s v1.22 -- it cannot install on sa4
# (v1.34). We pin the current chart 1.19.1 (Harbor 2.15.1), which emits a
# networking.k8s.io/v1 Ingress with a real ingressClassName.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

KUBE_CONTEXT="${KUBE_CONTEXT:-sa4}"
HARBOR_HOST="${HARBOR_HOST:-registry.ff26.it}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
NAMESPACE="${NAMESPACE:-harbor}"
CHART_VERSION="${CHART_VERSION:-1.19.1}"

helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo update harbor >/dev/null

# Render the values template (only the two placeholders, leave everything else).
values="$(mktemp)"; trap 'rm -f "$values"' EXIT
HARBOR_HOST="$HARBOR_HOST" HARBOR_ADMIN_PASSWORD="$HARBOR_ADMIN_PASSWORD" \
  envsubst '${HARBOR_HOST} ${HARBOR_ADMIN_PASSWORD}' < "$here/values.yaml" > "$values"

helm upgrade --install harbor harbor/harbor \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$CHART_VERSION" \
  -f "$values"
