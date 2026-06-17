#!/usr/bin/env bash
# Deploy a dedicated, LOCALLY-MANAGED cloudflared connector for the vcluster
# tunnel, fully isolated from the production tunnel (f7f3c592).
#
# Locally-managed tunnels honor config.yml (unlike the dashboard tunnel), so the
# catch-all -> Traefik (with noTLSVerify) works and tenant apps auto-publish.
#
# Reuses the existing d163a3f6 credentials already in the cluster
# (secret cloudflared/cloudflare-tunnel-credentials). Override TUNNEL_ID /
# CREDS_* to use a freshly created tunnel instead.
#
# Usage: ./cloudflared/deploy-dedicated-connector.sh
set -euo pipefail

HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
NS="${NS:-cloudflared-vcluster}"
# Locally-managed tunnel "vcluster" created via `cloudflared tunnel create`.
TUNNEL_ID="${TUNNEL_ID:-82051912-b874-49e9-955b-7a73552b75bc}"
# Source of the credentials JSON: a local file (CRED_FILE) OR an existing secret.
CRED_FILE="${CRED_FILE:-$HOME/.cloudflared/${TUNNEL_ID}.json}"
SRC_NS="${SRC_NS:-cloudflared}"
SRC_SECRET="${SRC_SECRET:-cloudflare-tunnel-credentials}"
K="kubectl --context $HOST_CONTEXT"

echo ">> Namespace $NS"
$K create namespace "$NS" --dry-run=client -o yaml | $K apply -f -

if [[ -f "$CRED_FILE" ]]; then
  echo ">> Using credentials file $CRED_FILE"
  SRCFILE="$CRED_FILE"
else
  echo ">> Copying credentials from $SRC_NS/$SRC_SECRET (key ${TUNNEL_ID}.json)"
  CRED="$($K -n "$SRC_NS" get secret "$SRC_SECRET" -o jsonpath="{.data.${TUNNEL_ID}\.json}" | base64 -d)"
  [[ -n "$CRED" ]] || { echo "!! no credentials for $TUNNEL_ID (file or secret)" >&2; exit 1; }
  printf '%s' "$CRED" > "/tmp/${TUNNEL_ID}.json"; SRCFILE="/tmp/${TUNNEL_ID}.json"
fi
$K -n "$NS" create secret generic tunnel-creds \
  --from-file="${TUNNEL_ID}.json=$SRCFILE" \
  --dry-run=client -o yaml | $K apply -f -
[[ "$SRCFILE" == /tmp/* ]] && rm -f "$SRCFILE"

echo ">> ConfigMap (config.yml: catch-all -> Traefik, noTLSVerify)"
cat > /tmp/vc-config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/creds/${TUNNEL_ID}.json
no-autoupdate: true

ingress:
  # Single catch-all -> Traefik. Traefik routes by Host: the ec-0X API
  # IngressRoutes and synced tenant-app Ingresses. noTLSVerify because Traefik
  # serves a self-signed cert on :443 (the public hop is TLS-verified by Cloudflare).
  - service: https://traefik.ingress.svc.cluster.local:443
    originRequest:
      noTLSVerify: true
EOF
$K -n "$NS" create configmap tunnel-config --from-file=config.yml=/tmp/vc-config.yml \
  --dry-run=client -o yaml | $K apply -f -
rm -f /tmp/vc-config.yml

echo ">> Deployment cloudflared-vcluster"
cat <<EOF | $K apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared-vcluster
  namespace: ${NS}
  labels: { app: cloudflared-vcluster }
spec:
  replicas: 1
  selector: { matchLabels: { app: cloudflared-vcluster } }
  template:
    metadata: { labels: { app: cloudflared-vcluster } }
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args: ["tunnel","--config","/etc/cloudflared/config.yml","--metrics","0.0.0.0:2000","--no-autoupdate","run"]
          livenessProbe: { httpGet: { path: /ready, port: 2000 }, initialDelaySeconds: 10, periodSeconds: 10 }
          volumeMounts:
            - { name: config, mountPath: /etc/cloudflared }
            - { name: creds,  mountPath: /etc/cloudflared/creds }
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { memory: 128Mi } }
      volumes:
        - name: config
          configMap: { name: tunnel-config, items: [{ key: config.yml, path: config.yml }] }
        - name: creds
          secret: { secretName: tunnel-creds }
EOF

$K -n "$NS" rollout status deploy/cloudflared-vcluster --timeout=120s || true
echo ">> Logs (look for 'Registered tunnel connection'):"
sleep 5
$K -n "$NS" logs deploy/cloudflared-vcluster --tail=20 | grep -iE "Registered tunnel connection|ERR|error|not found|config" | tail -8
