#!/usr/bin/env bash
# Expose a vcluster's API through Traefik at a public hostname, by generating and
# applying an IngressRoute (+ ServersTransport for the self-signed backend).
#
# Usage: ./scripts/07-expose-ingress.sh <name> <hostname> [namespace]
#   e.g. ./scripts/07-expose-ingress.sh ec-03 ec-03.nicolfo.it
#
# Set APPLY=0 to only print the manifest (don't apply).
# Set OUT=<file> to also write the manifest to disk.
#
# NOTE: you still need a Cloudflare tunnel route + DNS for <hostname> pointing at
#       https://traefik.ingress.svc.cluster.local:443 (see docs/remote-access-via-ingress.md).
set -euo pipefail

NAME="${1:?usage: 07-expose-ingress.sh <name> <hostname> [namespace]}"
HOSTNAME_="${2:?missing hostname}"
NAMESPACE="${3:-vcluster-${NAME}}"
HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
ENTRYPOINT="${ENTRYPOINT:-websecure}"

manifest="$(cat <<YAML
---
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: ${NAME}-backend
  namespace: ${NAMESPACE}
spec:
  insecureSkipVerify: true
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: ${NAME}-api
  namespace: ${NAMESPACE}
spec:
  entryPoints:
    - ${ENTRYPOINT}
  routes:
    - match: Host(\`${HOSTNAME_}\`)
      kind: Rule
      services:
        - name: ${NAME}
          port: 443
          scheme: https
          serversTransport: ${NAME}-backend
  tls: {}
YAML
)"

[[ -n "${OUT:-}" ]] && { printf '%s\n' "$manifest" > "$OUT"; echo ">> wrote $OUT"; }

if [[ "${APPLY:-1}" == "1" ]]; then
  printf '%s\n' "$manifest" | kubectl --context "$HOST_CONTEXT" apply -f -
  echo ">> exposed ${NAME} at https://${HOSTNAME_} (via Traefik ${ENTRYPOINT})"
else
  printf '%s\n' "$manifest"
fi
