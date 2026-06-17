#!/usr/bin/env bash
# Deploy External-DNS on the host cluster so vcluster-synced Ingresses get a
# Cloudflare CNAME (proxied, -> the tunnel) created automatically.
#
# Usage:
#   CF_API_TOKEN=xxxxx DOMAIN=example.com ./scripts/08-deploy-external-dns.sh
# or, if you'd rather be prompted (token not echoed):
#   ./scripts/08-deploy-external-dns.sh
#
# Env:
#   DOMAIN        zone External-DNS is allowed to edit       (default: nicolfo.it)
#   TUNNEL_CNAME  CNAME target every record points at        (default: the vcluster tunnel)
#   CF_API_TOKEN  Cloudflare token (Zone:DNS:Edit on DOMAIN). Prompted if unset; pass
#                 CF_API_TOKEN=- (or leave blank at the prompt) to keep an existing secret.
#
# See docs/external-dns.md for how to create the Cloudflare API token.
set -euo pipefail

HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
NS="external-dns"
DOMAIN="${DOMAIN:-nicolfo.it}"
TUNNEL_CNAME="${TUNNEL_CNAME:-82051912-b874-49e9-955b-7a73552b75bc.cfargotunnel.com}"
MANIFEST="$(dirname "$0")/../external-dns/external-dns.yaml"
K="kubectl --context $HOST_CONTEXT"

if [[ -z "${CF_API_TOKEN:-}" ]]; then
  read -rsp "Cloudflare API token (Zone:DNS:Edit on ${DOMAIN}) [blank=keep existing]: " CF_API_TOKEN; echo
fi

echo ">> Creating namespace ${NS}"
$K create namespace "$NS" --dry-run=client -o yaml | $K apply -f -

if [[ -n "${CF_API_TOKEN}" && "${CF_API_TOKEN}" != "-" ]]; then
  echo ">> Creating/updating secret cloudflare-api-token"
  $K -n "$NS" create secret generic cloudflare-api-token \
    --from-literal=token="$CF_API_TOKEN" \
    --dry-run=client -o yaml | $K apply -f -
else
  $K -n "$NS" get secret cloudflare-api-token >/dev/null 2>&1 \
    || { echo "!! no token provided and no existing secret cloudflare-api-token" >&2; exit 1; }
  echo ">> Keeping existing secret cloudflare-api-token"
fi

echo ">> Rendering + applying External-DNS manifest (domain=${DOMAIN}, target=${TUNNEL_CNAME})"
sed -e "s/nicolfo\.it/${DOMAIN}/g" \
    -e "s/82051912-b874-49e9-955b-7a73552b75bc\.cfargotunnel\.com/${TUNNEL_CNAME}/g" \
    "$MANIFEST" | $K apply -f -

echo ">> Waiting for rollout"
kubectl --context "$HOST_CONTEXT" -n "$NS" rollout status deploy/external-dns --timeout=120s

echo ">> Done. Follow logs with:"
echo "   kubectl -n ${NS} logs -f deploy/external-dns"
