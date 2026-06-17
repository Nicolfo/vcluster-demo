#!/usr/bin/env bash
# Ensure proxied Cloudflare CNAMEs  <host> -> <tunnel>.cfargotunnel.com  using a
# Cloudflare API TOKEN (Zone:DNS:Edit), NOT the cloudflared `cert.pem`.
#
# Why: `cloudflared tunnel route dns` authenticates with ~/.cloudflared/cert.pem,
# which is only valid for the zone you ran `cloudflared tunnel login` against.
# A freshly chosen domain (different zone/account) fails there with
# "code: 10000 Authentication error" even when your API token is perfectly valid.
# This script uses the same token External-DNS uses, so it works for any zone the
# token is authorized for. Idempotent: updates the record if it already exists.
#
# Usage:
#   CF_API_TOKEN=xxx DOMAIN=ff26.it TUNNEL_ID=... ./scripts/09-route-dns.sh <host> [host2 ...]
# If CF_API_TOKEN is unset, it is read from the external-dns secret on the host.
set -euo pipefail

DOMAIN="${DOMAIN:?set DOMAIN (the Cloudflare zone), e.g. ff26.it}"
TUNNEL_ID="${TUNNEL_ID:-82051912-b874-49e9-955b-7a73552b75bc}"
TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"
HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"

TOKEN="${CF_API_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(kubectl --context "$HOST_CONTEXT" -n external-dns get secret cloudflare-api-token \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
fi
[[ -z "$TOKEN" ]] && { echo "!! no Cloudflare API token (set CF_API_TOKEN)" >&2; exit 1; }

api() { curl -fsS -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" "$@"; }

# Extract the first 32-hex id from JSON on stdin. The `|| true` is essential: a
# no-match grep exits 1, which under `set -e`+`pipefail` would otherwise abort the
# whole script before we can act on (or report) the empty result.
first_id() { grep -o '"id":"[0-9a-f]\{32\}"' | head -n1 | cut -d'"' -f4 || true; }

zresp="$(api "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}")" \
  || { echo "!! Cloudflare API error querying zone '${DOMAIN}' (token lacks Zone:Read, or network)" >&2; exit 1; }
ZID="$(printf '%s' "$zresp" | first_id)"
[[ -z "$ZID" ]] && { echo "!! zone '${DOMAIN}' not found, or token not authorized for it" >&2; exit 1; }

for host in "$@"; do
  body="{\"type\":\"CNAME\",\"name\":\"${host}\",\"content\":\"${TUNNEL_CNAME}\",\"proxied\":true}"
  rresp="$(api "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records?type=CNAME&name=${host}")" \
    || { echo "!! API error looking up ${host}" >&2; exit 1; }
  rid="$(printf '%s' "$rresp" | first_id)"
  if [[ -n "$rid" ]]; then
    api -X PUT "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records/${rid}" --data "$body" >/dev/null \
      || { echo "!! failed to update ${host}" >&2; exit 1; }
    echo "  updated ${host} -> ${TUNNEL_CNAME} (proxied)"
  else
    api -X POST "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records" --data "$body" >/dev/null \
      || { echo "!! failed to create ${host}" >&2; exit 1; }
    echo "  created ${host} -> ${TUNNEL_CNAME} (proxied)"
  fi
done
