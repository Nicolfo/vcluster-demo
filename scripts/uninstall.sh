#!/usr/bin/env bash
# Tear down the vcluster public-access stack created by install.sh.
#
# Removes (in this order):
#   - External-DNS (deployment + RBAC + namespace)
#   - the N virtual clusters and their namespaces
#   - the dedicated cloudflared connector (namespace cloudflared-vcluster)
#   - generated local files (kubeconfigs/, ingress/<prefix>-*.yaml)
#
# KEPT ON PURPOSE (so install.sh can reuse them):
#   - the Cloudflare tunnel itself and its credentials JSON (~/.cloudflared/<id>.json)
#   - the production tunnel / its connector namespace `cloudflared` (never touched)
#   - cert-manager and every other pre-existing namespace
#
# DNS records (the proxied CNAMEs pointing at the tunnel) are LEFT by default:
# they're harmless with the tunnel kept, and install.sh recreates them. To also
# delete every record that targets this tunnel, run with PURGE_DNS=1 (needs a
# Cloudflare token: env CF_API_TOKEN, else read from the external-dns secret).
#
# Env (all optional):
#   HOST_CONTEXT (xeon-local)  PREFIX (ec)  COUNT (10)
#   TUNNEL_ID (82051912…)      DOMAIN (nicolfo.it, only used by PURGE_DNS)
#   PURGE_DNS (0)              LOCAL_CLEAN (1)
#
# Usage: ./scripts/uninstall.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
PREFIX="${PREFIX:-ec}"
COUNT="${COUNT:-10}"
TUNNEL_ID="${TUNNEL_ID:-82051912-b874-49e9-955b-7a73552b75bc}"
DOMAIN="${DOMAIN:-nicolfo.it}"
PURGE_DNS="${PURGE_DNS:-0}"
LOCAL_CLEAN="${LOCAL_CLEAN:-1}"
TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"
K="kubectl --context ${HOST_CONTEXT}"

echo "=== vcluster public-access uninstaller (context ${HOST_CONTEXT}) ==="
echo ">> tunnel ${TUNNEL_ID} and its credentials will be KEPT for reuse"

# 0) optional: delete every Cloudflare DNS record that points at this tunnel ---
if [[ "$PURGE_DNS" == "1" ]]; then
  echo ">> [0] Purging DNS records targeting ${TUNNEL_CNAME} in zone ${DOMAIN}"
  TOKEN="${CF_API_TOKEN:-$($K -n external-dns get secret cloudflare-api-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)}"
  if [[ -z "$TOKEN" ]]; then
    echo "   !! no Cloudflare token available — skipping DNS purge"
  else
    api() { curl -fsS -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" "$@"; }
    ZID="$(api "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" | grep -o '"id":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)"
    if [[ -z "$ZID" ]]; then
      echo "   !! could not resolve zone id for ${DOMAIN} — skipping"
    else
      # CNAMEs whose content is the tunnel, plus the edns- TXT registry records.
      ids="$(api "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records?type=CNAME&content=${TUNNEL_CNAME}&per_page=500" \
              | grep -o '"id":"[0-9a-f]\{32\}"' | cut -d'"' -f4)"
      ids+=$'\n'"$(api "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records?type=TXT&per_page=500" \
              | tr '}' '\n' | grep 'edns-' | grep -o '"id":"[0-9a-f]\{32\}"' | cut -d'"' -f4)"
      n=0
      for id in $ids; do
        [[ -z "$id" ]] && continue
        api -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records/${id}" >/dev/null && n=$((n+1))
      done
      echo "   deleted ${n} DNS record(s)"
    fi
  fi
fi

# 1) External-DNS -------------------------------------------------------------
echo ">> [1] Removing External-DNS"
$K delete clusterrolebinding external-dns --ignore-not-found
$K delete clusterrole external-dns --ignore-not-found
$K delete namespace external-dns --ignore-not-found

# 2) the virtual clusters -----------------------------------------------------
echo ">> [2] Deleting ${COUNT} vclusters (${PREFIX}-00 .. ${PREFIX}-$(printf '%02d' $((COUNT-1))))"
for i in $(seq 0 $((COUNT - 1))); do
  n="$(printf "%s-%02d" "$PREFIX" "$i")"; ns="vcluster-${n}"
  if $K get ns "$ns" >/dev/null 2>&1; then
    echo "   - ${n}"
    vcluster delete "$n" --namespace "$ns" --context "$HOST_CONTEXT" >/dev/null 2>&1 || true
    $K delete namespace "$ns" --ignore-not-found >/dev/null 2>&1 || true
  fi
done

# 3) the dedicated connector (tunnel + creds kept) ----------------------------
echo ">> [3] Removing cloudflared connector (namespace cloudflared-vcluster)"
$K delete namespace cloudflared-vcluster --ignore-not-found

# 4) local files --------------------------------------------------------------
if [[ "$LOCAL_CLEAN" == "1" ]]; then
  echo ">> [4] Cleaning generated local files"
  rm -f "$here/../kubeconfigs/"*.yaml 2>/dev/null || true
  rm -f "$here/../ingress/${PREFIX}-"*.yaml 2>/dev/null || true
fi

echo
echo ">> Done. Tunnel ${TUNNEL_ID} + creds kept. Reinstall with: ./scripts/install.sh"
[[ "$PURGE_DNS" != "1" ]] && echo ">> DNS records left in place (harmless). To remove them: PURGE_DNS=1 ./scripts/uninstall.sh"
