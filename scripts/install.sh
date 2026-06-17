#!/usr/bin/env bash
# One-shot installer for the whole vcluster public-access stack:
#   - vcluster CLI (if missing)
#   - N virtual clusters <prefix>-00 .. <prefix>-(N-1)
#   - the dedicated, locally-managed cloudflared connector (reuses an existing tunnel)
#   - External-DNS (Cloudflare), scoped to your DOMAIN and pointing at the tunnel
#   - per-vcluster API IngressRoute + DNS route + a ready-to-share kubeconfig
#   - platform apps (everything under platform/<app>/) installed in each vcluster
#
# It asks for the two things that MUST be provided:
#   1. the DOMAIN to publish under (e.g. example.com)
#   2. the Cloudflare API token for External-DNS (Zone:DNS:Edit on that domain)
# Everything else has a sensible default (just press Enter), and any prompt can be
# pre-set via an env var of the same name for non-interactive runs.
#
# The Cloudflare *tunnel* is reused, not recreated: by default the existing
# "vcluster" tunnel (82051912…) and its local credentials file are used, matching
# the "suppose the tunnel token is the one you already have" assumption.
#
# Usage:
#   ./scripts/install.sh                      # interactive
#   DOMAIN=example.com CF_API_TOKEN=xxx ./scripts/install.sh   # non-interactive
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# ---- prompt helper: ask VAR "label" "default" [secret] -----------------------
ask() {
  local var="$1" label="$2" def="${3:-}" secret="${4:-}" cur="${!1:-}" ans
  [[ -n "$cur" ]] && { echo ">> ${label}: (from env)"; return; }   # already set via env
  if [[ "$secret" == "secret" ]]; then
    read -rsp "${label}: " ans; echo
  else
    read -rp "${label}$( [[ -n "$def" ]] && echo " [${def}]" ): " ans
  fi
  printf -v "$var" '%s' "${ans:-$def}"
}

echo "=== vcluster public-access installer ==="

# --- the two required answers ---
ask DOMAIN       "Domain to publish under (e.g. example.com)" "nicolfo.it"
ask CF_API_TOKEN "Cloudflare API token (Zone:DNS:Edit on ${DOMAIN})" "" secret
[[ -z "${CF_API_TOKEN}" ]] && { echo "!! a Cloudflare API token is required" >&2; exit 1; }

# --- everything else: defaults, press Enter to accept ---
ask HOST_CONTEXT "Host kube-context"                    "xeon-local"
ask TUNNEL_ID    "Existing Cloudflare tunnel ID to reuse" "82051912-b874-49e9-955b-7a73552b75bc"
ask CRED_FILE    "Tunnel credentials JSON file"          "$HOME/.cloudflared/${TUNNEL_ID}.json"
ask PREFIX       "vcluster name prefix"                  "ec"
ask COUNT        "how many vclusters"                    "10"
ask TTL          "kubeconfig token TTL (seconds)"        "86400"
ask INSTALL_PLATFORM "install platform apps in each vcluster (1/0)" "1"

TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"
export HOST_CONTEXT
K="kubectl --context ${HOST_CONTEXT}"

echo
echo ">> Plan: ${COUNT}x ${PREFIX}-NN under *.${DOMAIN}, tunnel ${TUNNEL_ID}, context ${HOST_CONTEXT}"
[[ -f "$CRED_FILE" ]] || echo "!! warning: ${CRED_FILE} not found — the connector step will try the in-cluster secret instead"
echo

# 1) vcluster CLI -------------------------------------------------------------
if ! command -v vcluster >/dev/null 2>&1; then
  echo ">> [1/7] Installing vcluster CLI"
  "$here/00-install-cli.sh"
else
  echo ">> [1/7] vcluster CLI present ($(vcluster version 2>/dev/null | head -1))"
fi

# 2) the virtual clusters -----------------------------------------------------
echo ">> [2/7] Creating ${COUNT} vclusters"
"$here/06-create-many.sh" "$PREFIX" "$COUNT"

# 3) dedicated cloudflared connector (reusing the tunnel) ---------------------
echo ">> [3/7] Deploying cloudflared connector (tunnel ${TUNNEL_ID})"
TUNNEL_ID="$TUNNEL_ID" CRED_FILE="$CRED_FILE" "$here/../cloudflared/deploy-dedicated-connector.sh"

# 4) External-DNS -------------------------------------------------------------
echo ">> [4/7] Deploying External-DNS for ${DOMAIN}"
CF_API_TOKEN="$CF_API_TOKEN" DOMAIN="$DOMAIN" TUNNEL_CNAME="$TUNNEL_CNAME" \
  "$here/08-deploy-external-dns.sh"

# 5) tenant-isolation admission policy (host API server, no Kyverno) ----------
echo ">> [5/7] Applying tenant Ingress isolation policy"
DOMAIN="$DOMAIN" "$here/10-tenant-isolation.sh"

# 6) per-vcluster: API IngressRoute + DNS route + kubeconfig ------------------
echo ">> [6/7] Exposing each vcluster API + minting kubeconfigs"
mkdir -p "$here/../ingress" "$here/../kubeconfigs"
failed=()
platform_failed=()
for i in $(seq 0 $((COUNT - 1))); do
  n="$(printf "%s-%02d" "$PREFIX" "$i")"
  host="${n}.${DOMAIN}"                       # one label deep -> Universal SSL covers it
  echo "   - ${n}: ${host}"
  # A single vcluster's failure must not abort the rest of the fleet.
  if ! (
    set -e
    OUT="$here/../ingress/${n}-ingressroute.yaml" \
      "$here/07-expose-ingress.sh" "$n" "$host" >/dev/null
    CF_API_TOKEN="$CF_API_TOKEN" DOMAIN="$DOMAIN" TUNNEL_ID="$TUNNEL_ID" \
      "$here/09-route-dns.sh" "$host" >/dev/null
    SERVER="https://${host}" CLUSTER_ROLE=cluster-admin TTL="$TTL" PUBLIC_TLS=1 \
      "$here/03-grant-access.sh" "$n" "vcluster-${n}" "$here/../kubeconfigs/kubeconfig-${n}.yaml" >/dev/null
  ); then
    echo "     !! ${n} failed — skipping"; failed+=("$n"); continue
  fi

  # 7) platform apps inside this vcluster (best-effort: a platform failure must
  #    not invalidate an otherwise-working vcluster). Skipped if INSTALL_PLATFORM=0.
  if [[ "${INSTALL_PLATFORM:-1}" == "1" ]]; then
    echo "   >> [7/7] ${n}: installing platform apps"
    if ! DOMAIN="$DOMAIN" TUNNEL_ID="$TUNNEL_ID" HOST_CONTEXT="$HOST_CONTEXT" \
         "$here/11-install-platform.sh" "$n"; then
      echo "     !! ${n}: platform install had errors"; platform_failed+=("$n")
    fi
  fi
done
[[ ${#failed[@]} -gt 0 ]] && echo ">> WARNING: failed vclusters: ${failed[*]}"
[[ ${#platform_failed[@]} -gt 0 ]] && echo ">> WARNING: platform install issues on: ${platform_failed[*]}"

echo
echo ">> Done. Verify e.g.:  kubectl --kubeconfig kubeconfigs/kubeconfig-${PREFIX}-00.yaml get ns"
echo ">> Tenant apps: apply an Ingress (class traefik, host <vc>-<app>.${DOMAIN}) — see examples/tenant-app-ingress.yaml"
[[ "${INSTALL_PLATFORM:-1}" == "1" ]] && \
  echo ">> Platform apps installed per vcluster, e.g. Argo CD at  https://${PREFIX}-00-argocd.${DOMAIN}  (admin pw: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
