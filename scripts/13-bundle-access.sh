#!/usr/bin/env bash
# Build one self-contained access ZIP per kubeconfig in kubeconfigs/.
#
# Each ZIP (bundles/<vc>-access.zip) contains:
#   - the kubeconfig itself (cluster-admin inside that vcluster)
#   - INSTRUCTIONS.md: how to connect to the cluster, Argo CD URL + credentials,
#     and the Harbor registry URL + the tenant's own username/password.
#
# To make the registry credentials actually work, the script PROVISIONS Harbor
# for each tenant <vc> (e.g. ec-00) via the Harbor API:
#   - a PRIVATE project named <vc>
#   - a user named <vc> with a freshly generated random password
#   - that user added as Developer of project <vc> ONLY
# so each tenant can push/pull just registry.ff26.it/<vc>/*  and nothing else.
#
# Re-running rotates the Harbor passwords and rebuilds every ZIP.
#
# Env (all have defaults):
#   DOMAIN                 zone the apps live under         (default: ff26.it)
#   HARBOR_URL             Harbor base URL                  (default: https://registry.ff26.it)
#   HARBOR_ADMIN_USER      Harbor admin user                (default: admin)
#   HARBOR_ADMIN_PASSWORD  Harbor admin password            (default: Harbor12345)
#   KUBECONFIG_DIR         where the kubeconfigs are        (default: <repo>/kubeconfigs)
#   OUT_DIR                where to write the ZIPs          (default: <repo>/bundles)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

DOMAIN="${DOMAIN:-ff26.it}"
HARBOR_URL="${HARBOR_URL:-https://registry.ff26.it}"
HARBOR_ADMIN_USER="${HARBOR_ADMIN_USER:-admin}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
KUBECONFIG_DIR="${KUBECONFIG_DIR:-$repo/kubeconfigs}"
OUT_DIR="${OUT_DIR:-$repo/bundles}"

AUTH="$HARBOR_ADMIN_USER:$HARBOR_ADMIN_PASSWORD"
API="$HARBOR_URL/api/v2.0"

# --- tiny Harbor API helpers -------------------------------------------------
# Echo the HTTP status code; leave the response body in $RESP_FILE (read via `body`).
RESP_FILE="$(mktemp)"; trap 'rm -f "$RESP_FILE"' EXIT
api() { # METHOD PATH [JSON]
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sk -u "$AUTH" -o "$RESP_FILE" -w '%{http_code}' \
      -X "$method" -H 'Content-Type: application/json' -H 'X-Is-Resource-Name: true' \
      -d "$data" "$API$path"
  else
    curl -sk -u "$AUTH" -o "$RESP_FILE" -w '%{http_code}' \
      -X "$method" -H 'X-Is-Resource-Name: true' "$API$path"
  fi
}
body() { cat "$RESP_FILE"; }

gen_password() {
  # >=8 chars with upper+lower+digit (Harbor policy). "Tm" + 12 hex + "9X".
  echo "Tm$(openssl rand -hex 6)9X"
}

harbor_provision() { # <vc> <password>  -> ensures project, user (pw reset), membership
  local vc="$1" pw="$2" code uid
  # 1) private project
  code="$(api POST /projects "{\"project_name\":\"$vc\",\"metadata\":{\"public\":\"false\"}}")"
  [[ "$code" =~ ^(201|409)$ ]] || { echo "      ! project create HTTP $code: $(body)" >&2; return 1; }
  # 2) user (create; if it exists, reset its password)
  code="$(api POST /users "{\"username\":\"$vc\",\"password\":\"$pw\",\"realname\":\"$vc\",\"email\":\"$vc@$DOMAIN\",\"comment\":\"vcluster tenant\"}")"
  if [[ "$code" == 409 ]]; then
    api GET "/users/search?username=$vc" >/dev/null
    uid="$(body | jq -r '.[0].user_id')"
    code="$(api PUT "/users/$uid/password" "{\"new_password\":\"$pw\"}")"
    [[ "$code" == 200 ]] || echo "      ! password reset for existing user '$vc' HTTP $code: $(body)" >&2
  elif [[ "$code" != 201 ]]; then
    echo "      ! user create HTTP $code: $(body)" >&2; return 1
  fi
  # 3) membership: Developer (role_id 2) on their own project only
  code="$(api POST "/projects/$vc/members" "{\"role_id\":2,\"member_user\":{\"username\":\"$vc\"}}")"
  [[ "$code" =~ ^(201|409)$ ]] || echo "      ! add member '$vc' HTTP $code: $(body)" >&2
}

# --- preflight ---------------------------------------------------------------
shopt -s nullglob
kubeconfigs=("$KUBECONFIG_DIR"/kubeconfig-*.yaml)
[[ ${#kubeconfigs[@]} -gt 0 ]] || { echo "no kubeconfigs in $KUBECONFIG_DIR"; exit 1; }

# /users/current requires auth (unlike /projects or /systeminfo, which allow
# anonymous read), so it actually validates the admin credentials.
code="$(api GET /users/current)"
[[ "$code" == 200 ]] || { echo "Harbor admin auth failed at $API (HTTP $code). Check HARBOR_ADMIN_PASSWORD." >&2; exit 1; }
[[ "$(body | jq -r '.sysadmin_flag')" == true ]] || { echo "Harbor user '$HARBOR_ADMIN_USER' is not a system admin." >&2; exit 1; }

mkdir -p "$OUT_DIR"
echo "Building access bundles -> $OUT_DIR"

for kc in "${kubeconfigs[@]}"; do
  base="$(basename "$kc")"                 # kubeconfig-ec-00.yaml
  vc="${base#kubeconfig-}"; vc="${vc%.yaml}"  # ec-00
  argocd_url="https://${vc}-argocd.${DOMAIN}"
  echo " - $vc"

  # Argo CD initial admin password (lives inside the vcluster's argocd ns)
  argocd_pw="$(kubectl --kubeconfig "$kc" get secret argocd-initial-admin-secret \
      -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "$argocd_pw" ]] || argocd_pw="(not found — fetch with: kubectl --kubeconfig $base get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)"

  # Harbor: generate password + provision project/user/membership
  harbor_pw="$(gen_password)"
  harbor_provision "$vc" "$harbor_pw"

  # Stage the bundle
  stage="$(mktemp -d)"
  cp "$kc" "$stage/$base"
  cat > "$stage/INSTRUCTIONS.md" <<EOF
# Access bundle — ${vc}

This archive contains everything you need for your dedicated environment.

Files:
  - ${base}        your Kubernetes credentials (cluster-admin inside your vcluster)
  - INSTRUCTIONS.md  this file

================================================================
1. Kubernetes cluster
================================================================
API endpoint: https://${vc}.${DOMAIN}
The kubeconfig grants cluster-admin INSIDE your virtual cluster only
(no access to the host or to other tenants).

  export KUBECONFIG="\$PWD/${base}"
  kubectl get ns
  kubectl get pods -A

(The token is time-limited — ask the platform owner to re-issue if it expires.)

================================================================
2. Argo CD  (GitOps UI)
================================================================
URL:      ${argocd_url}
Username: admin
Password: ${argocd_pw}

Please change this password after first login.

================================================================
3. Container registry  (Harbor)
================================================================
URL:      ${HARBOR_URL}
Username: ${vc}
Password: ${harbor_pw}

You can ONLY access your own project:  ${HARBOR_URL#https://}/${vc}/*
(Image names MUST start with "${vc}/" — other projects are private to their owners.)

Push an image:
  docker login ${HARBOR_URL#https://} -u ${vc}
  docker tag  myapp:latest ${HARBOR_URL#https://}/${vc}/myapp:latest
  docker push ${HARBOR_URL#https://}/${vc}/myapp:latest

Pull it back:
  docker pull ${HARBOR_URL#https://}/${vc}/myapp:latest

Use it from Kubernetes (create an image pull secret, then reference it):
  kubectl create secret docker-registry harbor \\
    --docker-server=${HARBOR_URL#https://} \\
    --docker-username=${vc} \\
    --docker-password='${harbor_pw}'
  # pod spec:  imagePullSecrets: [{ name: harbor }]
EOF

  out="$OUT_DIR/${vc}-access.zip"
  rm -f "$out"
  ( cd "$stage" && zip -q "$out" "$base" INSTRUCTIONS.md )
  rm -rf "$stage"
  echo "      -> $out"
done

echo "Done. ${#kubeconfigs[@]} bundle(s) in $OUT_DIR (they contain live credentials — do not commit)."
